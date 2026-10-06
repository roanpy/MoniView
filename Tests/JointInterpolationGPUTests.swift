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
    print("SKIP: \(message) (not a pass)")
    exit(2)
}

private struct RGB: CustomStringConvertible {
    let red: Double
    let green: Double
    let blue: Double

    var description: String {
        String(format: "(%.3f, %.3f, %.3f)", red, green, blue)
    }
}

private struct JointCase {
    let width: Int
    let height: Int
    let optional: Bool

    var label: String { "\(width)x\(height)→\(width * 2)x\(height * 2)" }
}

private struct JointBuffers {
    var previous: CVPixelBuffer
    let scaledSource: CVPixelBuffer
    let midpoint: CVPixelBuffer
}

private enum ProcessingMode: Equatable {
    case commandBuffer
    case asyncDiagnostic
}

@available(macOS 26.0, *)
private final class JointInterpolationGPUSuite {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let mode: ProcessingMode
    private let serialQueue = DispatchQueue(label: "MoniView.JointInterpolationGPUFixture", qos: .userInitiated)
    private let cases: [JointCase]

    // All mutable fixture state is confined to serialQueue.
    private var caseIndex = 0
    private var commandIndex = 0
    private var processor: VTFrameProcessor?
    private var configuration: VTLowLatencyFrameInterpolationConfiguration?
    private var buffers: JointBuffers?
    private var sourcePixelBufferAttributes: [String: any Sendable]?
    private var cpuMilliseconds: [Double] = []
    private var gpuMilliseconds: [Double] = []
    private var asyncCompletionWallMilliseconds: [Double] = []
    private var skippedRequiredCases: [String] = []
    private var skippedOptionalCases: [String] = []
    private var finished = false
    private let finishedLock = NSLock()

    init(device: MTLDevice, commandQueue: MTLCommandQueue?, mode: ProcessingMode) {
        self.device = device
        self.commandQueue = commandQueue
        self.mode = mode

        let allCases = [
            JointCase(width: 640, height: 360, optional: false),
            JointCase(width: 960, height: 540, optional: false),
            JointCase(width: 1920, height: 1080, optional: true)
        ]
        if let selector = ProcessInfo.processInfo.environment["MONIVIEW_JOINT_CASES"] {
            let selectedWidths = Set(selector.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let validWidths: Set<String> = ["640", "960", "1920"]
            guard !selectedWidths.isEmpty, selectedWidths.isSubset(of: validWidths) else {
                fail("MONIVIEW_JOINT_CASES must be a comma-separated subset of 640,960,1920")
            }
            if mode == .asyncDiagnostic, selectedWidths.count != 1 {
                fail("async diagnostic accepts exactly one source width in MONIVIEW_JOINT_CASES")
            }
            self.cases = allCases.filter { selectedWidths.contains(String($0.width)) }
        } else if mode == .asyncDiagnostic {
            self.cases = [allCases[0]]
        } else {
            self.cases = allCases
        }
    }

    func start() {
        print("GPU device: \(device.name)")
        switch mode {
        case .commandBuffer:
            print("Joint VideoToolbox fixture: 2 serial warmups + 60 serial steady command buffers per supported resolution.")
            print("CPU timing covers only VTFrameProcessor.process(with:) encoding, excluding pixel-buffer allocation/fill; GPU timing uses command-buffer timestamps. No frames are presented.")
        case .asyncDiagnostic:
            print("Joint VideoToolbox async diagnostic: one process(parameters:completionHandler:) call per selected resolution; reports wall-clock completion only, collects no GPU timing, and presents no frames.")
        }
        if let selector = ProcessInfo.processInfo.environment["MONIVIEW_JOINT_CASES"] {
            print("Case filter MONIVIEW_JOINT_CASES=\(selector)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 900) { [weak self] in
            guard let self, !self.isFinished else { return }
            fail("joint interpolation GPU fixture timed out")
        }

        serialQueue.async { [self] in
            beginNextCase()
        }
    }

    private var isFinished: Bool {
        finishedLock.lock()
        defer { finishedLock.unlock() }
        return finished
    }

    private func setFinished() {
        finishedLock.lock()
        finished = true
        finishedLock.unlock()
    }

    private func beginNextCase() {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        guard caseIndex < cases.count else {
            finishSuite()
            return
        }

        let testCase = cases[caseIndex]
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: testCase.width,
            frameHeight: testCase.height,
            spatialScaleFactor: 2
        ) else {
            skipCase(testCase, reason: "runtime rejected the 2x joint configuration")
            return
        }
        print("CONFIG \(testCase.label): spatialScaleFactor=\(configuration.spatialScaleFactor) numberOfInterpolatedFrames=\(configuration.numberOfInterpolatedFrames) requestedPhases=[0.5] destinationCount=2 supportedPixelFormats=\(configuration.supportedPixelFormats)")
        print("SOURCE_REQUIRED_ATTRIBUTES \(describeAttributes(configuration.sourcePixelBufferAttributes))")
        print("DESTINATION_REQUIRED_ATTRIBUTES \(describeAttributes(configuration.destinationPixelBufferAttributes))")
        guard configuration.supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
            skipCase(testCase, reason: "runtime does not advertise Rec.709 420v for the joint configuration")
            return
        }

        self.configuration = configuration
        let frameProcessor = VTFrameProcessor()
        do {
            try frameProcessor.startSession(configuration: configuration)
        } catch {
            frameProcessor.endSession()
            self.configuration = nil
            let nsError = error as NSError
            if nsError.domain == VTFrameProcessorErrorDomain && nsError.code == -19731 {
                skipCase(testCase, reason: "VideoToolbox reported unsupported source resolution")
                return
            }
            fail("startSession failed at \(testCase.label): \(error)")
        }

        let caseBuffers = makeBuffers(for: testCase, configuration: configuration)
        processor = frameProcessor
        buffers = caseBuffers
        sourcePixelBufferAttributes = configuration.sourcePixelBufferAttributes
        commandIndex = 0
        cpuMilliseconds.removeAll(keepingCapacity: true)
        gpuMilliseconds.removeAll(keepingCapacity: true)
        asyncCompletionWallMilliseconds.removeAll(keepingCapacity: true)
        print("RUN \(testCase.label): source Rec.709 420v; phase 0.5; destination[0]=scaled source, destination[1]=midpoint")
        encodeNextCommand(for: testCase)
    }

