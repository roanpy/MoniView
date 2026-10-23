import CoreMedia
import CoreVideo
import Dispatch
import Foundation

enum InputContentCadenceUnknownReason: Equatable {
    case noSamples
    case warmingUp
    case staticContent
    case insufficientChanges
    case sequenceGap
    case timestampDiscontinuity
    case invalidTimestamp
    case unsupportedPixelFormat
    case frameLayoutChanged
    case streamEpochChanged
}

enum InputContentCadenceState: Equatable {
    case unknown(InputContentCadenceUnknownReason)
    case estimated(fps: Double)
    case stale(lastKnownFPS: Double?, reason: InputContentCadenceUnknownReason?)
}

/// Consecutive exact-content endpoints observed by the input worker. A display-rate window
/// stream repeats one picture across several capture callbacks; keeping these two buffers lets
/// the renderer pair real updates even when queued 3× phases advance the mailbox in between.
struct InputUniquePairSnapshot {
    let previousBuffer: CVPixelBuffer
    let previousSequence: UInt64
    let previousPTS: CMTime
    let currentBuffer: CVPixelBuffer
    let currentSequence: UInt64
    let currentPTS: CMTime
    let streamEpoch: UInt64
}

struct InputContentCadenceSnapshot {
    /// Only a fresh estimate is usable as a rate. Stale snapshots retain their last value
    /// separately so a caller cannot accidentally consume it as current.
    let state: InputContentCadenceState
    let streamEpoch: UInt64?
    let sequence: UInt64?
    /// The original PTS from the most recently processed sample.
    let presentationTime: CMTime?
    let measurementStartPTS: CMTime?
    let measurementEndPTS: CMTime?
    let measurementDuration: TimeInterval?
    let uniqueUpdateCount: Int
    /// Independent exact-pixel evidence from the same contiguous window. The rate is
    /// diagnostic; long-pair admission additionally requires repeat confirmation.
    let strictUniqueFPS: Double?
    let strictRepeatedCadenceConfirmed: Bool
    let strictUniqueMeasurementStartPTS: CMTime?
    let strictUniqueMeasurementEndPTS: CMTime?
    let strictUniqueUpdateCount: Int
    let strictRepeatPairCount: Int
    /// The newest consecutive unique endpoints in this stream. Repeated captures of the same
    /// picture are intentionally absent from this pair.
    let uniquePair: InputUniquePairSnapshot?
    /// Monotonic time at which the newest processed sample was submitted.
    let sampleArrivalUptimeNanoseconds: UInt64?

    var fps: Double? {
        guard case let .estimated(value) = state else { return nil }
        return value
    }
}

/// Estimates unique input-content updates independently of drawing or GPU presentation.
///
/// Submitted CVPixelBuffers must be immutable for the lifetime of the sample. The worker
/// retains at most one pending latest sample, one processing sample, and its previous
/// comparison frame. `submit` only replaces the mailbox value and schedules the worker;
/// it never waits for pixel comparison to finish.
final class InputContentCadence {
    private static let measurementWindowSeconds: Double = 1.0
    private static let minimumUniqueUpdates = 4
    private static let maximumContentChangeAge: Double = 0.25
    // At the supported 20 FPS floor, normal content periods are at most 50 ms. A
    // forward step over 250 ms therefore spans several unobserved periods.
    private static let maximumContiguousPTSGap: Double = 0.25
    private static let oneSecond = CMTime(value: 1, timescale: 1)

    private struct Sample {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
        let sequence: UInt64
        let streamEpoch: UInt64
        let arrivalUptimeNanoseconds: UInt64
    }

    private struct PixelLayout: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let planeCount: Int

