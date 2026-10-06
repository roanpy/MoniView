import CoreMedia
import CoreVideo
import Foundation

private final class WeakObjectReference {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
        self.value = value
    }
}

@main
struct CaptureCompatibilityTests {
    private static func pixelBuffer(width: Int = 64, height: Int = 48) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        precondition(status == kCVReturnSuccess && buffer != nil, "could not allocate test pixel buffer")
        return buffer!
    }

    private static func objectIdentity(_ buffer: CVPixelBuffer) -> ObjectIdentifier {
        ObjectIdentifier(buffer as AnyObject)
    }

    private static func hasNoPair(_ frames: LatestVideoFrame, sequence: UInt64) -> Bool {
        if case nil = frames.interpolationPair(sequence: sequence) { return true }
        return false
    }

    private static func assertPair(
        _ frames: LatestVideoFrame,
        sequence: UInt64,
        previousIdentity: ObjectIdentifier,
        previousSequence: UInt64,
        previousPTS: CMTime,
        sourcePTS: CMTime
    ) {
        guard let pair = frames.interpolationPair(sequence: sequence) else {
            preconditionFailure("expected adjacent interpolation pair for sequence \(sequence)")
        }
        precondition(objectIdentity(pair.0) == previousIdentity, "interpolation pair must retain the immediately preceding buffer")
        precondition(pair.1 == previousSequence, "interpolation pair previous sequence mismatch")
        precondition(CMTimeCompare(pair.2, previousPTS) == 0, "interpolation pair previous PTS mismatch")
        precondition(CMTimeCompare(pair.3, sourcePTS) == 0, "interpolation pair source PTS mismatch")
    }

    private static func insertAdjacentPair(
        into frames: LatestVideoFrame,
        previousPTS: CMTime,
        sourcePTS: CMTime
    ) -> (weakPrevious: WeakObjectReference, identity: ObjectIdentifier, previousSequence: UInt64, sourceSequence: UInt64) {
        var previous: CVPixelBuffer? = pixelBuffer()
        let weakPrevious = WeakObjectReference(previous! as AnyObject)
        let identity = objectIdentity(previous!)
        frames.put(previous!, pts: previousPTS)
        let previousSequence = frames.latest()!.1
        frames.put(pixelBuffer(), pts: sourcePTS)
        let sourceSequence = frames.latest()!.1
        previous = nil
        return (weakPrevious, identity, previousSequence, sourceSequence)
    }

    private static func timestamp(index: Int, frameTicks: Int64, timescale: Int32) -> CMTime {
        CMTime(value: Int64(index) * frameTicks, timescale: timescale)
    }

    private static func putCadence(
        into frames: LatestVideoFrame,
        startIndex: Int,
        count: Int,
        width: Int = 64,
        height: Int = 48,
        frameTicks: Int64,
        timescale: Int32
    ) {
        guard count > 0 else { return }
        let buffer = pixelBuffer(width: width, height: height)
        for index in startIndex..<(startIndex + count) {
            frames.put(buffer, pts: timestamp(index: index, frameTicks: frameTicks, timescale: timescale))
        }
    }

    private static func assertRate(_ frames: LatestVideoFrame, near expected: Double, context: String) {
        guard let rate = frames.sourceFrameRate() else {
            preconditionFailure("expected stable source FPS for \(context)")
        }
        precondition(abs(rate - expected) < 0.001, "\(context) FPS was \(rate), expected \(expected)")
    }

    private static func testPresentationIntervalsAndDuplicateSkips() {
        let frames = LatestVideoFrame()
        frames.put(pixelBuffer(), pts: .zero)
        let snapshot = frames.latestSnapshot()!
        frames.markPresentedSource(sequence: snapshot.sequence, streamEpoch: snapshot.streamEpoch, presentedTime: 1)
        frames.markGenerated(streamEpoch: snapshot.streamEpoch, presentedTime: 1 + 1/120.0)
        frames.markPresentedSource(sequence: snapshot.sequence, streamEpoch: snapshot.streamEpoch, presentedTime: 1.1)
        precondition(abs(frames.presentationP95() - 1000/120.0) < 0.001, "same-source redraw must not inflate intervals")
        frames.markDuplicateSkipped(sequence: snapshot.sequence, streamEpoch: snapshot.streamEpoch)
        frames.markDuplicateSkipped(sequence: snapshot.sequence, streamEpoch: snapshot.streamEpoch)
        precondition(frames.takeDuplicateSkips() == 1 && frames.takeDuplicateSkips() == 0, "duplicate skip count deduplicates repeated draws")
        frames.setPreviewState("hidden")
        precondition(frames.presentationP95() == 0, "hidden preview resets presentation interval baseline")
        frames.clear()
        frames.markDuplicateSkipped(sequence: snapshot.sequence + 1, streamEpoch: snapshot.streamEpoch)
        precondition(frames.takeDuplicateSkips() == 0, "retired stream skip ignored")
    }

    private static func testOldPictureSettingsJSON() {
        var newSettings = PictureSettings()
        newSettings.frameInterpolation = .balanced
        newSettings.preferredInterpolationQuality = .balanced
        newSettings.forceFrameInterpolation = true
        let restored = try! JSONDecoder().decode(PictureSettings.self, from: JSONEncoder().encode(newSettings))
        precondition(restored == newSettings && restored.forceFrameInterpolation, "new force/quality settings persist")
        // This is the persisted shape before interpolationMode was added.
        precondition(!PictureSettings().forceFrameInterpolation, "force defaults off")
        let oldJSON = #"{"brightness":0.12,"contrast":1.08,"saturation":0.91,"sharpness":0.2,"vibrance":0.15,"lowLatency":true,"enhancementEnabled":true,"enhancementStrength":0.35,"upscaleTarget":"原始","upscaleMethod":"MetalFX","highlightRecovery":0.05}"#
        let decoded: PictureSettings
        do {
            decoded = try JSONDecoder().decode(PictureSettings.self, from: Data(oldJSON.utf8))
        } catch {
            preconditionFailure("legacy PictureSettings JSON did not decode: \(error)")
        }
        precondition(!decoded.forceFrameInterpolation && decoded.preferredInterpolationQuality == nil, "legacy additions default to off/unset")
        var prior = try! JSONSerialization.jsonObject(with: Data(oldJSON.utf8)) as! [String: Any]
        prior["interpolationMode"] = FrameInterpolationMode.quality.rawValue
        let priorDecoded = try! JSONDecoder().decode(PictureSettings.self, from: JSONSerialization.data(withJSONObject: prior))
        precondition(priorDecoded.frameInterpolation == .quality && !priorDecoded.forceFrameInterpolation && priorDecoded.preferredInterpolationQuality == nil, "previous interpolation settings preserve quality with override off")
        precondition(decoded.interpolationMode == nil, "missing persisted interpolation mode should stay unset")
        precondition(decoded.frameInterpolation == .off, "missing persisted interpolation mode should default to off")
        precondition(decoded.brightness == 0.12 && decoded.upscaleTarget == .native && decoded.upscaleMethod == .metalFX,
                     "legacy picture settings values were not preserved")
        print("PASS PictureSettings decodes legacy JSON without interpolationMode and defaults interpolation to off")
    }

    private static func testInterpolationHistory() {
        let previousPTS = CMTime(value: 1001, timescale: 60000)
        let sourcePTS = CMTime(value: 2002, timescale: 60000)

        let disabledByDefault = LatestVideoFrame()
        disabledByDefault.put(pixelBuffer(), pts: previousPTS)
        disabledByDefault.put(pixelBuffer(), pts: sourcePTS)
        let defaultSequence = disabledByDefault.latest()!.1
        precondition(hasNoPair(disabledByDefault, sequence: defaultSequence),
                     "interpolation history must be off by default")
        print("PASS LatestVideoFrame interpolation history defaults off")

        let frames = LatestVideoFrame()
        frames.setInterpolationHistoryEnabled(true)
        let retained = insertAdjacentPair(into: frames, previousPTS: previousPTS, sourcePTS: sourcePTS)
        precondition(retained.weakPrevious.value != nil, "enabled history must strongly retain the previous pixel buffer")
        assertPair(
            frames,
            sequence: retained.sourceSequence,
            previousIdentity: retained.identity,
            previousSequence: retained.previousSequence,
            previousPTS: previousPTS,
            sourcePTS: sourcePTS
        )
        precondition(hasNoPair(frames, sequence: retained.sourceSequence &- 1),
                     "interpolation pair must only be returned for the current source sequence")

        frames.setInterpolationHistoryEnabled(false)
        precondition(hasNoPair(frames, sequence: retained.sourceSequence),
                     "disabling interpolation history must clear the previous frame")
        precondition(retained.weakPrevious.value == nil,
                     "disabling interpolation history must release its strong previous-buffer reference")
        frames.put(pixelBuffer(), pts: CMTime(value: 3003, timescale: 60000))
        precondition(hasNoPair(frames, sequence: frames.latest()!.1),
                     "disabled history must not retain subsequent frames")
        print("PASS enabled history retains only the adjacent buffer and exact PTS; disabling releases it")
    }

    private static func testStableSourceFrameRatesAndResets() {
        let fractional = LatestVideoFrame()
        putCadence(into: fractional, startIndex: 0, count: 8, frameTicks: 1001, timescale: 60000)
        precondition(fractional.sourceFrameRate() == nil, "seven intervals are insufficient for stable FPS")
        putCadence(into: fractional, startIndex: 8, count: 1, frameTicks: 1001, timescale: 60000)
        assertRate(fractional, near: 59.94, context: "59.94 FPS after eight intervals")

        let sixty = LatestVideoFrame()
        putCadence(into: sixty, startIndex: 0, count: 9, frameTicks: 1, timescale: 60)
        assertRate(sixty, near: 60, context: "60 FPS after eight intervals")
        print("PASS source FPS stabilizes after exactly eight PTS intervals at 59.94 and 60")

        let changing = LatestVideoFrame()
        changing.setInterpolationHistoryEnabled(true)
        putCadence(into: changing, startIndex: 0, count: 9, frameTicks: 1001, timescale: 60000)
        assertRate(changing, near: 59.94, context: "pre-resolution-change cadence")
        let newSizePTS = timestamp(index: 9, frameTicks: 1001, timescale: 60000)
        changing.put(pixelBuffer(width: 96, height: 64), pts: newSizePTS)
        precondition(changing.sourceFrameRate() == nil, "resolution change must reset stable cadence")
        precondition(hasNoPair(changing, sequence: changing.latest()!.1),
                     "resolution change must not pair buffers with different dimensions")
        putCadence(into: changing, startIndex: 10, count: 8, width: 96, height: 64, frameTicks: 1001, timescale: 60000)
        assertRate(changing, near: 59.94, context: "cadence rebuilt after resolution change")

        let decreasingPTS = timestamp(index: 16, frameTicks: 1001, timescale: 60000)
        changing.put(pixelBuffer(width: 96, height: 64), pts: decreasingPTS)
        precondition(changing.sourceFrameRate() == nil, "non-increasing PTS must reset stable cadence")
        let invalidSequence = changing.latest()!.1
        guard let invalidPair = changing.interpolationPair(sequence: invalidSequence) else {
            preconditionFailure("history should expose the PTS pair for caller-side validation")
        }
        precondition(CMTimeCompare(invalidPair.2, invalidPair.3) > 0,
                     "history must preserve non-increasing source PTS rather than rewriting timestamps")
        putCadence(into: changing, startIndex: 17, count: 8, width: 96, height: 64, frameTicks: 1001, timescale: 60000)
        assertRate(changing, near: 59.94, context: "cadence rebuilt after non-increasing PTS")
        print("PASS resolution and non-increasing PTS reset cadence; stable cadence rebuilds")

        let beforeClear = changing.latest()!.1
        changing.clear()
        if case nil = changing.latest() {} else { preconditionFailure("clear must remove the latest frame") }
        precondition(changing.sourceFrameRate() == nil, "clear must remove measured cadence")
        precondition(hasNoPair(changing, sequence: beforeClear),
                     "clear must invalidate the old interpolation pair")
        precondition(hasNoPair(changing, sequence: beforeClear &+ 1),
                     "clear must not leave a previous frame retained")
        putCadence(into: changing, startIndex: 0, count: 9, width: 96, height: 64, frameTicks: 1, timescale: 60)
        assertRate(changing, near: 60, context: "cadence rebuilt after clear")
        let postClearSequence = changing.latest()!.1
        guard let resumedPair = changing.interpolationPair(sequence: postClearSequence) else {
            preconditionFailure("interpolation history should rebuild after clear")
        }
        precondition(resumedPair.1 == postClearSequence &- 1, "post-clear history should start with the adjacent sequence")
        precondition(CMTimeCompare(resumedPair.2, timestamp(index: 7, frameTicks: 1, timescale: 60)) == 0)
        precondition(CMTimeCompare(resumedPair.3, timestamp(index: 8, frameTicks: 1, timescale: 60)) == 0)
        print("PASS clear resets latest, cadence, and pair state; subsequent cadence restarts cleanly")
    }

    private static func option(_ rate: Double) -> CaptureFormatOption {
        CaptureFormatOption(id: 0, width: 1920, height: 1080, minimumFPS: Int(rate.rounded()), maximumFPS: Int(rate.rounded()), rates: [rate...rate])
    }

    static func main() {
        for mode in FrameInterpolationMode.allCases where mode != .off {
            var settings = PictureSettings()
            settings.frameInterpolation = mode
            settings.setInterpolationEnabled(false)
            settings.setInterpolationEnabled(false)
            precondition(settings.preferredInterpolationQuality == mode)
            settings.setInterpolationEnabled(true)
            precondition(settings.frameInterpolation == mode, "Repeated off must preserve \(mode)")
        }
        for saved in [FrameInterpolationMode?.none, .some(.off)] {
            var settings = PictureSettings()
            settings.preferredInterpolationQuality = saved
            settings.setInterpolationEnabled(true)
            precondition(settings.frameInterpolation == .balanced, "Invalid saved quality must recover")
        }
        testPresentationIntervalsAndDuplicateSkips()
        testOldPictureSettingsJSON()
        testInterpolationHistory()
        testStableSourceFrameRatesAndResets()

        let presentationFrames = LatestVideoFrame()
        presentationFrames.put(pixelBuffer())
        let first = presentationFrames.latestSnapshot()!
        presentationFrames.markPresentedSource(sequence: first.sequence, streamEpoch: first.streamEpoch)
        presentationFrames.markPresentedSource(sequence: first.sequence, streamEpoch: first.streamEpoch)
        var presentations = presentationFrames.presentationStatistics()
        precondition(presentations.presentedSource == 1 && presentations.generated == 0, "Native fallback counts once even without generated frames")
        presentationFrames.markPresentedSource(sequence: first.sequence, streamEpoch: first.streamEpoch)
        precondition(presentationFrames.presentationStatistics().presentedSource == 0, "Redraw across sample windows must remain deduplicated")
        presentationFrames.clear()
        presentationFrames.markPresentedSource(sequence: first.sequence + 10, streamEpoch: first.streamEpoch)
        presentationFrames.markGenerated(streamEpoch: first.streamEpoch)
        precondition(presentationFrames.presentationStatistics() == (0, 0), "Retired stream callbacks must not pollute output FPS")
        presentationFrames.put(pixelBuffer())
        let second = presentationFrames.latestSnapshot()!
        presentationFrames.markPresentedSource(sequence: second.sequence, streamEpoch: second.streamEpoch)
        presentationFrames.markGenerated(streamEpoch: second.streamEpoch)
        presentations = presentationFrames.presentationStatistics()
        precondition(presentations.presentedSource == 1 && presentations.generated == 1, "Source and midpoint counts share one sampling window")
        print("PASS presentation deduplication, native fallback, retired stream callbacks and atomic output sampling")

        precondition(UpscaleMethod.ai.availableMethod(aiSupported: false) == .metalFX)
        precondition(UpscaleMethod.ai.availableMethod(aiSupported: true) == .ai)
        precondition(UpscaleMethod.lanczos.availableMethod(aiSupported: false) == .lanczos)
        let fractional = option(59.94), sixty = option(60.00024)
        precondition(fractional.supportsFrameRate(59.94) && !fractional.supportsFrameRate(60))
        precondition(sixty.supportsFrameRate(60) && !sixty.supportsFrameRate(59.94))
        precondition(!fractional.prefers(over: sixty, nativeNV12: true))
        precondition(sixty.prefers(over: fractional, nativeNV12: false))
        precondition(sixty.prefers(over: sixty, nativeNV12: true))
        for rate in [24.0, 25, 29.97, 30, 50, 59.94, 60, 90, 120, 144] {
            precondition(option(rate).supportsFrameRate(rate))
        }
        let variable = CaptureFormatOption(id: 1, width: 3840, height: 2160, minimumFPS: 24, maximumFPS: 60, rates: [24...60])
        precondition(variable.supportsFrameRate(59.94) && variable.supportsFrameRate(0))
        precondition(!variable.supportsFrameRate(120) && !variable.supportsFrameRate(.nan))
        precondition(UpscaleTarget.fullHD.resolvedLongEdge(screenLongEdge: 3024, sourceLongEdge: 1280) == 1920)
        precondition(UpscaleTarget.uhd.resolvedLongEdge(screenLongEdge: 3024, sourceLongEdge: 1280) == 3840)
        precondition(UpscaleTarget.screen.resolvedLongEdge(screenLongEdge: 3024, sourceLongEdge: 1280) == 3024)
        precondition(UpscaleTarget.screen.resolvedLongEdge(screenLongEdge: 5120, sourceLongEdge: 1920) == 5120)
        precondition(UpscaleTarget.screen.resolvedLongEdge(screenLongEdge: nil, sourceLongEdge: 1920) == 1920)
        precondition(UpscaleTarget.native.resolvedLongEdge(screenLongEdge: 5120, sourceLongEdge: 2160) == 2160)
        print("Capture compatibility tests passed: legacy settings, frame history/PTS, cadence resets, formats, rates, and display targets.")
    }
}
