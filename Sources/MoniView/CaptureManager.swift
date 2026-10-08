@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation

struct CaptureInputOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Where the preview's video comes from. Capture devices are the default; the Mac
/// window source exists for games and software running on this same machine.
enum CaptureSourceKind: String, CaseIterable, Identifiable, Codable {
    case device = "采集设备"
    case macWindow = "Mac 窗口"
    var id: String { rawValue }
}

/// Serializes which source owns the preview with the ingest of its frames.
///
/// A switch publishes the new owner, clears the mailbox and starts the new input in one critical
/// section; every frame is written in another. A frame from a source that lost the preview is
/// therefore refused instead of being stored and retracted afterwards, and a frame stored before
/// the switch is cleared by it. Checking, writing and then reverting left a window in which the
/// wrong frame was already renderable and pairable while the retraction could no longer stop a
/// draw that had already been submitted.
final class PreviewIngestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: CaptureSourceKind = .device

    /// Runs the body while the expected source owns the preview, atomically with respect to a
    /// switch. Returns nil when another source owns it, so the caller writes nothing at all.
    func run<Value>(forOwner expected: CaptureSourceKind, _ body: () -> Value) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard owner == expected else { return nil }
        return body()
    }

    /// Publishes a new owner and runs the switch body in the same critical section, so no frame
    /// can be ingested between the two.
    @discardableResult
    func switchOwner<Value>(to newOwner: CaptureSourceKind, _ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        owner = newOwner
        return body()
    }

    /// The owner, read atomically. For queries and reporting only; frame ingest uses run(forOwner:).
    var currentOwner: CaptureSourceKind {
        lock.lock(); defer { lock.unlock() }
        return owner
    }
}

struct CaptureFormatOption: Identifiable, Hashable {
    let id: Int
    let width: Int
    let height: Int
    let minimumFPS: Int
    let maximumFPS: Int
    let rates: [ClosedRange<Double>]
    var title: String { "\(width) × \(height)" }
    var fpsTitle: String { L10n.format("最高 %d FPS", maximumFPS) }
    func supportsFPS(_ fps: Int) -> Bool { supportsFrameRate(Double(fps)) }
    /// Preserve fractional maxima when choosing the representative of a resolution.
    /// Integer UI labels must not make a 59.94 format outrank a real 60 format.
    func prefers(over previous: CaptureFormatOption, nativeNV12: Bool) -> Bool {
        let candidate = rates.map(\.upperBound).max() ?? 0
        let current = previous.rates.map(\.upperBound).max() ?? 0
        return candidate > current + 0.00001 || (abs(candidate - current) <= 0.00001 && nativeNV12)
    }
    func supportsFrameRate(_ fps: Double) -> Bool {
        fps == 0 || rates.contains { $0.lowerBound - 0.01 <= fps && $0.upperBound + 0.01 >= fps }
    }
}

enum AspectMode: String, CaseIterable, Identifiable, Codable {
    case fit = "适应画面"
    case fill = "填满窗口"
    case stretch = "拉伸填满"
    var id: String { rawValue }
}

enum UpscaleTarget: String, CaseIterable, Identifiable, Codable {
    case native = "原始"
    case fullHD = "1080p"
    case qhd = "2K"
    case uhd = "4K"
    case screen = "屏幕"
    var id: String { rawValue }
    /// Fixed long edge for fixed targets; nil for native (no scaling) and screen (resolved per display).
    var longEdge: Double? {
        switch self {
        case .native, .screen: return nil
        case .fullHD: return 1920
        case .qhd: return 2560
        case .uhd: return 3840
        }
    }
    /// Resolves the processing long edge; the screen target adapts to the display's backing-store pixel count.
    func resolvedLongEdge(screenLongEdge: Double?, sourceLongEdge: Double) -> Double {
        switch self {
        case .native: return sourceLongEdge
        case .fullHD, .qhd, .uhd: return longEdge ?? sourceLongEdge
        case .screen: return screenLongEdge ?? sourceLongEdge
        }
    }
}

enum UpscaleMethod: String, CaseIterable, Identifiable, Codable {
    case metalFX = "MetalFX"
    case lanczos = "Lanczos"
    case ai = "AI 超分"
    var id: String { rawValue }
    func availableMethod(aiSupported: Bool) -> UpscaleMethod {
        self == .ai && !aiSupported ? .metalFX : self
    }
}

struct PictureSettings: Equatable, Codable {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var sharpness = 0.0
    var vibrance = 0.0
    var lowLatency = true
    var enhancementEnabled = true
    var enhancementStrength = 0.55
    var upscaleTarget: UpscaleTarget = .native
    var upscaleMethod: UpscaleMethod = .metalFX
    // Optional keeps old persisted settings decodable; absence means off.
    var interpolationMode: FrameInterpolationMode?
    var preferredInterpolationQuality: FrameInterpolationMode? = .flowBlend
    // Optional additions preserve previously saved settings.
    var interpolationForce: Bool?
    var interpolationSkipDuplicates: Bool?
    var skipsExactDuplicateInterpolation: Bool {
        get { interpolationSkipDuplicates ?? true }
        set { interpolationSkipDuplicates = newValue }
    }
    var forceFrameInterpolation: Bool {
        get { interpolationForce ?? false }
        set { interpolationForce = newValue }
    }
    var frameInterpolation: FrameInterpolationMode {
        get { interpolationMode ?? .off }
        set { interpolationMode = newValue == .off ? nil : newValue }
    }
    /// Force only has meaning while interpolation runs. Call this from a plain load or
    /// setter path, never from picture.didSet: writing the flag inside the observer
    /// re-enters it, which recursed until the stack ran out.
    mutating func normalizeForceFlag() {
        if frameInterpolation == .off, forceFrameInterpolation { forceFrameInterpolation = false }
    }

    /// Force only has meaning while interpolation runs, so turning interpolation off
    /// clears it. This is never called from picture.didSet: writing the flag inside the
    /// observer re-enters it, which recursed until the stack ran out.
    mutating func setInterpolationEnabled(_ enabled: Bool) {
        if !enabled { forceFrameInterpolation = false }
        if enabled {
            forceFrameInterpolation = true
            let preferred = preferredInterpolationQuality ?? .flowBlend
            frameInterpolation = preferred == .off ? .flowBlend : preferred
        } else {
            // A repeated off action must not destroy the last enabled quality.
            if frameInterpolation != .off { preferredInterpolationQuality = frameInterpolation }
            frameInterpolation = .off
        }
    }

    /// Update the quality a preset prefers without changing the independent on/off switch.
    mutating func applyInterpolationPreset(_ quality: FrameInterpolationMode) {
        let wasEnabled = frameInterpolation != .off
        preferredInterpolationQuality = quality
        frameInterpolation = wasEnabled ? quality : .off
        if !wasEnabled { forceFrameInterpolation = false }
    }
    var highlightRecovery = 0.0
    var colorParameters: [Double] { [brightness, contrast, saturation, vibrance, highlightRecovery] }
}

