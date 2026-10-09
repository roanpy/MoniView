import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Metal

setbuf(stdout, nil)

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private enum VideoMatrix {
    case rec601, rec709, rec2020

    var coefficients: (r: Double, b: Double) {
        switch self {
        case .rec601: return (0.299, 0.114)
        case .rec709: return (0.2126, 0.0722)
        case .rec2020: return (0.2627, 0.0593)
        }
    }

    var attachment: CFString {
        switch self {
        case .rec601: return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case .rec709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .rec2020: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
    }
}

private struct ImageError {
    let mean: Double
    let maximum: Int
    let lumaBias: Double
}

private final class FlowBlendSuite {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    // Match PreviewLayerView. References render the original CIImage through the
    // same destination space; raw CV rows are not a display-path reference.
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var interpolator: FlowBlendInterpolator
    private var checks = 0
    private var failures: [String] = []

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let interpolator = FlowBlendInterpolator(device: device) else { return nil }
        self.device = device
        self.queue = queue
        self.interpolator = interpolator
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
    }

    func run() {
        print("GPU device: \(device.name)")
        print("Image checks: asymmetric non-gray RGB, 420v matrix/transfer/chroma, CI transforms, requested size, endpoints and motion.")
        checkStaticImages()
        for matrix in [VideoMatrix.rec709, .rec601, .rec2020] {
            checkMotion(name: "420v \(matrix) horizontal +48", matrix: matrix, dx: 48, dy: 0)
        }
        checkMotion(name: "BGRA horizontal +48", matrix: nil, dx: 48, dy: 0)
        checkMotion(name: "BGRA vertical +32", matrix: nil, dx: 0, dy: 32)
        checkMotion(name: "420v vertical -32", matrix: .rec709, dx: 0, dy: -32)
        checkMotion(name: "420v diagonal -32,+32", matrix: .rec709, dx: -32, dy: 32)
        checkMotion(name: "BGRA 1080p/720p horizontal +48", matrix: nil, dx: 48, dy: 0, sourceWidth: 1920, sourceHeight: 1080)
        checkMotion(name: "420v 1080p/720p diagonal -48,+48", matrix: .rec709, dx: -48, dy: 48, sourceWidth: 1920, sourceHeight: 1080)
        checkInFlightImages()
        for matrix in [nil, VideoMatrix.rec709] {
            benchmark(sourceWidth: 1280, sourceHeight: 720, width: 1280, height: 720, matrix: matrix, present: false)
            benchmark(sourceWidth: 1280, sourceHeight: 720, width: 1280, height: 720, matrix: matrix, present: true)
            benchmark(sourceWidth: 1920, sourceHeight: 1080, width: 1280, height: 720, matrix: matrix, present: true)
        }
        benchmark(sourceWidth: 1920, sourceHeight: 1080, width: 1920, height: 1080, matrix: .rec709, present: true)
        workingSizeSweep()
        print("Image checks: \(checks - failures.count)/\(checks) passed; \(failures.count) failed.")
        print("Performance is reported separately; no universal 4 ms pass/fail gate.")
        if !failures.isEmpty { fail(failures.joined(separator: "; ")) }
        exit(0)
    }

    private func checkStaticImages() {
        let width = 256, height = 192
        let bytes = Self.colorChart(width: width, height: height)
        let bgraCases: [(String, CGColorSpace?)] = [
            ("BGRA implicit sRGB", nil), ("BGRA tagged sRGB", colorSpace),
            ("BGRA tagged Rec.709", CGColorSpace(name: CGColorSpace.itur_709)!),
            ("BGRA tagged Display P3", CGColorSpace(name: CGColorSpace.displayP3)!)
        ]
        for (name, space) in bgraCases {
            let a = Self.makeBGRA(width: width, height: height, bytes: bytes, colorSpace: space)
            let b = Self.makeBGRA(width: width, height: height, bytes: bytes, colorSpace: space)
            checkStatic(name: name, previous: CIImage(cvPixelBuffer: a), current: CIImage(cvPixelBuffer: b),
                        previousBuffer: a, currentBuffer: b, width: width, height: height)
        }
        let buffer = Self.makeBGRA(width: width, height: height, bytes: bytes, colorSpace: colorSpace)
        let image = CIImage(cvPixelBuffer: buffer)
        checkStatic(name: "CI image only", previous: image, current: image, width: width, height: height)
        checkStatic(name: "mixed raw/CI input", previous: image, current: image, previousBuffer: buffer, width: width, height: height)
        for orientation in [CGImagePropertyOrientation.down, .upMirrored, .right] {
            let oriented = image.oriented(orientation)
            checkStatic(name: "oriented CI \(orientation.rawValue) with buffer", previous: oriented, current: oriented,
                        previousBuffer: buffer, currentBuffer: buffer, width: Int(oriented.extent.width), height: Int(oriented.extent.height))
        }
        let cropped = image.cropped(to: CGRect(x: 32, y: 16, width: 192, height: 144))
        checkStatic(name: "cropped CI with buffer", previous: cropped, current: cropped,
                    previousBuffer: buffer, currentBuffer: buffer, width: 192, height: 144)
        let override = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!])
        checkStatic(name: "CI colorSpace override with buffer", previous: override, current: override,
                    previousBuffer: buffer, currentBuffer: buffer, width: width, height: height)
        checkStatic(name: "BGRA requested half size", previous: image, current: image,
                    previousBuffer: buffer, currentBuffer: buffer, width: width / 2, height: height / 2)

        for matrix in [VideoMatrix.rec709, .rec601, .rec2020] {
            for chroma in [kCVImageBufferChromaLocation_Center, kCVImageBufferChromaLocation_Left] {
                let a = Self.make420v(width: width, height: height, bytes: bytes, matrix: matrix, chroma: chroma)
                let b = Self.make420v(width: width, height: height, bytes: bytes, matrix: matrix, chroma: chroma)
                checkStatic(name: "420v \(matrix) \(chroma)", previous: CIImage(cvPixelBuffer: a), current: CIImage(cvPixelBuffer: b),
                            previousBuffer: a, currentBuffer: b, width: width, height: height)
            }
        }
        let yuv = Self.make420v(width: width, height: height, bytes: bytes, matrix: .rec709)
        let yuvImage = CIImage(cvPixelBuffer: yuv)
        checkStatic(name: "420v CI image only", previous: yuvImage, current: yuvImage, width: width, height: height)
        checkStatic(name: "420v mixed raw/CI", previous: yuvImage, current: yuvImage,
                    previousBuffer: yuv, width: width, height: height)
        checkStatic(name: "420v requested half size", previous: yuvImage, current: yuvImage,
                    previousBuffer: yuv, currentBuffer: yuv, width: width / 2, height: height / 2)
        let untagged = Self.make420v(width: width, height: height, bytes: bytes, matrix: .rec601, tagged: false)
        checkStatic(name: "420v implicit metadata", previous: CIImage(cvPixelBuffer: untagged), current: CIImage(cvPixelBuffer: untagged),
                    previousBuffer: untagged, currentBuffer: untagged, width: width, height: height)
        // This is the real 1080p-input/720p-work rung, with dark and colored panels.
        let largeBytes = Self.colorChart(width: 1920, height: 1080)
        for matrix in [nil, VideoMatrix.rec709] {
            let large = matrix.map { Self.make420v(width: 1920, height: 1080, bytes: largeBytes, matrix: $0) }
                ?? Self.makeBGRA(width: 1920, height: 1080, bytes: largeBytes, colorSpace: colorSpace)
            checkStatic(name: "\(matrix == nil ? "BGRA" : "420v") 1080p input / 720p work", previous: CIImage(cvPixelBuffer: large),
                        current: CIImage(cvPixelBuffer: large), previousBuffer: large, currentBuffer: large, width: 1280, height: 720)
        }
    }

    private func checkStatic(name: String, previous: CIImage, current: CIImage,
                             previousBuffer: CVPixelBuffer? = nil, currentBuffer: CVPixelBuffer? = nil, width: Int, height: Int) {
        interpolator.prepare(width: width, height: height)
        let reference = renderReference(previous, width: width, height: height)
        for blend: Float in [0, 0.5, 1] {
            let actual = interpolate(previous: previous, current: current, previousBuffer: previousBuffer,
                                     currentBuffer: currentBuffer, blend: blend, width: width, height: height)
            let error = Self.error(actual, reference)
            let flipped = Self.error(actual, Self.flipRows(reference, width: width, height: height))
            let description = String(format: "RGB MAE %.3f codes, max %d, Y bias %+.3f; flipped-reference MAE %.3f",
                                     error.mean, error.maximum, error.lumaBias, flipped.mean)
            // Two codes cover 8-bit rendering/sampler rounding. Dark, saturated and
            // asymmetric panels expose transfer/matrix/row mistakes independently.
            check(error.mean <= 0.5 && error.maximum <= 2 && abs(error.lumaBias) <= 0.25,
                  "\(name) blend=\(blend)", description)
        }
    }

    private func checkMotion(name: String, matrix: VideoMatrix?, dx: Int, dy: Int,
                             sourceWidth: Int = 1280, sourceHeight: Int = 720) {
        let width = 1280, height = 720, blockSize = 192
        interpolator.prepare(width: width, height: height)
        let sourceAX = 336, sourceAY = 240, sourceBX = sourceAX + dx, sourceBY = sourceAY + dy
        let sx = Double(width) / Double(sourceWidth), sy = Double(height) / Double(sourceHeight)
        let ax = Int(Double(sourceAX) * sx), ay = Int(Double(sourceAY) * sy)
        let bx = Int(Double(sourceBX) * sx), by = Int(Double(sourceBY) * sy)
        let blockWidth = Int(Double(blockSize) * sx), blockHeight = Int(Double(blockSize) * sy)
        func make(_ x: Int, _ y: Int) -> CVPixelBuffer {
            let bytes = Self.movingChart(width: sourceWidth, height: sourceHeight, blockX: x, blockY: y, blockSize: blockSize)
            return matrix.map { Self.make420v(width: sourceWidth, height: sourceHeight, bytes: bytes, matrix: $0) }
                ?? Self.makeBGRA(width: sourceWidth, height: sourceHeight, bytes: bytes, colorSpace: colorSpace)
        }
        let a = make(sourceAX, sourceAY), b = make(sourceBX, sourceBY)
        let ideal = make((sourceAX + sourceBX) / 2, (sourceAY + sourceBY) / 2)
        let previous = CIImage(cvPixelBuffer: a), current = CIImage(cvPixelBuffer: b)
        let nativeA = renderReference(previous, width: width, height: height)
        let nativeB = renderReference(current, width: width, height: height)
        let reference = renderReference(CIImage(cvPixelBuffer: ideal), width: width, height: height)
        for blend: Float in [0, 1] {
            let actual = interpolate(previous: previous, current: current, previousBuffer: a, currentBuffer: b,
                                     blend: blend, width: width, height: height)
            let error = Self.error(actual, blend == 0 ? nativeA : nativeB)
            check(error.mean <= 0.5 && error.maximum <= 2, "\(name) endpoint \(blend)",
                  String(format: "RGB MAE %.3f codes, max %d", error.mean, error.maximum))
        }
        let actual = interpolate(previous: previous, current: current, previousBuffer: a, currentBuffer: b,
                                 blend: 0.5, width: width, height: height)
        var flowRGB = 0.0, dissolveRGB = 0.0, flowY = 0.0, dissolveY = 0.0
        var samples = 0
        let mx = (ax + bx) / 2, my = (ay + by) / 2
        for y in (my - 24)..<(my + blockHeight + 24) {
            for x in (mx - 24)..<(mx + blockWidth + 24) {
                // Default CI->Metal rendering is bottom-up, unlike CV buffer rows.
                let offset = ((height - 1 - y) * width + x) * 4
                for channel in 0..<3 {
                    flowRGB += abs(Double(actual[offset + channel]) - Double(reference[offset + channel]))
                    dissolveRGB += abs((Double(nativeA[offset + channel]) + Double(nativeB[offset + channel])) * 0.5
                                       - Double(reference[offset + channel]))
                }
                flowY += abs(Self.luma(actual, offset) - Self.luma(reference, offset))
                dissolveY += abs((Self.luma(nativeA, offset) + Self.luma(nativeB, offset)) * 0.5 - Self.luma(reference, offset))
                samples += 1
            }
        }
        flowRGB /= Double(samples * 3) * 255
        dissolveRGB /= Double(samples * 3) * 255
        flowY /= Double(samples) * 255
        dissolveY /= Double(samples) * 255
        check(flowRGB < 0.13 && flowRGB < dissolveRGB * 0.95 && flowY < dissolveY * 0.95,
              "\(name) midpoint displacement",
              String(format: "RGB MAE flow %.4f / dissolve %.4f; Y MAE %.4f / %.4f", flowRGB, dissolveRGB, flowY, dissolveY))

        // Compare non-midpoint phases against the known translated-block image. The
        // edge ROI covers the block's previous, intermediate and current contours,
        // where a wrong reverse-flow lookup can change confidence with blend phase.
        for phase: Float in [0.25, 0.75] {
            let phaseSourceX = sourceAX + Int((Double(sourceBX - sourceAX) * Double(phase)).rounded())
            let phaseSourceY = sourceAY + Int((Double(sourceBY - sourceAY) * Double(phase)).rounded())
            let phaseX = Int(Double(phaseSourceX) * sx), phaseY = Int(Double(phaseSourceY) * sy)
            let phaseBuffer = make(phaseSourceX, phaseSourceY)
            let phaseReference = renderReference(CIImage(cvPixelBuffer: phaseBuffer), width: width, height: height)
            let phaseActual = interpolate(previous: previous, current: current, previousBuffer: a, currentBuffer: b,
                                          blend: phase, width: width, height: height)
            let roiPadding = 24, edgeRadius = 8
            let roiMinX = max(0, min(ax, min(phaseX, bx)) - roiPadding)
            let roiMinY = max(0, min(ay, min(phaseY, by)) - roiPadding)
            let roiMaxX = min(width, max(ax, max(phaseX, bx)) + blockWidth + roiPadding)
            let roiMaxY = min(height, max(ay, max(phaseY, by)) + blockHeight + roiPadding)
            var roiFlowError = 0.0, roiDissolveError = 0.0
            var edgeFlowError = 0.0, edgeDissolveError = 0.0
            var roiPixels = 0, edgePixels = 0

            func nearBoundary(_ x: Int, _ y: Int, _ blockX: Int, _ blockY: Int) -> Bool {
                let left = blockX, right = blockX + blockWidth - 1
                let top = blockY, bottom = blockY + blockHeight - 1
                return x >= left - edgeRadius && x <= right + edgeRadius &&
                       y >= top - edgeRadius && y <= bottom + edgeRadius &&
                       (abs(x - left) <= edgeRadius || abs(x - right) <= edgeRadius ||
                        abs(y - top) <= edgeRadius || abs(y - bottom) <= edgeRadius)
            }

            for y in roiMinY..<roiMaxY {
                for x in roiMinX..<roiMaxX {
                    let offset = ((height - 1 - y) * width + x) * 4
                    let isEdge = nearBoundary(x, y, ax, ay) || nearBoundary(x, y, phaseX, phaseY) ||
                                 nearBoundary(x, y, bx, by)
                    for channel in 0..<3 {
                        let expected = Double(phaseReference[offset + channel])
                        let dissolve = Double(nativeA[offset + channel]) * (1.0 - Double(phase)) +
                                       Double(nativeB[offset + channel]) * Double(phase)
                        roiFlowError += abs(Double(phaseActual[offset + channel]) - expected)
                        roiDissolveError += abs(dissolve - expected)
                        if isEdge {
                            edgeFlowError += abs(Double(phaseActual[offset + channel]) - expected)
                            edgeDissolveError += abs(dissolve - expected)
                        }
                    }
                    roiPixels += 1
                    if isEdge { edgePixels += 1 }
                }
            }
            let roiFlowMAE = roiFlowError / Double(roiPixels * 3 * 255)
            let roiDissolveMAE = roiDissolveError / Double(roiPixels * 3 * 255)
            let edgeFlowMAE = edgeFlowError / Double(edgePixels * 3 * 255)
            let edgeDissolveMAE = edgeDissolveError / Double(edgePixels * 3 * 255)
            check(roiFlowMAE < 0.13 && roiFlowMAE < roiDissolveMAE * 0.95,
                  "\(name) phase \(phase) motion ROI",
                  String(format: "RGB MAE flow %.4f / phase-weighted dissolve %.4f", roiFlowMAE, roiDissolveMAE))
            check(edgePixels > 0 && edgeFlowMAE < 0.13 && edgeFlowMAE < edgeDissolveMAE * 0.95,
                  "\(name) phase \(phase) motion/occlusion boundary",
                  String(format: "RGB MAE flow %.4f / phase-weighted dissolve %.4f over %d boundary pixels",
                         edgeFlowMAE, edgeDissolveMAE, edgePixels))
        }

        var backgroundMax = 0
        var interiorBias = [Double](repeating: 0, count: 3)
        var interiorSamples = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = ((height - 1 - y) * width + x) * 4
                if x < min(ax, bx) - 64 || x >= max(ax, bx) + blockWidth + 64 ||
                   y < min(ay, by) - 64 || y >= max(ay, by) + blockHeight + 64 {
                    for channel in 0..<3 {
                        backgroundMax = max(backgroundMax, abs(Int(actual[offset + channel]) - Int(nativeA[offset + channel])))
                    }
                }
                if x >= mx + blockWidth / 3 && x < mx + blockWidth * 2 / 3 &&
                   y >= my + blockHeight / 3 && y < my + blockHeight * 2 / 3 {
                    for channel in 0..<3 {
                        interiorBias[channel] += Double(actual[offset + channel]) - Double(reference[offset + channel])
                    }
                    interiorSamples += 1
                }
            }
        }
        let bias = interiorBias.map { $0 / Double(interiorSamples) }
        check(backgroundMax <= 2 && bias.allSatisfy { abs($0) <= 3 }, "\(name) original/midpoint colors",
              String(format: "static background max %d; interior B/G/R bias %+.3f/%+.3f/%+.3f codes",
                     backgroundMax, bias[0], bias[1], bias[2]))
    }

    private func checkInFlightImages() {
        let width = 256, height = 192
        var pending: [(MTLCommandBuffer, MTLTexture, [UInt8])] = []
        for index in 0..<5 {
            let outputWidth = index % 2 == 0 ? width : width / 2
            let outputHeight = index % 2 == 0 ? height : height / 2
            interpolator.prepare(width: outputWidth, height: outputHeight)
            var bytes = Self.colorChart(width: width, height: height)
            for offset in stride(from: 0, to: bytes.count, by: 4) { bytes[offset + index % 3] /= 2 }
            let buffer = Self.makeBGRA(width: width, height: height, bytes: bytes, colorSpace: colorSpace)
            let image = CIImage(cvPixelBuffer: buffer)
            let reference = renderReference(image, width: outputWidth, height: outputHeight)
            let command = makeCommand()
            let texture = makeReadback(width: outputWidth, height: outputHeight)
            guard let output = interpolator.interpolate(previous: image, current: image,
                previousTime: CMTime(value: 0, timescale: 60), currentTime: CMTime(value: 1, timescale: 60),
                context: context, command: command, previousBuffer: buffer, currentBuffer: buffer, blendFactor: 0.5) else {
                fail("in-flight interpolation returned nil")
            }
            check(output.extent == CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
                  "in-flight prepared size \(index)", "actual \(output.extent)")
            context.render(output, to: texture, commandBuffer: command,
                           bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight), colorSpace: colorSpace)
            pending.append((command, texture, reference))
        }
        // Stopping/clearing the pool must not invalidate already encoded outputs.
        interpolator.stop()
        for (command, _, _) in pending { command.commit() }
        for (index, item) in pending.enumerated() {
            complete(item.0)
            let error = Self.error(read(item.1), item.2)
            check(error.mean <= 0.5 && error.maximum <= 2, "in-flight static midpoint \(index)",
                  String(format: "RGB MAE %.3f codes, max %d", error.mean, error.maximum))
        }
    }

    private func benchmark(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int, matrix: VideoMatrix?, present: Bool) {
        measure(sourceWidth: sourceWidth, sourceHeight: sourceHeight, width: width, height: height, matrix: matrix, present: present, label: "BENCH")
    }

    /// Total cost by working size for one 1080p 420v source. The flow search runs at
    /// quarter resolution, so a smaller working size saves kernel work but adds Core
    /// Image normalization work; this sweep shows where the balance actually falls.
    private func workingSizeSweep() {
        for (sourceWidth, sourceHeight, sizes) in [
            (1920, 1080, [(1920, 1080), (1440, 810), (1280, 720), (960, 540), (854, 480)]),
            (2560, 1440, [(2560, 1440), (1920, 1080), (1280, 720)]),
            (3840, 2160, [(3840, 2160), (1920, 1080), (1280, 720)])
        ] {
            print("WORKING SIZE SWEEP (\(sourceWidth)x\(sourceHeight) 420v input, normalize+flow+final CI render)")
            for (width, height) in sizes {
                // A fresh engine per size: one shared pool would mix allocation costs of the
                // previous size into the next, which is not the steady-state product path.
                guard let fresh = FlowBlendInterpolator(device: device) else { fail("sweep engine creation") }
                let saved = interpolator
                interpolator = fresh
                measure(sourceWidth: sourceWidth, sourceHeight: sourceHeight, width: width, height: height,
                        matrix: .rec709, present: true, label: "SWEEP")
                interpolator = saved
            }
        }
    }

    private func measure(sourceWidth: Int, sourceHeight: Int, width: Int, height: Int, matrix: VideoMatrix?, present: Bool, label: String) {
        let bytesA = Self.movingChart(width: sourceWidth, height: sourceHeight, blockX: 272, blockY: 192, blockSize: 192)
        let bytesB = Self.movingChart(width: sourceWidth, height: sourceHeight, blockX: 320, blockY: 192, blockSize: 192)
        let a = matrix.map { Self.make420v(width: sourceWidth, height: sourceHeight, bytes: bytesA, matrix: $0) }
            ?? Self.makeBGRA(width: sourceWidth, height: sourceHeight, bytes: bytesA, colorSpace: colorSpace)
        let b = matrix.map { Self.make420v(width: sourceWidth, height: sourceHeight, bytes: bytesB, matrix: $0) }
            ?? Self.makeBGRA(width: sourceWidth, height: sourceHeight, bytes: bytesB, colorSpace: colorSpace)
        let previous = CIImage(cvPixelBuffer: a), current = CIImage(cvPixelBuffer: b)
        interpolator.prepare(width: width, height: height)
        let texture = makeReadback(width: width, height: height)
        let warmups = 3, measured = 20
        var gpu: [Double] = [], encoding: [Double] = [], completion: [Double] = []
        var actualExtent = CGRect.zero
        for index in 0..<(warmups + measured) {
            let command = makeCommand()
            let started = ProcessInfo.processInfo.systemUptime
            guard let output = interpolator.interpolate(previous: previous, current: current,
                previousTime: CMTime(value: 0, timescale: 60), currentTime: CMTime(value: 1, timescale: 60),
                context: context, command: command, previousBuffer: a, currentBuffer: b, blendFactor: 0.5) else {
                fail("benchmark interpolation returned nil")
            }
            actualExtent = output.extent
            if present {
                context.render(output, to: texture, commandBuffer: command,
                               bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
            }
            let submitted = ProcessInfo.processInfo.systemUptime
            command.commit()
            complete(command)
            let ended = ProcessInfo.processInfo.systemUptime
            if index >= warmups {
                gpu.append((command.gpuEndTime - command.gpuStartTime) * 1000)
                encoding.append((submitted - started) * 1000)
                completion.append((ended - submitted) * 1000)
            }
        }
        let format = matrix == nil ? "BGRA" : "420v"
        let scope = present ? "normalize+flow+final CI render" : "normalize+flow"
        print("\(label) input \(sourceWidth)x\(sourceHeight), requested \(width)x\(height), actual \(Int(actualExtent.width))x\(Int(actualExtent.height)) \(format) \(scope); \(warmups) warmups + \(measured) samples")
        print("  GPU ms: \(Self.timing(gpu))")
        print("  CPU encode ms: \(Self.timing(encoding)); commit-to-completion ms: \(Self.timing(completion))")
        check(actualExtent == CGRect(x: 0, y: 0, width: width, height: height), "benchmark \(format) working dimensions", "actual \(actualExtent)")
    }

    private func interpolate(previous: CIImage, current: CIImage, previousBuffer: CVPixelBuffer?, currentBuffer: CVPixelBuffer?,
                             blend: Float, width: Int, height: Int) -> [UInt8] {
        let command = makeCommand()
        let texture = makeReadback(width: width, height: height)
        guard let output = interpolator.interpolate(previous: previous, current: current,
            previousTime: CMTime(value: 0, timescale: 60), currentTime: CMTime(value: 1, timescale: 60),
            context: context, command: command, previousBuffer: previousBuffer, currentBuffer: currentBuffer,
            blendFactor: blend) else { fail("interpolation returned nil") }
        check(output.extent == CGRect(x: 0, y: 0, width: width, height: height), "CI output geometry blend=\(blend)",
              "expected \(width)x\(height), actual \(output.extent)")
        context.render(output, to: texture, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        command.commit()
        complete(command)
        return read(texture)
    }

    private func renderReference(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        let command = makeCommand()
        let texture = makeReadback(width: width, height: height)
        var normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let sx = Double(width) / image.extent.width, sy = Double(height) / image.extent.height
        if abs(sx - 1) > 0.000001 || abs(sy - 1) > 0.000001 {
            normalized = normalized.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        }
        context.render(normalized, to: texture, commandBuffer: command,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        command.commit()
        complete(command)
        return read(texture)
    }

    private func makeCommand() -> MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else { fail("could not create command buffer") }
        return command
    }

    private func complete(_ command: MTLCommandBuffer) {
        command.waitUntilCompleted()
        guard command.status == .completed else { fail("Metal command failed: \(String(describing: command.error))") }
        guard command.gpuEndTime > command.gpuStartTime else { fail("GPU timestamps unavailable") }
    }

    private func makeReadback(width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { fail("could not create readback texture") }
        return texture
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    private func check(_ passed: Bool, _ name: String, _ detail: String) {
        checks += 1
        if !passed { failures.append(name) }
        if !passed || !name.hasPrefix("CI output geometry") { print("\(passed ? "PASS" : "FAIL") \(name): \(detail)") }
    }

    private static func timing(_ values: [Double]) -> String {
        let sorted = values.sorted(), count = values.count
        let p95 = sorted[Int(ceil(Double(count) * 0.95)) - 1]
        return String(format: "mean %.3f, median %.3f, p95 %.3f, min %.3f, max %.3f",
                      sorted.reduce(0, +) / Double(count), (sorted[count / 2 - 1] + sorted[count / 2]) * 0.5,
                      p95, sorted[0], sorted.last!)
    }

    private static func error(_ actual: [UInt8], _ expected: [UInt8]) -> ImageError {
        precondition(actual.count == expected.count)
        var sum = 0.0, bias = 0.0, maximum = 0
        for offset in stride(from: 0, to: actual.count, by: 4) {
            for channel in 0..<3 {
                let difference = abs(Int(actual[offset + channel]) - Int(expected[offset + channel]))
                maximum = max(maximum, difference)
                sum += Double(difference)
            }
            bias += luma(actual, offset) - luma(expected, offset)
        }
        return ImageError(mean: sum / Double(actual.count / 4 * 3), maximum: maximum, lumaBias: bias / Double(actual.count / 4))
    }

    private static func luma(_ bytes: [UInt8], _ offset: Int) -> Double {
        0.2126 * Double(bytes[offset + 2]) + 0.7152 * Double(bytes[offset + 1]) + 0.0722 * Double(bytes[offset])
    }

    private static func flipRows(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<height {
            result.replaceSubrange(y * width * 4..<(y + 1) * width * 4,
                                   with: bytes[(height - 1 - y) * width * 4..<(height - y) * width * 4])
        }
        return result
    }

    private static func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { fail("could not create pixel buffer") }
        return buffer
    }

    private static func makeBGRA(width: Int, height: Int, bytes: [UInt8], colorSpace: CGColorSpace?) -> CVPixelBuffer {
        let buffer = makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        if let colorSpace { CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate) }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else { fail("could not lock BGRA buffer") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        bytes.withUnsafeBytes { source in
            for y in 0..<height { memcpy(base.advanced(by: y * stride), source.baseAddress!.advanced(by: y * width * 4), width * 4) }
        }
        return buffer
    }

    private static func make420v(width: Int, height: Int, bytes: [UInt8], matrix: VideoMatrix,
                                 chroma: CFString = kCVImageBufferChromaLocation_Center, tagged: Bool = true) -> CVPixelBuffer {
        let buffer = makeBuffer(width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        if tagged {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix.attachment, .shouldPropagate)
            let primaries = matrix == .rec2020 ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
            let transfer = matrix == .rec2020 ? kCVImageBufferTransferFunction_ITU_R_2020 : kCVImageBufferTransferFunction_ITU_R_709_2
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, chroma, .shouldPropagate)
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { fail("could not lock 420v buffer") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let (kr, kb) = matrix.coefficients
        let kg = 1 - kr - kb
        for y in 0..<height {
            let row = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = (kr * Double(bytes[offset + 2]) + kg * Double(bytes[offset + 1]) + kb * Double(bytes[offset])) / 255
                row[x] = UInt8(max(16, min(235, Int((16 + 219 * luma).rounded()))))
            }
        }
        for y in stride(from: 0, to: height, by: 2) {
            let row = uvBase.advanced(by: y / 2 * uvStride).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: 2) {
                var r = 0.0, g = 0.0, b = 0.0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let offset = ((y + dy) * width + x + dx) * 4
                        r += Double(bytes[offset + 2]) / 1020
                        g += Double(bytes[offset + 1]) / 1020
                        b += Double(bytes[offset]) / 1020
                    }
                }
                let luma = kr * r + kg * g + kb * b
                let cb = (b - luma) / (2 * (1 - kb)), cr = (r - luma) / (2 * (1 - kr))
                row[x] = UInt8(max(16, min(240, Int((128 + 224 * cb).rounded()))))
                row[x + 1] = UInt8(max(16, min(240, Int((128 + 224 * cr).rounded()))))
            }
        }
        return buffer
    }

    private static func colorChart(width: Int, height: Int) -> [UInt8] {
        let palette: [(Int, Int, Int)] = [(214, 35, 55), (28, 181, 78), (32, 60, 222), (205, 112, 24),
            (25, 172, 190), (200, 45, 170), (170, 172, 30), (103, 44, 181),
            (12, 23, 36), (26, 17, 41), (44, 37, 19), (16, 41, 29),
            (92, 147, 196), (177, 94, 64), (71, 103, 128), (214, 199, 173)]
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = y / (height / 4) * 4 + x / (width / 4)
                let (r, g, b) = palette[index]
                let texture = ((x / 4 * 17 + y / 4 * 29 + x / 4 * (y / 4) * 3) & 7) - 3
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(b + texture)
                bytes[offset + 1] = UInt8(g + texture)
                bytes[offset + 2] = UInt8(r + texture)
            }
        }
        return bytes
    }

    private static func movingChart(width: Int, height: Int, blockX: Int, blockY: Int, blockSize: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if x >= blockX && x < blockX + blockSize && y >= blockY && y < blockY + blockSize {
                    let tx = (x - blockX) / 8, ty = (y - blockY) / 8
                    let value = 140 + ((tx * 17 + ty * 29 + tx * ty * 3) & 7) * 14
                    bytes[offset] = UInt8(value - 28)
                    bytes[offset + 1] = UInt8(value - 12)
                    bytes[offset + 2] = UInt8(value)
                } else {
                    bytes[offset] = y < height / 2 ? 36 : 52
                    bytes[offset + 1] = y < height / 2 ? 30 : 24
                    bytes[offset + 2] = y < height / 2 ? 24 : 44
                }
            }
        }
        return bytes
    }
}

guard let device = MTLCreateSystemDefaultDevice() else {
    print("SKIP: Metal device unavailable (not a pass)")
    exit(2)
}
guard let suite = FlowBlendSuite(device: device) else { fail("could not initialize fixture") }
suite.run()
