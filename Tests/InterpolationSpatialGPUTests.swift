import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Metal
import MetalFX
import QuartzCore
import VideoToolbox

setbuf(stdout, nil)

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private func skip(_ message: String) -> Never {
    print("SKIP: \(message) (not a pass)")
    exit(2)
}

private struct SpatialCase {
    let name: String
    let sourceWidth: Int
    let sourceHeight: Int
    let workingWidth: Int
    let workingHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let expectedInputPath: String

    var label: String {
        "\(name) \(sourceWidth)x\(sourceHeight)→\(workingWidth)x\(workingHeight)→\(outputWidth)x\(outputHeight)"
    }
}

private struct RGB {
    let r: Double
    let g: Double
    let b: Double
}

private struct Timing {
    let vtCPU: Double
    let spatialAndFinalCPU: Double
    let totalCPU: Double
    let commandGPU: Double
    let commitToCompletion: Double
}

private struct InputPair {
    let previous: CVPixelBuffer
    let current: CVPixelBuffer
}

#if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
@available(macOS 26.0, *)
private final class InterpolationSpatialGPUSuite {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let context: CIContext
    private let interpolator: FrameInterpolator
    private let upscaler: MetalUpscaler

    // Production quality working edges for a 1920x1080 source: low 960, medium 1280, high 1920.
    // 720p and 4K cases exercise the native and downsampled compatibility paths.
    private static let allCases: [SpatialCase] = [
        SpatialCase(name: "1080 low / 2560", sourceWidth: 1920, sourceHeight: 1080,
                    workingWidth: 960, workingHeight: 540, outputWidth: 2560, outputHeight: 1440,
                    expectedInputPath: "resampled"),
        SpatialCase(name: "1080 medium / 2560", sourceWidth: 1920, sourceHeight: 1080,
                    workingWidth: 1280, workingHeight: 720, outputWidth: 2560, outputHeight: 1440,
                    expectedInputPath: "resampled"),
        SpatialCase(name: "1080 medium / 4K", sourceWidth: 1920, sourceHeight: 1080,
                    workingWidth: 1280, workingHeight: 720, outputWidth: 3840, outputHeight: 2160,
                    expectedInputPath: "resampled"),
        SpatialCase(name: "1080 high / 2560", sourceWidth: 1920, sourceHeight: 1080,
                    workingWidth: 1920, workingHeight: 1080, outputWidth: 2560, outputHeight: 1440,
                    expectedInputPath: "original"),
        SpatialCase(name: "1080 high / 4K", sourceWidth: 1920, sourceHeight: 1080,
                    workingWidth: 1920, workingHeight: 1080, outputWidth: 3840, outputHeight: 2160,
                    expectedInputPath: "original"),
        SpatialCase(name: "720 medium / 2560", sourceWidth: 1280, sourceHeight: 720,
                    workingWidth: 1280, workingHeight: 720, outputWidth: 2560, outputHeight: 1440,
                    expectedInputPath: "original"),
        SpatialCase(name: "720 medium / 4K", sourceWidth: 1280, sourceHeight: 720,
                    workingWidth: 1280, workingHeight: 720, outputWidth: 3840, outputHeight: 2160,
                    expectedInputPath: "original"),
        SpatialCase(name: "4K low / 2560", sourceWidth: 3840, sourceHeight: 2160,
                    workingWidth: 960, workingHeight: 540, outputWidth: 2560, outputHeight: 1440,
                    expectedInputPath: "resampled"),
        SpatialCase(name: "4K medium / 4K", sourceWidth: 3840, sourceHeight: 2160,
                    workingWidth: 1280, workingHeight: 720, outputWidth: 3840, outputHeight: 2160,
                    expectedInputPath: "resampled"),
        SpatialCase(name: "4K high / 4K", sourceWidth: 3840, sourceHeight: 2160,
                    workingWidth: 1920, workingHeight: 1080, outputWidth: 3840, outputHeight: 2160,
                    expectedInputPath: "resampled")
    ]