/// Latest-frame mailbox. Optional interpolation retains ONE preceding reference, never a queue.
final class LatestVideoFrame {
    private let lock = NSLock()
    private let inputContentCadence = InputContentCadence()
    private var frameHandler: (() -> Void)?
    private var buffer: CVPixelBuffer?
    private var formatDescription: CMFormatDescription?
    private var sequence: UInt64 = 0
    private var streamEpoch: UInt64 = 0
    private var pts: CMTime = .invalid
    private var sourceIntervals: [Double] = []
    private var historyEnabled = false
    private var previous: (CVPixelBuffer, UInt64, CMTime)?
    private var generated = 0
    private var presentedSource = 0
    private var skippedDuplicatePairs = 0
    private var lastSkippedDuplicate: (sequence: UInt64, epoch: UInt64)?
    private var lastPresentationTime: Double?
    private var presentationIntervals: [Double] = []
    func markDuplicateSkipped(sequence: UInt64, streamEpoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard streamEpoch == self.streamEpoch else { return }
        if let lastSkippedDuplicate, lastSkippedDuplicate.epoch == streamEpoch, lastSkippedDuplicate.sequence >= sequence { return }
        lastSkippedDuplicate = (sequence, streamEpoch); skippedDuplicatePairs += 1
    }
    func takeDuplicateSkips() -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = skippedDuplicatePairs; skippedDuplicatePairs = 0; return count
    }
    private func recordPresentationTime(_ time: Double?) {
        guard let time, time.isFinite, time > 0 else { return }
        if let previous = lastPresentationTime, time > previous {
            presentationIntervals.append((time - previous) * 1000)
            presentationIntervals = Array(presentationIntervals.suffix(120))
        }
        if time > (lastPresentationTime ?? 0) { lastPresentationTime = time }
    }
    func presentationP95() -> Double {
        lock.lock(); defer { lock.unlock() }
        let sorted = presentationIntervals.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
    }
    private var lastPresentedSource: (sequence: UInt64, streamEpoch: UInt64)?
    private var interpolationState = "关闭"
    /// Wall time of the most recent generated frame that actually reached the display.
    /// Coupled with the output frames it authorises, it keeps a warm-up label from
    /// contradicting complete pairs that keep presenting.
    private var lastGeneratedPresentationAt: TimeInterval?
    /// Stream epoch a pending blank-preview request belongs to. See clear(blankPreview:).
    private var blankRequestEpoch: UInt64?
    /// Authorization for frames that may enter the mailbox. Starting a new input advances it, so a
    /// frame produced by the stream that lost the preview cannot be written afterwards: the check
    /// and the write share this lock instead of being a check-write-retract sequence whose middle
    /// a source switch can interleave.
    private var ingestToken: UInt64 = 0
    private var interpolationCostMS = 0.0
    private var interpolationBudgetMS = 0.0
    private var interpolationWorkingSize: String?
    private var displayRates = (maximum: 0.0, observed: 0.0)
    private var captured = 0
    private var rendered = 0
    private var dropped = 0
    private var level: Float = 0
    private var receivedAt: UInt64 = 0
    private var processingMilliseconds = 0.0
    private var previewState = "starting"
    func setPreviewState(_ state: String) {
        lock.lock()
        if state == "hidden", previewState != state { lastPresentationTime = nil; presentationIntervals.removeAll(keepingCapacity: true) }
        previewState = state; lock.unlock()
    }
    func currentPreviewState() -> String { lock.lock(); defer { lock.unlock() }; return previewState }
    private var engine = "原始"
    private var enhancedSize: String?
    private var timings: [Double] = []
    private var gpuTimings: [Double] = []

    /// Stores the newest frame and returns the sequence number it was stored under.
    @discardableResult
    func put(_ pixelBuffer: CVPixelBuffer, pts: CMTime = .invalid, formatDescription: CMFormatDescription? = nil) -> UInt64 {
        lock.lock()
        let stored = storeLocked(pixelBuffer, pts: pts, formatDescription: formatDescription)
        lock.unlock()
        publish(pixelBuffer, pts: pts, stored: stored)
        return stored.sequence
    }
    /// Stores a frame only while the token is the one this mailbox issued for the current input.
    /// Returns nil when the frame is refused. The ownership decision and the write happen under
    /// the same lock, so a frame produced by a stream that lost the preview is refused here
    /// instead of being stored first and retracted after the switch: a draw can no longer pick up
    /// an old source's frame in the window between the check and the retraction.
    @discardableResult
    func put(_ pixelBuffer: CVPixelBuffer, pts: CMTime = .invalid,
             formatDescription: CMFormatDescription? = nil, token: UInt64) -> UInt64? {
        lock.lock()
        guard token == ingestToken else { lock.unlock(); return nil }
        let stored = storeLocked(pixelBuffer, pts: pts, formatDescription: formatDescription)
        lock.unlock()
        publish(pixelBuffer, pts: pts, stored: stored)
        return stored.sequence
    }
    /// Caller holds the lock. Applies the frame to the mailbox state.
    private func storeLocked(_ pixelBuffer: CVPixelBuffer, pts: CMTime,
                             formatDescription: CMFormatDescription?) -> (sequence: UInt64, epoch: UInt64, notify: (() -> Void)?) {
        let sameSize = buffer.map { CVPixelBufferGetWidth($0) == CVPixelBufferGetWidth(pixelBuffer) && CVPixelBufferGetHeight($0) == CVPixelBufferGetHeight(pixelBuffer) } ?? false
        let interval = CMTimeGetSeconds(CMTimeSubtract(pts, self.pts))
        if sameSize, self.pts.isNumeric, pts.isNumeric, interval.isFinite, interval >= 1 / 240.0, interval <= 0.1 {
            if let last = sourceIntervals.last, abs(interval - last) > last * 0.1 { sourceIntervals.removeAll(keepingCapacity: true) }
            sourceIntervals.append(interval); sourceIntervals = Array(sourceIntervals.suffix(12))
        } else {
            sourceIntervals.removeAll(keepingCapacity: true)
            streamEpoch &+= 1
            publishedMultiplier = nil
            publishedInterpolationBasisFPS = nil
            publishedInterpolationAt = nil
            // The new epoch is a new input: nothing generated has reached the display for it.
            lastGeneratedPresentationAt = nil
            inputContentCadence.reset(streamEpoch: streamEpoch)
            lastPresentationTime = nil; presentationIntervals.removeAll(keepingCapacity: true)
        }
        previous = historyEnabled && sameSize ? buffer.map { ($0, sequence, self.pts) } : nil
        self.pts = pts
        buffer = pixelBuffer
        self.formatDescription = formatDescription
        receivedAt = DispatchTime.now().uptimeNanoseconds
        sequence &+= 1
        captured += 1
        return (sequence, streamEpoch, frameHandler)
    }
    /// Publishes a stored frame to the cadence monitor and the renderer.
    private func publish(_ pixelBuffer: CVPixelBuffer, pts: CMTime,
                         stored: (sequence: UInt64, epoch: UInt64, notify: (() -> Void)?)) {
        inputContentCadence.submit(pixelBuffer, presentationTime: pts,
                                   sequence: stored.sequence, streamEpoch: stored.epoch)
        stored.notify?()
    }
    /// Input-side measurement remains valid when rendering skips or pauses drawing.
    func inputContentCadenceSnapshot() -> InputContentCadenceSnapshot? {
        let value = inputContentCadence.snapshot()
        lock.lock(); let currentEpoch = streamEpoch; let hasInput = buffer != nil; lock.unlock()
        guard hasInput, value.streamEpoch == currentEpoch else { return nil }
        return value
    }
    func setFrameHandler(_ handler: @escaping () -> Void) { lock.lock(); frameHandler = handler; lock.unlock() }
    func latest() -> (CVPixelBuffer, UInt64, UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, sequence, receivedAt)
    }
    func latestSnapshot() -> (buffer: CVPixelBuffer, sequence: UInt64, receivedAt: UInt64, streamEpoch: UInt64, pts: CMTime)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, sequence, receivedAt, streamEpoch, pts)
    }
    /// Keep capture metadata paired with its buffer. Only the current description is retained.
    func latestFormatSnapshot() -> (buffer: CVPixelBuffer, description: CMFormatDescription?)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, formatDescription)
    }
    /// Actual media timestamps, not selected/rounded FPS or callback arrival jitter.
    func sourceFrameRate() -> Double? {
        lock.lock(); let intervals = sourceIntervals; lock.unlock()
        guard intervals.count >= 8 else { return nil }
        let sorted = intervals.sorted(), median = sorted[sorted.count / 2]
        guard median > 0, sorted.allSatisfy({ abs($0 - median) <= median * 0.05 }) else { return nil }
        return 1 / median
    }
    func streamGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return streamEpoch
    }
    func setInterpolationHistoryEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        historyEnabled = enabled
        if !enabled { previous = nil }
    }
    func interpolationPair(sequence expected: UInt64) -> (CVPixelBuffer, UInt64, CMTime, CMTime)? {
        lock.lock(); defer { lock.unlock() }
        guard expected == sequence, let previous else { return nil }
        return (previous.0, previous.1, previous.2, pts)
    }
    /// Publishes a caption that is not a running claim: a preparation state, a fallback reason,
    /// a GPU error or off. The write time is recorded because a running claim built on older
    /// presentation evidence must not erase a reason stated after that evidence.
    func setInterpolationState(_ value: String) {
        lock.lock()
        interpolationState = value
        interpolationReasonAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }
    private var interpolationMidpointGPUMs = 0.0
    func setInterpolationGPUCost(milliseconds: Double) {
        lock.lock(); interpolationMidpointGPUMs = milliseconds; lock.unlock()
    }
    func currentInterpolationGPUCost() -> Double {
        lock.lock(); defer { lock.unlock() }; return interpolationMidpointGPUMs
    }
    func setInterpolationCost(seconds: Double, budget: Double) {
        lock.lock(); interpolationCostMS = seconds * 1000; interpolationBudgetMS = budget * 1000; lock.unlock()
    }
    func setInterpolationWorkingSize(_ value: String?) { lock.lock(); interpolationWorkingSize = value; lock.unlock() }
    /// Multiplier the renderer actually applied to the most recent pair. Published by the
    /// renderer rather than recomputed here, so the panel cannot announce a different step
    /// than the engine is running.
    private var publishedMultiplier: Double?
    private var publishedInterpolationBasisFPS: Double?
    private var publishedInterpolationAt: TimeInterval?
    // HUD rates summarize a one-second window. A single native fallback must not
    // erase a successful pair from that window; absence of new success still expires.
    static let interpolationActivityLifetime: TimeInterval = 1.25
    func setActiveMultiplier(_ value: Double?, inputFPS: Double? = nil, streamEpoch expectedEpoch: UInt64? = nil,
                             at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if let expectedEpoch, expectedEpoch != streamEpoch { return }
        if let value {
            guard expectedEpoch != nil, buffer != nil, value.isFinite, value > 1,
                  let inputFPS, inputFPS.isFinite, inputFPS > 0, now.isFinite else { return }
        }
        publishedMultiplier = value
        publishedInterpolationBasisFPS = value == nil ? nil : inputFPS
        publishedInterpolationAt = value == nil ? nil : now
    }
    func currentInterpolationActivity(at now: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> (multiplier: Double, basisFPS: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let publishedInterpolationAt, now.isFinite, now >= publishedInterpolationAt,
              now - publishedInterpolationAt <= Self.interpolationActivityLifetime,
              let publishedMultiplier, let publishedInterpolationBasisFPS else { return nil }
        return (publishedMultiplier, publishedInterpolationBasisFPS)
    }
    func currentActiveMultiplier() -> Double? { currentInterpolationActivity()?.multiplier }
    func currentInterpolationBasisFPS() -> Double? { currentInterpolationActivity()?.basisFPS }
    func currentInterpolationWorkingSize() -> String? { lock.lock(); defer { lock.unlock() }; return interpolationWorkingSize }
    func interpolationCost() -> (Double, Double) {
        lock.lock(); defer { lock.unlock() }; return (interpolationCostMS, interpolationBudgetMS)
    }
    func setDisplayRates(maximum: Double, observed: Double) {
        lock.lock(); displayRates = (maximum, observed); lock.unlock()
    }
    func currentDisplayRates() -> (maximum: Double, observed: Double) {
        lock.lock(); defer { lock.unlock() }; return displayRates
    }
    func currentInterpolationState() -> String { lock.lock(); defer { lock.unlock() }; return interpolationState }
    /// Wall time of the most recent caption that was not a running claim. A running claim must
    /// be backed by presentation evidence newer than this, or a late success callback would
    /// erase the reason the engine is not running.
    private var interpolationReasonAt: TimeInterval?
    private var aiUpscaleStatus = ""
    func setAIUpscaleStatus(_ value: String) { lock.lock(); aiUpscaleStatus = value; lock.unlock() }
    func currentAIUpscaleStatus() -> String { lock.lock(); defer { lock.unlock() }; return aiUpscaleStatus }
    /// Records a generated frame that reached the display. Returns false when the callback
    /// belongs to a superseded stream, so the caller cannot use it as evidence that the
    /// current source or configuration is running. It counts the presentation; the evidence the
    /// caption is built from is recorded separately, because only the caller knows whether the
    /// callback still belongs to the current render configuration.
    @discardableResult
    func markGenerated(streamEpoch: UInt64, presentedTime: Double? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard streamEpoch == self.streamEpoch else { return false }
        generated += 1; recordPresentationTime(presentedTime)
        return true
    }
    func markPresentedSource(sequence: UInt64, streamEpoch: UInt64, presentedTime: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard streamEpoch == self.streamEpoch else { return }
        if let lastPresentedSource {
            guard streamEpoch > lastPresentedSource.streamEpoch ||
                    (streamEpoch == lastPresentedSource.streamEpoch && sequence > lastPresentedSource.sequence) else { return }
        }
        lastPresentedSource = (sequence, streamEpoch)
        presentedSource += 1; recordPresentationTime(presentedTime)
    }
    func presentationStatistics() -> (generated: Int, presentedSource: Int) {
        lock.lock(); defer { lock.unlock() }
        let value = (generated, presentedSource)
        generated = 0; presentedSource = 0
        return value
    }
    /// Timestamp of the most recent generated frame that actually reached the display inside
    /// the activity window, or nil when nothing generated has presented recently. The renderer
    /// publishes the running caption from this evidence, so bookkeeping warm-up resets cannot
    /// contradict complete pairs that keep presenting.
    ///
    /// Evidence is bound to the stream epoch it was recorded under: every epoch change clears
    /// it, so a late callback from a previous source or render configuration cannot vouch for
    /// the current one.
    func recentGeneratedPresentationEvidence(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        lifetime: TimeInterval = LatestVideoFrame.interpolationActivityLifetime
    ) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let lastGeneratedPresentationAt, now.isFinite, now >= lastGeneratedPresentationAt,
              now - lastGeneratedPresentationAt <= lifetime else { return nil }
        return lastGeneratedPresentationAt
    }
    /// Invalidates the presentation evidence. Called when the stream epoch or the render
    /// configuration changes: nothing generated has reached the display for the new one yet.
    func clearGeneratedPresentationEvidence() {
        lock.lock(); lastGeneratedPresentationAt = nil; lock.unlock()
    }
    /// Records that a generated frame reached the display for this stream and the render
    /// configuration the caller is drawing. Only this counts as evidence that the engine runs;
    /// a late callback from a superseded generation must not vouch for the new one.
    func recordGeneratedPresentationEvidence(streamEpoch: UInt64, at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard streamEpoch == self.streamEpoch, time.isFinite else { return }
        lastGeneratedPresentationAt = time
    }
    /// Publishes the running caption from a presentation that reached the display. Returns
    /// false when a reason was stated after that evidence, so a GPU error or a fallback reason
    /// keeps the caption until newer evidence proves the engine runs again.
    @discardableResult
    func publishInterpolationRunning(forced: Bool, evidence: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard evidence.isFinite else { return false }
        if let interpolationReasonAt, interpolationReasonAt > evidence { return false }
        interpolationState = forced ? "强制插帧运行中" : "插帧运行中"
        return true
    }
    /// Publishes the running caption for a pair whose midpoint reached the display, and returns
    /// whether it was published. The evidence is that generated midpoint, never the later source
    /// endpoint: an endpoint that presents after a fallback reason does not prove the engine
    /// generated anything since the reason was stated, so the pair may only re-announce running
    /// from the midpoint's own presentation time.
    @discardableResult
    func publishRunningForPresentedPair(forced: Bool, midpointPresentedAt midpointTime: TimeInterval) -> Bool {
        publishInterpolationRunning(forced: forced, evidence: midpointTime)
    }
    /// True while the renderer still owes a blank frame for the most recent source switch.
    var isBlankRequestPending: Bool { lock.lock(); defer { lock.unlock() }; return blankRequestEpoch != nil }
    /// Takes the pending blank request and reports the stream epoch it belongs to. Nil means
    /// there is nothing pending, or a frame for the current stream arrived first and supersedes
    /// the blank. The caller returns the request with rearmBlankRequest(epoch:) if the clearing
    /// command could not be submitted, so a failed attempt is retried instead of silently
    /// leaving the previous source on screen.
    func consumeBlankRequest() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard let requestedEpoch = blankRequestEpoch else { return nil }
        blankRequestEpoch = nil
        guard buffer == nil, requestedEpoch == streamEpoch else { return nil }
        return requestedEpoch
    }
    /// Puts a blank request back after the drawable could not be cleared, so the next render
    /// retries it. Returns false when the request no longer belongs to the current input: a late
    /// callback from a superseded source must not open a blank on the new one.
    @discardableResult
    func rearmBlankRequest(epoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == streamEpoch, buffer == nil else { return false }
        blankRequestEpoch = epoch
        return true
    }
    /// True while a blank for this input epoch is still the right thing to draw: the epoch is the
    /// current one and no frame has taken the mailbox over. A blank registration for an epoch that
    /// a newer stream replaced must not be retried or retired, because that would disturb the
    /// preview which already moved on.
    func isBlankStillNeeded(forEpoch epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == streamEpoch && buffer == nil
    }
    /// Clears the mailbox. blankPreview additionally asks the renderer to blank the drawable,
    /// because the last presented frame would otherwise stay on screen while the new source
    /// has not delivered anything.
    func clear(blankPreview: Bool = false) {
        lock.lock()
        let callback = clearLocked(blankPreview: blankPreview)
        lock.unlock()
        callback?()
    }
    /// Starts a new input: invalidates every token issued to the previous one, clears the mailbox
    /// and returns the token the new input must present. Issued and cleared in one critical
    /// section, so a frame carrying the old token can never land after the clear.
    @discardableResult
    func beginInput(blankPreview: Bool) -> UInt64 {
        lock.lock()
        ingestToken &+= 1
        let token = ingestToken
        let callback = clearLocked(blankPreview: blankPreview)
        lock.unlock()
        callback?()
        return token
    }
    /// Caller holds the lock. Returns the frame handler to notify after unlocking.
    private func clearLocked(blankPreview: Bool) -> (() -> Void)? {
        buffer = nil
        formatDescription = nil
        previous = nil; pts = .invalid; sourceIntervals.removeAll(keepingCapacity: true)
        sequence &+= 1
        streamEpoch &+= 1
        publishedMultiplier = nil
        publishedInterpolationBasisFPS = nil
        publishedInterpolationAt = nil
        lastGeneratedPresentationAt = nil
        blankRequestEpoch = blankPreview ? streamEpoch : nil
        inputContentCadence.reset(streamEpoch: streamEpoch)
        level = 0; lastPresentationTime = nil; presentationIntervals.removeAll(keepingCapacity: true)
        // The blanking draw is requested now: nothing else would ask for one until a frame arrives.
        return blankPreview ? frameHandler : nil
    }
    func markRendered(receivedAt: UInt64, gpuMS: Double) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - receivedAt) / 1_000_000
        lock.lock(); rendered += 1; timings.append(milliseconds); gpuTimings.append(gpuMS); lock.unlock()
    }
    func setEngine(_ value: String) { lock.lock(); engine = value; lock.unlock() }
    func currentEngine() -> String { lock.lock(); defer { lock.unlock() }; return engine }
    func setEnhancedSize(_ value: String?) { lock.lock(); enhancedSize = value; lock.unlock() }
    func currentEnhancedSize() -> String? { lock.lock(); defer { lock.unlock() }; return enhancedSize }
    func processingTimes() -> (Double, Double, Double) {
        lock.lock(); defer { lock.unlock() }
        guard !timings.isEmpty else { return (processingMilliseconds, 0, 0) }
        processingMilliseconds = timings.reduce(0, +) / Double(timings.count)
        let sorted = timings.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let gpu = gpuTimings.reduce(0, +) / Double(gpuTimings.count)
        timings.removeAll(keepingCapacity: true); gpuTimings.removeAll(keepingCapacity: true)
        return (processingMilliseconds, gpu, p95)
    }
    func markDropped() { lock.lock(); dropped += 1; lock.unlock() }
    func setLevel(_ value: Float) { lock.lock(); level = value; lock.unlock() }
    func statistics() -> (Int, Int, Int, Float) {
        lock.lock(); defer { lock.unlock() }
        let value = (captured, rendered, dropped, level)
        captured = 0; rendered = 0; dropped = 0
        return value
    }
}

