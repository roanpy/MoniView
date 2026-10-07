import CoreMedia
import CoreVideo
import Foundation

@main
struct InputContentCadenceTests {
    private static var checks = 0
    private static let width = 64
    private static let height = 48

    static func main() {
        testExactRepeatsAndStaticContent()
        testCadenceNoiseTolerance()
        testDynamic20To30To60()
        testRepeatedCadencesAcrossWindowStarts()
        testJitteredFractionalRate()
        testUnquantizedRate()
        testMotionToStaticExpiresEstimate()
        testTimestampReset()
        testForwardPTSGap()
        testFrameSizeChange()
        testStreamEpochChange()
        testSequenceGapRebuildsWindow()
        testUnsupportedPixelFormat()
        testBoundedOverload()
        testResetInvalidatesInFlightAndPinsEpoch()
        print("InputContentCadence: \(checks) checks passed (content cadence, resets, freshness, unsupported layouts, and bounded worker queue).")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            fflush(stderr)
            fatalError("FAIL: \(message)")
        }
        checks += 1
    }

    private static func makeBGRAFrame(contentID: Int,
                                      width: Int = width,
                                      height: Int = height,
                                      noiseOffset: Int? = nil,
                                      noiseValue: UInt8 = 0xE7) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey as String: 64] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        precondition(status == kCVReturnSuccess && pixelBuffer != nil,
                     "CVPixelBufferCreate failed: \(status)")
        let buffer = pixelBuffer!
        precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
                     "pixel-buffer write lock failed")
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            preconditionFailure("BGRA pixel buffer has no base address")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let activeRowBytes = width * 4
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<activeRowBytes {
                let value = contentID &* 37 &+ row &* 19 &+ column &* 11
                bytes[row * stride + column] = UInt8(truncatingIfNeeded: value)
            }
        }
        if let noiseOffset {
            precondition(noiseOffset >= 0 && noiseOffset < activeRowBytes * height)
            let row = noiseOffset / activeRowBytes
            let column = noiseOffset % activeRowBytes
            bytes[row * stride + column] = noiseValue
        }
        return buffer
    }

    private static func makeUnsupportedPlanarFrame() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8Planar, nil, &pixelBuffer)
        precondition(status == kCVReturnSuccess && pixelBuffer != nil,
                     "planar CVPixelBufferCreate failed: \(status)")
        return pixelBuffer!
    }

    private static func send(_ cadence: InputContentCadence,
                             tick: Int,
                             sequence: UInt64,
                             epoch: UInt64,
                             contentID: Int,
                             frameWidth: Int = width,
                             frameHeight: Int = height,
                             noiseOffset: Int? = nil) {
        let buffer = makeBGRAFrame(contentID: contentID,
                                   width: frameWidth,
                                   height: frameHeight,
                                   noiseOffset: noiseOffset)
        cadence.submit(buffer,
                       presentationTime: CMTime(value: Int64(tick), timescale: 60),
                       sequence: sequence,
                       streamEpoch: epoch)
        check(cadence._testWaitUntilIdle(), "worker drains a sequential sample")
    }

    private static func send(_ cadence: InputContentCadence,
                             presentationTime: CMTime,
                             sequence: UInt64,
                             epoch: UInt64,
                             contentID: Int,
                             width: Int = width,
                             height: Int = height) {
        cadence.submit(makeBGRAFrame(contentID: contentID, width: width, height: height),
                       presentationTime: presentationTime,
                       sequence: sequence,
                       streamEpoch: epoch)
        check(cadence._testWaitUntilIdle(), "worker drains a sequential sample")
    }

    private static func assertEstimated(_ snapshot: InputContentCadenceSnapshot,
                                        fps expected: Double,
                                        tolerance: Double = 0.001,
                                        _ message: String) {
        guard case let .estimated(fps) = snapshot.state else {
            check(false, "\(message): expected estimate, got \(snapshot.state)")
            return
        }
        check(abs(fps - expected) <= tolerance, "\(message): expected \(expected), got \(fps)")
        check(snapshot.fps == fps, "\(message): fresh FPS accessor returns the estimate")
        let endpointDuration: Double? = {
            guard let start = snapshot.measurementStartPTS,
                  let end = snapshot.measurementEndPTS else { return nil }
            return CMTimeGetSeconds(CMTimeSubtract(end, start))
        }()
        check(endpointDuration != nil && snapshot.measurementDuration != nil &&
              abs(endpointDuration! - snapshot.measurementDuration!) < 0.000_001,
              "\(message): reported duration matches the first/last change PTS")
        check(snapshot.uniqueUpdateCount >= 4, "\(message): estimate has multiple content changes")
        check(abs(Double(snapshot.uniqueUpdateCount - 1) / snapshot.measurementDuration! - fps) <= tolerance,
              "\(message): FPS is intervals between unique changes divided by their span")
    }

    private static func assertUnknown(_ snapshot: InputContentCadenceSnapshot,
                                      reason: InputContentCadenceUnknownReason,
                                      _ message: String) {
        check(snapshot.state == .unknown(reason), "\(message): expected unknown(\(reason)), got \(snapshot.state)")
        check(snapshot.fps == nil, "\(message): unknown cadence has no usable FPS")
    }

    private static func testExactRepeatsAndStaticContent() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 1, contentID: 9)
        }
        let snapshot = cadence.snapshot(maxAge: 60)
        assertUnknown(snapshot, reason: .staticContent, "one second of exact repeats")
        check(snapshot.streamEpoch == 1 && snapshot.sequence == 60,
              "static snapshot identifies the current stream epoch and sequence")
        check(snapshot.presentationTime.map { CMTimeCompare($0, CMTime(value: 60, timescale: 60)) == 0 } == true,
              "static snapshot preserves the original PTS")
        check(snapshot.sampleArrivalUptimeNanoseconds != nil,
              "unknown snapshot records a monotonic sample timestamp")

        let stale = cadence.snapshot(maxAge: 0)
        check(stale.state == .stale(lastKnownFPS: nil, reason: .staticContent),
              "a stale unknown snapshot remains explicitly unknown and stale")
        check(stale.streamEpoch == 1 && stale.presentationTime.map { CMTimeCompare($0, CMTime(value: 60, timescale: 60)) == 0 } == true,
              "stale snapshot retains epoch and original PTS")
    }

    private static func testCadenceNoiseTolerance() {
        let cadence = InputContentCadence()
        let activeByteCount = width * height * 4
        for tick in 0...60 {
            send(cadence,
                 tick: tick,
                 sequence: UInt64(tick),
                 epoch: 2,
                 contentID: 17,
                 noiseOffset: (tick * 97) % activeByteCount,
                 )
        }
        assertUnknown(cadence.snapshot(maxAge: 60), reason: .staticContent,
                      "capture noise within areEquivalentForCadence tolerance is static")
    }

    private static func testDynamic20To30To60() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 3,
                 contentID: tick / 3)
        }
        let at20 = cadence.snapshot(maxAge: 60)
        assertEstimated(at20, fps: 20, "20 FPS unique content")

        for tick in 61...120 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 3,
                 contentID: 20 + (tick - 60) / 2)
        }
        let at30 = cadence.snapshot(maxAge: 60)
        assertEstimated(at30, fps: 30, "20 to 30 FPS content change")

        for tick in 121...180 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 3,
                 contentID: 50 + tick - 120)
        }
        let at60 = cadence.snapshot(maxAge: 60)
        assertEstimated(at60, fps: 60, "30 to 60 FPS content change")
        check(at60.sequence == 180 && at60.streamEpoch == 3,
              "dynamic estimate identifies its latest sample and epoch")

        let stale = cadence.snapshot(maxAge: 0)
        check(stale.state == .stale(lastKnownFPS: 60, reason: nil) && stale.fps == nil,
              "stale estimate preserves its value without exposing it as fresh FPS")
    }

    private static func testRepeatedCadencesAcrossWindowStarts() {
        let twenty = InputContentCadence()
        for tick in 0...120 {
            send(twenty, tick: tick, sequence: UInt64(tick), epoch: 30,
                 contentID: tick / 3)
            if [60, 73, 90, 120].contains(tick) {
                assertEstimated(twenty.snapshot(maxAge: 60), fps: 20,
                                "20 FPS survives trailing windows with different start phases")
            }
        }

        let thirty = InputContentCadence()
        for tick in 0...120 {
            send(thirty, tick: tick, sequence: UInt64(tick), epoch: 31,
                 contentID: tick / 2)
            if [60, 73, 90, 120].contains(tick) {
                assertEstimated(thirty.snapshot(maxAge: 60), fps: 30,
                                "30 FPS survives trailing windows with different start phases")
            }
        }
    }

    private static func testJitteredFractionalRate() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            let nominalMicroseconds = Int64(1_000_000.0 + Double(tick) / 59.94 * 1_000_000.0)
            let jitterMicroseconds = Int64((tick * 37) % 9 * 50)
            send(cadence,
                 presentationTime: CMTime(value: nominalMicroseconds + jitterMicroseconds,
                                          timescale: 1_000_000),
                 sequence: UInt64(tick),
                 epoch: 32,
                 contentID: tick)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 59.94, tolerance: 0.2,
                        "59.94 FPS remains accurate with small PTS jitter")
    }

    private static func testUnquantizedRate() {
        let cadence = InputContentCadence()
        send(cadence, presentationTime: CMTime(value: 0, timescale: 1_000),
             sequence: 0, epoch: 4, contentID: 0)
        for change in 1...28 {
            let milliseconds = Int64(3 + (change - 1) * 37)
            send(cadence,
                 presentationTime: CMTime(value: milliseconds, timescale: 1_000),
                 sequence: UInt64(change),
                 epoch: 4,
                 contentID: change)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 27, tolerance: 0.05,
                        "non-standard cadence is reported without quantization")
    }

    private static func testMotionToStaticExpiresEstimate() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 33,
                 contentID: tick)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 60,
                        "moving content begins with a fresh 60 FPS estimate")

        for tick in 61...75 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 33,
                 contentID: 60)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 60,
                        "the last change remains fresh through the 250 ms boundary")

        send(cadence, tick: 76, sequence: 76, epoch: 33, contentID: 60)
        let staticSnapshot = cadence.snapshot(maxAge: 60)
        assertUnknown(staticSnapshot, reason: .staticContent,
                      "repeated arriving frames do not keep the pre-static 60 FPS estimate alive")
        check(staticSnapshot.uniqueUpdateCount > 4 && staticSnapshot.fps == nil,
              "stale change history is visible for diagnosis but is not a usable rate")
        check(staticSnapshot.measurementStartPTS != nil && staticSnapshot.measurementEndPTS != nil &&
              staticSnapshot.measurementDuration != nil,
              "static transition diagnostics retain a consistent change interval")
        guard let start = staticSnapshot.measurementStartPTS,
              let end = staticSnapshot.measurementEndPTS,
              let duration = staticSnapshot.measurementDuration else {
            check(false, "static diagnostic interval has all endpoints and duration")
            return
        }
        let endpointDuration = CMTimeGetSeconds(CMTimeSubtract(end, start))
        check(abs(endpointDuration - duration) < 0.000_001,
              "static diagnostic duration matches its first/last change PTS")
    }

    private static func testTimestampReset() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 5,
                 contentID: tick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20, "pre-reset rate")

        send(cadence, presentationTime: CMTime(value: 0, timescale: 60),
             sequence: 61, epoch: 5, contentID: 0)
        let reset = cadence.snapshot(maxAge: 60)
        assertUnknown(reset, reason: .timestampDiscontinuity, "backward PTS resets the window")
        check(reset.streamEpoch == 5 && reset.sequence == 61,
              "PTS reset snapshot identifies the current stream sample")

        for relativeTick in 1...60 {
            send(cadence,
                 presentationTime: CMTime(value: Int64(relativeTick), timescale: 60),
                 sequence: UInt64(61 + relativeTick),
                 epoch: 5,
                 contentID: relativeTick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20,
                        "a fresh window recovers after PTS reset")
    }

    private static func testForwardPTSGap() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 12,
                 contentID: tick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20, "pre-forward-gap rate")

        send(cadence, presentationTime: CMTime(value: 90, timescale: 60),
             sequence: 61, epoch: 12, contentID: 20)
        let gap = cadence.snapshot(maxAge: 60)
        assertUnknown(gap, reason: .timestampDiscontinuity,
                      "forward PTS jump over 250 ms resets the measurement window")
        check(gap.streamEpoch == 12 && gap.sequence == 61,
              "forward-gap snapshot identifies the new baseline sample")

        for relativeTick in 1...60 {
            send(cadence,
                 presentationTime: CMTime(value: Int64(90 + relativeTick), timescale: 60),
                 sequence: UInt64(61 + relativeTick),
                 epoch: 12,
                 contentID: 20 + relativeTick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20,
                        "fresh PTS coverage recovers after a forward jump")
    }

    private static func testFrameSizeChange() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 6,
                 contentID: tick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20, "pre-size-change rate")

        send(cadence, tick: 61, sequence: 61, epoch: 6, contentID: 1_000,
             frameWidth: 80, frameHeight: 48)
        let changed = cadence.snapshot(maxAge: 60)
        assertUnknown(changed, reason: .frameLayoutChanged, "pixel-buffer size change resets the window")
        check(changed.streamEpoch == 6 && changed.sequence == 61,
              "size-change snapshot identifies the current sample")

        for tick in 62...121 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 6,
                 contentID: 1_000 + (tick - 61) / 3,
                 frameWidth: 80,
                 frameHeight: 48)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20,
                        "new dimensions build an independent estimate")
    }

    private static func testStreamEpochChange() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 7,
                 contentID: tick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20, "pre-epoch-change rate")

        send(cadence, presentationTime: CMTime(value: 0, timescale: 60),
             sequence: 0, epoch: 8, contentID: 1_000)
        let changed = cadence.snapshot(maxAge: 60)
        assertUnknown(changed, reason: .streamEpochChanged, "new stream epoch resets the window")
        check(changed.streamEpoch == 8 && changed.sequence == 0,
              "epoch-change snapshot reports the new epoch and sequence")

        for tick in 1...60 {
            send(cadence,
                 presentationTime: CMTime(value: Int64(tick), timescale: 60),
                 sequence: UInt64(tick), epoch: 8,
                 contentID: 1_000 + tick / 2)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 30,
                        "new epoch builds an independent estimate")
    }

    private static func testSequenceGapRebuildsWindow() {
        let cadence = InputContentCadence()
        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 9,
                 contentID: tick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20, "pre-gap rate")

        send(cadence, presentationTime: CMTime(value: 62, timescale: 60),
             sequence: 62, epoch: 9, contentID: 1_000)
        let gap = cadence.snapshot(maxAge: 60)
        assertUnknown(gap, reason: .sequenceGap, "missing sequence invalidates the estimate")
        check(gap.streamEpoch == 9 && gap.sequence == 62,
              "gap snapshot identifies the newest contiguous-window baseline")

        for sequence in 63...122 {
            send(cadence,
                 presentationTime: CMTime(value: Int64(sequence), timescale: 60),
                 sequence: UInt64(sequence), epoch: 9,
                 contentID: 1_000 + (sequence - 62) / 2)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 30,
                        "sequence gap is excluded and the new window recovers")
    }

    private static func testUnsupportedPixelFormat() {
        let cadence = InputContentCadence()
        let buffer = makeUnsupportedPlanarFrame()
        cadence.submit(buffer,
                       presentationTime: CMTime(value: 0, timescale: 60),
                       sequence: 0,
                       streamEpoch: 10)
        check(cadence._testWaitUntilIdle(), "unsupported sample is processed")
        let snapshot = cadence.snapshot(maxAge: 60)
        assertUnknown(snapshot, reason: .unsupportedPixelFormat,
                      "unsupported pixel layout remains unknown")
        check(snapshot.streamEpoch == 10 && snapshot.presentationTime.map { $0.isValid } == true,
              "unsupported-layout snapshot retains epoch and PTS")
    }

    private static func testBoundedOverload() {
        let cadence = InputContentCadence()
        cadence._testSuspendWorker()
        cadence.submit(makeBGRAFrame(contentID: 0),
                       presentationTime: CMTime(value: 0, timescale: 60),
                       sequence: 0,
                       streamEpoch: 11)
        check(cadence._testWaitUntilWorkerIsProcessing(), "worker holds only its active sample at the test gate")

        for sequence in 1...100 {
            cadence.submit(makeBGRAFrame(contentID: sequence),
                           presentationTime: CMTime(value: Int64(sequence), timescale: 60),
                           sequence: UInt64(sequence),
                           streamEpoch: 11)
        }
        let metrics = cadence._testQueueMetrics
        check(metrics.coalescedSampleCount >= 99,
              "overload replaces intermediate pending samples with the latest")
        check(metrics.maximumPendingSampleCount == 1,
              "mailbox retains at most one pending sample")
        check(metrics.workerScheduleCount == 1,
              "overload schedules one drain closure instead of one closure per frame")

        cadence._testResumeWorker()
        check(cadence._testWaitUntilIdle(), "overloaded mailbox drains after the worker resumes")
        let snapshot = cadence.snapshot(maxAge: 60)
        assertUnknown(snapshot, reason: .sequenceGap,
                      "coalesced sequence numbers invalidate rather than lower the measured rate")
        check(snapshot.sequence == 100 && snapshot.streamEpoch == 11,
              "overload snapshot refers to the newest retained sample")
    }

    private static func testResetInvalidatesInFlightAndPinsEpoch() {
        let cadence = InputContentCadence()
        send(cadence, tick: 0, sequence: 0, epoch: 14, contentID: 0)

        cadence._testSuspendBeforeCommit()
        cadence.submit(makeBGRAFrame(contentID: 1),
                       presentationTime: CMTime(value: 1, timescale: 60),
                       sequence: 1,
                       streamEpoch: 14)
        check(cadence._testWaitUntilReadyToCommit(),
              "worker computes a result and pauses before publishing it")

        cadence.submit(makeBGRAFrame(contentID: 2),
                       presentationTime: CMTime(value: 2, timescale: 60),
                       sequence: 2,
                       streamEpoch: 14)
        cadence.submit(makeBGRAFrame(contentID: 3),
                       presentationTime: CMTime(value: 3, timescale: 60),
                       sequence: 3,
                       streamEpoch: 14)
        check(cadence._testQueueMetrics.coalescedSampleCount >= 1,
              "reset race fixture has a replaceable pending sample")

        cadence.reset(streamEpoch: 15)
        let resetSnapshot = cadence.snapshot(maxAge: 60)
        assertUnknown(resetSnapshot, reason: .warmingUp,
                      "reset immediately publishes an empty new-epoch state")
        check(resetSnapshot.streamEpoch == 15 && resetSnapshot.sequence == nil &&
              resetSnapshot.presentationTime == nil && resetSnapshot.sampleArrivalUptimeNanoseconds == nil,
              "reset clears old sample timestamps and sequence while retaining the requested epoch")

        cadence.submit(makeBGRAFrame(contentID: 99),
                       presentationTime: CMTime(value: 4, timescale: 60),
                       sequence: 4,
                       streamEpoch: 14)
        cadence._testResumeCommit()
        check(cadence._testWaitUntilIdle(), "invalidated worker and cleared mailbox become idle")
        let afterRace = cadence.snapshot(maxAge: 60)
        assertUnknown(afterRace, reason: .warmingUp,
                      "in-flight old-generation result cannot publish after reset")
        check(afterRace.streamEpoch == 15 && afterRace.sequence == nil &&
              afterRace.presentationTime == nil,
              "late old-epoch submission cannot repopulate reset snapshot")

        for tick in 0...60 {
            send(cadence, tick: tick, sequence: UInt64(tick), epoch: 15,
                 contentID: tick / 3)
        }
        assertEstimated(cadence.snapshot(maxAge: 60), fps: 20,
                        "matching reset epoch starts a clean estimate")
    }
}
