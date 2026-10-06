import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal

setbuf(stdout, nil)

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private struct Frame {
    let buffer: CVPixelBuffer
    let bytes: [UInt8]
}

private final class FlowBlendSuite {
    private let width = 1280
    private let height = 720
    private let previousX = 272
    private let currentX = 320
    private let blockY = 192
    private let blockWidth = 192
    private let blockHeight = 192
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let interpolator: FlowBlendInterpolator
    private let previous: Frame
    private let current: Frame
    private let previous420v: Frame
    private let current420v: Frame
    private let ideal: [UInt8]
    private let readback: MTLTexture
    private let warmupCount = 3
    private let measuredCount = 20
    private var sampleIndex = -1
    private var gpuTimes: [Double] = []

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let interpolator = FlowBlendInterpolator(device: device),
              let readback = Self.makeReadbackTexture(device: device, width: width, height: height) else { return nil }
        self.device = device
        self.queue = queue
        self.interpolator = interpolator
        self.readback = readback
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
        guard let previous = Self.makeFrame(width: width, height: height, blockX: previousX,
                                            blockY: blockY, blockWidth: blockWidth, blockHeight: blockHeight),
              let current = Self.makeFrame(width: width, height: height, blockX: currentX,
                                           blockY: blockY, blockWidth: blockWidth, blockHeight: blockHeight),
              let previous420v = Self.make420vFrame(width: width, height: height, source: previous.bytes),
              let current420v = Self.make420vFrame(width: width, height: height, source: current.bytes) else { return nil }
        self.previous = previous
        self.current = current
        self.previous420v = previous420v
        self.current420v = current420v
        ideal = Self.makeBytes(width: width, height: height, blockX: (previousX + currentX) / 2,
                               blockY: blockY, blockWidth: blockWidth, blockHeight: blockHeight)
    }

    func run() {
        print("GPU device: \(device.name)")
        print("Fixture: 1280x720 BGRA and 420v; 192x192 textured block moves 48 px; blend=0.5.")
        print("Timing: 3 warmups + 20 measured command buffers; timestamps cover interpolation kernels.")
        runNext()
    }

    private func runNext() {
        sampleIndex += 1
        let isQuality = sampleIndex == 0
        let is420v = sampleIndex == 1
        let commandIndex = sampleIndex - 2
        let isWarmup = !isQuality && !is420v && commandIndex < warmupCount
        guard isQuality || is420v || commandIndex < warmupCount + measuredCount else {
            finish()
            return
        }
        guard let command = queue.makeCommandBuffer() else { fail("could not create command buffer") }
        let inputPrevious = is420v ? previous420v : previous
        let inputCurrent = is420v ? current420v : current
        guard let output = interpolator.interpolate(
            previous: CIImage(cvPixelBuffer: inputPrevious.buffer),
            current: CIImage(cvPixelBuffer: inputCurrent.buffer),
            previousTime: CMTime(value: 0, timescale: 60),
            currentTime: CMTime(value: 1, timescale: 60),
            context: context,
            command: command,
            previousBuffer: inputPrevious.buffer,
            currentBuffer: inputCurrent.buffer,
            blendFactor: 0.5
        ) else { fail("interpolation returned nil") }

        if isQuality || is420v {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.render(output, to: readback, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        }
        command.addCompletedHandler { [weak self] completed in
            guard completed.status == .completed else {
                fail("Metal command failed: \(String(describing: completed.error))")
            }
            guard let self else { return }
            let gpuMilliseconds = (completed.gpuEndTime - completed.gpuStartTime) * 1000.0
            if !isQuality && !is420v && !isWarmup { self.gpuTimes.append(gpuMilliseconds) }
            if isQuality || is420v {
                self.checkImageQuality()
                let formatName = is420v ? "420v" : "BGRA"
                print(String(format: "PASS %@ moving-block image check; command GPU %.3f ms", formatName, gpuMilliseconds))
            } else if !isWarmup {
                print(String(format: "SAMPLE %02d GPU %.3f ms", commandIndex - self.warmupCount + 1, gpuMilliseconds))
            }
            DispatchQueue.main.async { self.runNext() }
        }
        command.commit()
    }

    private func checkImageQuality() {
        var actual = [UInt8](repeating: 0, count: width * height * 4)
        actual.withUnsafeMutableBytes { bytes in
            readback.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                              from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let expectedX = (previousX + currentX) / 2
        let xRange = max(0, expectedX - 24)..<min(width, expectedX + blockWidth + 24)
        let yRange = max(0, blockY - 24)..<min(height, blockY + blockHeight + 24)
        var actualError = 0.0
        var dissolveError = 0.0
        var samples = 0
        for y in yRange {
            for x in xRange {
                let offset = (y * width + x) * 4
                let actualLuma = Self.luma(actual, offset)
                let expectedLuma = Self.luma(ideal, offset)
                let dissolveLuma = (Self.luma(previous.bytes, offset) + Self.luma(current.bytes, offset)) * 0.5
                actualError += abs(actualLuma - expectedLuma)
                dissolveError += abs(dissolveLuma - expectedLuma)
                samples += 1
            }
        }
        let actualMAE = actualError / Double(samples)
        let dissolveMAE = dissolveError / Double(samples)
        print(String(format: "Image MAE vs ideal midpoint: flow %.4f, dissolve %.4f", actualMAE, dissolveMAE))
        guard actualMAE < 0.13, actualMAE < dissolveMAE * 0.95 else {
            fail("warped result did not beat the cross-dissolve reference")
        }
    }

    private func finish() {
        let sorted = gpuTimes.sorted()
        guard sorted.count == measuredCount else { fail("expected \(measuredCount) timing samples, got \(sorted.count)") }
        let mean = sorted.reduce(0.0, +) / Double(sorted.count)
        let median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) * 0.5
        let p95 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        print(String(format: "GPU benchmark 1280x720: mean %.3f ms, median %.3f ms, p95 %.3f ms, min %.3f ms, max %.3f ms",
                     mean, median, p95, sorted[0], sorted[sorted.count - 1]))
        print(String(format: "4 ms budget: %@ (p95 %.3f ms)", p95 <= 4.0 ? "PASS" : "MISS", p95))
        guard p95 <= 4.0 else { fail("GPU p95 exceeds the 4 ms target") }
        exit(0)
    }

    private static func makeFrame(width: Int, height: Int, blockX: Int, blockY: Int,
                                  blockWidth: Int, blockHeight: Int) -> Frame? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let bytes = makeBytes(width: width, height: height, blockX: blockX, blockY: blockY,
                              blockWidth: blockWidth, blockHeight: blockHeight)
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            bytes.withUnsafeBytes { source in
                for row in 0..<height {
                    memcpy(base.advanced(by: row * rowBytes), source.baseAddress!.advanced(by: row * width * 4), width * 4)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return Frame(buffer: buffer, bytes: bytes)
    }

    private static func make420vFrame(width: Int, height: Int, source: [UInt8]) -> Frame? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height {
            let row = yBase.advanced(by: y * yRowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Double(source[offset + 2]) / 255.0
                let g = Double(source[offset + 1]) / 255.0
                let b = Double(source[offset]) / 255.0
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                row[x] = UInt8(max(16, min(235, Int((16.0 + 219.0 * luma).rounded()))))
            }
        }
        for y in stride(from: 0, to: height, by: 2) {
            let row = uvBase.advanced(by: (y / 2) * uvRowBytes).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: 2) {
                var r = 0.0, g = 0.0, b = 0.0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let offset = ((y + dy) * width + x + dx) * 4
                        r += Double(source[offset + 2]) / 255.0
                        g += Double(source[offset + 1]) / 255.0
                        b += Double(source[offset]) / 255.0
                    }
                }
                r *= 0.25; g *= 0.25; b *= 0.25
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let cb = (b - luma) / 1.8556
                let cr = (r - luma) / 1.5748
                row[x] = UInt8(max(16, min(240, Int((128.0 + 224.0 * cb).rounded()))) )
                row[x + 1] = UInt8(max(16, min(240, Int((128.0 + 224.0 * cr).rounded()))) )
            }
        }
        return Frame(buffer: buffer, bytes: source)
    }

    private static func makeBytes(width: Int, height: Int, blockX: Int, blockY: Int,
                                  blockWidth: Int, blockHeight: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inBlock = x >= blockX && x < blockX + blockWidth && y >= blockY && y < blockY + blockHeight
                let red: UInt8
                let green: UInt8
                let blue: UInt8
                if inBlock {
                    let localX = x - blockX
                    let localY = y - blockY
                    let tileX = localX / 8
                    let tileY = localY / 8
                    let code = (tileX * 17 + tileY * 29 + tileX * tileY * 3) & 7
                    let value = UInt8(140 + code * 14)
                    red = value
                    green = UInt8(min(255, Int(value) - 12))
                    blue = UInt8(min(255, Int(value) - 28))
                } else {
                    let checker = ((x / 32 + y / 32) & 1) == 0
                    red = checker ? 24 : 34
                    green = checker ? 30 : 40
                    blue = checker ? 36 : 46
                }
                let offset = (y * width + x) * 4
                bytes[offset] = blue
                bytes[offset + 1] = green
                bytes[offset + 2] = red
                bytes[offset + 3] = 255
            }
        }
        return bytes
    }

    private static func luma(_ bytes: [UInt8], _ offset: Int) -> Double {
        (0.2126 * Double(bytes[offset + 2]) + 0.7152 * Double(bytes[offset + 1])
         + 0.0722 * Double(bytes[offset])) / 255.0
    }

    private static func makeReadbackTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                   width: width, height: height,
                                                                   mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderWrite, .renderTarget]
        return device.makeTexture(descriptor: descriptor)
    }
}

guard let device = MTLCreateSystemDefaultDevice() else {
    print("SKIP: Metal device unavailable (not a pass)")
    exit(2)
}
guard let suite = FlowBlendSuite(device: device) else { fail("could not initialize fixture") }
suite.run()
RunLoop.main.run()