        static func supportedLayout(of pixelBuffer: CVPixelBuffer) -> PixelLayout? {
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planes = CVPixelBufferGetPlaneCount(pixelBuffer)
            let supported420 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let supportedBGRA = format == kCVPixelFormatType_32BGRA
            guard (supported420 && planes == 2) || (supportedBGRA && planes == 0) else { return nil }
            return PixelLayout(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer),
                               pixelFormat: format,
                               planeCount: planes)
        }
    }

    /// This is copied before a pixel comparison and committed only if its generation is
    /// still current. That lets reset clear retained state without racing the comparison.
    private struct MeasurementState {
        var previousPixelBuffer: CVPixelBuffer?
        var previousPTS: CMTime?
        var coverageStartPTS: CMTime?
        var activeLayout: PixelLayout?
        var activeStreamEpoch: UInt64?
        var lastSequence: UInt64?
        var transitionPTS: [CMTime] = []
        var strictTransitionPTS: [CMTime] = []
        var strictRepeatPTS: [CMTime] = []
        var strictComparisonPTS: [CMTime] = []
        var previousUniqueSample: Sample?
        var latestUniqueSample: Sample?

        mutating func clear() {
            self = MeasurementState()
        }
    }

    private struct StoredSnapshot {
        var state: InputContentCadenceState = .unknown(.noSamples)
        var streamEpoch: UInt64?
        var sequence: UInt64?
        var presentationTime: CMTime?
        var measurementStartPTS: CMTime?
        var measurementEndPTS: CMTime?
        var measurementDuration: TimeInterval?
        var uniqueUpdateCount = 0
        var strictUniqueFPS: Double?
        var strictRepeatedCadenceConfirmed = false
        var strictUniqueMeasurementStartPTS: CMTime?
        var strictUniqueMeasurementEndPTS: CMTime?
        var strictUniqueUpdateCount = 0
        var strictRepeatPairCount = 0
        var uniquePair: InputUniquePairSnapshot?
        var sampleArrivalUptimeNanoseconds: UInt64?

        var value: InputContentCadenceSnapshot {
            InputContentCadenceSnapshot(state: state,
                                        streamEpoch: streamEpoch,
                                        sequence: sequence,
                                        presentationTime: presentationTime,
                                        measurementStartPTS: measurementStartPTS,
                                        measurementEndPTS: measurementEndPTS,
                                        measurementDuration: measurementDuration,
                                        uniqueUpdateCount: uniqueUpdateCount,
                                        strictUniqueFPS: strictUniqueFPS,
                                        strictRepeatedCadenceConfirmed: strictRepeatedCadenceConfirmed,
                                        strictUniqueMeasurementStartPTS: strictUniqueMeasurementStartPTS,
                                        strictUniqueMeasurementEndPTS: strictUniqueMeasurementEndPTS,
                                        strictUniqueUpdateCount: strictUniqueUpdateCount,
                                        strictRepeatPairCount: strictRepeatPairCount,
                                        uniquePair: uniquePair,
                                        sampleArrivalUptimeNanoseconds: sampleArrivalUptimeNanoseconds)
        }
    }

    private struct StrictCadenceSnapshot {
        var fps: Double?
        var repeatedCadenceConfirmed = false
        var measurementStartPTS: CMTime?
        var measurementEndPTS: CMTime?
        var uniqueUpdateCount = 0
        var repeatPairCount = 0
    }

    private let condition = NSCondition()
    private let workerQueue = DispatchQueue(label: "MoniView.InputContentCadence.serial")
    private var pendingSample: Sample?
    private var workerScheduled = false
    private var workerIsProcessing = false
    private var resetGeneration: UInt64 = 0
    /// A reset pins accepted submissions to its epoch, preventing late callbacks from an
    /// older capture stream from repopulating the just-cleared estimator.
    private var pinnedStreamEpoch: UInt64?
    private var retainsUniquePair = true
    private var measurementState = MeasurementState()
    private var storedSnapshot = StoredSnapshot()

    #if INPUT_CONTENT_CADENCE_TESTING
    struct TestQueueMetrics {
        let coalescedSampleCount: UInt64
        let maximumPendingSampleCount: Int
        let workerScheduleCount: UInt64
    }

    private var testWorkerSuspended = false
    private var testCommitSuspended = false
    private var testReadyToCommit = false
    private var testCoalescedSampleCount: UInt64 = 0
    private var testMaximumPendingSampleCount = 0
    private var testWorkerScheduleCount: UInt64 = 0
    #endif

    init() {}

    /// Clears queued and retained measurement frames immediately and invalidates any
    /// in-flight result. Until the next matching sample, snapshots identify this epoch
    /// with an unknown warming-up state and no sample PTS.
    func reset(streamEpoch: UInt64) {
        condition.lock()
        resetGeneration &+= 1
        pinnedStreamEpoch = streamEpoch
        pendingSample = nil
        measurementState.clear()
        storedSnapshot = StoredSnapshot(state: .unknown(.warmingUp), streamEpoch: streamEpoch)
        condition.broadcast()
        condition.unlock()
    }

    /// Pair retention exists only while interpolation needs frame history. Stopping interpolation
    /// must release these buffers even if no newer sample arrives to rebuild the snapshot.
    func setUniquePairRetentionEnabled(_ enabled: Bool) {
        condition.lock()
        retainsUniquePair = enabled
        if !enabled {
            measurementState.previousUniqueSample = nil
            measurementState.latestUniqueSample = nil
            storedSnapshot.uniquePair = nil
        }
        condition.unlock()
    }

    /// Enqueues an immutable frame with its original presentation timestamp and identity.
    /// Submissions from an epoch older or newer than an explicit reset are ignored.
    func submit(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
                sequence: UInt64, streamEpoch: UInt64) {
        condition.lock()
        if let pinnedStreamEpoch, pinnedStreamEpoch != streamEpoch {
            condition.unlock()
            return
        }
        let sample = Sample(pixelBuffer: pixelBuffer,
                            presentationTime: presentationTime,
                            sequence: sequence,
                            streamEpoch: streamEpoch,
                            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        #if INPUT_CONTENT_CADENCE_TESTING
        if pendingSample != nil { testCoalescedSampleCount &+= 1 }
        #endif
        pendingSample = sample
        #if INPUT_CONTENT_CADENCE_TESTING
        testMaximumPendingSampleCount = max(testMaximumPendingSampleCount, 1)
        #endif
        let shouldScheduleWorker = !workerScheduled
        if shouldScheduleWorker {
            workerScheduled = true
            #if INPUT_CONTENT_CADENCE_TESTING
            testWorkerScheduleCount &+= 1
            #endif
        }
        condition.unlock()

        if shouldScheduleWorker {
            workerQueue.async { self.drainMailbox() }
        }
    }

    /// Returns a point-in-time snapshot. A stale result includes its original PTS, epoch,
    /// and last estimate, but `fps` is nil so it cannot be mistaken for a fresh rate.
    func snapshot(maxAge: TimeInterval = 1.0) -> InputContentCadenceSnapshot {
        condition.lock()
        let stored = storedSnapshot
        condition.unlock()

        guard let arrival = stored.sampleArrivalUptimeNanoseconds else { return stored.value }
        let ageLimit = maxAge.isFinite && maxAge >= 0 ? maxAge : 1.0
        let now = DispatchTime.now().uptimeNanoseconds
        let ageNanoseconds = now >= arrival ? now - arrival : 0
        guard Double(ageNanoseconds) / 1_000_000_000 >= ageLimit else { return stored.value }

        let staleState: InputContentCadenceState
        switch stored.state {
        case let .estimated(fps):
            staleState = .stale(lastKnownFPS: fps, reason: nil)
        case let .unknown(reason):
            staleState = .stale(lastKnownFPS: nil, reason: reason)
        case .stale:
            staleState = stored.state
        }
        return InputContentCadenceSnapshot(state: staleState,
                                           streamEpoch: stored.streamEpoch,
                                           sequence: stored.sequence,
                                           presentationTime: stored.presentationTime,
                                           measurementStartPTS: stored.measurementStartPTS,
                                           measurementEndPTS: stored.measurementEndPTS,
                                           measurementDuration: stored.measurementDuration,
                                           uniqueUpdateCount: stored.uniqueUpdateCount,
                                           strictUniqueFPS: nil,
                                           strictRepeatedCadenceConfirmed: false,
                                           strictUniqueMeasurementStartPTS: nil,
                                           strictUniqueMeasurementEndPTS: nil,
                                           strictUniqueUpdateCount: 0,
                                           strictRepeatPairCount: 0,
                                           uniquePair: nil,
                                           sampleArrivalUptimeNanoseconds: stored.sampleArrivalUptimeNanoseconds)
    }

    private func drainMailbox() {
        while true {
            condition.lock()
            guard let sample = pendingSample else {
                workerScheduled = false
                condition.broadcast()
                condition.unlock()
                return
            }
            pendingSample = nil
            workerIsProcessing = true
            let generation = resetGeneration
            condition.broadcast()
            condition.unlock()

            process(sample, generation: generation)

            condition.lock()
            workerIsProcessing = false
            condition.broadcast()
            condition.unlock()
        }
    }

    private func process(_ sample: Sample, generation: UInt64) {
        #if INPUT_CONTENT_CADENCE_TESTING
        condition.lock()
        while testWorkerSuspended { condition.wait() }
        condition.unlock()
        #endif

        condition.lock()
        guard generation == resetGeneration else {
            condition.unlock()
            return
        }
        var nextMeasurement = measurementState
        condition.unlock()

        var nextSnapshot = advance(sample, measurement: &nextMeasurement)
        if let previous = nextMeasurement.previousUniqueSample,
           let current = nextMeasurement.latestUniqueSample,
           previous.streamEpoch == current.streamEpoch,
           previous.sequence < current.sequence {
            nextSnapshot.uniquePair = InputUniquePairSnapshot(
                previousBuffer: previous.pixelBuffer, previousSequence: previous.sequence,
                previousPTS: previous.presentationTime,
                currentBuffer: current.pixelBuffer, currentSequence: current.sequence,
                currentPTS: current.presentationTime, streamEpoch: current.streamEpoch)
        }

        #if INPUT_CONTENT_CADENCE_TESTING
        condition.lock()
        testReadyToCommit = true
        condition.broadcast()
        while testCommitSuspended { condition.wait() }
        testReadyToCommit = false
        condition.unlock()
        #endif

        condition.lock()
        guard generation == resetGeneration else {
            condition.unlock()
            return
        }
        if !retainsUniquePair {
            nextMeasurement.previousUniqueSample = nil
            nextMeasurement.latestUniqueSample = nil
            nextSnapshot.uniquePair = nil
        }
        measurementState = nextMeasurement
        storedSnapshot = nextSnapshot
        condition.unlock()
    }

    private func advance(_ sample: Sample,
                         measurement: inout MeasurementState) -> StoredSnapshot {
        let layout = PixelLayout.supportedLayout(of: sample.pixelBuffer)
        guard isValidPTS(sample.presentationTime) else {
            measurement.clear()
            measurement.activeStreamEpoch = sample.streamEpoch
            measurement.activeLayout = layout
            measurement.lastSequence = sample.sequence
            return makeSnapshot(sample, state: .unknown(.invalidTimestamp))
        }

        if measurement.activeStreamEpoch == nil {
            measurement.activeStreamEpoch = sample.streamEpoch
            measurement.lastSequence = sample.sequence
            guard let layout else {
                measurement.clear()
                measurement.activeStreamEpoch = sample.streamEpoch
                measurement.lastSequence = sample.sequence
                return makeSnapshot(sample, state: .unknown(.unsupportedPixelFormat))
            }
            beginWindow(sample, layout: layout, measurement: &measurement)
            return makeSnapshot(sample, state: .unknown(.warmingUp))
        }

        if measurement.activeStreamEpoch != sample.streamEpoch {
            return resetForCurrentSample(sample, layout: layout,
                                         reason: .streamEpochChanged, measurement: &measurement)
        }

        if let lastSequence = measurement.lastSequence,
           !follows(lastSequence, sample.sequence) {
            return resetForCurrentSample(sample, layout: layout,
                                         reason: .sequenceGap, measurement: &measurement)
        }

        guard let layout else {
            measurement.clear()
            measurement.activeStreamEpoch = sample.streamEpoch
            measurement.lastSequence = sample.sequence
            return makeSnapshot(sample, state: .unknown(.unsupportedPixelFormat))
        }

        if let activeLayout = measurement.activeLayout, activeLayout != layout {
            return resetForCurrentSample(sample, layout: layout,
                                         reason: .frameLayoutChanged, measurement: &measurement)
        }

        if let previousPTS = measurement.previousPTS {
            guard CMTimeCompare(sample.presentationTime, previousPTS) > 0,
                  let ptsStep = secondsBetween(previousPTS, sample.presentationTime),
                  ptsStep <= Self.maximumContiguousPTSGap else {
                return resetForCurrentSample(sample, layout: layout,
                                             reason: .timestampDiscontinuity, measurement: &measurement)
            }
        }

        guard let previousPixelBuffer = measurement.previousPixelBuffer,
              measurement.previousPTS != nil,
              measurement.coverageStartPTS != nil else {
            measurement.activeStreamEpoch = sample.streamEpoch
            measurement.lastSequence = sample.sequence
            beginWindow(sample, layout: layout, measurement: &measurement)
            return makeSnapshot(sample, state: .unknown(.warmingUp))
        }

        let equivalent = VideoFrameDuplicateDetector.areEquivalentForCadence(previousPixelBuffer,
                                                                                sample.pixelBuffer)
        // The tolerant judge supplies the UI estimate. Exact equality is recorded independently
        // so a small moving region is not required to exceed a whole-frame noise allowance before
        // it can prove a repeated-sampling period. This stays inside the existing serial worker.
        let strictlyEquivalent = equivalent &&
            VideoFrameDuplicateDetector.areIdentical(previousPixelBuffer, sample.pixelBuffer)
        if !equivalent { measurement.transitionPTS.append(sample.presentationTime) }
        if !strictlyEquivalent { measurement.strictTransitionPTS.append(sample.presentationTime) }
        else { measurement.strictRepeatPTS.append(sample.presentationTime) }
        if !strictlyEquivalent {
            // Keep both sides of the newest real transition. This state is independent of
            // renderer queue occupancy; every source update gets a chance to become the next
            // interpolation pair even while the previous pair's phases are on screen.
            measurement.previousUniqueSample = measurement.latestUniqueSample
            measurement.latestUniqueSample = sample
        }
        measurement.strictComparisonPTS.append(sample.presentationTime)
        measurement.previousPixelBuffer = sample.pixelBuffer
        measurement.previousPTS = sample.presentationTime
        measurement.activeLayout = layout
        measurement.activeStreamEpoch = sample.streamEpoch
        measurement.lastSequence = sample.sequence

        guard let coverageStartPTS = measurement.coverageStartPTS,
              let coveredDuration = secondsBetween(coverageStartPTS, sample.presentationTime),
              coveredDuration >= Self.measurementWindowSeconds else {
            return makeSnapshot(sample, state: .unknown(.warmingUp))
        }

        let windowStart = CMTimeSubtract(sample.presentationTime, Self.oneSecond)
        guard isValidPTS(windowStart),
              let windowDuration = secondsBetween(windowStart, sample.presentationTime),
              windowDuration > 0 else {
            return resetForCurrentSample(sample, layout: layout,
                                         reason: .timestampDiscontinuity, measurement: &measurement)
        }
        measurement.transitionPTS.removeAll { CMTimeCompare($0, windowStart) <= 0 }
        measurement.strictTransitionPTS.removeAll { CMTimeCompare($0, windowStart) <= 0 }
        measurement.strictRepeatPTS.removeAll { CMTimeCompare($0, windowStart) <= 0 }
        measurement.strictComparisonPTS.removeAll { CMTimeCompare($0, windowStart) <= 0 }
        let strict = strictCadenceSnapshot(measurement, sample: sample)

        let updates = measurement.transitionPTS.count
        guard let firstChangePTS = measurement.transitionPTS.first,
              let lastChangePTS = measurement.transitionPTS.last else {
            return makeSnapshot(sample, state: .unknown(.staticContent), uniqueUpdateCount: 0,
                                strict: strict)
        }

        let changeDuration = updates >= 2
            ? secondsBetween(firstChangePTS, lastChangePTS)
            : nil
        let intervalStartPTS = changeDuration == nil ? nil : firstChangePTS
        let intervalEndPTS = changeDuration == nil ? nil : lastChangePTS
        let changeAge = secondsBetween(lastChangePTS, sample.presentationTime)
        guard let changeAge, changeAge <= Self.maximumContentChangeAge else {
            return makeSnapshot(sample, state: .unknown(.staticContent),
                                measurementStartPTS: intervalStartPTS,
                                measurementEndPTS: intervalEndPTS,
                                measurementDuration: changeDuration,
                                uniqueUpdateCount: updates,
                                strict: strict)
        }

        guard updates >= Self.minimumUniqueUpdates,
              let changeDuration, changeDuration > 0 else {
            return makeSnapshot(sample, state: .unknown(.insufficientChanges),
                                measurementStartPTS: intervalStartPTS,
                                measurementEndPTS: intervalEndPTS,
                                measurementDuration: changeDuration,
                                uniqueUpdateCount: updates,
                                strict: strict)
        }

        let fps = Double(updates - 1) / changeDuration
        guard fps.isFinite, fps > 0 else {
            return makeSnapshot(sample, state: .unknown(.insufficientChanges),
                                measurementStartPTS: firstChangePTS,
                                measurementEndPTS: lastChangePTS,
                                measurementDuration: changeDuration,
                                uniqueUpdateCount: updates,
                                strict: strict)
        }
        return makeSnapshot(sample, state: .estimated(fps: fps),
                            measurementStartPTS: firstChangePTS,
                            measurementEndPTS: lastChangePTS,
                            measurementDuration: changeDuration,
                            uniqueUpdateCount: updates,
                            strict: strict)
    }

    private func resetForCurrentSample(_ sample: Sample,
                                       layout: PixelLayout?,
                                       reason: InputContentCadenceUnknownReason,
                                       measurement: inout MeasurementState) -> StoredSnapshot {
        measurement.clear()
        measurement.activeStreamEpoch = sample.streamEpoch
        measurement.lastSequence = sample.sequence
        guard let layout else {
            return makeSnapshot(sample, state: .unknown(.unsupportedPixelFormat))
        }
        beginWindow(sample, layout: layout, measurement: &measurement)
        return makeSnapshot(sample, state: .unknown(reason))
    }

    private func beginWindow(_ sample: Sample,
                             layout: PixelLayout,
                             measurement: inout MeasurementState) {
        measurement.previousPixelBuffer = sample.pixelBuffer
        measurement.previousUniqueSample = nil
        measurement.latestUniqueSample = sample
        measurement.previousPTS = sample.presentationTime
        measurement.coverageStartPTS = sample.presentationTime
        measurement.activeLayout = layout
        measurement.transitionPTS.removeAll(keepingCapacity: true)
        measurement.strictTransitionPTS.removeAll(keepingCapacity: true)
        measurement.strictRepeatPTS.removeAll(keepingCapacity: true)
        measurement.strictComparisonPTS.removeAll(keepingCapacity: true)
    }

    private func makeSnapshot(_ sample: Sample,
                              state: InputContentCadenceState,
                              measurementStartPTS: CMTime? = nil,
                              measurementEndPTS: CMTime? = nil,
                              measurementDuration: TimeInterval? = nil,
                              uniqueUpdateCount: Int = 0,
                              strict: StrictCadenceSnapshot = StrictCadenceSnapshot()) -> StoredSnapshot {
        StoredSnapshot(state: state,
                       streamEpoch: sample.streamEpoch,
                       sequence: sample.sequence,
                       presentationTime: sample.presentationTime,
                       measurementStartPTS: measurementStartPTS,
                       measurementEndPTS: measurementEndPTS,
                       measurementDuration: measurementDuration,
                       uniqueUpdateCount: uniqueUpdateCount,
                       strictUniqueFPS: strict.fps,
                       strictRepeatedCadenceConfirmed: strict.repeatedCadenceConfirmed,
                       strictUniqueMeasurementStartPTS: strict.measurementStartPTS,
                       strictUniqueMeasurementEndPTS: strict.measurementEndPTS,
                       strictUniqueUpdateCount: strict.uniqueUpdateCount,
                       strictRepeatPairCount: strict.repeatPairCount,
                       sampleArrivalUptimeNanoseconds: sample.arrivalUptimeNanoseconds)
    }

    private func strictCadenceSnapshot(_ measurement: MeasurementState,
                                       sample: Sample) -> StrictCadenceSnapshot {
        var result = StrictCadenceSnapshot()
        result.uniqueUpdateCount = measurement.strictTransitionPTS.count
        result.repeatPairCount = measurement.strictRepeatPTS.count
        guard let first = measurement.strictTransitionPTS.first,
              let last = measurement.strictTransitionPTS.last,
              measurement.strictTransitionPTS.count >= Self.minimumUniqueUpdates,
              let duration = secondsBetween(first, last), duration > 0,
              let changeAge = secondsBetween(last, sample.presentationTime),
              changeAge <= Self.maximumContentChangeAge else { return result }

        let intervals = zip(measurement.strictTransitionPTS,
                            measurement.strictTransitionPTS.dropFirst())
            .compactMap { secondsBetween($0.0, $0.1) }
        guard intervals.count >= Self.minimumUniqueUpdates - 1 else { return result }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let close = intervals.filter { abs($0 - median) <= median * 0.12 }.count
        guard median > 0, close * 4 >= intervals.count * 3 else { return result }

        result.fps = Double(measurement.strictTransitionPTS.count - 1) / duration
        result.measurementStartPTS = first
        result.measurementEndPTS = last
        let comparisons = measurement.strictComparisonPTS.count
        let repeatFraction = comparisons > 0
            ? Double(result.repeatPairCount) / Double(comparisons) : 0
        result.repeatedCadenceConfirmed = result.repeatPairCount >= 2 && repeatFraction >= 0.5
        return result
    }

    private func follows(_ previous: UInt64, _ current: UInt64) -> Bool {
        previous != UInt64.max && current == previous + 1
    }

    private func isValidPTS(_ pts: CMTime) -> Bool {
        pts.isValid && pts.isNumeric && CMTimeGetSeconds(pts).isFinite
    }

    private func secondsBetween(_ start: CMTime, _ end: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(CMTimeSubtract(end, start))
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    #if INPUT_CONTENT_CADENCE_TESTING
    func _testWaitUntilIdle(timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while workerScheduled {
            if !condition.wait(until: deadline), workerScheduled { return false }
        }
        return true
    }

    func _testSuspendWorker() {
        condition.lock()
        testWorkerSuspended = true
        condition.unlock()
    }

    func _testResumeWorker() {
        condition.lock()
        testWorkerSuspended = false
        condition.broadcast()
        condition.unlock()
    }

    func _testSuspendBeforeCommit() {
        condition.lock()
        testCommitSuspended = true
        condition.unlock()
    }

    func _testResumeCommit() {
        condition.lock()
        testCommitSuspended = false
        condition.broadcast()
        condition.unlock()
    }

    func _testWaitUntilReadyToCommit(timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while !testReadyToCommit {
            if !condition.wait(until: deadline), !testReadyToCommit { return false }
        }
        return true
    }

    func _testWaitUntilWorkerIsProcessing(timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while !workerIsProcessing {
            if !condition.wait(until: deadline), !workerIsProcessing { return false }
        }
        return true
    }

    var _testQueueMetrics: TestQueueMetrics {
        condition.lock()
        defer { condition.unlock() }
        return TestQueueMetrics(coalescedSampleCount: testCoalescedSampleCount,
                                maximumPendingSampleCount: testMaximumPendingSampleCount,
                                workerScheduleCount: testWorkerScheduleCount)
    }
    #endif
}
