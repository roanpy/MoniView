// Fault-injection fixture for CaptureRecorder. Synthetic PCM/BGRA media goes through the
// real AVAssetWriter. The testing hook records source, accepted, and dropped audio PTS so
// ordering is asserted directly; AAC packet/frame-count heuristics are intentionally unused.
import AVFoundation
import CoreMedia
import Foundation

// These types normally live in the AppKit-only CaptureManager.swift.
struct PictureSettings: Equatable {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var sharpness = 0.0
    var vibrance = 0.0
    var enhancementEnabled = true
    var enhancementStrength = 0.35
    var highlightRecovery = 0.0
}

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return L10n.text(message) }
        return nil
    }
}

let sampleRate: Float64 = 48_000
let framesPerPacket = 1_024
let packetDuration = Double(framesPerPacket) / sampleRate

func makeAudioASBD() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
}

func audioPTS(_ index: Int) -> CMTime {
    CMTime(value: CMTimeValue(index * framesPerPacket), timescale: CMTimeScale(sampleRate))
}

func makeAudioPacket(index: Int) -> CMSampleBuffer {
    var asbd = makeAudioASBD()
    var format: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                magicCookie: nil, extensions: nil,
                                                formatDescriptionOut: &format) == noErr && format != nil,
                 "audio format description")
    let byteCount = framesPerPacket * MemoryLayout<Float>.size
    var values = [Float](repeating: 0, count: framesPerPacket)
    let phase = Float(index % 64)
    for frame in values.indices { values[frame] = sinf(Float(frame) * 0.05 + phase) * 0.2 }
    var block: CMBlockBuffer?
    precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                    memoryBlock: nil, blockLength: byteCount,
                                                    blockAllocator: kCFAllocatorDefault,
                                                    customBlockSource: nil, offsetToData: 0,
                                                    dataLength: byteCount, flags: 0,
                                                    blockBufferOut: &block) == kCMBlockBufferNoErr && block != nil,
                 "audio block buffer")
    let copyStatus = values.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!,
                                      offsetIntoDestination: 0, dataLength: byteCount)
    }
    precondition(copyStatus == kCMBlockBufferNoErr, "audio block fill")
    var sample: CMSampleBuffer?
    precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!,
        sampleCount: framesPerPacket, presentationTimeStamp: audioPTS(index),
        packetDescriptions: nil, sampleBufferOut: &sample) == noErr && sample != nil,
        "audio sample buffer")
    return sample!
}

func makeVideoSample(index: Int, width: Int = 320, height: Int = 180) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                    nil, &pixelBuffer) == kCVReturnSuccess && pixelBuffer != nil,
                 "video pixel buffer")
    CVPixelBufferLockBaseAddress(pixelBuffer!, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer!) {
        memset(base, Int32(40 + (index % 120)), CVPixelBufferGetBytesPerRow(pixelBuffer!) * height)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
    var format: CMVideoFormatDescription?
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: pixelBuffer!,
                                                              formatDescriptionOut: &format) == noErr && format != nil,
                 "video format description")
    let pts = CMTime(value: CMTimeValue(index) * 10, timescale: 600)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 10, timescale: 600),
                                    presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                          imageBuffer: pixelBuffer!,
                                                          formatDescription: format!, sampleTiming: &timing,
                                                          sampleBufferOut: &sample) == noErr && sample != nil,
                 "video sample buffer")
    return sample!
}

func audioTrackPTS(_ url: URL) -> [CMTime] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first,
          let reader = try? AVAssetReader(asset: asset) else { return [] }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }
    var values: [CMTime] = []
    while let sample = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if pts.isValid { values.append(pts) }
    }
    return values
}

func videoTrackPTS(_ url: URL) -> [CMTime] {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first,
          let reader = try? AVAssetReader(asset: asset) else { return [] }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }
    var values: [CMTime] = []
    while let sample = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if pts.isValid { values.append(pts) }
    }
    return values
}

func samePTS(_ lhs: [CMTime], _ rhs: [CMTime]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CMTimeCompare($0, $1) == 0 }
}

