import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import VideoToolbox

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private func skip(_ message: String) -> Never {
    print("SKIP: \(message)")
    exit(2)
}

#if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
@available(macOS 26.0, *)
private final class FrameInterpolatorGPUSuite {
    private enum InputMode {
        case ciFallback
        case ciFallbackFast
        case direct420v
        case fullRangeFallback
        case otherColorFallback
        case orientedFallback
        case cositedChromaFallback
    }
    private struct Case {
        let name: String
        let targetWidth: Int
        let targetHeight: Int
        let inputWidth: Int
        let inputHeight: Int
        let inputMode: InputMode
        let stopWhileInFlight: Bool
    }
    private enum Phase {
        case cancelledWarmup
        case waitingForCase(Int)
        case runningCase(Int)
        case done
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let interpolator: FrameInterpolator
    private let cases = [
        Case(name: "CI fallback resize warmup 1920x1080→1280x720", targetWidth: 1280, targetHeight: 720, inputWidth: 1920, inputHeight: 1080, inputMode: .ciFallback, stopWhileInFlight: false),
        Case(name: "CI fallback resize warmed 1920x1080→1280x720", targetWidth: 1280, targetHeight: 720, inputWidth: 1920, inputHeight: 1080, inputMode: .ciFallback, stopWhileInFlight: false),
        Case(name: "CI fast fallback nonzero-origin 1920x1080→640x360", targetWidth: 640, targetHeight: 360, inputWidth: 1920, inputHeight: 1080, inputMode: .ciFallbackFast, stopWhileInFlight: false),
        Case(name: "direct 420v resize 1920x1080→1280x720", targetWidth: 1280, targetHeight: 720, inputWidth: 1920, inputHeight: 1080, inputMode: .direct420v, stopWhileInFlight: false),
        Case(name: "full-range input falls back", targetWidth: 1280, targetHeight: 720, inputWidth: 1280, inputHeight: 720, inputMode: .fullRangeFallback, stopWhileInFlight: false),
        Case(name: "non-709 input falls back", targetWidth: 1280, targetHeight: 720, inputWidth: 1280, inputHeight: 720, inputMode: .otherColorFallback, stopWhileInFlight: false),
        Case(name: "non-up orientation falls back", targetWidth: 1280, targetHeight: 720, inputWidth: 1280, inputHeight: 720, inputMode: .orientedFallback, stopWhileInFlight: false),
        Case(name: "cosited chroma attachment falls back", targetWidth: 1280, targetHeight: 720, inputWidth: 1280, inputHeight: 720, inputMode: .cositedChromaFallback, stopWhileInFlight: false),
        Case(name: "CI fallback copy warmup 1920x1080", targetWidth: 1920, targetHeight: 1080, inputWidth: 1920, inputHeight: 1080, inputMode: .ciFallback, stopWhileInFlight: false),
        Case(name: "CI fallback copy warmed 1920x1080", targetWidth: 1920, targetHeight: 1080, inputWidth: 1920, inputHeight: 1080, inputMode: .ciFallback, stopWhileInFlight: false),
        Case(name: "direct 420v copy 1920x1080", targetWidth: 1920, targetHeight: 1080, inputWidth: 1920, inputHeight: 1080, inputMode: .direct420v, stopWhileInFlight: true)
    ]
    private var phase: Phase = .cancelledWarmup
    private var pollScheduled = false
    private var readyDeadline = 0.0
    private var failures: [String] = []

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
        interpolator = FrameInterpolator(device: device)
        interpolator.onStateChange = { [weak self] in self?.stateChanged() }
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        print("GPU: \(device.name)")
        print("Checking cancelled warmup and same-size rebuild…")
        readyDeadline = ProcessInfo.processInfo.systemUptime + 90
        interpolator.prepare(width: cases[0].targetWidth, height: cases[0].targetHeight)
        interpolator.stop()
        guard !interpolator.isReady else { fail("stop left a cancelled warmup ready") }
        // This request arrives while the cancelled worker may still be preparing. The
        // old generation must not publish; its state callback restarts this new request.
        interpolator.prepare(width: cases[0].targetWidth, height: cases[0].targetHeight)

        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { [weak self] in
            guard let self else { return }
            if case .done = self.phase { return }
            fail("overall GPU fixture timed out")
        }
    }

