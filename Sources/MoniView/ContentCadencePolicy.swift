import Foundation

enum ContentCadencePolicy {
    /// Delivered sampling and unique content are separate measurements. A window capture may
    /// sample at the display rate even when its content changes much more slowly.
    static let minimumSamplingIntervals = 8
    static let samplingIntervalTolerance = 0.05

    /// ScreenCaptureKit delivery can omit or delay a callback without changing the stream's
    /// timestamp clock. One late interval must not discard the whole sampling window. Keep the
    /// median of a bounded recent window, but require at least three quarters of the intervals
    /// to stay within five percent of it; a genuinely mixed or unstable cadence remains unknown.
    static func samplingFPS(from intervals: [Double]) -> Double? {
        guard intervals.count >= minimumSamplingIntervals,
              intervals.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let sorted = intervals.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        guard median.isFinite, median > 0,
              FrameInterpolationPolicy.samplingFPS(1 / median) != nil else { return nil }
        let close = sorted.filter { abs($0 - median) <= median * samplingIntervalTolerance }
        let recent = intervals.suffix(4)
        guard close.count * 4 >= sorted.count * 3,
              recent.filter({ abs($0 - median) <= median * samplingIntervalTolerance }).count >= 3 else {
            return nil
        }
        return FrameInterpolationPolicy.samplingFPS(1 / median)
    }

    /// Content updates cannot exceed delivered sampling cadence. Window-edge counts
    /// can overshoot by one; preserve slower or nonstandard content estimates.
    static func boundedObservedRate(_ rate: Double?, signalFPS: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0 else { return nil }
        guard let signalFPS, signalFPS.isFinite, signalFPS > 0 else { return rate }
        return min(rate, signalFPS)
    }
    static let stabilityThreshold = 5
    /// Diagnostic stability only. Renderer admission uses measured PTS and fresh input
    /// evidence directly, never this display-statistics tolerance.
    static let frameRateTolerance = 0.01