func strictlyIncreasing(_ values: [CMTime]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { CMTimeCompare($0, $1) < 0 }
}

func describePTS(_ values: [CMTime]) -> String {
    guard let first = values.first, let last = values.last else { return "count=0 []" }
    let firstLabel = "\(first.value)/\(first.timescale)"
    let lastLabel = "\(last.value)/\(last.timescale)"
    if values.count <= 24 {
        return "count=\(values.count) [" + values.map { "\($0.value)/\($0.timescale)" }.joined(separator: ",") + "]"
    }
    let step = CMTimeSubtract(values[1], values[0])
    let uniform = zip(values, values.dropFirst()).allSatisfy {
        CMTimeCompare(CMTimeSubtract($1, $0), step) == 0
    }
    let order = strictlyIncreasing(values) ? "strictly-increasing" : "unordered"
    if uniform {
        return "count=\(values.count) range=\(firstLabel)…\(lastLabel) step=\(step.value)/\(step.timescale) \(order)"
    }
    return "count=\(values.count) first=\(firstLabel) last=\(lastLabel) \(order)"
}

final class CompletionBox {
    private let lock = NSLock()
    private var storedErrors: [String?] = []
    let signal = DispatchSemaphore(value: 0)

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storedErrors.count
    }

    var firstError: String? {
        lock.lock(); defer { lock.unlock() }
        guard !storedErrors.isEmpty else { return "completion has not arrived" }
        return storedErrors[0]
    }

    func finish(_ error: Error?) {
        lock.lock()
        storedErrors.append(error.map { String(describing: $0) })
        lock.unlock()
        signal.signal()
    }
}

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("  PASS \(label)") }
    else { failures += 1; print("  FAIL \(label)") }
}

func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return predicate()
}

func waitForCompletion(_ box: CompletionBox, seconds: TimeInterval = 15) -> Bool {
    box.signal.wait(timeout: .now() + seconds) == .success
}

func checkSingleCompletion(_ box: CompletionBox, _ label: String) {
    check(waitForCompletion(box), "\(label): completion arrived")
    // Give a duplicate callback a chance to expose itself; count access is synchronized.
    _ = box.signal.wait(timeout: .now() + 0.15)
    check(box.count == 1, "\(label): completion exactly once (\(box.count))")
}

func startRecording(_ recorder: CaptureRecorder, url: URL, box: CompletionBox, audio: Bool = true) {
    let previousSessionID = recorder.testing.snapshot().sessionID
    recorder.start(url: url, width: 320, height: 180, fps: 60,
                   audio: audio ? makeAudioASBD() : nil) { box.finish($0) }
    check(waitUntil {
        let state = recorder.testing.snapshot()
        return (state.sessionID > previousSessionID && state.writerStarted) || box.count > 0
    },
          "writer start answered for \(url.lastPathComponent)")
}

func feedVideo(_ recorder: CaptureRecorder, _ index: Int) {
    recorder.append(makeVideoSample(index: index), video: true)
}

func feedAudio(_ recorder: CaptureRecorder, _ index: Int) {
    recorder.append(makeAudioPacket(index: index), video: false)
}

func printLedger(_ label: String, _ state: RecorderFaultInjectionHooks.Snapshot) {
    print("  PTS \(label) received=\(describePTS(state.receivedAudioPTS))")
    print("  PTS \(label) accepted=\(describePTS(state.acceptedAudioPTS))")
    print("  PTS \(label) dropped=\(describePTS(state.droppedAudioPTS))")
}

func expectNoTemporaryFiles(in directory: URL, _ label: String) throws {
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(".moniview-") }
    check(leftovers.isEmpty, "\(label): no recorder temporary files remain (\(leftovers))")
}

let workRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("moniview-recorder-faults-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
let keepOutputs = ProcessInfo.processInfo.environment["MONIVIEW_TEST_KEEP"] == "1"

// 1. Force the real audio append path to observe not-ready, then recover without reordering.
print("Scenario 1: brief forced audio backpressure and ordered recovery")
do {
    let recorder = CaptureRecorder()
    recorder.testing.setAudioInputForcedNotReady(true)
    let box = CompletionBox()
    startRecording(recorder, url: workRoot.appendingPathComponent("brief.mov"), box: box)
    feedVideo(recorder, 0)
    for index in 0..<12 { feedAudio(recorder, index) }
    check(waitUntil { recorder.testing.snapshot().notReadyObservations > 0 },
          "forced not-ready branch was observed")
    check(recorder.testing.snapshot().acceptedAudioPTS.isEmpty,
          "no audio append while input is forced not-ready")
    recorder.testing.setAudioInputForcedNotReady(false)
    for index in 12..<20 { feedAudio(recorder, index) }
    recorder.stop()
    checkSingleCompletion(box, "brief recovery")
    check(box.firstError == nil, "brief recovery completed successfully: \(String(describing: box.firstError))")
    let state = recorder.testing.snapshot()
    printLedger("brief", state)
    check(samePTS(state.receivedAudioPTS, (0..<20).map(audioPTS)), "all input PTS received in source order")
    check(samePTS(state.acceptedAudioPTS, (0..<20).map(audioPTS)), "all queued old PTS then new PTS accepted in order")
    check(state.droppedAudioPTS.isEmpty && state.failedAudioPTS.isEmpty,
          "brief stall caused no drops or append failures")
    let outputPTS = audioTrackPTS(workRoot.appendingPathComponent("brief.mov"))
    check(!outputPTS.isEmpty && strictlyIncreasing(outputPTS),
          "final compressed audio track PTS is present and strictly increasing")
}

// 2. Hold readiness false beyond the two-second media budget. Exact input/drop/write PTS
// accounting proves oldest-first eviction and that recovery drains buffered packets first.
print("Scenario 2: sustained forced backpressure exceeds the two-second FIFO budget")
do {
    let recorder = CaptureRecorder()
    recorder.testing.setAudioInputForcedNotReady(true)
    let box = CompletionBox()
    startRecording(recorder, url: workRoot.appendingPathComponent("sustained.mov"), box: box)
    feedVideo(recorder, 0)
    for index in 0..<250 { feedAudio(recorder, index) }
    check(waitUntil { recorder.testing.snapshot().notReadyObservations > 0 },
          "sustained forced not-ready branch was observed")
    let beforeRecovery = recorder.testing.snapshot()
    check(beforeRecovery.acceptedAudioPTS.isEmpty, "backlog remained queued while input was not-ready")
    check(!beforeRecovery.droppedAudioPTS.isEmpty, "more than two seconds of media caused FIFO eviction")
    check(samePTS(beforeRecovery.droppedAudioPTS,
                  (0..<beforeRecovery.droppedAudioPTS.count).map(audioPTS)),
          "FIFO evicted the oldest source PTS first")
    check(samePTS(beforeRecovery.pendingAudioPTS,
                  (beforeRecovery.droppedAudioPTS.count..<250).map(audioPTS)),
          "remaining pre-recovery queue is the exact newest PTS suffix")
    if let first = beforeRecovery.pendingAudioPTS.first, let last = beforeRecovery.pendingAudioPTS.last {
        let queuedSpan = CMTimeGetSeconds(last) - CMTimeGetSeconds(first) + packetDuration
        check(queuedSpan <= 2.000_001, "retained media fits the two-second FIFO budget (\(queuedSpan)s)")
    } else {
        check(false, "retained queue has PTS after sustained backpressure")
    }
    let oldQueuedPTS = beforeRecovery.pendingAudioPTS
    recorder.testing.setAudioInputForcedNotReady(false)
    check(waitUntil(timeout: 12) {
        let state = recorder.testing.snapshot()
        return state.pendingAudioPTS.isEmpty && state.acceptedAudioPTS.count == oldQueuedPTS.count
    }, "all buffered old PTS drain before new audio arrives")
    for index in 250..<260 { feedAudio(recorder, index) }
    recorder.stop()
    checkSingleCompletion(box, "sustained recovery")
    check(box.firstError == nil, "sustained recovery completed successfully: \(String(describing: box.firstError))")
    let state = recorder.testing.snapshot()
    printLedger("sustained", state)
    let expectedReceived = (0..<260).map(audioPTS)
    let expectedAccepted = oldQueuedPTS + (250..<260).map(audioPTS)
    check(samePTS(state.receivedAudioPTS, expectedReceived), "all 260 received PTS preserved in ingress order")
    check(samePTS(state.droppedAudioPTS, beforeRecovery.droppedAudioPTS), "FIFO reports the exact oldest dropped PTS set")
    check(samePTS(state.acceptedAudioPTS, expectedAccepted), "all buffered old packets precede the 10 new packets")
    check(strictlyIncreasing(state.acceptedAudioPTS), "accepted audio PTS are strictly increasing")
    check(recorder.droppedSamples().audio == state.droppedAudioPTS.count,
          "drop counter matches PTS ledger (\(recorder.droppedSamples().audio))")
    check(state.ignoredAudioPTS.isEmpty && state.failedAudioPTS.isEmpty,
          "all input is either accepted or accounted as a FIFO drop")
    let outputPTS = audioTrackPTS(workRoot.appendingPathComponent("sustained.mov"))
    check(!outputPTS.isEmpty && strictlyIncreasing(outputPTS),
          "final compressed audio track PTS is present and strictly increasing")
}

// 3. Stop while a short tail is still blocked, then release it before the wall-clock deadline.
print("Scenario 3: stop waits for a recoverable audio tail to drain")
do {
    let recorder = CaptureRecorder()
    recorder.testing.setAudioInputForcedNotReady(true)
    let box = CompletionBox()
    startRecording(recorder, url: workRoot.appendingPathComponent("stop-drain.mov"), box: box)
    feedVideo(recorder, 0)
    for index in 0..<20 { feedAudio(recorder, index) }
    check(waitUntil { recorder.testing.snapshot().notReadyObservations > 0 }, "stop-drain stall observed")
    recorder.stop()
    check(waitUntil { recorder.testing.snapshot().finishing }, "stop entered tail-drain state")
    recorder.testing.setAudioInputForcedNotReady(false)
    checkSingleCompletion(box, "stop tail drain")
    check(box.firstError == nil, "stop tail drain completed successfully")
    let state = recorder.testing.snapshot()
    check(samePTS(state.acceptedAudioPTS, (0..<20).map(audioPTS)), "stop drained the entire queued PTS tail")
    check(state.droppedAudioPTS.isEmpty && state.finishWritingStarted,
          "tail drained before finishWriting without deadline drops")
}

// 4. Keep the input permanently not-ready during stop. Completion must follow the 2s deadline.
print("Scenario 4: permanent not-ready at stop expires at the two-second deadline")
do {
    let recorder = CaptureRecorder()
    recorder.testing.setAudioInputForcedNotReady(true)
    let box = CompletionBox()
    startRecording(recorder, url: workRoot.appendingPathComponent("deadline.mov"), box: box)
    feedVideo(recorder, 0)
    for index in 0..<12 { feedAudio(recorder, index) }
    check(waitUntil { recorder.testing.snapshot().notReadyObservations > 0 }, "deadline stall observed")
    let stopTime = ProcessInfo.processInfo.systemUptime
    recorder.stop()
    check(waitForCompletion(box), "permanent stall deadline: completion arrived")
    let elapsed = ProcessInfo.processInfo.systemUptime - stopTime
    _ = box.signal.wait(timeout: .now() + 0.15)
    check(box.count == 1, "permanent stall deadline: completion exactly once (\(box.count))")
    check(box.firstError == nil, "deadline drop still finishes the valid video recording")
    check(elapsed >= 1.8 && elapsed < 8,
          "completion waited for the 2s drain deadline (elapsed \(String(format: "%.2f", elapsed))s)")
    let state = recorder.testing.snapshot()
    check(samePTS(state.receivedAudioPTS, (0..<12).map(audioPTS)), "deadline scenario received all 12 audio PTS")
    check(state.acceptedAudioPTS.isEmpty && samePTS(state.droppedAudioPTS, (0..<12).map(audioPTS)),
          "all queued audio PTS were explicitly dropped at the deadline")
    check(recorder.droppedSamples().audio == 12 && state.finishWritingStarted,
          "deadline drop accounting is exact and finishWriting started")
    check(audioTrackPTS(workRoot.appendingPathComponent("deadline.mov")).isEmpty,
          "timed-out audio was not written to the final asset")
}

// 5. Audio is optional; a video-only recording must finish and contain no audio samples.
print("Scenario 5: video-only recording")
do {
    let recorder = CaptureRecorder()
    let box = CompletionBox()
    startRecording(recorder, url: workRoot.appendingPathComponent("video-only.mov"), box: box, audio: false)
    for index in 0..<3 { feedVideo(recorder, index) }
    recorder.stop()
    checkSingleCompletion(box, "video-only recording")
    check(box.firstError == nil, "video-only recording succeeded")
    let url = workRoot.appendingPathComponent("video-only.mov")
    check(!videoTrackPTS(url).isEmpty, "video-only asset contains video")
    check(audioTrackPTS(url).isEmpty, "video-only asset has no audio samples")
}

// 6. Reuse one recorder for successive sessions; stale session PTS cannot leak forward.
print("Scenario 6: repeated start/stop resets the PTS ledger")
do {
    let recorder = CaptureRecorder()
    let firstURL = workRoot.appendingPathComponent("repeat-a.mov")
    let firstBox = CompletionBox()
    startRecording(recorder, url: firstURL, box: firstBox)
    feedVideo(recorder, 0)
    for index in 0..<8 { feedAudio(recorder, index) }
    recorder.stop()
    checkSingleCompletion(firstBox, "first repeated session")
    check(firstBox.firstError == nil, "first repeated session succeeded")

    let secondURL = workRoot.appendingPathComponent("repeat-b.mov")
    let secondBox = CompletionBox()
    startRecording(recorder, url: secondURL, box: secondBox)
    feedVideo(recorder, 6_000)
    for index in 4_688..<4_696 { feedAudio(recorder, index) }
    recorder.stop()
    checkSingleCompletion(secondBox, "second repeated session")
    check(secondBox.firstError == nil, "second repeated session succeeded")
    let secondState = recorder.testing.snapshot()
    check(samePTS(secondState.receivedAudioPTS, (4_688..<4_696).map(audioPTS)),
          "second session ledger contains only its own source PTS")
    check(samePTS(secondState.acceptedAudioPTS, (4_688..<4_696).map(audioPTS)),
          "second session accepted only its own PTS in order")
    check(!audioTrackPTS(firstURL).isEmpty && !audioTrackPTS(secondURL).isEmpty,
          "both repeated-session assets retain audio")
}

// 7. Start failure completes once and leaves the same recorder reusable.
print("Scenario 7: start failure cleanup and recorder reuse")
do {
    let recorder = CaptureRecorder()
    let badBox = CompletionBox()
    startRecording(recorder, url: workRoot.appendingPathComponent("missing-dir/out.mov"), box: badBox)
    checkSingleCompletion(badBox, "missing destination directory")
    check(badBox.firstError != nil, "start failure is reported")

    let url = workRoot.appendingPathComponent("after-start-failure.mov")
    let goodBox = CompletionBox()
    startRecording(recorder, url: url, box: goodBox)
    feedVideo(recorder, 0)
    feedAudio(recorder, 0)
    recorder.stop()
    checkSingleCompletion(goodBox, "reuse after start failure")
    check(goodBox.firstError == nil, "recorder successfully reused after failed start")
    check(!videoTrackPTS(url).isEmpty, "reused recorder produced a valid asset")
}

// 8. A recording that fails before commit must preserve a same-name old file and remove temp data.
print("Scenario 8: recording failure preserves an existing destination")
do {
    let recorder = CaptureRecorder()
    let url = workRoot.appendingPathComponent("preserved.mov")
    let original = Data("ORIGINAL-DESTINATION".utf8)
    try original.write(to: url)
    let box = CompletionBox()
    startRecording(recorder, url: url, box: box)
    feedAudio(recorder, 0) // No video: stop must fail without reaching commit.
    recorder.stop()
    checkSingleCompletion(box, "missing-video failure")
    check(box.firstError != nil, "missing video is a reported recording failure")
    let state = recorder.testing.snapshot()
    check(samePTS(state.receivedAudioPTS, [audioPTS(0)]), "failed session records received audio PTS")
    check(samePTS(state.failedAudioPTS, [audioPTS(0)]), "unwritten queued audio is classified as failed")
    check(try Data(contentsOf: url) == original, "old destination bytes remain unchanged")
    try expectNoTemporaryFiles(in: workRoot, "recording failure")
}

// 9. A successful same-name replacement commits the new writer output over the old file.
print("Scenario 9: successful same-name replacement")
do {
    let recorder = CaptureRecorder()
    let url = workRoot.appendingPathComponent("replace-success.mov")
    let original = Data("OLD-FILE".utf8)
    try original.write(to: url)
    let box = CompletionBox()
    startRecording(recorder, url: url, box: box)
    feedVideo(recorder, 0)
    for index in 0..<6 { feedAudio(recorder, index) }
    recorder.stop()
    checkSingleCompletion(box, "same-name replacement")
    check(box.firstError == nil, "same-name replacement committed successfully: \(String(describing: box.firstError))")
    check(try Data(contentsOf: url) != original, "destination now contains the new recording")
    check(!videoTrackPTS(url).isEmpty && !audioTrackPTS(url).isEmpty,
          "replacement asset contains video and audio")
    try expectNoTemporaryFiles(in: workRoot, "successful replacement")
}

// 10. Inject a commit error after writer finish; original data survives and the temp is removed.
print("Scenario 10: injected commit failure preserves old destination")
do {
    let recorder = CaptureRecorder()
    recorder.testing.injectNextCommitFailure()
    let url = workRoot.appendingPathComponent("replace-failure.mov")
    let original = Data("KEEP-THIS-OLD-FILE".utf8)
    try original.write(to: url)
    let box = CompletionBox()
    startRecording(recorder, url: url, box: box)
    feedVideo(recorder, 0)
    feedAudio(recorder, 0)
    recorder.stop()
    checkSingleCompletion(box, "injected commit failure")
    check(box.firstError != nil, "commit failure reaches the completion handler")
    check(try Data(contentsOf: url) == original, "old destination bytes survive commit failure")
    try expectNoTemporaryFiles(in: workRoot, "commit failure")
}

// 11. A second start while the first session is active is rejected without disturbing it.
print("Scenario 11: concurrent start rejection")
do {
    let recorder = CaptureRecorder()
    let firstBox = CompletionBox()
    startRecording(recorder, url: workRoot.appendingPathComponent("concurrent-first.mov"), box: firstBox)
    feedVideo(recorder, 0)
    let secondBox = CompletionBox()
    recorder.start(url: workRoot.appendingPathComponent("concurrent-second.mov"), width: 320,
                   height: 180, fps: 60, audio: makeAudioASBD()) { secondBox.finish($0) }
    checkSingleCompletion(secondBox, "rejected concurrent start")
    check(secondBox.firstError != nil, "active recording rejects second start")
    feedAudio(recorder, 0)
    recorder.stop()
    checkSingleCompletion(firstBox, "original concurrent session")
    check(firstBox.firstError == nil, "original recording remains healthy")
    check(!FileManager.default.fileExists(atPath: workRoot.appendingPathComponent("concurrent-second.mov").path),
          "rejected start created no destination")
}

if keepOutputs {
    print("kept synthetic outputs at \(workRoot.path)")
} else {
    try FileManager.default.removeItem(at: workRoot)
}
print(failures == 0 ? "All recorder fault-injection scenarios passed." : "\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