    private let cases: [SpatialCase]
    private let warmupCount = 2
    private let measuredCount = 20
    private var caseIndex = 0
    private var sampleIndex = 0
    private var active = false
    private var pollScheduled = false
    private var readyDeadline = 0.0
    private var nextPresentationTick: Int64 = 0
    private var sourceAttributesForCase: [String: any Sendable]?
    private var slidingInput: CVPixelBuffer?
    private var referenceQuadrantsForCase: [(UInt8, UInt8, UInt8)]?
    private var finalTextureForCase: MTLTexture?
    private var timings: [Timing] = []
    private var skippedCases: [String] = []

    init(device: MTLDevice, queue: MTLCommandQueue) {
        let requestedCase = ProcessInfo.processInfo.environment["MONIVIEW_TEST_CASE"]
        let selectedCases: [SpatialCase]
        if let requestedCase {
            let filter = requestedCase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filter.isEmpty else { fail("MONIVIEW_TEST_CASE must not be empty") }
            selectedCases = Self.allCases.filter {
                $0.label.localizedCaseInsensitiveContains(filter)
            }
            guard !selectedCases.isEmpty else {
                fail("MONIVIEW_TEST_CASE filter '\(filter)' matched no fixture cases")
            }
        } else {
            selectedCases = Self.allCases
        }

        let forceInputCopy = ProcessInfo.processInfo.environment["MONIVIEW_TEST_FORCE_INPUT_COPY"] == "1"
        cases = selectedCases.map { testCase in
            guard forceInputCopy, testCase.expectedInputPath == "original" else { return testCase }
            return SpatialCase(name: testCase.name,
                               sourceWidth: testCase.sourceWidth,
                               sourceHeight: testCase.sourceHeight,
                               workingWidth: testCase.workingWidth,
                               workingHeight: testCase.workingHeight,
                               outputWidth: testCase.outputWidth,
                               outputHeight: testCase.outputHeight,
                               expectedInputPath: "resampled")
        }
        self.device = device
        self.queue = queue
        context = CIContext(mtlDevice: device,
                            options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
        interpolator = FrameInterpolator(device: device)
        guard let upscaler = MetalUpscaler(device: device) else {
            skip("MetalFX spatial scaler is unsupported on \(device.name)")
        }
        self.upscaler = upscaler
        interpolator.onStateChange = { [weak self] in self?.stateChanged() }
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        print("Build condition: Swift production optimization (-O); timings reflect this optimized offscreen build and do not guarantee 120 Hz throughput.")
        if ProcessInfo.processInfo.environment["MONIVIEW_TEST_FORCE_INPUT_COPY"] == "1" {
            print("Input-copy test override enabled: native-size input path expects resampled.")
        }
        if let requestedCase = ProcessInfo.processInfo.environment["MONIVIEW_TEST_CASE"] {
            print("Case filter: '\(requestedCase)' selected \(cases.count) of \(Self.allCases.count) cases.")
        }
        print("GPU device: \(device.name)")
        print("Joint fixture: VideoToolbox midpoint → MetalFX spatial scaler → shared final texture; one command in flight.")
        print("Each supported case uses \(warmupCount) warmups + \(measuredCount) measured commands.")
        print("Inputs use adjacent sliding 420v frames: one new IOSurface-backed current buffer per sample.")
        print("Timing reports: VT CPU encode, MetalFX+final-render CPU encode, total CPU encode, command GPU time, and commit→completion-callback wall time.")
        print("All timings are offscreen fixture conditions; callback wall time is not HDMI/display latency or a 120 Hz guarantee.")
        print("Explicit compatibility skip: low 960x540 → 3840x2160 is 4x and exceeds MetalUpscaler’s 3x per-axis guard.")
        print("SKIP low 960x540 → 3840x2160: 4.0x per axis exceeds the wrapper limit; direct target is unsupported.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self, self.caseIndex < self.cases.count else { return }
            fail("joint interpolation/spatial fixture timed out at \(self.cases[self.caseIndex].label)")
        }
        beginCurrentCase()
    }

    private func stateChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard caseIndex < cases.count, !active else { return }
        runWhenReady()
    }