    static func stableRate(_ rate: Double?, streak: Int) -> Double? {
        guard streak >= stabilityThreshold, let rate, rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// Display-statistics accumulator with a fixed reference sample. Comparing only adjacent
    /// noisy estimates lets a value such as 37 FPS walk upward indefinitely; every candidate
    /// is instead checked against the reference that began the current streak.
    struct StabilityTracker: Equatable {
        private(set) var reference: Double?
        private(set) var streak = 0

        @discardableResult
        mutating func observe(_ rate: Double?) -> Double? {
            guard let rate, rate.isFinite, rate > 0 else {
                reset()
                return nil
            }
            guard let reference,
                  abs(rate - reference) <= ContentCadencePolicy.frameRateTolerance else {
                self.reference = rate
                self.streak = 1
                return nil
            }
            self.streak = min(ContentCadencePolicy.stabilityThreshold, self.streak + 1)
            return ContentCadencePolicy.stableRate(reference, streak: self.streak)
        }

        mutating func reset() {
            reference = nil
            streak = 0
        }
    }

    /// Follow must never choose a rate below the measured content rate: doing so would
    /// deliberately drop content the source is producing, which is the opposite of what
    /// following is for. A stale or drifting estimate that lands under the content rate
    /// is rejected rather than applied.
    static func isAcceptableFollowTarget(contentFPS: Double, target: Double) -> Bool {
        guard contentFPS.isFinite, target.isFinite, contentFPS > 0, target > 0 else { return false }
        return target >= contentFPS - frameRateTolerance
    }

    /// Standard content rates used only by the display statistics. Normalization is
    /// deliberately narrow so a nonstandard rate such as 37 FPS remains 37 FPS.
    static let standardRates: [Double] = [20, 23.976, 24, 25, 29.97, 30, 40, 45, 48, 50, 59.94, 60]

    static func normalizedStatisticsRate(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0 else { return nil }
        if let exact = standardRates.first(where: { abs($0 - rate) < 0.000_001 }) {
            return exact
        }
        guard let nearest = standardRates.min(by: { abs($0 - rate) < abs($1 - rate) }) else {
            return rate
        }
        // A narrow absolute/relative band resolves measurement noise such as 20.017 and
        // 20.031 without creating nearest-neighbour locking for arbitrary nonstandard rates.
        let tolerance = max(0.15, rate * 0.015)
        return abs(nearest - rate) <= tolerance ? nearest : rate
    }

    static func targetRate(contentFPS: Double, supportedRates: [Double]) -> Double? {
        guard contentFPS.isFinite, contentFPS > 0 else { return nil }
        let rates = supportedRates.filter { $0.isFinite && $0 > 0 }.sorted()
        return rates.first { $0 >= contentFPS - frameRateTolerance } ?? rates.last
    }

    struct PairCadenceEvidence: Equatable {
        let contentFPS: Double
        let measurementEndPTS: Double
        let freshForCurrentEpoch: Bool
    }

    /// Up to 60.25 Hz sampling, one-to-three-tick pairs use their real PTS interval without a
    /// rolling-estimate veto. Longer periods, and every pair above 60.25 Hz sampling, require
    /// fresh causal content evidence plus strictly unique endpoints. This preserves 60 Hz and
    /// 40-in-60 timing while allowing 20-in-120 and similar repeated windows to use their real
    /// PTS period and still rejecting unexplained gaps.
    static func uniquePairPeriod(previousPTS: Double, currentPTS: Double,
                                 samplingFPS: Double,
                                 contentEvidence: PairCadenceEvidence? = nil,
                                 endpointsStrictlyUnique: Bool = false) -> Double? {
        guard previousPTS.isFinite, currentPTS.isFinite, currentPTS > previousPTS,
              let signalRate = FrameInterpolationPolicy.samplingFPS(samplingFPS) else { return nil }
        let period = currentPTS - previousPTS
        let signalPeriod = 1 / signalRate
        let ticks = period / signalPeriod
        let nearestTicks = ticks.rounded()
        guard period <= 0.1, nearestTicks >= 1,
              abs(ticks - nearestTicks) <= max(0.12, nearestTicks * 0.12) else { return nil }
        // Up to a 60.25 Hz signal, one-to-three-tick pairs remain governed by their real PTS
        // interval. A rolling estimate can lag a mode switch and must not veto capture-adjacent
        // 60 Hz timing or the alternating periods of 40-in-60. Above that sampling range, even
        // a short pair needs evidence: otherwise losing every other true-120-FPS frame could
        // manufacture a plausible two-tick 60 FPS pair without proving repeated content.
        guard nearestTicks > 3 || signalRate > 60.25 else { return period }

        if let contentEvidence {
            guard contentEvidence.freshForCurrentEpoch,
                  contentEvidence.measurementEndPTS.isFinite,
                  contentEvidence.measurementEndPTS <= currentPTS,
                  let contentRate = FrameInterpolationPolicy.nominalInputFPS(contentEvidence.contentFPS),
                  contentRate <= signalRate + 0.5 else { return nil }
            let contentPeriod = 1 / contentRate
            // Window contents are often driven by an application animation timer rather than
            // a hardware clock. Its updates can alternate around the display boundaries by a
            // few ticks. Keep the fresh measured content rate as the authority for a pair's
            // intended period, while a whole missing update still fails below by a wide margin.
            guard abs(period - contentPeriod) <= max(0.010, contentPeriod * 0.25) else { return nil }
        }
        guard contentEvidence != nil, endpointsStrictlyUnique else { return nil }
        return period
    }

    static func presentedPairIsTimely(midpointTime: Double, midpointDeadline: Double,
                                      endpointTime: Double, endpointDeadline: Double, slot: Double,
                                      presentationIntervalP95: Double) -> Bool {
        guard midpointTime.isFinite, midpointDeadline.isFinite,
              endpointTime.isFinite, endpointDeadline.isFinite,
              slot.isFinite, slot > 0, presentationIntervalP95.isFinite,
              presentationIntervalP95 > 0 else { return false }
        return midpointTime <= midpointDeadline + slot * 0.35 &&
            abs((endpointTime - midpointTime) - slot) <= slot * 0.35 &&
            endpointTime <= endpointDeadline + slot * 0.35 &&
            presentationIntervalP95 <= slot * 1.35
    }
}