    private func stateChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        switch phase {
        case .cancelledWarmup:
            guard !interpolator.isReady else { fail("cancelled generation published a stale session") }
            print("PASS cancelled warmup was not published")
            phase = .waitingForCase(0)
            readyDeadline = ProcessInfo.processInfo.systemUptime + 90
            pollReadiness(for: 0)
        case .waitingForCase(let index):
            pollReadiness(for: index)
        case .runningCase, .done:
            break
        }
    }

    private func pollReadiness(for index: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .waitingForCase(let expected) = phase, expected == index else { return }
        let testCase = cases[index]
        if interpolator.isReady {
            phase = .runningCase(index)
            runCase(index)
            return
        }
        guard ProcessInfo.processInfo.systemUptime < readyDeadline else {
            fail("\(testCase.targetWidth)x\(testCase.targetHeight) session did not become ready for \(testCase.name)")
        }
        interpolator.prepare(width: testCase.targetWidth, height: testCase.targetHeight)
        guard !pollScheduled else { return }
        pollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.pollScheduled = false
            self.pollReadiness(for: index)
        }
    }

    private func runCase(_ index: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        let testCase = cases[index]
        let width = testCase.targetWidth, height = testCase.targetHeight
        let previous = makeFrame(width: testCase.inputWidth, height: testCase.inputHeight, blockCenterX: 0.32,
                                 originX: testCase.inputMode == .direct420v ? 0 : 23,
                                 originY: testCase.inputMode == .direct420v ? 0 : 37)
        let current = makeFrame(width: testCase.inputWidth, height: testCase.inputHeight, blockCenterX: 0.44,
                                originX: testCase.inputMode == .direct420v ? 0 : -19,
                                originY: testCase.inputMode == .direct420v ? 0 : 11)
        let inputBuffers = makeInputBuffers(for: testCase, previous: previous, current: current)
        let interpolationPrevious: CIImage
        let interpolationCurrent: CIImage
        if testCase.inputMode == .direct420v {
            // Black CI sentinels prove the eligible pixel-buffer route supplies the actual frames.
            let inputBounds = CGRect(x: 0, y: 0, width: testCase.inputWidth, height: testCase.inputHeight)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: inputBounds)
            interpolationPrevious = black
            interpolationCurrent = black
        } else {
            interpolationPrevious = previous
            interpolationCurrent = current
        }
        guard let command = queue.makeCommandBuffer() else { fail("could not create a Metal command buffer") }
        let stopGate: MTLSharedEvent?
        if testCase.stopWhileInFlight {
            guard let gate = device.makeSharedEvent() else { fail("could not create a shared event for the in-flight stop check") }
            stopGate = gate
            // Hold GPU execution before interpolation until stop() has retired the session.
            command.encodeWaitForEvent(gate, value: 1)
        } else {
            stopGate = nil
        }
        let encodeStarted = DispatchTime.now().uptimeNanoseconds
        guard let middle = interpolator.interpolate(
            previous: interpolationPrevious,
            current: interpolationCurrent,
            previousTime: CMTime(value: 0, timescale: 30),
            currentTime: CMTime(value: 1, timescale: 30),
            context: context,
            command: command,
            previousBuffer: inputBuffers?.0,
            currentBuffer: inputBuffers?.1,
            fastInputResampling: testCase.inputMode == .ciFallbackFast
        ) else { fail("interpolation encoding returned nil for \(testCase.name)") }
        let encodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - encodeStarted) / 1_000_000

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let previousTexture = makeReadbackTexture(width: width, height: height),
              let currentTexture = makeReadbackTexture(width: width, height: height),
              let middleTexture = makeReadbackTexture(width: width, height: height) else {
            fail("could not allocate RGBA readback textures at \(width)x\(height)")
        }
        context.render(normalized(previous, width: width, height: height), to: previousTexture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        context.render(normalized(current, width: width, height: height), to: currentTexture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        context.render(middle, to: middleTexture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)

        command.addCompletedHandler { [weak self, previous, current, middle, previousTexture, currentTexture, middleTexture, stopGate, inputBuffers, testCase] completed in
            withExtendedLifetime((previous, current, middle, stopGate, inputBuffers)) {}
            guard completed.status == .completed else {
                fail("Metal command failed for \(testCase.name): \(String(describing: completed.error))")
            }
            let previousPixels = Self.read(previousTexture, width: width, height: height)
            let currentPixels = Self.read(currentTexture, width: width, height: height)
            let middlePixels = Self.read(middleTexture, width: width, height: height)
            var caseFailures = Self.colorFailures(middlePixels, width: width, height: height)
            let previousDistance = Self.meanDifference(middlePixels, previousPixels, width: width, height: height)
            let currentDistance = Self.meanDifference(middlePixels, currentPixels, width: width, height: height)
            let previousCenter = Self.magentaCenterX(previousPixels, width: width, height: height)
            let currentCenter = Self.magentaCenterX(currentPixels, width: width, height: height)
            let middleCenter = Self.magentaCenterX(middlePixels, width: width, height: height)
            if previousDistance <= 0.001 || currentDistance <= 0.001 {
                caseFailures.append("midpoint readback did not differ from both endpoints: d=\(previousDistance),\(currentDistance)")
            }
            var centers = "patch centroid unavailable"
            if let previousCenter, let currentCenter, let middleCenter {
                let previousX = previousCenter / Double(width)
                let currentX = currentCenter / Double(width)
                let middleX = middleCenter / Double(width)
                centers = String(format: "center %.3f, endpoints %.3f / %.3f", middleX, previousX, currentX)
                if abs(previousX - 0.32) >= 0.05 || abs(currentX - 0.44) >= 0.05 {
                    caseFailures.append("nonzero-origin endpoint normalization failed: \(centers)")
                }
                let low = min(previousX, currentX)
                let high = max(previousX, currentX)
                let displacedFromBoth = min(abs(middleX - previousX), abs(middleX - currentX)) > 0.008
                if !(middleX > low - 0.03 && middleX < high + 0.03 && displacedFromBoth) {
                    caseFailures.append("moving patch readback matched an endpoint or left its motion corridor: \(centers)")
                }
            } else {
                caseFailures.append("magenta patch missing from one or more readbacks")
            }
            if caseFailures.isEmpty {
                let gpuMilliseconds = completed.gpuEndTime > completed.gpuStartTime
                    ? (completed.gpuEndTime - completed.gpuStartTime) * 1000 : 0
                print(String(format: "PASS %@; %@; endpoint deltas %.4f / %.4f; CPU encode %.3f ms; command GPU %.3f ms; color direction/orientation",
                             testCase.name, centers, previousDistance, currentDistance, encodeMilliseconds, gpuMilliseconds))
            } else {
                print("FAIL \(testCase.name): \(caseFailures.joined(separator: "; "))")
            }

            DispatchQueue.main.async {
                guard let self else { return }
                guard case .runningCase(let active) = self.phase, active == index else { return }
                self.failures.append(contentsOf: caseFailures.map { "\(testCase.name): \($0)" })
                if index + 1 < self.cases.count {
                    let nextIndex = index + 1
                    let nextCase = self.cases[nextIndex]
                    self.phase = .waitingForCase(nextIndex)
                    self.readyDeadline = ProcessInfo.processInfo.systemUptime + 90
                    self.interpolator.prepare(width: nextCase.targetWidth, height: nextCase.targetHeight)
                    self.pollReadiness(for: nextIndex)
                } else {
                    self.phase = .done
                    if self.failures.isEmpty {
                        print("PASS stop during submitted GPU work retained direct-buffer resources through readback")
                        print("GPU fixture passed. These checks do not claim interpolation image quality or a real-time frame-rate guarantee.")
                        exit(0)
                    }
                    print("GPU fixture completed with failed assertions: \(self.failures.joined(separator: " | "))")
                    exit(1)
                }
            }
        }

        command.commit()
        if testCase.stopWhileInFlight {
            // The shared-event wait guarantees this command is still pending here.
            // Retiring the session before releasing the GPU must preserve its resources.
            interpolator.stop()
            guard !interpolator.isReady else { fail("stop left the submitted session ready") }
            stopGate?.signaledValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, case .runningCase(let active) = self.phase, active == index else { return }
            fail("GPU command/readback timed out for \(testCase.name)")
        }
    }

    private func makeInputBuffers(for testCase: Case, previous: CIImage, current: CIImage) -> (CVPixelBuffer, CVPixelBuffer)? {
        switch testCase.inputMode {
        case .ciFallback, .ciFallbackFast:
            return nil
        case .direct420v:
            return (
                makePixelBuffer(from: previous, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec709),
                makePixelBuffer(from: current, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec709)
            )
        case .fullRangeFallback:
            return (
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, color: .rec709),
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, color: .rec709)
            )
        case .otherColorFallback:
            return (
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec2020),
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec2020)
            )
        case .orientedFallback:
            return (
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec709, orientation: .down),
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec709, orientation: .down)
            )
        case .cositedChromaFallback:
            return (
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec709,
                                chromaLocation: kCVImageBufferChromaLocation_Left),
                makePixelBuffer(from: nil, width: testCase.inputWidth, height: testCase.inputHeight,
                                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, color: .rec709,
                                chromaLocation: kCVImageBufferChromaLocation_Left)
            )
        }
    }

    private enum BufferColor {
        case rec709
        case rec2020
    }

    private enum BufferOrientation {
        case up
        case down
    }

    private func makePixelBuffer(from image: CIImage?, width: Int, height: Int, format: OSType,
                                 color: BufferColor, orientation: BufferOrientation = .up,
                                 chromaLocation: CFString? = nil) -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { fail("could not allocate (format) input buffer at \(width)x\(height)") }
        if let image {
            context.render(normalized(image, width: width, height: height), to: buffer,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        } else {
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
                fail("could not lock sentinel input buffer")
            }
            let y = yBase.assumingMemoryBound(to: UInt8.self)
            let chroma = cBase.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let black: UInt8 = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 0 : 16
            for row in 0..<height {
                for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) { y[row * yStride + column] = black }
            }
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
                for column in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) { chroma[row * cStride + column] = 128 }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        let matrix = color == .rec709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020
        let primaries = color == .rec709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020
        let transfer = color == .rec709 ? kCVImageBufferTransferFunction_ITU_R_709_2 : kCVImageBufferTransferFunction_ITU_R_2020
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        if let chromaLocation {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, chromaLocation, .shouldPropagate)
        }
        let exifOrientation = orientation == .up
            ? CGImagePropertyOrientation.up.rawValue
            : CGImagePropertyOrientation.down.rawValue
        CVBufferSetAttachment(buffer, kCGImagePropertyOrientation, NSNumber(value: exifOrientation), .shouldPropagate)
        return buffer
    }

    private func makeFrame(width: Int, height: Int, blockCenterX: Double, originX: CGFloat, originY: CGFloat) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let halfWidth = CGFloat(width) / 2
        let halfHeight = CGFloat(height) / 2
        let quadrants: [(CIColor, CGRect)] = [
            (CIColor(red: 1, green: 0, blue: 0), CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight)),
            (CIColor(red: 0, green: 1, blue: 0), CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight)),
            (CIColor(red: 0, green: 0, blue: 1), CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight)),
            (CIColor(red: 1, green: 1, blue: 0), CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight))
        ]
        var image = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        for (color, rect) in quadrants {
            image = CIImage(color: color).cropped(to: rect).composited(over: image)
        }
        let patch = CGRect(
            x: CGFloat(blockCenterX) * CGFloat(width) - CGFloat(width) * 0.04,
            y: CGFloat(height) * 0.18,
            width: CGFloat(width) * 0.08,
            height: CGFloat(height) * 0.14
        )
        image = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: patch).composited(over: image)
        // Sparse, non-repeating magenta shades give optical flow stable features
        // without periodic checkerboard edges or crossing the quadrant boundaries.
        let marks: [(CGRect, CIColor)] = [
            (CGRect(x: patch.minX + patch.width * 0.16, y: patch.minY + patch.height * 0.18, width: patch.width * 0.31, height: patch.height * 0.14), CIColor(red: 0.55, green: 0.02, blue: 0.55)),
            (CGRect(x: patch.minX + patch.width * 0.62, y: patch.minY + patch.height * 0.12, width: patch.width * 0.12, height: patch.height * 0.38), CIColor(red: 1, green: 0.16, blue: 1)),
            (CGRect(x: patch.minX + patch.width * 0.35, y: patch.minY + patch.height * 0.64, width: patch.width * 0.43, height: patch.height * 0.13), CIColor(red: 0.78, green: 0.03, blue: 0.78)),
            (CGRect(x: patch.minX + patch.width * 0.82, y: patch.minY + patch.height * 0.59, width: patch.width * 0.09, height: patch.height * 0.12), CIColor(red: 0.64, green: 0.02, blue: 0.64))
        ]
        for (mark, color) in marks {
            image = CIImage(color: color).cropped(to: mark).composited(over: image)
        }
        return image.cropped(to: bounds).transformed(by: CGAffineTransform(translationX: originX, y: originY))
    }

    private func normalized(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let extent = image.extent
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
    }

    private func makeReadbackTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private static func read(_ texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    private static func pixel(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> (Int, Int, Int) {
        let offset = (y * width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private static func colorFailures(_ pixels: [UInt8], width: Int, height: Int) -> [String] {
        // Match the asymmetric four-quadrant sampling pattern used by the AI GPU fixture.
        let locations = [(width / 4, height / 4), (3 * width / 4, height / 4), (width / 4, 3 * height / 4), (3 * width / 4, 3 * height / 4)]
        let samples = locations.map { pixel(pixels, x: $0.0, y: $0.1, width: width) }
        let red = samples[0], green = samples[1], blue = samples[2], yellow = samples[3]
        if red.0 > red.1 + 32, red.0 > red.2 + 32,
           green.1 > green.0 + 32, green.1 > green.2 + 32,
           blue.2 > blue.0 + 32, blue.2 > blue.1 + 20,
           yellow.0 > yellow.2 + 36, yellow.1 > yellow.2 + 36 {
            return []
        }
        return ["quadrant color direction/orientation mismatch: \(samples)"]
    }

    private static func magentaCenterX(_ pixels: [UInt8], width: Int, height: Int) -> Double? {
        var weightedX = 0.0
        var totalWeight = 0.0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let (red, green, blue) = pixel(pixels, x: x, y: y, width: width)
                let score = min(red, blue) - green
                if score > 48 {
                    let weight = Double(score - 48)
                    weightedX += Double(x) * weight
                    totalWeight += weight
                }
            }
        }
        guard totalWeight > 0 else { return nil }
        return weightedX / totalWeight
    }

    private static func meanDifference(_ lhs: [UInt8], _ rhs: [UInt8], width: Int, height: Int) -> Double {
        var total = 0.0
        var samples = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let offset = (y * width + x) * 4
                for channel in 0..<3 { total += Double(abs(Int(lhs[offset + channel]) - Int(rhs[offset + channel]))) }
                samples += 1
            }
        }
        return total / Double(max(1, samples * 3 * 255))
    }
}
#endif

#if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
if #available(macOS 26.0, *) {
    guard FrameInterpolatorSupport.isSupported else {
        skip("VideoToolbox frame interpolation is unsupported by this macOS/runtime")
    }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        skip("no Metal device or command queue is available")
    }
    for (width, height) in [(1280, 720), (1920, 1080)] {
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1),
              configuration.supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
            skip("VideoToolbox does not support required 420v interpolation at \(width)x\(height)")
        }
    }
    let suite = FrameInterpolatorGPUSuite(device: device, queue: queue)
    DispatchQueue.main.async { suite.start() }
    dispatchMain()
} else {
    skip("requires macOS 26 runtime support for VideoToolbox frame interpolation")
}
#else
skip("requires Swift 6.2 and the macOS 26 SDK")
#endif
