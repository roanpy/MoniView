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
        frames.setActiveMultiplier(2, inputFPS: 30, streamEpoch: snapshot.streamEpoch)
        precondition(frames.currentActiveMultiplier() == 2 && frames.currentInterpolationBasisFPS() == 30)
        // Deterministic freshness checks, without sleeping or retaining obsolete activity.
        frames.setActiveMultiplier(2, inputFPS: 30, streamEpoch: snapshot.streamEpoch, at: 10)
        precondition(frames.currentInterpolationActivity(at: 10.9)?.basisFPS == 30, "native fallback preserves recent success")
        precondition(frames.currentInterpolationActivity(at: 11.25)?.multiplier == 2, "statistics window remains stable")
        precondition(frames.currentInterpolationActivity(at: 11.251) == nil, "sustained inactivity expires")
        precondition(frames.currentInterpolationActivity(at: 9) == nil, "future timestamp cannot count as recent success")
        frames.setActiveMultiplier(nil)
        precondition(frames.currentInterpolationActivity(at: 10.1) == nil, "hard reset immediately clears recent activity")
        frames.setActiveMultiplier(3, inputFPS: 20, streamEpoch: snapshot.streamEpoch, at: 12)
        precondition(frames.currentInterpolationActivity(at: 12.1)?.basisFPS == 20, "new success replaces basis dynamically")
        // A fresh success re-arms the window instead of leaving the original deadline in place.
        frames.setActiveMultiplier(2, inputFPS: 30, streamEpoch: snapshot.streamEpoch, at: 13.2)
        precondition(frames.currentInterpolationActivity(at: 14.3)?.multiplier == 2, "renewal restarts the readout window")
        precondition(frames.currentInterpolationActivity(at: 14.5) == nil, "the window still expires after renewal")
        // An older stream generation cannot republish over activity from the current one.
        frames.setActiveMultiplier(2, inputFPS: 30, streamEpoch: snapshot.streamEpoch, at: 15.0)
        frames.setActiveMultiplier(3, inputFPS: 20, streamEpoch: snapshot.streamEpoch &+ 7, at: 15.2)
        precondition(frames.currentInterpolationActivity(at: 15.3)?.multiplier == 2, "an older epoch cannot republish over recent activity")
        frames.setActiveMultiplier(2, inputFPS: 30, streamEpoch: snapshot.streamEpoch)
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
        precondition(frames.currentActiveMultiplier() == nil && frames.currentInterpolationBasisFPS() == nil, "clearing input clears the applied pairing")
        frames.setActiveMultiplier(3, inputFPS: 20, streamEpoch: snapshot.streamEpoch)
        precondition(frames.currentActiveMultiplier() == nil, "retired epoch cannot republish a multiplier")
        frames.put(pixelBuffer(), pts: CMTime(value: 1, timescale: 30))
        let resumedEpoch = frames.streamGeneration()
        frames.setActiveMultiplier(2, inputFPS: 30, streamEpoch: resumedEpoch)
        frames.put(pixelBuffer(width: 32, height: 32), pts: CMTime(value: 2, timescale: 30))
        precondition(frames.currentActiveMultiplier() == nil && frames.currentInterpolationBasisFPS() == nil, "layout epoch clears pairing")
        frames.setActiveMultiplier(2, inputFPS: 30, streamEpoch: resumedEpoch)
        precondition(frames.currentActiveMultiplier() == nil, "prior layout epoch cannot overwrite resumed state")
        frames.markDuplicateSkipped(sequence: snapshot.sequence + 1, streamEpoch: snapshot.streamEpoch)
        precondition(frames.takeDuplicateSkips() == 0, "retired stream skip ignored")
    }

    /// A source switch clears the mailbox and asks for a blank draw. The request must survive a
    /// draw that could not clear the drawable, must not be cancelled by a frame from the source
    /// that lost the preview, and must never be re-opened for a newer stream by a late callback.
    private static func testSourceSwitchClearingAndCaptionEvidence() {
        let frames = LatestVideoFrame()
        frames.put(pixelBuffer(), pts: CMTime(value: 0, timescale: 60))
        frames.clear(blankPreview: true)
        let switchEpoch = frames.streamGeneration()
        precondition(frames.isBlankRequestPending, "a source switch requests a blank")
        precondition(frames.latest() == nil, "a source switch clears the previous source's frame")
        guard let requestedEpoch = frames.consumeBlankRequest(), requestedEpoch == switchEpoch else {
            preconditionFailure("the draw takes the blank request for its own stream epoch")
        }
        precondition(!frames.isBlankRequestPending, "taking the request clears it")
        // A draw whose command could not carry the clear puts the request back and is retried.
        frames.rearmBlankRequest(epoch: requestedEpoch)
        precondition(frames.isBlankRequestPending, "a failed blank draw re-arms the request")
        precondition(frames.consumeBlankRequest() == requestedEpoch, "the retry keeps the stream epoch")
        // A frame for the current stream supersedes the blank.
        frames.rearmBlankRequest(epoch: switchEpoch)
        frames.put(pixelBuffer(), pts: CMTime(value: 1, timescale: 60))
        precondition(frames.consumeBlankRequest() == nil, "a frame that arrived first supersedes the blank")
        // A late callback from the previous stream must not re-open a blank on the new one.
        frames.clear(blankPreview: true)
        let currentEpoch = frames.streamGeneration()
        precondition(currentEpoch != switchEpoch, "a switch starts a new stream epoch")
        precondition(frames.consumeBlankRequest() == currentEpoch, "the new switch requests its own blank")
        frames.rearmBlankRequest(epoch: switchEpoch)
        precondition(!frames.isBlankRequestPending, "a superseded epoch cannot re-open a blank")
        // A blank for an input that was replaced is never retried or retired: a newer stream owns
        // the preview, and re-arming its predecessor's blank would disturb it.
        frames.rearmBlankRequest(epoch: currentEpoch)
        precondition(frames.isBlankRequestPending, "the current epoch can re-arm the blank")
        frames.put(pixelBuffer(width: 32, height: 32), pts: CMTime(value: 2, timescale: 60))
        let newerEpoch = frames.streamGeneration()
        precondition(newerEpoch != currentEpoch, "a new input starts a new stream epoch")
        precondition(!frames.isBlankStillNeeded(forEpoch: currentEpoch),
                     "a blank of a replaced input is no longer needed")
        precondition(!frames.rearmBlankRequest(epoch: currentEpoch),
                     "a superseded input cannot re-arm its blank")
        print("PASS source-switch blank request: retained through a failed draw, and never re-armed or retired for an input a newer stream replaced")

        // Recent generated activity is evidence for the caption, but only for the stream it was
        // recorded under and only while no newer reason was stated.
        let evidenceFrames = LatestVideoFrame()
        evidenceFrames.put(pixelBuffer())
        let epoch = evidenceFrames.streamGeneration()
        let now = ProcessInfo.processInfo.systemUptime
        precondition(evidenceFrames.markGenerated(streamEpoch: epoch, presentedTime: now - 0.5),
                     "a generated presentation is counted for its own stream")
        precondition(evidenceFrames.recentGeneratedPresentationEvidence(at: now) == nil,
                     "counting a presentation is not evidence until the caller binds it to its configuration")
        evidenceFrames.recordGeneratedPresentationEvidence(streamEpoch: epoch, at: now - 0.5)
        precondition(evidenceFrames.recentGeneratedPresentationEvidence(at: now) == now - 0.5,
                     "recent generation is available as evidence")
        evidenceFrames.recordGeneratedPresentationEvidence(streamEpoch: epoch &+ 7, at: now)
        precondition(evidenceFrames.recentGeneratedPresentationEvidence(at: now) == now - 0.5,
                     "a superseded stream cannot record evidence")
        evidenceFrames.setInterpolationState("GPU错误，保留原始画面")
        precondition(!evidenceFrames.publishInterpolationRunning(forced: false, evidence: now - 0.5),
                     "a reason stated after the evidence keeps the caption")
        precondition(evidenceFrames.currentInterpolationState() == "GPU错误，保留原始画面",
                     "a late success callback cannot erase a GPU error")
        precondition(evidenceFrames.publishInterpolationRunning(forced: false, evidence: ProcessInfo.processInfo.systemUptime),
                     "evidence newer than the reason claims running again")
        precondition(evidenceFrames.currentInterpolationState() == "插帧运行中")
        precondition(evidenceFrames.recentGeneratedPresentationEvidence(at: now + 10) == nil,
                     "evidence expires with the activity window")
        evidenceFrames.clearGeneratedPresentationEvidence()
        precondition(evidenceFrames.recentGeneratedPresentationEvidence(at: now) == nil,
                     "a configuration change drops the evidence")
        // A layout change advances the stream epoch: the previous epoch is no longer evidence.
        let layoutFrames = LatestVideoFrame()
        layoutFrames.put(pixelBuffer())
        let firstEpoch = layoutFrames.streamGeneration()
        layoutFrames.recordGeneratedPresentationEvidence(streamEpoch: firstEpoch, at: ProcessInfo.processInfo.systemUptime)
        precondition(layoutFrames.recentGeneratedPresentationEvidence() != nil,
                     "evidence is recorded for its own stream")
        layoutFrames.put(pixelBuffer(width: 32, height: 32))
        precondition(layoutFrames.recentGeneratedPresentationEvidence() == nil,
                     "a new input layout drops the previous evidence")
        precondition(!layoutFrames.markGenerated(streamEpoch: firstEpoch),
                     "a superseded stream cannot count a presentation")
        layoutFrames.recordGeneratedPresentationEvidence(streamEpoch: firstEpoch, at: ProcessInfo.processInfo.systemUptime)
        precondition(layoutFrames.recentGeneratedPresentationEvidence() == nil,
                     "a superseded stream cannot record evidence")
        print("PASS caption evidence: bound to its stream, refused for a superseded one, and unable to overwrite a newer reason")
    }

    /// The constructible orderings of a source switch, driven through the same gate and mailbox the
    /// capture paths use. A frame whose source lost the preview must never be stored at all: the
    /// check, the write and the switch share one critical section, so no draw or pair can pick the
    /// frame up while a retraction is still on its way.
    private static func testSourceIsolationInterleavings() {
        // (1) The switch runs first. A device frame that reaches its critical section afterwards is
        // refused before anything is written.
        let gate = PreviewIngestGate()
        let frames = LatestVideoFrame()
        frames.put(pixelBuffer(), pts: CMTime(value: 0, timescale: 60))
        gate.switchOwner(to: .macWindow) { frames.beginInput(blankPreview: true) }
        precondition(gate.currentOwner == .macWindow, "the switch publishes the new owner")
        precondition(frames.latest() == nil, "the switch cleared the mailbox")
        precondition(frames.isBlankRequestPending, "the switch requested its blank")
        var ingestBodyRan = false
        let refused: Bool? = gate.run(forOwner: .device) { () -> Bool in
            ingestBodyRan = true
            frames.put(pixelBuffer(), pts: CMTime(value: 1, timescale: 60))
            return true
        }
        precondition(refused == nil && !ingestBodyRan, "a card frame cannot be ingested after the switch")
        precondition(frames.latestSnapshot() == nil, "nothing renderable holds the card's frame")
        precondition(frames.interpolationPair(sequence: 1) == nil, "no pair can be built from the card's frame")
        precondition(frames.inputContentCadenceSnapshot() == nil, "no cadence measurement is fed by the card's frame")

        // (2) The ingest is already inside its critical section when the switch starts. The switch
        // cannot run inside it; the frame it stores is then cleared by that switch, which is the
        // only trace it may leave.
        let racingGate = PreviewIngestGate()
        let racingFrames = LatestVideoFrame()
        racingFrames.put(pixelBuffer(), pts: CMTime(value: 0, timescale: 60))
        let switchAttempted = DispatchSemaphore(value: 0)
        let switchCompleted = DispatchSemaphore(value: 0)
        var switchRanInsideIngest = false
        var storedInsideIngest = false
        let delivered: Bool? = racingGate.run(forOwner: .device) { () -> Bool in
            DispatchQueue.global().async {
                switchAttempted.signal()
                racingGate.switchOwner(to: .macWindow) { racingFrames.beginInput(blankPreview: true) }
                switchCompleted.signal()
            }
            switchAttempted.wait()
            // The switch must not be able to complete while this body still holds the gate.
            switchRanInsideIngest = switchCompleted.wait(timeout: .now()) == .success
            racingFrames.put(pixelBuffer(), pts: CMTime(value: 1, timescale: 60))
            storedInsideIngest = racingFrames.latest() != nil
            return true
        }
        precondition(delivered == true && storedInsideIngest,
                     "the frame is stored while its source still owns the preview")
        precondition(!switchRanInsideIngest, "a switch cannot run inside a frame's ingest critical section")
        precondition(switchCompleted.wait(timeout: .now() + 2) == .success, "the switch completes after the ingest")
        precondition(racingFrames.latest() == nil, "the switch clears the frame that ingest stored")
        precondition(racingFrames.isBlankRequestPending, "the switch's blank stands once the frame is cleared")

        // (3) A frame for the new input arrives after the switch and is kept: there is no retraction
        // left that could take it away, and it cancels the blank it belongs to.
        let deviceGate = PreviewIngestGate()
        let deviceFrames = LatestVideoFrame()
        deviceFrames.put(pixelBuffer(), pts: CMTime(value: 0, timescale: 60))
        deviceGate.switchOwner(to: .device) { deviceFrames.clear(blankPreview: true) }
        let newFrameStored: Bool? = deviceGate.run(forOwner: .device) { () -> Bool in
            deviceFrames.put(pixelBuffer(), pts: CMTime(value: 1, timescale: 60))
            return deviceFrames.latest() != nil
        }
        precondition(newFrameStored == true, "the new input's frame is ingested")
        precondition(deviceFrames.latest() != nil, "nothing removes the new input's frame afterwards")
        precondition(deviceFrames.consumeBlankRequest() == nil, "the new frame supersedes the switch's blank")
        print("PASS source isolation: a refused frame is never stored, a switch cannot interleave an ingest, and a new input's frame survives")
    }

    /// The window path hands every frame the token issued for its stream. A token from a stream a
    /// switch replaced is refused by the mailbox itself, so a frame that passed the adapter's check
    /// just before the switch cannot be stored after it.
    private static func testIngestTokenRefusesSupersededStream() {
        let frames = LatestVideoFrame()
        let firstToken = frames.beginInput(blankPreview: true)
        precondition(frames.put(pixelBuffer(), pts: CMTime(value: 1, timescale: 60), token: firstToken) != nil,
                     "the current input's token is accepted")
        let switchedToken = frames.beginInput(blankPreview: true)
        precondition(switchedToken != firstToken, "a new input issues a new token")
        precondition(frames.latest() == nil, "starting a new input clears the mailbox")
        precondition(frames.put(pixelBuffer(), pts: CMTime(value: 2, timescale: 60), token: firstToken) == nil,
                     "a frame from the replaced stream is refused inside the mailbox")
        precondition(frames.latest() == nil, "nothing renderable holds the replaced stream's frame")
        precondition(frames.isBlankRequestPending, "the switch keeps its blank")
        precondition(frames.put(pixelBuffer(), pts: CMTime(value: 3, timescale: 60), token: switchedToken) != nil,
                     "the new input's token is accepted")
        precondition(frames.latestSnapshot() != nil, "the new input's frame is renderable")
        print("PASS ingest token: a replaced stream's frame is refused by the mailbox, and the new input's frame is kept")
    }

    /// The endpoint of a pair is the source frame, not a generated one. When a fallback reason is
    /// stated between a midpoint and its already-scheduled endpoint, the endpoint presenting later
    /// must keep that reason: only the midpoint's own presentation is evidence that the engine ran.
    private static func testPresentedPairEvidenceUsesMidpoint() {
        let frames = LatestVideoFrame()
        frames.put(pixelBuffer(), pts: CMTime(value: 0, timescale: 60))
        let epoch = frames.streamGeneration()
        let midpointPresented = ProcessInfo.processInfo.systemUptime
        frames.recordGeneratedPresentationEvidence(streamEpoch: epoch, at: midpointPresented)
        // The pair is left native by a fallback reason while its endpoint is still scheduled.
        frames.setInterpolationState("处理超预算，暂用原始帧率")
        let endpointPresented = ProcessInfo.processInfo.systemUptime
        precondition(!frames.publishRunningForPresentedPair(forced: false, midpointPresentedAt: midpointPresented),
                     "an endpoint presenting after a fallback reason keeps that reason")
        precondition(frames.currentInterpolationState() == "处理超预算，暂用原始帧率",
                     "the fallback reason survives the late endpoint")
        // The endpoint's own later time is not evidence: using it is the defect this covers, and it
        // is why the presented-pair entry point takes the midpoint instead.
        precondition(frames.publishInterpolationRunning(forced: false, evidence: endpointPresented),
                     "the endpoint's later time is not presentation evidence, so it must not be used as such")
        print("PASS presented-pair evidence: the endpoint reports the midpoint's presentation, so a fallback reason survives it")
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
        precondition(PictureSettings().skipsExactDuplicateInterpolation, "content follow defaults on")
        var explicitCaptureBasis = PictureSettings()
        explicitCaptureBasis.skipsExactDuplicateInterpolation = false
        let savedCaptureBasis = try! JSONDecoder().decode(PictureSettings.self, from: JSONEncoder().encode(explicitCaptureBasis))
        precondition(!savedCaptureBasis.skipsExactDuplicateInterpolation, "explicit capture basis remains off after save")
        precondition(FrameInterpolationMode.availableQuality(.quality, supported: [.flowBlend]) == .flowBlend, "unavailable VT falls back to available Flow")
        precondition(FrameInterpolationMode.availableQuality(.flowBlend, supported: [.balanced]) == .balanced, "unavailable Flow falls back to available VT")
        precondition(FrameInterpolationMode.availableQuality(.quality, supported: []) == .off, "no available engine disables interpolation")
        precondition(FrameInterpolationMode.availableQuality(.quality, supported: [.quality, .flowBlend]) == .quality, "supported saved engine is retained")
        let oldJSON = #"{"brightness":0.12,"contrast":1.08,"saturation":0.91,"sharpness":0.2,"vibrance":0.15,"lowLatency":true,"enhancementEnabled":true,"enhancementStrength":0.35,"upscaleTarget":"原始","upscaleMethod":"MetalFX","highlightRecovery":0.05}"#
        let decoded: PictureSettings
        do {
            decoded = try JSONDecoder().decode(PictureSettings.self, from: Data(oldJSON.utf8))
        } catch {
            preconditionFailure("legacy PictureSettings JSON did not decode: \(error)")
        }
        precondition(decoded.enhancementStrength == 0.35, "saved strength is not raised by new defaults")
        precondition(decoded.skipsExactDuplicateInterpolation, "legacy unspecified follow defaults on")
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
        // The independent input-cadence worker may still be comparing this buffer.
        // Interpolation releases immediately; the bounded input comparison releases
        // its preceding sample as soon as the newest sample finishes processing.
        let releaseDeadline = Date().addingTimeInterval(1)
        while retained.weakPrevious.value != nil && Date() < releaseDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        precondition(retained.weakPrevious.value == nil,
                     "disabled interpolation and completed input comparison must release the preceding buffer")
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

    private static func testCaptureLifecyclePolicies() {
        precondition(CaptureSessionPolicy.action(isRunning: true, inputCount: 1) == nil,
                     "A running session with audio still attached is left alone")
        precondition(CaptureSessionPolicy.action(isRunning: true, inputCount: 0) == .stop,
                     "A running session with no input is stopped")
        precondition(CaptureSessionPolicy.action(isRunning: false, inputCount: 1) == .start,
                     "Window mode starts an idle session so audio keeps running")
        precondition(CaptureSessionPolicy.action(isRunning: false, inputCount: 0) == nil,
                     "An idle session with no input is left alone")
        precondition(CaptureSessionPolicy.shouldRun(inputCount: 1) && !CaptureSessionPolicy.shouldRun(inputCount: 0),
                     "Only an input justifies running the session")

        let pending = AudioSelectionIntent(id: "external-mic", persist: true)
        precondition(AudioPermissionPolicy.shouldRequestAccess(for: .notDetermined, requestInFlight: false))
        precondition(!AudioPermissionPolicy.shouldRequestAccess(for: .notDetermined, requestInFlight: true),
                     "A refresh must not issue another permission request while one is pending")
        precondition(!AudioPermissionPolicy.shouldRequestAccess(for: .denied, requestInFlight: false),
                     "A denial waits for the user to grant access in System Settings")
        precondition(AudioPermissionPolicy.restorableSelection(
            pending: pending, selectedID: pending.id, authorization: .denied, deviceAvailable: true
        ) == nil)
        precondition(AudioPermissionPolicy.restorableSelection(
            pending: pending, selectedID: pending.id, authorization: .authorized, deviceAvailable: true
        ) == pending, "Grant recovery preserves both selected ID and persist intent")
        precondition(AudioPermissionPolicy.restorableSelection(
            pending: pending, selectedID: "another-device", authorization: .authorized, deviceAvailable: true
        ) == nil, "A stale permission callback cannot replace the current selection")
        precondition(AudioPermissionPolicy.restorableSelection(
            pending: pending, selectedID: pending.id, authorization: .authorized, deviceAvailable: false
        ) == nil, "A disconnected pending device waits until it reappears")

        precondition(!CaptureSessionPolicy.audioInputNeedsConfiguration(actualID: "mic", requestedID: "mic"),
                     "Repeated selection does not reopen audio configuration")
        precondition(CaptureSessionPolicy.audioInputNeedsConfiguration(actualID: "mic", requestedID: nil))
        precondition(!CaptureSessionPolicy.audioInputNeedsConfiguration(actualID: nil, requestedID: nil))
        precondition(!CaptureSessionPolicy.canRecordWindowCapture(isRunning: false, width: 640, height: 360),
                     "A starting window stream is not recordable")
        precondition(!CaptureSessionPolicy.canRecordWindowCapture(isRunning: true, width: 0, height: 360),
                     "A running stream without configured dimensions is not recordable")
        precondition(CaptureSessionPolicy.canRecordWindowCapture(isRunning: true, width: 640, height: 360),
                     "A running window stream with valid dimensions is recordable")
        print("PASS audio permission recovery, idempotent input configuration, shared session, and window recording gates")
    }

    private static func testQualityPresetInterpolationState() {
        var disabled = PictureSettings()
        disabled.setInterpolationEnabled(false)
        disabled.forceFrameInterpolation = true
        disabled.applyInterpolationPreset(.quality)
        precondition(disabled.frameInterpolation == .off, "Applying a preset must preserve interpolation-off")
        precondition(disabled.preferredInterpolationQuality == .quality,
                     "An off setting still remembers the preset quality")
        precondition(!disabled.forceFrameInterpolation, "A preset clears the force override")
        disabled.setInterpolationEnabled(true)
        precondition(disabled.frameInterpolation == .quality,
                     "Turning interpolation back on restores the quality chosen by the preset")
        precondition(disabled.forceFrameInterpolation, "Enabling interpolation defaults to force-on")

        var enabled = PictureSettings()
        enabled.frameInterpolation = .efficient
        enabled.preferredInterpolationQuality = .efficient
        enabled.forceFrameInterpolation = true
        enabled.applyInterpolationPreset(.flowBlend)
        precondition(enabled.frameInterpolation == .flowBlend,
                     "An enabled setting switches to the preset's interpolation engine")
        precondition(enabled.preferredInterpolationQuality == .flowBlend && enabled.forceFrameInterpolation,
                     "An enabled preset preserves the force choice")
        enabled.forceFrameInterpolation = false
        enabled.applyInterpolationPreset(.quality)
        precondition(!enabled.forceFrameInterpolation, "Presets also preserve an explicit force-off choice")

        let smooth = CaptureManager.qualityPresets.first { $0.name == "流畅优先" }!
        let quality = CaptureManager.qualityPresets.first { $0.name == "画质优先" }!
        let native = CaptureManager.qualityPresets.first { $0.name == "原生增强" }!
        smooth.apply(to: &enabled, supported: [.flowBlend, .quality])
        precondition(enabled.enhancementStrength == 0.60 && enabled.frameInterpolation == .flowBlend)
        precondition(enabled.forceFrameInterpolation && enabled.skipsExactDuplicateInterpolation, "smooth explicitly enables force and content follow")
        quality.apply(to: &enabled, supported: [.flowBlend, .quality])
        precondition(enabled.enhancementStrength == 0.80 && enabled.upscaleTarget == .screen)
        let priorEngine = enabled.frameInterpolation
        enabled.skipsExactDuplicateInterpolation = false
        native.apply(to: &enabled, supported: [.flowBlend, .quality])
        precondition(enabled.frameInterpolation == .off && !enabled.forceFrameInterpolation, "native generates no frames")
        precondition(enabled.preferredInterpolationQuality == priorEngine, "native retains the selected engine for later enable")
        precondition(enabled.enhancementEnabled && enabled.enhancementStrength == 1 && enabled.upscaleTarget == .screen && !enabled.lowLatency, "native uses full display-sized enhancement")
        precondition(!enabled.skipsExactDuplicateInterpolation, "native preserves the chosen content basis")
        quality.apply(to: &enabled, supported: [.flowBlend])
        precondition(enabled.frameInterpolation == .flowBlend && enabled.preferredInterpolationQuality == .flowBlend && enabled.forceFrameInterpolation && enabled.skipsExactDuplicateInterpolation, "return from native enables interpolation with available fallback")
        enabled.setInterpolationEnabled(true)
        precondition(enabled.frameInterpolation == .flowBlend && enabled.forceFrameInterpolation, "explicit enable defaults force-on after native")
        for capabilities: [FrameInterpolationMode] in [[.flowBlend, .quality], [.flowBlend], []] {
            for oldMode in FrameInterpolationMode.allCases {
                for preset in CaptureManager.qualityPresets {
                    var settings = PictureSettings()
                    settings.enhancementEnabled = false
                    settings.frameInterpolation = oldMode
                    settings.forceFrameInterpolation = false
                    settings.skipsExactDuplicateInterpolation = false
                    preset.apply(to: &settings, supported: capabilities)
                    let expected = preset.nativeFrameRate ? FrameInterpolationMode.off :
                        FrameInterpolationMode.availableQuality(preset.interpolation, supported: capabilities)
                    precondition(settings.enhancementEnabled && settings.frameInterpolation == expected)
                    precondition(settings.forceFrameInterpolation == (expected != .off))
                    precondition(preset.nativeFrameRate || settings.skipsExactDuplicateInterpolation)
                    precondition(settings.upscaleTarget == preset.upscaleTarget && settings.enhancementStrength == preset.enhancementStrength)
                }
            }
        }
        print("PASS complete quality presets enable interpolation, content follow and force; native/no-engine disable safely")
    }

    static func main() {
        if CommandLine.arguments.contains("--pure-only") {
            testCaptureLifecyclePolicies()
            testQualityPresetInterpolationState()
            return
        }
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
            precondition(settings.frameInterpolation == .flowBlend, "Invalid saved quality must recover")
        }
        testPresentationIntervalsAndDuplicateSkips()
        testSourceSwitchClearingAndCaptionEvidence()
        testSourceIsolationInterleavings()
        testIngestTokenRefusesSupersededStream()
        testPresentedPairEvidenceUsesMidpoint()
        testOldPictureSettingsJSON()
        testInterpolationHistory()
        testStableSourceFrameRatesAndResets()
        testQualityPresetInterpolationState()

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
        precondition(UpscaleTarget.screen.processingLongEdge(screenLongEdge: 3024, sourceLongEdge: 1920,
            visibleLongEdge: 3024, lowLatency: true) == 3024, "Match Display must retain full visible source-frame scaling")
        precondition(UpscaleTarget.screen.processingLongEdge(screenLongEdge: 3024, sourceLongEdge: 1920,
            visibleLongEdge: 2400, lowLatency: true) == 2400, "Low latency retains the existing viewport bound")
        precondition(UpscaleTarget.screen.processingLongEdge(screenLongEdge: 3024, sourceLongEdge: 1920,
            visibleLongEdge: 2400, lowLatency: false) == 3024)
        precondition(UpscaleTarget.screen.processingLongEdge(screenLongEdge: 5120, sourceLongEdge: 1920,
            visibleLongEdge: 3840, lowLatency: true) == 3840)
        precondition(UpscaleTarget.screen.processingLongEdge(screenLongEdge: nil, sourceLongEdge: 1920,
            visibleLongEdge: 3024, lowLatency: false) == 1920)
        precondition(UpscaleTarget.native.processingLongEdge(screenLongEdge: 3024, sourceLongEdge: 1920,
            visibleLongEdge: 3024, lowLatency: true) == 1920)
        precondition(UpscaleTarget.fullHD.processingLongEdge(screenLongEdge: 3024, sourceLongEdge: 3840,
            visibleLongEdge: 2400, lowLatency: true) == 3840, "Enhancement never downsamples the source")
        precondition(UpscaleTarget.uhd.processingLongEdge(screenLongEdge: 3024, sourceLongEdge: 1920,
            visibleLongEdge: 3024, lowLatency: false) == 3840)

        testCaptureLifecyclePolicies()
        print("Capture compatibility tests passed: legacy settings, frame history/PTS, cadence resets, formats, rates, and display targets.")
    }
}