    private func describeAttributes(_ attributes: [String: any Sendable]) -> String {
        attributes.keys.sorted().map { key in
            "\(key)=\(String(describing: attributes[key]!))"
        }.joined(separator: "; ")
    }

    private func skipCase(_ testCase: JointCase, reason: String) {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        configuration = nil
        print("SKIP \(testCase.label): \(reason) (not a pass)")
        if !testCase.optional {
            skippedRequiredCases.append(testCase.label)
        } else {
            skippedOptionalCases.append(testCase.label)
        }
        caseIndex += 1
        beginNextCase()
    }

    private func makeBuffers(
        for testCase: JointCase,
        configuration: VTLowLatencyFrameInterpolationConfiguration
    ) -> JointBuffers {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        let previous = makePixelBuffer(
            width: testCase.width,
            height: testCase.height,
            requiredAttributes: configuration.sourcePixelBufferAttributes,
            patchCenterX: trianglePatchCenter(frameIndex: 0)
        )
        let destinationWidth = testCase.width * 2
        let destinationHeight = testCase.height * 2
        let scaledSource = makePixelBuffer(
            width: destinationWidth,
            height: destinationHeight,
            requiredAttributes: configuration.destinationPixelBufferAttributes,
            patchCenterX: nil
        )
        let midpoint = makePixelBuffer(
            width: destinationWidth,
            height: destinationHeight,
            requiredAttributes: configuration.destinationPixelBufferAttributes,
            patchCenterX: nil
        )
        return JointBuffers(previous: previous, scaledSource: scaledSource, midpoint: midpoint)
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        requiredAttributes: [String: any Sendable],
        patchCenterX: Double?
    ) -> CVPixelBuffer {
        var attributes = requiredAttributes.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = entry.value
        }
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
            fail("could not allocate 420v pixel buffer at \(width)x\(height), status \(status)")
        }

        if let patchCenterX {
            fillRec709420v(pixelBuffer, patchCenterX: patchCenterX)
        }
        attachRec709Metadata(to: pixelBuffer)
        CVBufferSetAttachment(
            pixelBuffer,
            kCGImagePropertyOrientation,
            NSNumber(value: CGImagePropertyOrientation.up.rawValue),
            .shouldPropagate
        )
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            fail("created pixel buffer does not match requested 420v dimensions \(width)x\(height)")
        }
        return pixelBuffer
    }

    private func attachRec709Metadata(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
    }

    private func fillRec709420v(_ pixelBuffer: CVPixelBuffer, patchCenterX: Double) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width.isMultiple(of: 2), height.isMultiple(of: 2),
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess,
              let yAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            fail("could not lock planar 420v source buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let yPlane = yAddress.assumingMemoryBound(to: UInt8.self)
        let uvPlane = uvAddress.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        for row in 0..<height {
            let outputRow = yPlane.advanced(by: row * yStride)
            for column in 0..<width {
                let color = patternColor(x: column, y: row, width: width, height: height, patchCenterX: patchCenterX)
                outputRow[column] = videoRangeLuma(color)
            }
        }

        for row in 0..<(height / 2) {
            let outputRow = uvPlane.advanced(by: row * uvStride)
            for column in 0..<(width / 2) {
                let x = column * 2
                let y = row * 2
                let colors = [
                    patternColor(x: x, y: y, width: width, height: height, patchCenterX: patchCenterX),
                    patternColor(x: x + 1, y: y, width: width, height: height, patchCenterX: patchCenterX),
                    patternColor(x: x, y: y + 1, width: width, height: height, patchCenterX: patchCenterX),
                    patternColor(x: x + 1, y: y + 1, width: width, height: height, patchCenterX: patchCenterX)
                ]
                let average = RGB(
                    red: colors.reduce(0) { $0 + $1.red } / 4,
                    green: colors.reduce(0) { $0 + $1.green } / 4,
                    blue: colors.reduce(0) { $0 + $1.blue } / 4
                )
                let luma = 0.2126 * average.red + 0.7152 * average.green + 0.0722 * average.blue
                let cb = (average.blue - luma) / (2 * (1 - 0.0722))
                let cr = (average.red - luma) / (2 * (1 - 0.2126))
                outputRow[column * 2] = videoRangeChroma(cb)
                outputRow[column * 2 + 1] = videoRangeChroma(cr)
            }
        }
    }

    private func patternColor(x: Int, y: Int, width: Int, height: Int, patchCenterX: Double) -> RGB {
        let nx = (Double(x) + 0.5) / Double(width)
        let ny = (Double(y) + 0.5) / Double(height)
        if abs(nx - patchCenterX) <= 0.018 && (0.40...0.60).contains(ny) {
            return RGB(red: 1, green: 0, blue: 1)
        }
        if ny < 0.5 {
            return nx < 0.5 ? RGB(red: 1, green: 0, blue: 0) : RGB(red: 0, green: 1, blue: 0)
        }
        return nx < 0.5 ? RGB(red: 0, green: 0, blue: 1) : RGB(red: 1, green: 1, blue: 0)
    }

    private func videoRangeLuma(_ color: RGB) -> UInt8 {
        let y = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return UInt8(clamping: Int((16 + 219 * y).rounded()))
    }

    private func videoRangeChroma(_ value: Double) -> UInt8 {
        UInt8(clamping: Int((128 + 224 * value).rounded()))
    }

    private func encodeNextCommand(for testCase: JointCase) {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        let commandLimit = mode == .commandBuffer ? 62 : 1
        guard commandIndex < commandLimit,
              let processor,
              let buffers,
              let sourcePixelBufferAttributes else {
            if commandIndex >= commandLimit {
                finishCurrentCase(testCase)
            } else {
                fail("could not prepare frame processing at \(testCase.label)")
            }
            return
        }

        let frameNumber = commandIndex
        let currentCenter = trianglePatchCenter(frameIndex: frameNumber + 1)
        let currentInput = makePixelBuffer(
            width: testCase.width,
            height: testCase.height,
            requiredAttributes: sourcePixelBufferAttributes,
            patchCenterX: currentCenter
        )
        let previousTime = CMTime(value: Int64(frameNumber), timescale: 30)
        let sourceTime = CMTime(value: Int64(frameNumber + 1), timescale: 30)
        let midpointTime = CMTime(value: Int64(frameNumber * 2 + 1), timescale: 60)
        // Preserve Apple's destination array order; timestamps follow each output's image content.
        guard let previousFrame = VTFrameProcessorFrame(buffer: buffers.previous, presentationTimeStamp: previousTime),
              let sourceFrame = VTFrameProcessorFrame(buffer: currentInput, presentationTimeStamp: sourceTime),
              let scaledSourceFrame = VTFrameProcessorFrame(buffer: buffers.scaledSource, presentationTimeStamp: sourceTime),
              let midpointFrame = VTFrameProcessorFrame(buffer: buffers.midpoint, presentationTimeStamp: midpointTime),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: sourceFrame,
                previousFrame: previousFrame,
                interpolationPhase: [0.5],
                destinationFrames: [scaledSourceFrame, midpointFrame]
              ) else {
            fail("could not create joint interpolation frames/parameters at \(testCase.label)")
        }

        if mode == .asyncDiagnostic {
            let wallStart = DispatchTime.now().uptimeNanoseconds
            processor.process(parameters: parameters) { [self, buffers, currentInput, previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters] _, error in
                let wallMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
                withExtendedLifetime((buffers, currentInput, previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters)) {}
                serialQueue.async { [self, buffers, currentInput, previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters] in
                    withExtendedLifetime((buffers, previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters)) {}
                    if let error {
                        self.processor?.endSession()
                        self.processor = nil
                        self.configuration = nil
                        let nsError = error as NSError
                        fail("async VideoToolbox processing failed at \(testCase.label): domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
                    }
                    print(String(format: "ASYNC COMPLETION %@: one source pair; wall-clock process-to-callback %.3f ms; GPU timing not collected", testCase.label, wallMilliseconds))
                    validateReadbacks(
                        testCase: testCase,
                        previousInput: buffers.previous,
                        currentInput: currentInput,
                        buffers: buffers,
                        expectedPreviousCenter: trianglePatchCenter(frameIndex: 0),
                        expectedCurrentCenter: trianglePatchCenter(frameIndex: 1)
                    )
                    asyncCompletionWallMilliseconds.append(wallMilliseconds)
                    self.buffers?.previous = currentInput
                    commandIndex = 1
                    finishCurrentCase(testCase)
                }
            }
            return
        }

        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            fail("could not allocate a Metal command buffer for \(testCase.label)")
        }

        let cpuStart = DispatchTime.now().uptimeNanoseconds
        processor.process(with: commandBuffer, parameters: parameters)
        let encodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - cpuStart) / 1_000_000
        commandBuffer.addCompletedHandler { [self, buffers, currentInput, previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters] completed in
            withExtendedLifetime((buffers, currentInput, previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters)) {}
            serialQueue.async { [self, buffers, currentInput, previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters] in
                commandCompleted(
                    completed,
                    testCase: testCase,
                    frameNumber: frameNumber,
                    encodeMilliseconds: encodeMilliseconds,
                    buffers: buffers,
                    previousInput: buffers.previous,
                    currentInput: currentInput,
                    retainedFrames: (previousFrame, sourceFrame, scaledSourceFrame, midpointFrame, parameters)
                )
            }
        }
        commandBuffer.commit()
    }

    private func commandCompleted(
        _ commandBuffer: MTLCommandBuffer,
        testCase: JointCase,
        frameNumber: Int,
        encodeMilliseconds: Double,
        buffers: JointBuffers,
        previousInput: CVPixelBuffer,
        currentInput: CVPixelBuffer,
        retainedFrames: (VTFrameProcessorFrame, VTFrameProcessorFrame, VTFrameProcessorFrame, VTFrameProcessorFrame, VTLowLatencyFrameInterpolationParameters)
    ) {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        withExtendedLifetime((buffers, retainedFrames)) {}
        guard commandBuffer.status == .completed else {
            fail("Metal command failed at \(testCase.label), command \(frameNumber): \(String(describing: commandBuffer.error))")
        }

        let gpuStart = commandBuffer.gpuStartTime
        let gpuEnd = commandBuffer.gpuEndTime
        let gpuTime: Double?
        if gpuStart > 0, gpuEnd > gpuStart {
            gpuTime = (gpuEnd - gpuStart) * 1000
        } else if frameNumber < 2 {
            gpuTime = nil
            print("WARMUP \(testCase.label) command \(frameNumber): GPU timestamps zero/unavailable; excluded, not a pass; no GPU-time inference.")
        } else {
            fail("steady GPU timestamps zero/unavailable at \(testCase.label), command \(frameNumber)")
        }

        if frameNumber == 2 {
            validateReadbacks(
                testCase: testCase,
                previousInput: previousInput,
                currentInput: currentInput,
                buffers: buffers,
                expectedPreviousCenter: trianglePatchCenter(frameIndex: frameNumber),
                expectedCurrentCenter: trianglePatchCenter(frameIndex: frameNumber + 1)
            )
        }
        if frameNumber >= 2 {
            guard let gpuTime else {
                fail("steady GPU timestamps missing at \(testCase.label), command \(frameNumber)")
            }
            cpuMilliseconds.append(encodeMilliseconds)
            gpuMilliseconds.append(gpuTime)
        }

        self.buffers?.previous = currentInput
        commandIndex += 1
        if commandIndex < 62 {
            encodeNextCommand(for: testCase)
        } else {
            finishCurrentCase(testCase)
        }
    }

    private func validateReadbacks(
        testCase: JointCase,
        previousInput: CVPixelBuffer,
        currentInput: CVPixelBuffer,
        buffers: JointBuffers,
        expectedPreviousCenter: Double,
        expectedCurrentCenter: Double
    ) {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        let expectedMidpointCenter = (expectedPreviousCenter + expectedCurrentCenter) / 2
        let previousReadback = inspectReadback(name: "previous input", pixelBuffer: previousInput, expectedPatchCenter: expectedPreviousCenter)
        let currentReadback = inspectReadback(name: "current input", pixelBuffer: currentInput, expectedPatchCenter: expectedCurrentCenter)
        let scaledReadback = inspectReadback(name: "destination[0] upscaled source output", pixelBuffer: buffers.scaledSource, expectedPatchCenter: expectedCurrentCenter)
        let midpointReadback = inspectReadback(name: "destination[1] midpoint output", pixelBuffer: buffers.midpoint, expectedPatchCenter: expectedMidpointCenter)
        for readback in [previousReadback, currentReadback, scaledReadback, midpointReadback] {
            fputs("\(readback.summary)\n", stderr)
        }
        fflush(stderr)

        for (name, buffer) in [("upscaled source", buffers.scaledSource), ("midpoint", buffers.midpoint)] {
            guard CVPixelBufferGetWidth(buffer) == testCase.width * 2,
                  CVPixelBufferGetHeight(buffer) == testCase.height * 2,
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                fail("\(name) readback has wrong dimensions or pixel format at \(testCase.label); see preceding per-buffer diagnostics")
            }
        }

        let previousCenter = previousReadback.centroid
        let sourceCenter = currentReadback.centroid
        let scaledCenter = scaledReadback.centroid
        let midpointCenter = midpointReadback.centroid
        guard let previousCenter, let sourceCenter, let scaledCenter, let midpointCenter else {
            let missing = [previousReadback, currentReadback, scaledReadback, midpointReadback]
                .filter { $0.centroid == nil }
                .map(\.name)
                .joined(separator: ", ")
            fail("moving patch centroid unavailable in [\(missing)] at \(testCase.label); see preceding per-buffer plane/sample diagnostics")
        }

        let low = min(previousCenter, sourceCenter)
        let high = max(previousCenter, sourceCenter)
        let sourceDistance = abs(scaledCenter - sourceCenter)
        let previousDistance = abs(scaledCenter - previousCenter)
        let inputMotion = abs(sourceCenter - previousCenter)
        guard abs(previousCenter - expectedPreviousCenter) < 0.012,
              abs(sourceCenter - expectedCurrentCenter) < 0.012,
              abs(inputMotion - 0.05) < 0.012,
              sourceDistance < previousDistance,
              sourceDistance < 0.03 else {
            fail(String(format: "upscaled-source output did not track the fresh current endpoint at %@: expected %.3f→%.3f, read %.3f→%.3f, output %.3f", testCase.label, expectedPreviousCenter, expectedCurrentCenter, previousCenter, sourceCenter, scaledCenter))
        }
        let motionMargin = min(0.012, inputMotion * 0.24)
        guard midpointCenter > low + motionMargin,
              midpointCenter < high - motionMargin,
              abs(midpointCenter - previousCenter) > motionMargin,
              abs(midpointCenter - sourceCenter) > motionMargin else {
            fail(String(format: "midpoint output matched an endpoint or left the motion corridor at %@: previous %.3f source %.3f midpoint %.3f", testCase.label, previousCenter, sourceCenter, midpointCenter))
        }

        validateQuadrantColors(in: buffers.scaledSource, label: "upscaled source", caseLabel: testCase.label)
        validateQuadrantColors(in: buffers.midpoint, label: "midpoint", caseLabel: testCase.label)
        print(String(format: "PASS readback %@: fresh source patch %.3f→%.3f (Δ%.3f); scaled source %.3f; midpoint %.3f; both 2x outputs 420v with Rec.709 quadrant orientation", testCase.label, previousCenter, sourceCenter, inputMotion, scaledCenter, midpointCenter))
    }

    private func trianglePatchCenter(frameIndex: Int) -> Double {
        let phase = frameIndex % 20
        let step = phase <= 10 ? phase : 20 - phase
        return 0.25 + Double(step) * 0.05
    }

    private func validateQuadrantColors(in pixelBuffer: CVPixelBuffer, label: String, caseLabel: String) {
        let points = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
        let samples = points.map { sampleRGB(pixelBuffer, x: $0.0, y: $0.1) }
        guard let red = samples[0], let green = samples[1], let blue = samples[2], let yellow = samples[3] else {
            fail("could not read Rec.709 420v \(label) pixels at \(caseLabel)")
        }
        let correct = red.red > red.green + 0.20 && red.red > red.blue + 0.20
            && green.green > green.red + 0.20 && green.green > green.blue + 0.20
            && blue.blue > blue.red + 0.20 && blue.blue > blue.green + 0.12
            && yellow.red > yellow.blue + 0.20 && yellow.green > yellow.blue + 0.20
        guard correct else {
            fail("\(label) Rec.709 quadrant direction/orientation mismatch at \(caseLabel): \(samples)")
        }
    }

    private func inspectReadback(
        name: String,
        pixelBuffer: CVPixelBuffer,
        expectedPatchCenter: Double
    ) -> (name: String, centroid: Double?, summary: String) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let expectedText = String(format: "%.4f", expectedPatchCenter)
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            return (name, nil, "READBACK \(name): \(width)x\(height), format=0x\(String(pixelFormat, radix: 16)), expectedX=\(expectedText), base-address lock failed status=\(lockStatus)")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let yAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return (name, nil, "READBACK \(name): \(width)x\(height), format=0x\(String(pixelFormat, radix: 16)), expectedX=\(expectedText), planar base address missing")
        }

        let yPlane = yAddress.assumingMemoryBound(to: UInt8.self)
        let uvPlane = uvAddress.assumingMemoryBound(to: UInt8.self)
        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        var ySum = 0.0
        for row in 0..<yHeight {
            let rowBase = yPlane.advanced(by: row * yStride)
            for column in 0..<yWidth { ySum += Double(rowBase[column]) }
        }
        var cbSum = 0.0
        var crSum = 0.0
        for row in 0..<uvHeight {
            let rowBase = uvPlane.advanced(by: row * uvStride)
            for column in 0..<uvWidth {
                cbSum += Double(rowBase[column * 2])
                crSum += Double(rowBase[column * 2 + 1])
            }
        }
        let meanY = ySum / Double(max(1, yWidth * yHeight))
        let meanCb = cbSum / Double(max(1, uvWidth * uvHeight))
        let meanCr = crSum / Double(max(1, uvWidth * uvHeight))

        func sample(x normalizedX: Double, y normalizedY: Double) -> (y: Double, cb: Double, cr: Double, rgb: RGB) {
            let px = min(width - 1, max(0, Int(normalizedX * Double(width))))
            let py = min(height - 1, max(0, Int(normalizedY * Double(height))))
            let rawY = Double(yPlane[py * yStride + px])
            let uvOffset = (py / 2) * uvStride + (px / 2) * 2
            let rawCb = Double(uvPlane[uvOffset])
            let rawCr = Double(uvPlane[uvOffset + 1])
            let cb = (rawCb - 128) / 224
            let cr = (rawCr - 128) / 224
            let yPrime = (rawY - 16) / 219
            let rgb = RGB(
                red: clamp01(yPrime + 1.5748 * cr),
                green: clamp01(yPrime - 0.187324 * cb - 0.468124 * cr),
                blue: clamp01(yPrime + 1.8556 * cb)
            )
            return (rawY, rawCb, rawCr, rgb)
        }

        let quadrantPoints: [(String, Double, Double)] = [
            ("TL", 0.25, 0.25), ("TR", 0.75, 0.25), ("BL", 0.25, 0.75), ("BR", 0.75, 0.75)
        ]
        let quadrants = quadrantPoints.map { point in
            let value = sample(x: point.1, y: point.2)
            return String(format: "%@ Y%.0f Cb%.0f Cr%.0f RGB%@", point.0, value.y, value.cb, value.cr, value.rgb.description)
        }.joined(separator: "; ")

        let probeXs = [0.25, 0.30, 0.35, expectedPatchCenter - 0.03, expectedPatchCenter,
                       expectedPatchCenter + 0.03, 0.45, 0.50, 0.55, 0.65, 0.75]
        let centerLine = probeXs.map { rawX in
            let x = min(0.99, max(0.01, rawX))
            let value = sample(x: x, y: 0.50)
            return String(format: "x%.3f:Y%.0f/Cb%.0f/Cr%.0f/RGB%@", x, value.y, value.cb, value.cr, value.rgb.description)
        }.joined(separator: "; ")

        let step = max(1, max(width, height) / 640)
        var weightedX = 0.0
        var totalWeight = 0.0
        var detectedPixels = 0
        var maxMagentaScore = -1.0
        for row in stride(from: 0, to: height, by: step) {
            for column in stride(from: 0, to: width, by: step) {
                let value = sample(x: (Double(column) + 0.5) / Double(width), y: (Double(row) + 0.5) / Double(height)).rgb
                let score = min(value.red, value.blue) - value.green
                maxMagentaScore = max(maxMagentaScore, score)
                if score > 0.22 {
                    let weight = score - 0.22
                    weightedX += ((Double(column) + 0.5) / Double(width)) * weight
                    totalWeight += weight
                    detectedPixels += 1
                }
            }
        }
        let centroid: Double? = totalWeight > 0 ? weightedX / totalWeight : nil
        let centroidText = centroid.map { String(format: "%.4f", $0) } ?? "missing"
        let summary = String(format: "READBACK %@: image=%dx%d format=0x%@ Yplane=%dx%d stride=%d UVplane=%dx%d stride=%d expectedPatchX=%@ centroid=%@ magentaSamples=%d maxScore=%.3f planeMeans[Y=%.2f Cb=%.2f Cr=%.2f] quadrants={%@} centerline-y0.50={%@}",
                             name, width, height, String(pixelFormat, radix: 16),
                             yWidth, yHeight, yStride, uvWidth, uvHeight, uvStride, expectedText, centroidText,
                             detectedPixels, maxMagentaScore, meanY, meanCb, meanCr, quadrants, centerLine)
        return (name, centroid, summary)
    }

    private func sampleRGB(_ pixelBuffer: CVPixelBuffer, x normalizedX: Double, y normalizedY: Double) -> RGB? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let yAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let px = min(width - 1, max(0, Int(normalizedX * Double(width))))
        let py = min(height - 1, max(0, Int(normalizedY * Double(height))))
        let yValue = Double(yAddress.assumingMemoryBound(to: UInt8.self)[py * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) + px])
        let uv = uvAddress.assumingMemoryBound(to: UInt8.self)
        let uvOffset = (py / 2) * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) + (px / 2) * 2
        let cb = (Double(uv[uvOffset]) - 128) / 224
        let cr = (Double(uv[uvOffset + 1]) - 128) / 224
        let yPrime = (yValue - 16) / 219
        return RGB(
            red: clamp01(yPrime + 1.5748 * cr),
            green: clamp01(yPrime - 0.187324 * cb - 0.468124 * cr),
            blue: clamp01(yPrime + 1.8556 * cb)
        )
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func finishCurrentCase(_ testCase: JointCase) {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        if mode == .commandBuffer {
            guard cpuMilliseconds.count == 60, gpuMilliseconds.count == 60 else {
                fail("expected 60 steady timings at \(testCase.label), got CPU \(cpuMilliseconds.count), GPU \(gpuMilliseconds.count)")
            }
        } else if asyncCompletionWallMilliseconds.count != 1 {
            fail("async diagnostic expected one completion callback at \(testCase.label), got \(asyncCompletionWallMilliseconds.count)")
        }
        processor?.endSession()
        processor = nil
        configuration = nil
        buffers = nil
        sourcePixelBufferAttributes = nil
        if mode == .commandBuffer {
            let cpu = summary(cpuMilliseconds)
            let gpu = summary(gpuMilliseconds)
            print(String(format: "PASS %@: 2 warmups + 60 steady; CPU process encode-only mean/P95 %.3f/%.3f ms (allocation/fill excluded); GPU command mean/P95 %.3f/%.3f ms", testCase.label, cpu.mean, cpu.p95, gpu.mean, gpu.p95))
        } else {
            print("ASYNC DIAGNOSTIC COMPLETE \(testCase.label): one pair processed and read back; wall-clock callback duration above; this is not a GPU timing or 120 Hz acceptance result.")
        }
        caseIndex += 1
        beginNextCase()
    }

    private func summary(_ values: [Double]) -> (mean: Double, p95: Double) {
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let p95Index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return (mean, sorted[p95Index])
    }

    private func finishSuite() {
        dispatchPrecondition(condition: .onQueue(serialQueue))
        if !skippedRequiredCases.isEmpty {
            print("SKIP: required resolution(s) unsupported: \(skippedRequiredCases.joined(separator: ", ")); any completed cases above are partial results, not a full fixture pass.")
            setFinished()
            DispatchQueue.main.async { exit(2) }
            return
        }
        if !skippedOptionalCases.isEmpty {
            if cases.contains(where: { !$0.optional }) {
                print("PASS: selected required resolution(s) completed; optional case(s) explicitly skipped as unsupported.")
            } else {
                print("SKIP: selected optional resolution(s) unsupported; no selected required case was run (not a pass).")
                setFinished()
                DispatchQueue.main.async { exit(2) }
                return
            }
        }
        if mode == .asyncDiagnostic {
            print("ASYNC DIAGNOSTIC COMPLETE: selected single-pair processing/readback finished; no GPU timestamps were collected.")
        } else {
            if skippedOptionalCases.isEmpty {
                print("PASS: selected joint interpolation readback and timing cases completed: \(cases.map(\.label).joined(separator: ", ")). This is a processing fixture, not a full-matrix, image-quality or 120 Hz display claim.")
            }
        }
        setFinished()
        DispatchQueue.main.async { exit(0) }
    }
}

private func main() {
    guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
        skip("VideoToolbox low-latency frame interpolation is unavailable on this runtime")
    }
    let mode: ProcessingMode = CommandLine.arguments.contains("--async-diagnostic") ? .asyncDiagnostic : .commandBuffer
    guard let device = MTLCreateSystemDefaultDevice() else {
        skip("no Metal device is available")
    }
    let commandQueue = mode == .commandBuffer ? device.makeCommandQueue() : nil
    if mode == .commandBuffer, commandQueue == nil {
        skip("no Metal command queue is available")
    }
    let suite = JointInterpolationGPUSuite(device: device, commandQueue: commandQueue, mode: mode)
    suite.start()
    dispatchMain()
}

if #available(macOS 26.0, *) {
    main()
} else {
    skip("requires macOS 26 or later for joint low-latency frame interpolation")
}
