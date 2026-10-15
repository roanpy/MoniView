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
                                        sampleArrivalUptimeNanoseconds: sampleArrivalUptimeNanoseconds)
        }
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

        let nextSnapshot = advance(sample, measurement: &nextMeasurement)

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
        if !equivalent { measurement.transitionPTS.append(sample.presentationTime) }
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

        let updates = measurement.transitionPTS.count
        guard let firstChangePTS = measurement.transitionPTS.first,
              let lastChangePTS = measurement.transitionPTS.last else {
            return makeSnapshot(sample, state: .unknown(.staticContent), uniqueUpdateCount: 0)
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
                                uniqueUpdateCount: updates)
        }

        guard updates >= Self.minimumUniqueUpdates,
              let changeDuration, changeDuration > 0 else {
            return makeSnapshot(sample, state: .unknown(.insufficientChanges),
                                measurementStartPTS: intervalStartPTS,
                                measurementEndPTS: intervalEndPTS,
                                measurementDuration: changeDuration,
                                uniqueUpdateCount: updates)
        }

        let fps = Double(updates - 1) / changeDuration
        guard fps.isFinite, fps > 0 else {
            return makeSnapshot(sample, state: .unknown(.insufficientChanges),
                                measurementStartPTS: firstChangePTS,
                                measurementEndPTS: lastChangePTS,
                                measurementDuration: changeDuration,
                                uniqueUpdateCount: updates)
        }
        return makeSnapshot(sample, state: .estimated(fps: fps),
                            measurementStartPTS: firstChangePTS,
                            measurementEndPTS: lastChangePTS,
                            measurementDuration: changeDuration,
                            uniqueUpdateCount: updates)
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
        measurement.previousPTS = sample.presentationTime
        measurement.coverageStartPTS = sample.presentationTime
        measurement.activeLayout = layout
        measurement.transitionPTS.removeAll(keepingCapacity: true)
    }

    private func makeSnapshot(_ sample: Sample,
                              state: InputContentCadenceState,
                              measurementStartPTS: CMTime? = nil,
                              measurementEndPTS: CMTime? = nil,
                              measurementDuration: TimeInterval? = nil,
                              uniqueUpdateCount: Int = 0) -> StoredSnapshot {
        StoredSnapshot(state: state,
                       streamEpoch: sample.streamEpoch,
                       sequence: sample.sequence,
                       presentationTime: sample.presentationTime,
                       measurementStartPTS: measurementStartPTS,
                       measurementEndPTS: measurementEndPTS,
                       measurementDuration: measurementDuration,
                       uniqueUpdateCount: uniqueUpdateCount,
                       sampleArrivalUptimeNanoseconds: sample.arrivalUptimeNanoseconds)
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