    private func beginCurrentCase() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard caseIndex < cases.count else {
            finish()
            return
        }
        let testCase = cases[caseIndex]
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: testCase.workingWidth,
            frameHeight: testCase.workingHeight,
            numberOfInterpolatedFrames: 1
        ) else {
            skipCurrentCase(testCase, reason: "VideoToolbox rejected the working dimensions")
            return
        }
        guard configuration.supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
            skipCurrentCase(testCase, reason: "VideoToolbox configuration does not advertise Rec.709 420v")
            return
        }
        sourceAttributesForCase = configuration.sourcePixelBufferAttributes
        slidingInput = nil
        referenceQuadrantsForCase = nil
        guard let finalTexture = makeFinalTexture(width: testCase.outputWidth, height: testCase.outputHeight) else {
            fail("could not allocate final \(testCase.outputWidth)x\(testCase.outputHeight) readback texture")
        }
        finalTextureForCase = finalTexture
        print("CONFIG \(testCase.label): source attributes {\(describe(configuration.sourcePixelBufferAttributes))}")
        sampleIndex = 0
        timings.removeAll(keepingCapacity: true)
        readyDeadline = ProcessInfo.processInfo.systemUptime + 90
        interpolator.prepare(width: testCase.workingWidth, height: testCase.workingHeight)
        runWhenReady()
    }

    private func describe(_ attributes: [String: any Sendable]) -> String {
        attributes.keys.sorted().map { key in
            "\(key)=\(String(describing: attributes[key]!))"
        }.joined(separator: "; ")
    }

    private func runWhenReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard caseIndex < cases.count, !active else { return }
        if interpolator.isReady {
            encodeNextSample()
            return
        }
        guard ProcessInfo.processInfo.systemUptime < readyDeadline else {
            fail("VT session did not become ready for \(cases[caseIndex].label)")
        }
        interpolator.prepare(width: cases[caseIndex].workingWidth, height: cases[caseIndex].workingHeight)
        guard !pollScheduled else { return }
        pollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.pollScheduled = false
            self.runWhenReady()
        }
    }

    private func encodeNextSample() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard caseIndex < cases.count else { finish(); return }
        guard !active else { fail("attempted to queue a second command while one was in flight") }
        let testCase = cases[caseIndex]
        guard testCase.outputWidth <= testCase.workingWidth * 3,
              testCase.outputHeight <= testCase.workingHeight * 3 else {
            skipCurrentCase(testCase, reason: "output exceeds the spatial scaler’s 3x per-axis limit")
            return
        }
        guard let command = queue.makeCommandBuffer() else { fail("could not create command buffer") }
        guard let finalTexture = finalTextureForCase else {
            fail("missing final texture for \(testCase.label)")
        }
        guard finalTexture.pixelFormat == .rgba8Unorm,
              finalTexture.width == testCase.outputWidth,
              finalTexture.height == testCase.outputHeight else {
            fail("final texture descriptor does not match the requested output size/format")
        }

        guard let sourceAttributesForCase else { fail("missing VT source attributes for \(testCase.label)") }
        let frameOrdinal = nextPresentationTick / 2
        let previousCenter = min(0.70, 0.24 + Double(frameOrdinal % 40) * 0.009)
        let currentCenter = min(0.72, previousCenter + 0.012)
        let previousBuffer = slidingInput ?? makeSourceBuffer(width: testCase.sourceWidth,
                                                               height: testCase.sourceHeight,
                                                               requiredAttributes: sourceAttributesForCase,
                                                               patchCenter: previousCenter)
        let currentBuffer = makeSourceBuffer(width: testCase.sourceWidth,
                                             height: testCase.sourceHeight,
                                             requiredAttributes: sourceAttributesForCase,
                                             patchCenter: currentCenter)
        let pair = InputPair(previous: previousBuffer, current: currentBuffer)
        slidingInput = currentBuffer

        let sourceColorSpace = colorSpace
        let previousImage = CIImage(cvPixelBuffer: pair.previous, options: [.colorSpace: sourceColorSpace])
        let currentImage = CIImage(cvPixelBuffer: pair.current, options: [.colorSpace: sourceColorSpace])
        if sampleIndex == 0 {
            referenceQuadrantsForCase = renderAndValidateNativeReference(currentImage,
                                                                          sourceBuffer: pair.current,
                                                                          testCase: testCase)
        }
        let previousTime = CMTime(value: nextPresentationTick, timescale: 60)
        let currentTime = CMTime(value: nextPresentationTick + 2, timescale: 60)
        nextPresentationTick += 2
        let cpuStart = CACurrentMediaTime()
        guard let midpoint = interpolator.interpolate(
            previous: previousImage,
            current: currentImage,
            previousTime: previousTime,
            currentTime: currentTime,
            context: context,
            command: command,
            previousBuffer: pair.previous,
            currentBuffer: pair.current
        ) else {
            fail("VideoToolbox interpolation encoding returned nil for \(testCase.label)")
        }
        let vtCPU = CACurrentMediaTime() - cpuStart
        guard Int(midpoint.extent.width.rounded()) == testCase.workingWidth,
              Int(midpoint.extent.height.rounded()) == testCase.workingHeight else {
            fail("midpoint extent \(midpoint.extent) does not match configured \(testCase.workingWidth)x\(testCase.workingHeight)")
        }
        guard interpolator.testInputPath == testCase.expectedInputPath else {
            fail("input path for \(testCase.label) was \(interpolator.testInputPath), expected \(testCase.expectedInputPath)")
        }
        guard let scaled = upscaler.upscale(midpoint,
                                            width: testCase.outputWidth,
                                            height: testCase.outputHeight,
                                            context: context,
                                            command: command,
                                            colorSpace: colorSpace) else {
            skip("MetalFX did not create the requested scaler for \(testCase.label) despite a ≤3x ratio")
        }
        let extent = scaled.extent.integral
        guard Int(extent.width) == testCase.outputWidth, Int(extent.height) == testCase.outputHeight else {
            fail("MetalFX output extent \(scaled.extent) does not match \(testCase.outputWidth)x\(testCase.outputHeight)")
        }
        context.render(scaled, to: finalTexture, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: testCase.outputWidth, height: testCase.outputHeight),
                       colorSpace: colorSpace)
        let totalCPU = CACurrentMediaTime() - cpuStart
        let spatialAndFinalCPU = totalCPU - vtCPU
        let inputPath = interpolator.testInputPath
        let currentSample = sampleIndex
        let committedAt = CACurrentMediaTime()
        active = true
        command.addCompletedHandler { [weak self] completed in
            let callbackAt = CACurrentMediaTime()
            let gpuMS = completed.gpuEndTime > completed.gpuStartTime
                ? (completed.gpuEndTime - completed.gpuStartTime) * 1000 : 0
            let pixels = Self.sampleQuadrants(finalTexture)
            let status = completed.status
            let timing = Timing(vtCPU: vtCPU * 1000,
                                spatialAndFinalCPU: spatialAndFinalCPU * 1000,
                                totalCPU: totalCPU * 1000,
                                commandGPU: gpuMS,
                                commitToCompletion: (callbackAt - committedAt) * 1000)
            DispatchQueue.main.async {
                guard let self else { return }
                self.active = false
                guard status == .completed else {
                    fail("command status \(status.rawValue), error: \(String(describing: completed.error)) at \(testCase.label)")
                }
                guard gpuMS > 0, gpuMS.isFinite else {
                    fail("Metal did not report a valid command GPU interval for \(testCase.label)")
                }
                if let issue = Self.quadrantIssue(pixels) {
                    fail("final texture color/orientation check failed at \(testCase.label): \(issue)")
                }
                guard let reference = self.referenceQuadrantsForCase else {
                    fail("missing native Core Image reference for \(testCase.label)")
                }
                if let issue = Self.quadrantDifferenceIssue(pixels, reference: reference) {
                    fail("joint output differs from native Core Image reference at \(testCase.label): \(issue)")
                }
                if currentSample >= self.warmupCount {
                    self.timings.append(timing)
                }
                let totalSamples = self.warmupCount + self.measuredCount
                self.sampleIndex += 1
                if self.sampleIndex < totalSamples {
                    self.encodeNextSample()
                } else {
                    self.finishCurrentCase(testCase, inputPath: inputPath)
                }
            }
        }
        command.commit()
    }

    private func makeSourceBuffer(width: Int, height: Int,
                                  requiredAttributes: [String: any Sendable],
                                  patchCenter: Double) -> CVPixelBuffer {
        let configWidth = (requiredAttributes[kCVPixelBufferWidthKey as String] as? Int)
            ?? (requiredAttributes[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue
        let configHeight = (requiredAttributes[kCVPixelBufferHeightKey as String] as? Int)
            ?? (requiredAttributes[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue
        let matchesConfiguredDimensions = configWidth == width && configHeight == height
        var attributes: [String: Any] = [:]
        if matchesConfiguredDimensions {
            attributes = requiredAttributes.reduce(into: [:]) { result, item in
                result[item.key] = item.value
            }
        }
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attributes as CFDictionary, &optional)
        guard status == kCVReturnSuccess, let buffer = optional else {
            fail("could not create IOSurface-backed 420v input \(width)x\(height), status \(status)")
        }
        guard CVPixelBufferGetIOSurface(buffer) != nil,
              CVPixelBufferGetWidth(buffer) == width,
              CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2 else {
            fail("input buffer does not meet IOSurface 420v dimensions/plane requirements")
        }
        fillRec709Pattern(buffer, patchCenter: patchCenter)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCGImagePropertyOrientation,
                              NSNumber(value: CGImagePropertyOrientation.up.rawValue), .shouldPropagate)
        return buffer
    }

    private func renderAndValidateNativeReference(_ image: CIImage,
                                                   sourceBuffer: CVPixelBuffer,
                                                   testCase: SpatialCase) -> [(UInt8, UInt8, UInt8)] {
        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)
        guard Int(image.extent.width.rounded()) == width,
              Int(image.extent.height.rounded()) == height,
              image.extent.minX == 0, image.extent.minY == 0 else {
            fail("raw CIImage extent \(image.extent) is not native source size \(width)x\(height) at \(testCase.label)")
        }
        guard let texture = makeFinalTexture(width: width, height: height),
              let command = queue.makeCommandBuffer() else {
            fail("could not allocate native CI reference resources at \(testCase.label)")
        }
        context.render(image, to: texture, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: colorSpace)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            fail("native CI reference command status \(command.status.rawValue), error: \(String(describing: command.error)) at \(testCase.label)")
        }

        let pixels = Self.sampleQuadrants(texture)
        guard let issue = Self.rawCIReferenceIssue(pixels) else {
            print("REFERENCE \(testCase.label): raw row0 is red/green and row-bottom is blue/yellow; CI lower-y readback order is \(pixels)")
            return pixels
        }
        fail("raw CI reference color/orientation check failed at \(testCase.label): \(issue)")
    }

    private func fillRec709Pattern(_ buffer: CVPixelBuffer, patchCenter: Double) {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width.isMultiple(of: 2), height.isMultiple(of: 2),
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            fail("could not lock 420v pattern input")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
        let uvPlane = uvBase.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        for row in 0..<height {
            let line = yPlane.advanced(by: row * yStride)
            for column in 0..<width {
                line[column] = videoRangeLuma(colorAt(x: column, y: row, width: width,
                                                     height: height, patchCenter: patchCenter))
            }
        }
        for row in 0..<(height / 2) {
            let line = uvPlane.advanced(by: row * uvStride)
            for column in 0..<(width / 2) {
                let x = column * 2, y = row * 2
                let colors = [
                    colorAt(x: x, y: y, width: width, height: height, patchCenter: patchCenter),
                    colorAt(x: x + 1, y: y, width: width, height: height, patchCenter: patchCenter),
                    colorAt(x: x, y: y + 1, width: width, height: height, patchCenter: patchCenter),
                    colorAt(x: x + 1, y: y + 1, width: width, height: height, patchCenter: patchCenter)
                ]
                let color = RGB(r: colors.reduce(0) { $0 + $1.r } / 4,
                                g: colors.reduce(0) { $0 + $1.g } / 4,
                                b: colors.reduce(0) { $0 + $1.b } / 4)
                let luma = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
                let cb = (color.b - luma) / (2 * (1 - 0.0722))
                let cr = (color.r - luma) / (2 * (1 - 0.2126))
                line[column * 2] = UInt8(clamping: Int((128 + 224 * cb).rounded()))
                line[column * 2 + 1] = UInt8(clamping: Int((128 + 224 * cr).rounded()))
            }
        }
    }

    private func colorAt(x: Int, y: Int, width: Int, height: Int, patchCenter: Double) -> RGB {
        let nx = (Double(x) + 0.5) / Double(width)
        let ny = (Double(y) + 0.5) / Double(height)
        if abs(nx - patchCenter) < 0.018 && (0.40...0.60).contains(ny) {
            return RGB(r: 1, g: 0, b: 1)
        }
        if ny < 0.5 {
            return nx < 0.5 ? RGB(r: 1, g: 0, b: 0) : RGB(r: 0, g: 1, b: 0)
        }
        return nx < 0.5 ? RGB(r: 0, g: 0, b: 1) : RGB(r: 1, g: 1, b: 0)
    }

    private func videoRangeLuma(_ color: RGB) -> UInt8 {
        let value = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
        return UInt8(clamping: Int((16 + 219 * value).rounded()))
    }

    private func makeFinalTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private static func sampleQuadrants(_ texture: MTLTexture) -> [(UInt8, UInt8, UInt8)] {
        let points = [
            (texture.width / 4, texture.height / 4),
            (3 * texture.width / 4, texture.height / 4),
            (texture.width / 4, 3 * texture.height / 4),
            (3 * texture.width / 4, 3 * texture.height / 4)
        ]
        return points.map { x, y in
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                texture.getBytes(bytes.baseAddress!, bytesPerRow: 4,
                                 from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            }
            return (rgba[0], rgba[1], rgba[2])
        }
    }

    private static func rawCIReferenceIssue(_ colors: [(UInt8, UInt8, UInt8)]) -> String? {
        guard colors.count == 4 else { return "four color samples missing" }
        // CIImage uses a lower-left origin: low-y samples address the bottom CV rows.
        let blue = colors[0], yellow = colors[1], red = colors[2], green = colors[3]
        guard Int(blue.2) > Int(blue.0) + 32, Int(blue.2) > Int(blue.1) + 20,
              Int(yellow.0) > Int(yellow.2) + 36, Int(yellow.1) > Int(yellow.2) + 36,
              Int(red.0) > Int(red.1) + 32, Int(red.0) > Int(red.2) + 32,
              Int(green.1) > Int(green.0) + 32, Int(green.1) > Int(green.2) + 32 else {
            return "CI lower-y quadrants should be blue/yellow then red/green; samples \(colors)"
        }
        return nil
    }

    private static func quadrantIssue(_ colors: [(UInt8, UInt8, UInt8)]) -> String? {
        rawCIReferenceIssue(colors)
    }

    private static func quadrantDifferenceIssue(_ output: [(UInt8, UInt8, UInt8)],
                                                reference: [(UInt8, UInt8, UInt8)]) -> String? {
        guard output.count == 4, reference.count == 4 else { return "four reference/output samples missing" }
        let maxChannelDifference = zip(output, reference).enumerated().map { index, pair in
            max(abs(Int(pair.0.0) - Int(pair.1.0)),
                abs(Int(pair.0.1) - Int(pair.1.1)),
                abs(Int(pair.0.2) - Int(pair.1.2)))
        }
        guard let largest = maxChannelDifference.max(), largest <= 16 else {
            return "per-quadrant max RGB deltas \(maxChannelDifference) exceed 16 (output \(output), reference \(reference))"
        }
        return nil
    }

    private func finishCurrentCase(_ testCase: SpatialCase, inputPath: String) {
        guard timings.count == measuredCount else {
            fail("expected \(measuredCount) measured timings at \(testCase.label), got \(timings.count)")
        }
        let vt = summary(timings.map(\.vtCPU))
        let spatialCPU = summary(timings.map(\.spatialAndFinalCPU))
        let totalCPU = summary(timings.map(\.totalCPU))
        let gpu = summary(timings.map(\.commandGPU))
        let wall = summary(timings.map(\.commitToCompletion))
        print(String(format: "PASS %@; inputPath=%@; 420v/Rec.709/up; output=%dx%d; VT CPU mean/P95 %.3f/%.3f ms; MetalFX+final CPU %.3f/%.3f ms; total CPU %.3f/%.3f ms; command GPU %.3f/%.3f ms; commit→completion callback wall %.3f/%.3f ms",
                     testCase.label, inputPath, testCase.outputWidth, testCase.outputHeight,
                     vt.mean, vt.p95, spatialCPU.mean, spatialCPU.p95, totalCPU.mean, totalCPU.p95,
                     gpu.mean, gpu.p95, wall.mean, wall.p95))
        finalTextureForCase = nil
        caseIndex += 1
        beginCurrentCase()
    }

    private func skipCurrentCase(_ testCase: SpatialCase, reason: String) {
        print("SKIP \(testCase.label): \(reason) (not a pass)")
        skippedCases.append(testCase.label)
        caseIndex += 1
        beginCurrentCase()
    }

    private func summary(_ values: [Double]) -> (mean: Double, p95: Double) {
        guard !values.isEmpty else { fail("cannot summarize an empty timing list") }
        let sorted = values.sorted()
        return (values.reduce(0, +) / Double(values.count), sorted[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)])
    }

    private func finish() {
        dispatchPrecondition(condition: .onQueue(.main))
        interpolator.stop()
        if !skippedCases.isEmpty {
            print("SKIP: incomplete required matrix: \(skippedCases.joined(separator: "; ")) (not a full pass)")
            exit(2)
        }
        print("PASS: all \(cases.count) compatible joint VT→MetalFX cases completed; low 960→3840 was explicitly excluded by the 3x limit. Offscreen timings are not image-quality, display-refresh, or HDMI-latency claims.")
        exit(0)
    }
}

private func main() {
    guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
        skip("VideoToolbox low-latency frame interpolation is unavailable")
    }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        skip("no Metal device/command queue is available")
    }
    guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
        skip("MetalFX spatial scaling is unsupported on \(device.name)")
    }
    let suite = InterpolationSpatialGPUSuite(device: device, queue: queue)
    suite.start()
    withExtendedLifetime(suite) { dispatchMain() }
}
#endif

#if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
if #available(macOS 26.0, *) {
    main()
} else {
    skip("requires macOS 26 or later")
}
#else
skip("requires Swift 6.2 compiler support for VideoToolbox frame interpolation")
#endif