final class CaptureManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let frames = LatestVideoFrame()
    @Published private(set) var videoOptions: [CaptureInputOption] = []
    @Published var sourceKind: CaptureSourceKind = .device {
        didSet {
            guard oldValue != sourceKind else { return }
            fittedWindowPreview.stop()
            UserDefaults.standard.set(sourceKind.rawValue, forKey: "source.kind")
            applySourceKind()
        }
    }
    @Published private(set) var macWindowOptions: [MacWindowOption] = []
    @Published private(set) var macWindowStatus: String?
    @Published var selectedMacWindowID: UInt32? {
        didSet {
            guard sourceKind == .macWindow, oldValue != selectedMacWindowID else { return }
            fittedWindowPreview.stop()
            UserDefaults.standard.set(Int(selectedMacWindowID ?? 0), forKey: "source.windowID")
            restartMacWindowCapture()
        }
    }
    @Published private(set) var audioOptions: [CaptureInputOption] = []
    @Published private(set) var formatOptions: [CaptureFormatOption] = []
    @Published var selectedVideoID: String?
    @Published var selectedAudioID: String?
    @Published var selectedFormatID: Int?
    @Published var selectedFPS = 0
    @Published private(set) var frameRateOptions: [Double] = [0]
    @Published private(set) var selectedFrameRate = 0.0
    @Published var aspectMode: AspectMode = .fit { didSet { userChoseAspect = true; UserDefaults.standard.set(aspectMode.rawValue, forKey: "view.aspect") } }
    private var userChoseAspect = false
    /// Portrait buffers are phone/tablet mirrors: fill the window by default until the
    /// user picks a mode explicitly. Landscape 4:3 (retro consoles) is never stretched.
    @Published private(set) var isPortraitSource = false
    var effectiveAspectMode: AspectMode {
        if isFittedWindowPreviewActive { return .fit }
        return isPortraitSource && !userChoseAspect ? .stretch : aspectMode
    }
    @Published var picture = PictureSettings() {
        didSet {
            if oldValue.enhancementEnabled != picture.enhancementEnabled ||
                oldValue.frameInterpolation != picture.frameInterpolation ||
                oldValue.forceFrameInterpolation != picture.forceFrameInterpolation ||
                oldValue.skipsExactDuplicateInterpolation != picture.skipsExactDuplicateInterpolation ||
                oldValue.enhancementStrength != picture.enhancementStrength ||
                oldValue.lowLatency != picture.lowLatency ||
                oldValue.upscaleTarget != picture.upscaleTarget ||
                oldValue.upscaleMethod != picture.upscaleMethod {
                frames.setActiveMultiplier(nil)
            }
            if !applyingPreset && oldValue.colorParameters != picture.colorParameters { selectedColorPreset = nil }
            if !applyingPreset, let current = selectedQualityPreset,
               let preset = Self.qualityPresets.first(where: { $0.name == current }),
               !matchesQualityPreset(preset, settings: picture) {
                selectedQualityPreset = nil
            }
            recorder.setPicture(recordIncludesPicture ? picture : nil)
            // Slider drags fire dozens of times per second; persist once the value settles.
            schedulePicturePersistence()
        }
    }
    @Published private(set) var selectedColorPreset: String? = "自然" {
        didSet { schedulePicturePersistence() }
    }
    /// Quality presets mirror the colour presets: they set a starting combination
    /// once and never lock a control. Editing any covered value shows 自定义.
    @Published private(set) var selectedQualityPreset: String? = "流畅优先" {
        didSet { schedulePicturePersistence() }
    }
    private var supportedInterpolationQualities: [FrameInterpolationMode]
    @Published var recordIncludesPicture = true { didSet { UserDefaults.standard.set(recordIncludesPicture, forKey: "record.picture") } }
    @Published var showsStatusBar = false { didSet { UserDefaults.standard.set(showsStatusBar, forKey: "view.statusBar") } }
    @Published var showsEngineStatus = false { didSet { UserDefaults.standard.set(showsEngineStatus, forKey: "view.engineStatus") } }
    private var applyingPreset = false
    private var picturePersistWork: DispatchWorkItem?
    @Published private(set) var generatedFPS = 0
    @Published private(set) var presentedSourceFPS = 0
    @Published private(set) var presentedOutputFPS = 0
    @Published private(set) var skippedDuplicatePairsPerSecond = 0
    @Published private(set) var detectedContentFPS: Double?
    @Published private(set) var stableContentFPS: Double?
    private var contentFPSStabilityStreak = 0
    private var lastContentMeasurementIdentity: (epoch: UInt64, sequence: UInt64)?
    @Published private(set) var presentationIntervalP95MS = 0.0
    /// Total presented output: source frames plus generated midpoints.
    /// Temporal multiplier the renderer is using for the current content rate, derived with
    /// the same policy the scheduler applies so the panel cannot disagree with the engine.
    var interpolationActivity: (multiplier: Double, basisFPS: Double)? {
        guard picture.enhancementEnabled, picture.frameInterpolation != .off else { return nil }
        return frames.currentInterpolationActivity()
    }
    var activeMultiplier: Double { interpolationActivity?.multiplier ?? 1 }
    /// Short label for the panel, e.g. "2×" or "3×"; 1x means no step is being generated.
    var activeMultiplierLabel: String {
        let value = activeMultiplier
        return value == value.rounded() ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }
    /// Frame rate the current content rate and multiplier aim at.
    var interpolationTargetFPS: Double {
        guard let activity = interpolationActivity else { return 0 }
        return activity.basisFPS * activity.multiplier
    }
    var interpolationBasisFPS: Double? {
        interpolationActivity?.basisFPS
    }
    var outputFPS: Int { presentedOutputFPS }
    @Published private(set) var interpolationStatus = "关闭"
    @Published private(set) var aiUpscaleStatus = ""
    @Published private(set) var interpolationCostMS = 0.0
    @Published private(set) var interpolationBudgetMS = 0.0
    @Published private(set) var interpolationWorkingSize: String?
    @Published private(set) var displayMaximumFPS = 0.0
    @Published private(set) var displayObservedFPS = 0.0
    @Published private(set) var previewRevision: UInt64 = 0
    @Published private(set) var isFittedWindowPreviewActive = false
    @Published private(set) var fittedWindowPreviewMessage: String?
    @Published private(set) var isMacWindowPreviewResizing = false
    lazy var fittedWindowPreview = FittedWindowPreview(capture: self)
    func setFittedPreviewState(_ active: Bool, message: String?) {
        isFittedWindowPreviewActive = active
        fittedWindowPreviewMessage = message
    }
    @MainActor func resizeMacWindowPreview(to size: CGSize, scale: CGFloat) async -> Bool {
        guard sourceKind == .macWindow, !isRecording, !isMacWindowPreviewResizing,
              let source = macWindowCapture else { return false }
        isMacWindowPreviewResizing = true
        defer { isMacWindowPreviewResizing = false }
        let resized = await source.resizeOutput(to: size, scale: scale)
        guard sourceKind == .macWindow, macWindowCapture === source else { return false }
        if resized {
            configuredMacWindowSize = source.configuredPixelSize
            resolution = "\(Int(configuredMacWindowSize.width)) × \(Int(configuredMacWindowSize.height))"
        }
        return resized
    }
    func rebuildPreview() { previewRevision &+= 1 }
    @Published private(set) var deviceName = "未连接"
    @Published private(set) var resolution = "—"
    @Published private(set) var pixelFormat = "—"
    @Published private(set) var measuredFPS = 0
    /// What the stored picture contained at launch, before any normalisation. Published so
    /// a mismatch between the saved setting and the running one can be identified directly.
    private(set) var loadedInterpolationForce: Bool?
    @Published private(set) var renderedFPS = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var processingMilliseconds = 0.0
    @Published private(set) var gpuMilliseconds = 0.0
    @Published private(set) var processingP95 = 0.0
    @Published private(set) var upscaleEngine = "原始"
    /// Actual size the enhancement stage produced for the latest frame; nil when no scaling ran.
    @Published private(set) var enhancedSize: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    private(set) var recordingError: String?
    @Published private(set) var recordingVideoDrops = 0
    @Published private(set) var recordingAudioDrops = 0
    @Published private(set) var statusMessage: String? {
        didSet { statusDismissal?.cancel(); statusDismissal = nil }
    }
    @Published private(set) var permissionDenied = false
    @Published private(set) var cameraPermissionPending = false
    @Published private(set) var audioVolume: Float = 0.8
    @Published private(set) var isMuted = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioStatus = "未连接音频"

    private let sessionQueue = DispatchQueue(label: "dev.moniview.capture", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "dev.moniview.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dev.moniview.audio", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()
    #if MONIVIEW_CAPTURE_TESTING
    // Installed before selecting audio; the fixture counts actual delegate deliveries.
    var audioSampleObserverForTesting: ((CMSampleBuffer) -> Void)?
    #endif
    private let recorder = CaptureRecorder()
    private var statsTimer: DispatchSourceTimer?
    private var displaySleepToken: NSObjectProtocol?
    /// Audio-callback queue only: last time the meter level was published to the UI.
    private var lastLevelPublish = 0.0
    /// Audio-callback queue only: loudest sample since the last publish.
    private var audioLevelPeak: Float = 0
    private var statusDismissal: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    // Session configuration state is accessed only on sessionQueue.
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var selectedDevice: AVCaptureDevice?
    private var requestedFrameRate = 0.0
    private var requestedFormatIndex: Int?
    private var configuredFrameDuration = CMTime.invalid
    private var writtenPixelFormat: OSType?
    private var lastStatsTime = ProcessInfo.processInfo.systemUptime
    private var diagnosticTick = 0
    private var recordingFinished: (() -> Void)?
    private var discoveryRetryCount = 0
    private var discoveryRetryScheduled = false
    private var videoPermissionRequestInFlight = false
    private var isSwitchingVideoDevice = false
    // Main-queue transaction state; prevents follow from reusing the old format ID.
    private var pendingVideoConfiguration: (formatID: Int, frameRate: Double)?
    private var pendingAudioSelection: (id: String?, persist: Bool)?
    // Keep an explicit choice until macOS grants microphone access, including after a
    // denial followed by a visit to System Settings.
    private var pendingAudioPermissionSelection: AudioSelectionIntent?
    private var audioPermissionRequestInFlight = false
    // Requests originate on main; queued work and its result both check this synchronized token.
    // Never hold its lock while configuring a device, starting a session or publishing UI state.
    private let videoConfiguration = ConfigurationRevision()
    private let audioConfiguration = ConfigurationRevision()
    private let macWindowRefreshRevision = ConfigurationRevision()
    private var macWindowCapture: MacWindowCapture?
    /// Set while a Mac-window session owns the preview, so device paths stay inactive.
    private var isMacWindowSourceActive = false
    /// Serializes the preview's owner with the ingest of capture frames. Capture callbacks run on
    /// their own queues, so a frame the previous source already pushed must be refused rather than
    /// written after the switch cleared the mailbox. See PreviewIngestGate.
    private let ingestGate = PreviewIngestGate()
    /// Main-queue mirror of ScreenCaptureKit state; starting alone is not recordable.
    private var macWindowCaptureIsRunning = false
    private var configuredMacWindowSize = CGSize.zero
    private var refreshMacWindowsAfterRecording = false
    #if MONIVIEW_CAPTURE_TESTING
    var windowCaptureStartCountForTesting = 0
    #endif

    init(supportedInterpolationQualities: [FrameInterpolationMode]) {
        self.supportedInterpolationQualities = supportedInterpolationQualities.filter { $0 != .off }
        super.init()
        let savedPreset = UserDefaults.standard.string(forKey: "view.colorPreset")
        if let data = UserDefaults.standard.data(forKey: "view.picture"), let saved = try? JSONDecoder().decode(PictureSettings.self, from: data) {
            // A stored force flag with interpolation off is not a reachable state; it came
            // from an older build. Normalise it here so runtime always matches what the
            // panel shows, whatever the preference cache returned.
            loadedInterpolationForce = saved.interpolationForce
            var loaded = saved
            loaded.normalizeForceFlag()
            if loaded != saved { UserDefaults.standard.set(try? JSONEncoder().encode(loaded), forKey: "view.picture") }
            applyingPreset = true; picture = loaded; applyingPreset = false
            selectedColorPreset = savedPreset == "自定义" ? nil : (savedPreset ?? "自然")
        }
        if UserDefaults.standard.object(forKey: "record.picture") != nil { recordIncludesPicture = UserDefaults.standard.bool(forKey: "record.picture") }
        if UserDefaults.standard.object(forKey: "view.statusBar") != nil { showsStatusBar = UserDefaults.standard.bool(forKey: "view.statusBar") }
        if UserDefaults.standard.object(forKey: "view.engineStatus") != nil { showsEngineStatus = UserDefaults.standard.bool(forKey: "view.engineStatus") }
        if let raw = UserDefaults.standard.string(forKey: "view.aspect"), let saved = AspectMode(rawValue: raw) { aspectMode = saved }
        if UserDefaults.standard.object(forKey: "audio.volume") != nil { audioVolume = UserDefaults.standard.float(forKey: "audio.volume") }
        if let raw = UserDefaults.standard.string(forKey: "source.kind"), let saved = CaptureSourceKind(rawValue: raw) { sourceKind = saved }
        if UserDefaults.standard.object(forKey: "source.windowID") != nil {
            let saved = UInt32(UserDefaults.standard.integer(forKey: "source.windowID"))
            selectedMacWindowID = saved == 0 ? nil : saved
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        audioPreview.volume = audioVolume
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            if self.session.canAddOutput(self.audioOutput) { self.session.addOutput(self.audioOutput) }
            if self.session.canAddOutput(self.audioPreview) { self.session.addOutput(self.audioPreview) }
            self.session.commitConfiguration()
        }
        // The Swift constant names changed in newer SDKs; the notification names are stable.
        for name in [Notification.Name("AVCaptureDeviceWasConnectedNotification"), Notification.Name("AVCaptureDeviceWasDisconnectedNotification")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshDevices(force: false) })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            if self.isRecording { self.stopRecording() }
            self.statusMessage = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "采集发生错误，请重新连接设备。"
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Re-read authorization so granting access in System Settings takes effect without a relaunch.
            self?.refreshDevices(force: false)
        })
        configureInterpolationCapabilities(supportedInterpolationQualities)
        startStatsTimer()
        // Only ask for camera access when the camera-based source is the one in use.
        // A window-source session never touches AVFoundation video input, so prompting
        // for it would block the app behind an unrelated permission.
        if sourceKind == .device { refreshDevices() } else { applySourceKind() }
    }

    deinit {
        statsTimer?.cancel()
        statusDismissal?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private static func devices(_ media: AVMediaType) -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: media == .video ? [.external, .builtInWideAngleCamera] : [.microphone], mediaType: media, position: .unspecified).devices
    }

    /// Automatic selection is for USB capture inputs only. Built-in and wireless
    /// cameras stay available for an explicit selection, even if one was saved before.
    private static func automaticVideoDevice(in videos: [AVCaptureDevice]) -> AVCaptureDevice? {
        let candidates = videos.filter { $0.deviceType == .external && $0.transportType == 0x75736220 }
        let preferredID = UserDefaults.standard.string(forKey: "device.lastVideo")
        return candidates.first { $0.uniqueID == preferredID } ?? candidates.first
    }

    // MARK: - Source selection

    /// Apply the stored source choice. Only one source may own the preview.
    private func applySourceKind() {
        switch sourceKind {
        case .device:
            // Published before any teardown so a capture callback that is already in flight sees
            // the new owner and drops its frame instead of refilling the mailbox this clears.
            beginPreviewInput(owner: .device)
            stopMacWindowCapture()
            selectedVideoID = selectedVideoID ?? Self.automaticVideoDevice(in: Self.devices(.video))?.uniqueID
            selectVideoDevice(id: selectedVideoID)
        case .macWindow:
            cameraPermissionPending = false
            permissionDenied = false
            // Release the device input so the UVC stream and the window stream never
            // compete for the same GPU and frame handoff. Audio is not part of that
            // conflict: it keeps its own input on the same session, so listening and
            // recording audio survive the switch. The session is stopped only when
            // nothing is left for it to run.
            //
            // The window source owns the preview from the moment it is selected. Clearing here
            // rather than only in restartMacWindowCapture() also covers enumeration that fails
            // or returns no window at all: those paths never reach a restart, and the device
            // picture and its pair readout would otherwise stay on screen behind the mask.
            beginPreviewInput(owner: .macWindow)
            frames.setInterpolationState(L10n.text("等待窗口画面"))
            videoConfiguration.advance()
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                if let old = self.videoInput { self.session.removeInput(old); self.videoInput = nil }
                self.selectedDevice = nil
                self.session.commitConfiguration()
                // Video just left, but audio may still be on this session. Stopping it here
                // silenced a selected capture-card audio input for the rest of the session.
                self.reconcileCaptureSessionRunning()
            }
            // This source doesn't enter camera-device discovery, but audio must still refresh.
            refreshAudioDevices()
            refreshMacWindows()
        }
    }

    /// Starts a new preview input: publishes the owner and clears the mailbox with a fresh ingest
    /// token in one critical section, so no capture callback can write between the two and no
    /// frame carrying the previous token can land after the clear. Returns the token the new input
    /// must present. The device path relies on the owner gate instead, because an AVFoundation
    /// frame carries no producer identity to compare against.
    @discardableResult
    private func beginPreviewInput(owner: CaptureSourceKind, blankPreview: Bool = true) -> UInt64 {
        ingestGate.switchOwner(to: owner) { frames.beginInput(blankPreview: blankPreview) }
    }

    func refreshMacWindows() {
        guard sourceKind == .macWindow else { return }
        guard !isRecording else { statusMessage = "停止录制后可更换设备。"; return }
        let revision = macWindowRefreshRevision.advance()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let options = try await MacWindowCapture.availableWindows(excludingBundleID: Bundle.main.bundleIdentifier)
                // Enumeration may outlive a source switch or the start of a recording.
                guard self.macWindowRefreshRevision.isCurrent(revision), self.sourceKind == .macWindow, !self.isRecording else { return }
                self.macWindowOptions = options
                if self.selectedMacWindowID == nil || !options.contains(where: { $0.id == self.selectedMacWindowID }) {
                    let saved = UInt32(UserDefaults.standard.integer(forKey: "source.windowID"))
                    let restored = saved != 0 && options.contains(where: { $0.id == saved }) ? saved : options.first?.id
                    // Assigning triggers restartMacWindowCapture through didSet.
                    self.selectedMacWindowID = restored
                    if restored == nil {
                        // No window to capture: clean up first, then publish why the list is
                        // empty. The stop path clears the pending status, so setting the reason
                        // before it left the user with no explanation at all.
                        self.stopMacWindowCapture()
                        self.macWindowStatus = L10n.text("没有可选择的窗口")
                    } else {
                        self.macWindowStatus = nil
                    }
                } else {
                    self.macWindowStatus = nil
                    self.restartMacWindowCapture()
                }
            } catch {
                guard self.macWindowRefreshRevision.isCurrent(revision), self.sourceKind == .macWindow, !self.isRecording else { return }
                self.macWindowOptions = []
                // Clean up first: the stop path clears the pending status, so publishing the
                // reason before it erased the reason the user needs to see.
                self.stopMacWindowCapture()
                self.macWindowStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func restartMacWindowCapture() {
        fittedWindowPreview.stop()
        guard sourceKind == .macWindow, let windowID = selectedMacWindowID else {
            stopMacWindowCapture()
            return
        }
        macWindowRefreshRevision.advance()
        let capture = macWindowCapture ?? MacWindowCapture(
            frameSink: { [weak self] (sample: CMSampleBuffer, generation: UInt64, source: MacWindowCapture) in
                self?.ingestMacWindowFrame(sample, generation: generation, from: source)
            },
            state: { [weak self] (state: MacWindowCapture.State) in self?.handleMacWindowState(state) },
            dropped: { [weak self] in self?.frames.markDropped() })
        macWindowCapture = capture
        isMacWindowSourceActive = true
        macWindowCaptureIsRunning = false
        configuredMacWindowSize = .zero
        isRunning = false
        // A new window source owns the preview only once it delivers a picture. The token issued
        // here invalidates the stream being replaced, and the clear inside it drops the frame, pair
        // and readout of the previous source, so neither an in-flight frame from the old window nor
        // the old picture itself can follow this switch.
        let ingestToken = beginPreviewInput(owner: .macWindow)
        frames.setInterpolationState(L10n.text("等待窗口画面"))
        // The window stream replaces any device stream in the same preview pipeline.
        #if MONIVIEW_CAPTURE_TESTING
        windowCaptureStartCountForTesting += 1
        #endif
        capture.start(windowID: windowID, ingestToken: ingestToken)
        let option = macWindowOptions.first { $0.id == windowID }
        deviceName = option.map { $0.title.isEmpty ? $0.applicationName : $0.title } ?? L10n.text("Mac 窗口")
        resolution = option.map { "\($0.width) × \($0.height)" } ?? "—"
        pixelFormat = "BGRA"
        formatOptions = []
        selectedFormatID = nil
        frameRateOptions = [0]
        selectedFrameRate = 0
        selectedFPS = 0
    }

    /// Window frames arrive on the ScreenCaptureKit callback queue. The adapter hands over the
    /// token issued for the stream that produced the frame, and the mailbox accepts the frame only
    /// while that token is still the current one. A source switch or a new window issued a newer
    /// token, so an in-flight frame from the previous window is refused inside the mailbox instead
    /// of being stored and retracted after it could already be drawn or paired.
    private func ingestMacWindowFrame(_ sample: CMSampleBuffer, generation: UInt64, from source: MacWindowCapture) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              let token = source.ingestToken(forGeneration: generation) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Same handoff as the capture-device path: the preview keeps only the newest buffer and
        // the recorder receives the original sample buffer.
        guard frames.put(buffer, pts: pts, formatDescription: CMSampleBufferGetFormatDescription(sample),
                         token: token) != nil else { return }
        recorder.append(sample, video: true)
    }

    private func handleMacWindowState(_ state: MacWindowCapture.State) {
        guard sourceKind == .macWindow else { return }
        switch state {
        case .running:
            macWindowCaptureIsRunning = true
            configuredMacWindowSize = macWindowCapture?.configuredPixelSize ?? .zero
            macWindowStatus = nil
            isRunning = true
        case .starting:
            macWindowCaptureIsRunning = false
            configuredMacWindowSize = .zero
            isRunning = false
            macWindowStatus = L10n.text("正在连接窗口…")
        case .noPicture:
            macWindowCaptureIsRunning = false
            configuredMacWindowSize = .zero
            isRunning = false
            frames.setInterpolationState(L10n.text("等待窗口画面"))
            // The stream stays installed so a window that starts presenting later recovers by
            // itself; reconnecting it here would only repeat the same failure. The reason is
            // reported so the waiting mask never hides a source that supplies nothing.
            macWindowStatus = L10n.text("所选窗口没有画面")
        case .failed(let message):
            macWindowCaptureIsRunning = false
            configuredMacWindowSize = .zero
            macWindowStatus = message
            isRunning = false
            // One critical section with the ingest, so a frame the failed stream still had in
            // flight cannot land after this clear.
            ingestGate.switchOwner(to: .macWindow) { frames.clear(blankPreview: true) }
            frames.setInterpolationState(L10n.text("等待窗口画面"))
            // A closed window is expected during normal use; refresh the list instead
            // of leaving a dead preview. Finalize an active file before enumerating again.
            if isRecording {
                refreshMacWindowsAfterRecording = true
                stopRecording()
            } else {
                refreshMacWindows()
            }
        case .stopped, .idle:
            macWindowCaptureIsRunning = false
            configuredMacWindowSize = .zero
            isRunning = false
        }
    }

    private func stopMacWindowCapture() {
        fittedWindowPreview.stop()
        macWindowRefreshRevision.advance()
        macWindowCapture?.stop()
        macWindowCapture = nil
        isMacWindowSourceActive = false
        macWindowCaptureIsRunning = false
        configuredMacWindowSize = .zero
        macWindowStatus = nil
        isRunning = false
        // No window stream is left, so its last picture and pair readout must not stay visible
        // under a mask that says there is nothing to show. A switch to the device source blanks
        // through selectVideoDevice() instead, which owns the preview by then.
        if sourceKind == .macWindow {
            // A fresh token also refuses the frames the stopped stream still has in flight.
            beginPreviewInput(owner: .macWindow)
            frames.setInterpolationState(L10n.text("等待窗口画面"))
        }
    }

    /// Share the recording completion path with the capture-device flow.
    private func startWindowRecording(url: URL, width: Int, height: Int, audio: AudioStreamBasicDescription?) {
        recorder.start(url: url, width: max(2, width & ~1), height: max(2, height & ~1), fps: 60, audio: audio) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                let drops = self.recorder.droppedSamples()
                self.recordingVideoDrops = drops.video; self.recordingAudioDrops = drops.audio
                self.isRecording = false
                self.recordingStartedAt = nil
                self.refreshDevices(force: false)
                let warning = drops.video + drops.audio > 0 ? L10n.format(" · 录制丢弃视频 %d 帧 / 音频 %d 包", drops.video, drops.audio) : ""
                self.recordingError = error?.localizedDescription
                self.statusMessage = error.map { L10n.format("录制失败：%@", $0.localizedDescription) } ?? L10n.format("已保存到 %@%@", url.lastPathComponent, warning)
                if error == nil && drops.video == 0 && drops.audio == 0 {
                    let dismiss = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
                    self.statusDismissal = dismiss
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismiss)
                }
                self.applyPendingAudioSelection()
                let refreshWindows = self.refreshMacWindowsAfterRecording
                self.refreshMacWindowsAfterRecording = false
                if refreshWindows { self.refreshMacWindows() }
                let finished = self.recordingFinished; self.recordingFinished = nil; finished?()
            }
        }
    }

    func refreshDevices(force: Bool = true) {
        // Audio permission and device discovery are independent of camera authorization.
        let audioDisconnected = refreshAudioDevices(checkingRecording: true)
        // Only the device source depends on camera authorization. While a window source
        // is selected this must not report a camera prompt, or the UI waits on a
        // permission the current source never needs.
        guard sourceKind == .device else {
            cameraPermissionPending = false
            permissionDenied = false
            // Audio discovery and restore already ran above this camera-source guard.
            return
        }
        // Discovery does not open a camera. Keep manual choices visible before permission
        // is granted, and ask only when an actual input is selected below.
        let videos = Self.devices(.video)
        videoOptions = videos.map { CaptureInputOption(id: $0.uniqueID, name: $0.localizedName) }
        if Self.automaticVideoDevice(in: videos) != nil { discoveryRetryCount = 0 }
        else if !isRecording && !discoveryRetryScheduled && discoveryRetryCount < 5 {
            // UVC providers can finish initializing after the initial discovery snapshot.
            discoveryRetryCount += 1
            discoveryRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.discoveryRetryScheduled = false
                if self.selectedVideoID == nil && !self.isRecording && !self.permissionDenied { self.refreshDevices(force: false) }
            }
        }
        if isRecording {
            let videoDisconnected = !videos.contains(where: { $0.uniqueID == selectedVideoID })
            if videoDisconnected || audioDisconnected {
                stopRecording()
                statusMessage = videoDisconnected ? "视频设备断开，正在保存录制。" : "音频设备断开，正在保存录制。"
            } else if force { statusMessage = "停止录制后可更换设备。" }
            return
        }
        if let id = selectedVideoID, videos.contains(where: { $0.uniqueID == id }) {
            if force { selectVideoDevice(id: id) }
            return
        }
        // No capture input means no automatic camera fallback, including after unplug.
        selectVideoDevice(id: Self.automaticVideoDevice(in: videos)?.uniqueID)
    }

    func selectVideoDevice(id: String?) {
        guard !isRecording else { statusMessage = "停止录制后可更换设备。"; return }
        guard sourceKind == .device else { return }
        if cameraPermissionPending, selectedVideoID == id,
           AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { return }
        let previouslyPaired = UserDefaults.standard.string(forKey: "audio.selection") == nil || audioOptions.first(where: { $0.id == selectedAudioID })?.name == deviceName
        let previousDeviceID = selectedVideoID
        selectedVideoID = id
        // Invalidate the previous device's format list immediately; its indices are not valid for the new device.
        formatOptions = []
        selectedFormatID = nil
        frameRateOptions = [0]
        selectedFrameRate = 0
        selectedFPS = 0
        isSwitchingVideoDevice = true
        pendingVideoConfiguration = nil
        resetContentRateObservation()
        let generation = videoConfiguration.advance()
        if let id { UserDefaults.standard.set(id, forKey: "device.lastVideo") }
        // The previous device's picture must not stay on screen while the new device has not
        // delivered its first frame; the waiting overlay alone left the stale drawable visible
        // behind a translucent mask.
        beginPreviewInput(owner: .device)
        var device = Self.devices(.video).first { $0.uniqueID == id }
        cameraPermissionPending = false
        permissionDenied = false
        if device != nil {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: break
            case .notDetermined:
                requestSelectedVideoPermission()
                device = nil
            default:
                permissionDenied = true
                device = nil
            }
        }
        // An unauthorized input follows the normal teardown path; the permission
        // completion reselects the current intent, never the original captured ID.
        let authorizedDevice = device
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.videoConfiguration.isCurrent(generation) else { return }
            self.session.beginConfiguration()
            var configurationOpen = true
            do {
                if let device = authorizedDevice {
                    if let old = self.videoInput { self.session.removeInput(old); self.videoInput = nil }
                    self.selectedDevice = nil
                    self.configuredFrameDuration = .invalid
                    self.requestedFormatIndex = nil
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw CaptureFailure.message("无法连接视频设备。") }
                    self.session.addInput(input)
                    self.videoInput = input
                    self.selectedDevice = device
                    let options = Self.formatChoices(for: device)
                    let saved = UserDefaults.standard.dictionary(forKey: "device.format.\(device.uniqueID)")
                    let preferred = options.first { $0.width == saved?["width"] as? Int && $0.height == saved?["height"] as? Int }
                        ?? options.first { $0.width == 1920 && $0.height == 1080 && $0.supportsFPS(60) }
                        ?? options.first { $0.width == 1280 && $0.height == 720 && $0.supportsFPS(60) }
                        ?? options.first
                    let savedFPS = saved?["fps"] as? Double ?? 0
                    let desiredFPS = preferred?.supportsFrameRate(savedFPS) == true ? savedFPS : 0
                    self.requestedFrameRate = desiredFPS
                    self.session.commitConfiguration()
                    configurationOpen = false
                    self.reconcileCaptureSessionRunning()
                    if previousDeviceID != id {
                        // The previous device stops delivering only once this configuration
                        // commits, and the owner is still the device, so a frame already queued
                        // for the old input would pass the ingest check. The queue is drained
                        // here and the mailbox cleared afterwards, so none of those frames can
                        // survive the switch; the blank stays requested until a frame from the
                        // new device arrives.
                        self.videoQueue.sync {}
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.videoConfiguration.isCurrent(generation), self.sourceKind == .device else { return }
                            self.ingestGate.switchOwner(to: .device) { self.frames.clear(blankPreview: true) }
                        }
                    }
                    // The session negotiates its own preset format at commit/start, and a format
                    // set inside a session configuration is reverted. Apply the chosen format
                    // directly to the device afterwards; this is verified to stick on UVC hardware.
                    if let preferred { try self.configureFormat(device, index: preferred.id, fps: desiredFPS) }
                    self.requestedFormatIndex = preferred?.id
                    let dim = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    DispatchQueue.main.async {
                        // A newer switch superseded this one; do not publish stale state.
                        guard self.videoConfiguration.isCurrent(generation) else { return }
                        self.deviceName = device.localizedName
                        self.resolution = "\(dim.width) × \(dim.height)"
                        self.pixelFormat = Self.fourCC(CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription))
                        self.formatOptions = options
                        self.selectedFormatID = preferred?.id
                        self.selectedFPS = Int(desiredFPS.rounded())
                        self.selectedFrameRate = desiredFPS
                        self.frameRateOptions = Self.frameRates(for: device)
                        self.isSwitchingVideoDevice = false
                        self.resetContentRateObservation()
                        self.statusMessage = nil
                        self.autoSelectAudio(for: device, replacePair: previouslyPaired)
                    }
                } else {
                    if let old = self.videoInput { self.session.removeInput(old); self.videoInput = nil }
                    self.selectedDevice = nil
                    self.configuredFrameDuration = .invalid
                    self.requestedFormatIndex = nil
                    self.session.commitConfiguration()
                    // Removing video must not stop an independent audio input.
                    self.reconcileCaptureSessionRunning()
                    DispatchQueue.main.async {
                        guard self.videoConfiguration.isCurrent(generation) else { return }
                        self.deviceName = "未连接"; self.resolution = "—"; self.pixelFormat = "—"
                        self.formatOptions = []; self.selectedFormatID = nil
                        self.frameRateOptions = [0]; self.selectedFrameRate = 0; self.selectedFPS = 0
                        self.isSwitchingVideoDevice = false
                        self.resetContentRateObservation()
                        self.isRunning = false
                    }
                }
            } catch {
                // Roll back to a consistent state: no video input, no stale device identity.
                if !configurationOpen { self.session.beginConfiguration() }
                if let old = self.videoInput { self.session.removeInput(old); self.videoInput = nil }
                self.selectedDevice = nil
                self.configuredFrameDuration = .invalid
                self.requestedFormatIndex = nil
                self.session.commitConfiguration()
                self.reconcileCaptureSessionRunning()
                DispatchQueue.main.async {
                    guard self.videoConfiguration.isCurrent(generation) else { return }
                    self.deviceName = "未连接"; self.resolution = "—"; self.pixelFormat = "—"
                    self.formatOptions = []; self.selectedFormatID = nil
                    self.frameRateOptions = [0]; self.selectedFrameRate = 0; self.selectedFPS = 0
                    self.isSwitchingVideoDevice = false
                    self.resetContentRateObservation()
                    self.isRunning = false
                    self.statusMessage = L10n.format("连接失败：%@", error.localizedDescription)
                }
            }
        }
    }

    /// Reconnect the user's saved audio input when it reappears in either source mode.
    private func restoreSavedAudioIfNeeded(audios: [AVCaptureDevice]) {
        guard !isRecording, let saved = UserDefaults.standard.string(forKey: "audio.selection"), saved != "off" else { return }
        guard selectedAudioID != saved, audios.contains(where: { $0.uniqueID == saved }) else { return }
        selectAudioDevice(id: saved, persist: false)
    }

    /// Refresh audio permissions, devices, saved selections and recording disconnects.
    /// Without it the audio picker stayed stale, a reconnected saved device was ignored,
    /// and unplugging audio mid-recording did not close the file.
    @discardableResult
    private func refreshAudioDevices(checkingRecording: Bool = false) -> Bool {
        let audios = Self.devices(.audio)
        audioOptions = audios.map { CaptureInputOption(id: $0.uniqueID, name: $0.localizedName) }
        if checkingRecording, isRecording {
            let audioDisconnected = selectedAudioID.map { id in
                !audios.contains(where: { $0.uniqueID == id })
            } ?? false
            if audioDisconnected {
                stopRecording()
                statusMessage = "音频设备断开，正在保存录制。"
            }
            return audioDisconnected
        }
        if isRecording { return false }
        if pendingAudioPermissionSelection != nil {
            resumePendingAudioPermissionSelection(audios: audios)
            return false
        }
        if let id = selectedAudioID, !audios.contains(where: { $0.uniqueID == id }) {
            selectAudioDevice(id: nil, persist: false)
            return false
        }
        restoreSavedAudioIfNeeded(audios: audios)
        return false
    }

    private func autoSelectAudio(for device: AVCaptureDevice, replacePair: Bool) {
        // An explicit user choice wins: "off" stays off, a saved device is reselected when present.
        if let saved = UserDefaults.standard.string(forKey: "audio.selection") {
            if saved == "off" { selectAudioDevice(id: nil, persist: false) }
            else if Self.devices(.audio).contains(where: { $0.uniqueID == saved }) { selectAudioDevice(id: saved, persist: false) }
            return
        }
        guard replacePair || selectedAudioID == nil else { return }
        let audios = Self.devices(.audio)
        let matched = audios.first { $0.localizedName == device.localizedName }
            ?? audios.first { $0.transportType == 0x75736220 && ($0.localizedName.localizedCaseInsensitiveContains(device.localizedName) || device.localizedName.localizedCaseInsensitiveContains($0.localizedName)) }
        if let matched { selectAudioDevice(id: matched.uniqueID, persist: false) }
        else { selectAudioDevice(id: nil, persist: false); audioStatus = "未找到采集卡音频，请在设置中选择" }
    }

    /// Only the settings picker persists the choice; internal pairing and cleanup stay implicit.
    func selectAudioDevice(id: String?, persist: Bool = false) {
        guard !isRecording else { statusMessage = "停止录制后可更换音频。"; return }
        selectedAudioID = id
        // Persist only a successfully configured explicit choice; failures must not
        // erase a saved device that is temporarily unplugged.
        guard let id else {
            pendingAudioPermissionSelection = nil
            configureAudioInput(id: nil, persist: persist)
            return
        }
        let intent = AudioSelectionIntent(id: id, persist: persist)
        switch audioAuthorizationState() {
        case .authorized:
            pendingAudioPermissionSelection = nil
            configureAudioInput(id: id, persist: persist)
        case .notDetermined, .denied:
            pendingAudioPermissionSelection = intent
            resumePendingAudioPermissionSelection()
        }
    }

    private func audioAuthorizationState() -> AudioAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private func resumePendingAudioPermissionSelection(
        authorization: AudioAuthorizationState? = nil,
        audios: [AVCaptureDevice]? = nil
    ) {
        guard let pending = pendingAudioPermissionSelection else { return }
        let state = authorization ?? audioAuthorizationState()
        switch state {
        case .notDetermined:
            audioStatus = "等待麦克风权限"
            guard AudioPermissionPolicy.shouldRequestAccess(for: state, requestInFlight: audioPermissionRequestInFlight) else { return }
            audioPermissionRequestInFlight = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.audioPermissionRequestInFlight = false
                    guard let current = self.pendingAudioPermissionSelection,
                          current.id == self.selectedAudioID else { return }
                    if granted {
                        self.resumePendingAudioPermissionSelection(authorization: .authorized)
                    } else {
                        self.audioStatus = "需要麦克风权限"
                        self.statusMessage = "请在系统设置 › 隐私与安全性 › 麦克风中允许 MoniView。"
                    }
                }
            }
        case .denied:
            audioStatus = "需要麦克风权限"
            statusMessage = "请在系统设置中允许 MoniView 访问麦克风，才能播放采集卡声音。"
        case .authorized:
            let available = audios ?? Self.devices(.audio)
            let restorable = AudioPermissionPolicy.restorableSelection(
                pending: pending,
                selectedID: selectedAudioID,
                authorization: state,
                deviceAvailable: available.contains { $0.uniqueID == pending.id }
            )
            guard let restorable else { return }
            pendingAudioPermissionSelection = nil
            if isRecording { pendingAudioSelection = (restorable.id, restorable.persist) }
            else { configureAudioInput(id: restorable.id, persist: restorable.persist) }
        }
    }

    private func configureAudioInput(id: String?, persist: Bool = false) {
        guard !isRecording else { pendingAudioSelection = (id, persist); return }
        let device = Self.devices(.audio).first { $0.uniqueID == id }
        let revision = audioConfiguration.advance()
        sessionQueue.async { [weak self] in
            guard let self, self.audioConfiguration.isCurrent(revision) else { return }
            // Inspect the installed input only on sessionQueue. Repeated refreshes and
            // permission callbacks need no new transaction when the actual device matches.
            let actualInput = self.session.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.audio) }
            self.audioInput = actualInput
            if !CaptureSessionPolicy.audioInputNeedsConfiguration(
                actualID: actualInput?.device.uniqueID,
                requestedID: id
            ) {
                self.reconcileCaptureSessionRunning()
                DispatchQueue.main.async {
                    guard self.audioConfiguration.isCurrent(revision) else { return }
                    if persist { UserDefaults.standard.set(id ?? "off", forKey: "audio.selection") }
                    self.audioStatus = id == nil ? "未连接音频" : "实时监听中"
                    if id == nil { self.audioLevel = 0 }
                    self.statusMessage = nil
                }
                return
            }
            let previousInput = actualInput
            self.session.beginConfiguration()
            var configurationOpen = true
            do {
                guard id == nil || device != nil else { throw CaptureFailure.message("无法连接音频输入。") }
                if let old = self.audioInput { self.session.removeInput(old); self.audioInput = nil }
                if let device {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw CaptureFailure.message("无法连接音频输入。") }
                    self.session.addInput(input); self.audioInput = input
                }
                self.session.commitConfiguration()
                configurationOpen = false
                // Window mode has no video input to start the session, and audio must not go
                // silent just because the preview comes from a window. Starting an idle session
                // is what makes listening and audio recording work there; the mirror case stops
                // a running session that no longer owns any input.
                self.reconcileCaptureSessionRunning()
                // Adding an audio input may renegotiate video. Reassert the requested format
                // directly; a session commit would revert it to the preset choice.
                if let video = self.selectedDevice {
                    let index = self.requestedFormatIndex ?? video.formats.firstIndex(of: video.activeFormat) ?? 0
                    try self.configureFormat(video, index: index, fps: self.requestedFrameRate)
                }
                DispatchQueue.main.async {
                    guard self.audioConfiguration.isCurrent(revision) else { return }
                    if persist { UserDefaults.standard.set(id ?? "off", forKey: "audio.selection") }
                    self.audioStatus = device == nil ? "未连接音频" : "实时监听中"
                    if device == nil { self.audioLevel = 0 }
                    self.statusMessage = nil
                }
            } catch {
                // Keep the UI, preference and actual session aligned if adding an input
                // or restoring the video format fails. Only the newest request publishes.
                if !configurationOpen { self.session.beginConfiguration() }
                if let current = self.audioInput { self.session.removeInput(current); self.audioInput = nil }
                if let previousInput, self.session.canAddInput(previousInput) {
                    self.session.addInput(previousInput)
                    self.audioInput = previousInput
                }
                self.session.commitConfiguration()
                // Restoring inputs must restore their running state as well.
                self.reconcileCaptureSessionRunning()
                if let video = self.selectedDevice, let index = self.requestedFormatIndex {
                    try? self.configureFormat(video, index: index, fps: self.requestedFrameRate)
                }
                self.configureConnectionTiming()
                let restoredID = self.audioInput?.device.uniqueID
                DispatchQueue.main.async {
                    guard self.audioConfiguration.isCurrent(revision) else { return }
                    self.selectedAudioID = restoredID
                    self.audioStatus = restoredID == nil ? "未连接音频" : "实时监听中"
                    if restoredID == nil { self.audioLevel = 0 }
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    /// Called only on sessionQueue, after committing a configuration.
    private func reconcileCaptureSessionRunning() {
        switch CaptureSessionPolicy.action(isRunning: session.isRunning, inputCount: session.inputs.count) {
        case .start: session.startRunning()
        case .stop: session.stopRunning()
        case nil: break
        }
    }

    /// Called on the main queue by both recording completion paths.
    private func applyPendingAudioSelection() {
        guard let pending = pendingAudioSelection else { return }
        pendingAudioSelection = nil
        selectedAudioID = pending.id
        configureAudioInput(id: pending.id, persist: pending.persist)
    }

    func setAudioVolume(_ volume: Float) {
        audioVolume = min(1, max(0, volume))
        UserDefaults.standard.set(audioVolume, forKey: "audio.volume")
        updateAudioVolume()
    }
    func setMuted(_ muted: Bool) { isMuted = muted; updateAudioVolume() }
    private func updateAudioVolume() {
        let volume = isMuted ? 0 : audioVolume
        sessionQueue.async { [weak self] in self?.audioPreview.volume = volume }
    }

    func selectFormat(id: Int?) {
        guard !isRecording else { statusMessage = "停止录制后可更改格式。"; return }
        guard let id else { return }
        let option = formatOptions.first { $0.id == id }
        let currentRate = pendingVideoConfiguration?.frameRate ?? selectedFrameRate
        applyFormat(index: id, fps: option?.supportsFrameRate(currentRate) == true ? currentRate : 0)
    }
    /// One interpolation basis switch; capture sampling remains an independent choice.
    var followsRealContentRate: Bool { picture.skipsExactDuplicateInterpolation }
    func selectFrameRate(_ fps: Int) { selectFrameRateValue(Double(fps)) }
    func selectFrameRateValue(_ fps: Double) {
        guard !isRecording else { statusMessage = "停止录制后可更改帧率。"; return }
        guard let formatID = pendingVideoConfiguration?.formatID ?? selectedFormatID else { return }
        applyFormat(index: formatID, fps: fps)
    }
    private func applyFormat(index: Int, fps: Double) {
        pendingVideoConfiguration = (index, fps)
        resetContentRateObservation()
        let generation = videoConfiguration.advance()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.videoConfiguration.isCurrent(generation) else { return }
            guard let device = self.selectedDevice else {
                DispatchQueue.main.async {
                    guard self.videoConfiguration.isCurrent(generation) else { return }
                    self.pendingVideoConfiguration = nil
                }
                return
            }
            do {
                // Direct device configuration only: committing the session here reverts
                // activeFormat to the preset choice on the current capture stack.
                try self.configureFormat(device, index: index, fps: fps)
                self.requestedFrameRate = fps
                self.requestedFormatIndex = index
                self.publishFormat(device: device, index: index, fps: fps, generation: generation)
            } catch {
                DispatchQueue.main.async {
                    guard self.videoConfiguration.isCurrent(generation) else { return }
                    self.pendingVideoConfiguration = nil
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func publishFormat(device: AVCaptureDevice, index: Int, fps: Double, generation: UInt64) {
        let format = device.activeFormat
        let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let options = Self.frameRates(for: device)
        let pixel = Self.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        UserDefaults.standard.set(["width": Int(dim.width), "height": Int(dim.height), "fps": fps], forKey: "device.format.\(device.uniqueID)")
        DispatchQueue.main.async {
            // Ignore a result that a newer switch already superseded.
            guard self.videoConfiguration.isCurrent(generation) else { return }
            self.selectedFormatID = self.formatOptions.first { $0.width == Int(dim.width) && $0.height == Int(dim.height) }?.id ?? index
            self.selectedFPS = Int(fps.rounded()); self.selectedFrameRate = fps
            self.frameRateOptions = options
            self.resolution = "\(dim.width) × \(dim.height)"; self.pixelFormat = pixel; self.statusMessage = nil
            self.pendingVideoConfiguration = nil
            self.resetContentRateObservation()
        }
    }

    private func resetContentRateObservation() {
        detectedContentFPS = nil
        stableContentFPS = nil
        contentFPSStabilityStreak = 0
        lastContentMeasurementIdentity = nil
    }
    private static func frameRates(for format: AVCaptureDevice.Format) -> [Double] {
        var values = Set<Double>()
        for range in format.videoSupportedFrameRateRanges {
            if abs(range.minFrameRate - range.maxFrameRate) < 0.01 {
                values.insert((range.maxFrameRate * 100).rounded() / 100)
            } else {
                for value in [20.0, 24, 25, 29.97, 30, 40, 45, 48, 50, 59.94, 60, 90, 100, 120, 144, range.minFrameRate, range.maxFrameRate] where value >= range.minFrameRate && value <= range.maxFrameRate {
                    values.insert((value * 100).rounded() / 100)
                }
            }
        }
        return [0] + values.sorted()
    }

    private static func frameRates(for device: AVCaptureDevice) -> [Double] {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let values = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == dimensions.width && size.height == dimensions.height
        }.flatMap { frameRates(for: $0) }
        return Set(values).sorted()
    }

    private func configureFormat(_ device: AVCaptureDevice, index: Int, fps: Double) throws {
        guard device.formats.indices.contains(index) else { throw CaptureFailure.message("格式已失效，请刷新设备。") }
        let selected = device.formats[index]
        let size = CMVideoFormatDescriptionGetDimensions(selected.formatDescription)
        let compatible = device.formats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == size.width && dims.height == size.height
        }
        let matches: (AVCaptureDevice.Format) -> Bool = { format in
            fps == 0 || format.videoSupportedFrameRateRanges.contains { $0.minFrameRate - 0.01 <= fps && $0.maxFrameRate + 0.01 >= fps }
        }
        let format = matches(selected) ? selected : compatible.first(where: matches) ?? selected
        let ranges = format.videoSupportedFrameRateRanges
        let target = fps == 0 ? (ranges.map(\.maxFrameRate).max() ?? 30) : fps
        guard let range = ranges.first(where: { $0.minFrameRate - 0.01 <= target && $0.maxFrameRate + 0.01 >= target })
            ?? (fps == 0 ? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) : nil) else {
            throw CaptureFailure.message(L10n.format("这个分辨率不支持 %.2f FPS，请选择其他格式。", fps))
        }
        // UVC rates are often 60.00024 / 30.00003, not exact integers. Use the advertised duration.
        let duration: CMTime
        if abs(range.maxFrameRate - target) < 0.01 { duration = range.minFrameDuration }
        else if abs(range.minFrameRate - target) < 0.01 { duration = range.maxFrameDuration }
        else { duration = CMTime(seconds: 1 / target, preferredTimescale: 1_000_000) }
        let supported = videoOutput.availableVideoPixelFormatTypes
        let preferences: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs]
        guard let outputType = preferences.first(where: { supported.contains($0) }) else {
            throw CaptureFailure.message("设备没有提供可用于预览的像素格式。")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Writing videoSettings renegotiates the session and reverts activeFormat on
        // current macOS, so only touch it when the pixel format actually changes, and
        // always before selecting the device format. Request only the pixel format:
        // explicit dimensions would force a scaling/conversion pass.
        if writtenPixelFormat != outputType {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: outputType]
            writtenPixelFormat = outputType
        }
        // Setting connection frame durations also renegotiates and reverts activeFormat
        // (verified on UVC hardware), so it happens here, only on change, and always
        // before the device format is selected.
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMinFrameDurationSupported, CMTimeCompare(connection.videoMinFrameDuration, duration) != 0 { connection.videoMinFrameDuration = duration }
            if connection.isVideoMaxFrameDurationSupported, CMTimeCompare(connection.videoMaxFrameDuration, duration) != 0 { connection.videoMaxFrameDuration = duration }
        }
        device.activeFormat = format
        // Output negotiation may reset the device's interval. Apply timing afterwards.
        try Self.setDuration(duration, on: device)
        // Drivers may change their output list after a new device format. Re-negotiate
        // only when necessary, with a bounded retry, then reassert format and timing.
        for _ in 0..<2 {
            let finalTypes = videoOutput.availableVideoPixelFormatTypes
            if let writtenPixelFormat, finalTypes.contains(writtenPixelFormat) { break }
            guard let replacement = preferences.first(where: { finalTypes.contains($0) }) else {
                throw CaptureFailure.message("设备没有提供可用于预览的像素格式。")
            }
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: replacement]
            writtenPixelFormat = replacement
            device.activeFormat = format
            try Self.setDuration(duration, on: device)
        }
        guard let writtenPixelFormat, videoOutput.availableVideoPixelFormatTypes.contains(writtenPixelFormat) else {
            throw CaptureFailure.message("设备没有提供可用于预览的像素格式。")
        }
        configuredFrameDuration = duration
    }

    private func configureConnectionTiming() {
        guard let device = selectedDevice, let connection = videoOutput.connection(with: .video) else { return }
        let duration = configuredFrameDuration.isValid ? configuredFrameDuration : device.activeVideoMinFrameDuration
        let format = device.activeFormat
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if connection.isVideoMinFrameDurationSupported, CMTimeCompare(connection.videoMinFrameDuration, duration) != 0 { connection.videoMinFrameDuration = duration }
            if connection.isVideoMaxFrameDurationSupported, CMTimeCompare(connection.videoMaxFrameDuration, duration) != 0 { connection.videoMaxFrameDuration = duration }
            device.activeFormat = format
            try Self.setDuration(duration, on: device)
        } catch {
            DispatchQueue.main.async { self.statusMessage = error.localizedDescription }
        }
    }

    private static func setDuration(_ duration: CMTime, on device: AVCaptureDevice) throws {
        let seconds = duration.seconds
        guard duration.isValid, seconds.isFinite, seconds > 0,
              device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                  seconds >= $0.minFrameDuration.seconds - 0.0000001 && seconds <= $0.maxFrameDuration.seconds + 0.0000001
              }) else { throw CaptureFailure.message("格式已失效，请刷新设备。") }
        if duration < device.activeVideoMinFrameDuration {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } else {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        }
    }

    func applyPreset(_ name: String) {
        applyingPreset = true
        defer { applyingPreset = false }
        var next = picture
        switch name {
        case "鲜艳": next.brightness = 0; next.contrast = 1.025; next.saturation = 1.07; next.vibrance = 0.08; next.highlightRecovery = 0.08
        case "电影": next.brightness = 0; next.contrast = 1.0; next.saturation = 0.96; next.vibrance = 0; next.highlightRecovery = 0.16
        default: next.brightness = 0; next.contrast = 1; next.saturation = 1; next.vibrance = 0; next.highlightRecovery = 0
        }
        picture = next
        selectedColorPreset = name
    }

    /// Quality presets cover the enhancement/interpolation choices a user actually
    /// tunes. They set a starting combination; every control stays editable, and a
    /// manual change switches the label to 自定义 exactly like the colour presets.
    struct QualityPreset {
        let name: String
        let lowLatency: Bool
        let enhancementStrength: Double
        let upscaleMethod: UpscaleMethod
        let upscaleTarget: UpscaleTarget
        let interpolation: FrameInterpolationMode
        var nativeFrameRate = false

        func apply(to settings: inout PictureSettings, supported: [FrameInterpolationMode]) {
            settings.lowLatency = lowLatency
            settings.enhancementStrength = enhancementStrength
            settings.upscaleMethod = upscaleMethod
            settings.upscaleTarget = upscaleTarget
            settings.enhancementEnabled = true
            if nativeFrameRate {
                settings.setInterpolationEnabled(false)
            } else {
                let resolved = FrameInterpolationMode.availableQuality(interpolation, supported: supported)
                settings.preferredInterpolationQuality = resolved
                settings.frameInterpolation = resolved
                settings.forceFrameInterpolation = resolved != .off
                settings.skipsExactDuplicateInterpolation = true
            }
        }
    }

    /// Selecting a preset applies a complete, predictable processing configuration.
    /// Subsequent manual edits remain available and change the preset label to custom.
    static let qualityPresets: [QualityPreset] = [
        // Source-sized flow avoids display-size scaling work. Throughput remains
        // dependent on the source cadence, GPU load and presentation deadlines.
        QualityPreset(name: "流畅优先", lowLatency: true, enhancementStrength: 0.55,
                      upscaleMethod: .metalFX, upscaleTarget: .native, interpolation: .flowBlend),
        // Display-sized: midpoints and endpoints scale up to the window. Sharper, and it
        // costs more, so the target rate may not hold on a busy GPU.
        QualityPreset(name: "画质优先", lowLatency: true, enhancementStrength: 0.80,
                      upscaleMethod: .metalFX, upscaleTarget: .screen, interpolation: .quality),
        QualityPreset(name: "原生增强", lowLatency: false, enhancementStrength: 1.00,
                      upscaleMethod: .metalFX, upscaleTarget: .screen, interpolation: .flowBlend, nativeFrameRate: true)
    ]

    func applyQualityPreset(_ name: String) {
        guard let preset = Self.qualityPresets.first(where: { $0.name == name }) ?? Self.qualityPresets.first else { return }
        applyingPreset = true
        defer { applyingPreset = false }
        var next = picture
        preset.apply(to: &next, supported: supportedInterpolationQualities)
        picture = next
        selectedQualityPreset = preset.name
    }

    /// UI supplies actual platform capabilities for load, presets and switch recovery.
    func configureInterpolationCapabilities(_ supported: [FrameInterpolationMode]) {
        supportedInterpolationQualities = supported.filter { $0 != .off }
        var next = picture
        let wasEnabled = next.frameInterpolation != .off
        let preferred = next.preferredInterpolationQuality ?? (wasEnabled ? next.frameInterpolation : .flowBlend)
        let resolved = FrameInterpolationMode.availableQuality(preferred, supported: supportedInterpolationQualities)
        next.preferredInterpolationQuality = resolved
        next.frameInterpolation = wasEnabled ? resolved : .off
        next.normalizeForceFlag()
        picture = next
        selectedQualityPreset = Self.qualityPresets.first { matchesQualityPreset($0, settings: next) }?.name
    }

    private func matchesQualityPreset(_ preset: QualityPreset, settings: PictureSettings) -> Bool {
        guard settings.lowLatency == preset.lowLatency,
              settings.enhancementStrength == preset.enhancementStrength,
              settings.upscaleMethod == preset.upscaleMethod,
              settings.upscaleTarget == preset.upscaleTarget else { return false }
        if preset.nativeFrameRate {
            return settings.enhancementEnabled && settings.frameInterpolation == .off
        }
        let resolved = FrameInterpolationMode.availableQuality(preset.interpolation, supported: supportedInterpolationQualities)
        return settings.enhancementEnabled && settings.frameInterpolation == resolved &&
            settings.preferredInterpolationQuality == resolved &&
            settings.forceFrameInterpolation == (resolved != .off) && settings.skipsExactDuplicateInterpolation
    }

    func startRecording(to url: URL) {
        guard !isRecording, !isFittedWindowPreviewActive, !isMacWindowPreviewResizing else { return }
        let windowSize = configuredMacWindowSize
        if sourceKind == .macWindow {
            guard CaptureSessionPolicy.canRecordWindowCapture(
                isRunning: macWindowCaptureIsRunning,
                width: Int(windowSize.width),
                height: Int(windowSize.height)
            ) else { return }
        } else {
            guard isRunning else { return }
        }
        isRecording = true
        recordingStartedAt = Date()
        recordingError = nil
        recordingVideoDrops = 0; recordingAudioDrops = 0
        statusMessage = "正在录制…"
        recorder.setPicture(recordIncludesPicture ? picture : nil)
        if sourceKind == .macWindow {
            // The size is valid only after ScreenCaptureKit has reported .running.
            // Never manufacture recording dimensions while its stream is still starting.
            macWindowRefreshRevision.advance()
            // Session mutations and the audio format snapshot share a queue. A just-selected
            // audio input must finish configuring before the recording's tracks are created.
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let audioDesc = self.audioInput?.device.activeFormat.formatDescription
                let asbd = audioDesc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                self.startWindowRecording(url: url, width: Int(windowSize.width), height: Int(windowSize.height), audio: asbd)
            }
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let video = self.selectedDevice else {
                DispatchQueue.main.async {
                    self.isRecording = false; self.recordingStartedAt = nil; self.recordingError = L10n.text("视频设备已断开。")
                    self.statusMessage = L10n.format("录制失败：%@", self.recordingError!)
                    self.applyPendingAudioSelection()
                    let finished = self.recordingFinished; self.recordingFinished = nil; finished?()
                }
                return
            }
            let dims = CMVideoFormatDescriptionGetDimensions(video.activeFormat.formatDescription)
            let audioDesc = self.audioInput?.device.activeFormat.formatDescription
            let asbd = audioDesc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let frameInterval = video.activeVideoMinFrameDuration.seconds
            // Devices without a valid frame duration would otherwise trap on Int(NaN).
            let recordingFPS = frameInterval.isFinite && frameInterval > 0 ? 1 / frameInterval : 60
            self.recorder.start(url: url, width: Int(dims.width), height: Int(dims.height), fps: recordingFPS, audio: asbd) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let drops = self.recorder.droppedSamples()
                    self.recordingVideoDrops = drops.video; self.recordingAudioDrops = drops.audio
                    self.isRecording = false
                    self.recordingStartedAt = nil
                    self.refreshDevices(force: false)
                    let warning = drops.video + drops.audio > 0 ? L10n.format(" · 录制丢弃视频 %d 帧 / 音频 %d 包", drops.video, drops.audio) : ""
                    self.recordingError = error?.localizedDescription
                    self.statusMessage = error.map { L10n.format("录制失败：%@", $0.localizedDescription) } ?? L10n.format("已保存到 %@%@", url.lastPathComponent, warning)
                    if error == nil && drops.video == 0 && drops.audio == 0 {
                        let dismiss = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
                        self.statusDismissal = dismiss
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismiss)
                    }
                    // Apply an audio device change that was deferred to avoid reconfiguring a live recording.
                    self.applyPendingAudioSelection()
                    let finished = self.recordingFinished; self.recordingFinished = nil; finished?()
                }
            }
        }
    }
    func stopRecording() { sessionQueue.async { [weak self] in self?.recorder.stop() } }

    /// AppKit delays process termination until MOV finalization completes.
    func finishRecordingBeforeExit(_ completion: @escaping () -> Void) {
        guard isRecording else { completion(); return }
        recordingFinished = completion
        stopRecording()
    }

    /// Stores a device frame only while the device still owns the preview. The ownership check and
    /// the write are one critical section with the switch that publishes the new owner and clears
    /// the mailbox, so a frame from a card that lost the preview is refused instead of being
    /// stored first and retracted after a draw could already have used it.
    @discardableResult
    func ingestDeviceFrame(_ sampleBuffer: CMSampleBuffer, buffer: CVPixelBuffer) -> Bool {
        ingestGate.run(forOwner: .device) {
            _ = frames.put(buffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                           formatDescription: CMSampleBufferGetFormatDescription(sampleBuffer))
            recorder.append(sampleBuffer, video: true)
            return true
        } ?? false
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            ingestDeviceFrame(sampleBuffer, buffer: buffer)
        } else if output === audioOutput {
            #if MONIVIEW_CAPTURE_TESTING
            audioSampleObserverForTesting?(sampleBuffer)
            #endif
            let power = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
            let level = power <= -80 ? 0 : min(1, pow(10, power / 20))
            frames.setLevel(level)
            audioLevelPeak = max(audioLevelPeak, level)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLevelPublish >= 0.12 {
                lastLevelPublish = now
                let peak = audioLevelPeak
                audioLevelPeak = 0
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Instant attack, gentle decay so the meter reads like a real level meter.
                    self.audioLevel = max(peak, self.audioLevel * 0.75)
                }
            }
            recorder.append(sampleBuffer, video: false)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { frames.markDropped() }

    private func requestSelectedVideoPermission() {
        cameraPermissionPending = true
        guard !videoPermissionRequestInFlight else { return }
        videoPermissionRequestInFlight = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.videoPermissionRequestInFlight = false
                self.cameraPermissionPending = false
                // The source, selection or device may have changed while the prompt was open.
                guard self.sourceKind == .device, let id = self.selectedVideoID,
                      Self.devices(.video).contains(where: { $0.uniqueID == id }) else { return }
                self.permissionDenied = !granted
                if granted { self.selectVideoDevice(id: id) }
            }
        }
    }
    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.recorder.checkFailure()
            if self.isRecording {
                let drops = self.recorder.droppedSamples()
                self.recordingVideoDrops = drops.video; self.recordingAudioDrops = drops.audio
                if drops.video > 5 || drops.audio > 0 {
                    self.statusMessage = L10n.format("录制过载：视频丢帧 %d / 音频丢包 %d，可降低录制分辨率或关闭增强。", drops.video, drops.audio)
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - self.lastStatsTime
            self.lastStatsTime = now
            let stats = self.frames.statistics()
            self.measuredFPS = Int((Double(stats.0) / elapsed).rounded())
            self.renderedFPS = Int((Double(stats.1) / elapsed).rounded())
            let presentationStats = self.frames.presentationStatistics()
            self.generatedFPS = Int((Double(presentationStats.generated) / elapsed).rounded())
            self.presentedSourceFPS = Int((Double(presentationStats.presentedSource) / elapsed).rounded())
            self.presentedOutputFPS = Int((Double(presentationStats.presentedSource + presentationStats.generated) / elapsed).rounded())
            self.skippedDuplicatePairsPerSecond = Int((Double(self.frames.takeDuplicateSkips()) / elapsed).rounded())
            // Measure every input frame, independently of preview load. Unknown or stale
            // results are not reused as evidence for capture or interpolation decisions.
            let inputMeasurement = self.frames.inputContentCadenceSnapshot()
            let detectedContentFPS = ContentCadencePolicy.boundedObservedRate(
                inputMeasurement?.fps, signalFPS: self.frames.sourceFrameRate())
            let isNewMeasurement: Bool
            if let epoch = inputMeasurement?.streamEpoch, let sequence = inputMeasurement?.sequence {
                isNewMeasurement = self.lastContentMeasurementIdentity.map {
                    $0.epoch != epoch || $0.sequence != sequence
                } ?? true
                self.lastContentMeasurementIdentity = (epoch, sequence)
            } else {
                isNewMeasurement = false
            }
            // Only a fresh measurement advances the streak. Re-feeding the held value every
            // second let an old result accumulate "stability" with no new evidence, which
            // then justified switching the capture rate on stale information.
            if detectedContentFPS != nil && isNewMeasurement {
                self.contentFPSStabilityStreak = ContentCadencePolicy.nextStabilityStreak(
                    previous: self.detectedContentFPS, current: detectedContentFPS, streak: self.contentFPSStabilityStreak)
            } else {
                self.contentFPSStabilityStreak = 0
            }
            self.detectedContentFPS = detectedContentFPS
            self.stableContentFPS = ContentCadencePolicy.stableRate(detectedContentFPS, streak: self.contentFPSStabilityStreak)
            if let (buffer, _, _) = self.frames.latest() {
                self.isPortraitSource = CVPixelBufferGetHeight(buffer) > CVPixelBufferGetWidth(buffer)
            }
            self.presentationIntervalP95MS = self.frames.presentationP95()
            self.interpolationStatus = self.frames.currentPreviewState() == "hidden" ? "预览不可见，暂停呈现" : self.frames.currentInterpolationState()
            let interpolationCost = self.frames.interpolationCost()
            self.interpolationCostMS = interpolationCost.0; self.interpolationBudgetMS = interpolationCost.1
            self.interpolationWorkingSize = self.frames.currentInterpolationWorkingSize()
            let displayRates = self.frames.currentDisplayRates()
            self.displayMaximumFPS = displayRates.maximum; self.displayObservedFPS = displayRates.observed
            self.droppedFrames = stats.2
            let times = self.frames.processingTimes()
            self.processingMilliseconds = times.0
            self.gpuMilliseconds = times.1
            self.processingP95 = times.2
            self.upscaleEngine = self.frames.currentEngine()
            self.aiUpscaleStatus = self.frames.currentAIUpscaleStatus()
            self.enhancedSize = self.frames.currentEnhancedSize()
            self.isRunning = self.sourceKind == .macWindow
                ? self.macWindowCaptureIsRunning
                : stats.0 > 0
            self.updatePowerAssertions()
            self.diagnosticTick += 1
            if self.diagnosticTick % 5 == 0, self.isRunning || self.isRecording { self.writeDiagnostics() }
        }
        timer.resume(); statsTimer = timer
    }
    private func schedulePicturePersistence() {
        picturePersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPicturePersistence() }
        picturePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Persist parameters and the preset name together so a quick quit never splits them.
    func flushPicturePersistence() {
        picturePersistWork?.cancel()
        picturePersistWork = nil
        if let data = try? JSONEncoder().encode(picture) { UserDefaults.standard.set(data, forKey: "view.picture") }
        UserDefaults.standard.set(selectedColorPreset ?? "自定义", forKey: "view.colorPreset")
    }

    /// Game and camera monitoring runs for long stretches without keyboard or mouse input;
    /// keep the display awake while a signal is being previewed.
    private func updatePowerAssertions() {
        if isRunning && displaySleepToken == nil {
            displaySleepToken = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Live capture preview")
        } else if !isRunning, let token = displaySleepToken {
            ProcessInfo.processInfo.endActivity(token)
            displaySleepToken = nil
        }
    }
    private func writeDiagnostics() {
        var payload: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "device": deviceName, "resolution": resolution, "captureFPS": measuredFPS, "renderFPS": renderedFPS, "droppedFrames": droppedFrames, "pixelFormat": pixelFormat, "audioDevice": audioOptions.first { $0.id == selectedAudioID }?.name ?? "none", "audioLevel": audioLevel, "audioStatus": audioStatus, "muted": isMuted, "volume": audioVolume]
        if let (buffer, description) = frames.latestFormatSnapshot() {
            payload["bufferWidth"] = CVPixelBufferGetWidth(buffer)
            payload["bufferHeight"] = CVPixelBufferGetHeight(buffer)
            payload["bufferPixelFormat"] = Self.fourCC(CVPixelBufferGetPixelFormatType(buffer))
            for (key, name) in [(kCVImageBufferYCbCrMatrixKey, "inputYCbCrMatrix"),
                                (kCVImageBufferColorPrimariesKey, "inputColorPrimaries"),
                                (kCVImageBufferTransferFunctionKey, "inputTransferFunction"),
                                (kCVImageBufferChromaLocationTopFieldKey, "inputChromaLocationTop"),
                                (kCVImageBufferChromaLocationBottomFieldKey, "inputChromaLocationBottom")] {
                if let attachment = CVBufferCopyAttachment(buffer, key, nil) { payload[name] = String(describing: attachment) }
                if let description, let value = CMFormatDescriptionGetExtension(description, extensionKey: key) {
                    payload["format" + name.dropFirst(5)] = String(describing: value)
                }
            }
        }
        payload["softwareProcessingMS"] = processingMilliseconds
        payload["softwareP95MS"] = processingP95
        payload["gpuMS"] = gpuMilliseconds
        payload["lowLatency"] = picture.lowLatency
        payload["previewState"] = frames.currentPreviewState()
        payload["interpolationMode"] = picture.frameInterpolation.rawValue
        payload["interpolationForce"] = picture.forceFrameInterpolation
        payload["loadedInterpolationForce"] = loadedInterpolationForce as Any? ?? NSNull()
        payload["interpolationSkipDuplicates"] = picture.skipsExactDuplicateInterpolation
        payload["skippedDuplicatePairsPerSecond"] = skippedDuplicatePairsPerSecond
        payload["followsRealContentRate"] = followsRealContentRate
        payload["selectedFrameRate"] = selectedFrameRate
        payload["frameRateOptions"] = frameRateOptions
        payload["videoFormatChangeInProgress"] = isSwitchingVideoDevice || pendingVideoConfiguration != nil
        payload["detectedContentFPS"] = detectedContentFPS as Any? ?? NSNull()
        payload["stableContentFPS"] = stableContentFPS as Any? ?? NSNull()
        payload["presentationIntervalP95MS"] = presentationIntervalP95MS
        payload["interpolationStatus"] = interpolationStatus
        payload["interpolationMidpointGPUMs"] = frames.currentInterpolationGPUCost()
        payload["interpolationBasisFPS"] = interpolationBasisFPS as Any? ?? NSNull()
        payload["enhancementStrength"] = picture.enhancementStrength
        payload["activeMultiplier"] = activeMultiplier
        payload["interpolationTargetFPS"] = interpolationTargetFPS
        payload["aiUpscaleStatus"] = aiUpscaleStatus
        payload["generatedFPS"] = generatedFPS
        payload["presentedSourceFPS"] = presentedSourceFPS
        payload["presentedOutputFPS"] = presentedOutputFPS
        payload["interpolationCostMS"] = interpolationCostMS
        payload["interpolationBudgetMS"] = interpolationBudgetMS
        if let interpolationWorkingSize { payload["interpolationWorkingSize"] = interpolationWorkingSize }
        payload["displayMaximumFPS"] = displayMaximumFPS
        payload["displayObservedFPS"] = displayObservedFPS
        payload["enhancementEnabled"] = picture.enhancementEnabled
        payload["enhancementTarget"] = picture.upscaleTarget.rawValue
        payload["upscaleEngine"] = upscaleEngine
        let snapshot = payload
        sessionQueue.async { [weak self] in
        guard let self else { return }
        var payload = snapshot
        if let device = self.selectedDevice {
            payload["configuredDeviceFPS"] = 1 / device.activeVideoMinFrameDuration.seconds
            payload["deviceMaxDuration"] = device.activeVideoMaxFrameDuration.seconds
        }
        if let connection = self.videoOutput.connection(with: .video) {
            payload["connectionMinDuration"] = connection.videoMinFrameDuration.seconds.isFinite ? connection.videoMinFrameDuration.seconds : 0
            payload["connectionMaxDuration"] = connection.videoMaxFrameDuration.seconds.isFinite ? connection.videoMaxFrameDuration.seconds : 0
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        // Foundation resolves the user's Library inside the app container under App Sandbox.
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let directory = library.appendingPathComponent("Logs/MoniView", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        }
    }
    private static func formatChoices(for device: AVCaptureDevice) -> [CaptureFormatOption] {
        var best: [String: CaptureFormatOption] = [:]
        for (index, format) in device.formats.enumerated() {
            let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            guard dim.width > 0, dim.height > 0, !ranges.isEmpty else { continue }
            let option = CaptureFormatOption(id: index, width: Int(dim.width), height: Int(dim.height), minimumFPS: Int((ranges.map(\.minFrameRate).min() ?? 1).rounded()), maximumFPS: Int((ranges.map(\.maxFrameRate).max() ?? 30).rounded()), rates: ranges.map { $0.minFrameRate...$0.maxFrameRate })
            let key = "\(dim.width)x\(dim.height)"
            let nativeNV12 = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if let previous = best[key] {
                let preferNew = option.prefers(over: previous, nativeNV12: nativeNV12)
                best[key] = CaptureFormatOption(id: preferNew ? option.id : previous.id, width: option.width, height: option.height,
                    minimumFPS: min(previous.minimumFPS, option.minimumFPS), maximumFPS: max(previous.maximumFPS, option.maximumFPS),
                    rates: previous.rates + option.rates)
            } else { best[key] = option }
        }
        return best.values.sorted { $0.width * $0.height > $1.width * $1.height }
    }
    private static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "—"
    }
}

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return L10n.text(text) }; return nil }
}
