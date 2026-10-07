import Foundation

enum ContentCadencePolicy {
    /// Content updates cannot exceed delivered sampling cadence. Window-edge counts
    /// can overshoot by one; preserve slower or nonstandard content estimates.
    static func boundedObservedRate(_ rate: Double?, signalFPS: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0 else { return nil }
        guard let signalFPS, signalFPS.isFinite, signalFPS > 0 else { return rate }
        return min(rate, signalFPS)
    }
    static let stabilityThreshold = 5
    static let frameRateTolerance = 0.01

    static func nextStabilityStreak(previous: Double?, current: Double?, streak: Int) -> Int {
        guard let previous, let current, previous.isFinite, current.isFinite,
              previous > 0, current > 0,
              abs(current - previous) <= frameRateTolerance else { return 0 }
        return min(stabilityThreshold, max(0, streak) + 1)
    }

    static func stableRate(_ rate: Double?, streak: Int) -> Double? {
        guard streak >= stabilityThreshold, let rate, rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// Follow must never choose a rate below the measured content rate: doing so would
    /// deliberately drop content the source is producing, which is the opposite of what
    /// following is for. A stale or drifting estimate that lands under the content rate
    /// is rejected rather than applied.
    static func isAcceptableFollowTarget(contentFPS: Double, target: Double) -> Bool {
        guard contentFPS.isFinite, target.isFinite, contentFPS > 0, target > 0 else { return false }
        return target >= contentFPS - frameRateTolerance
    }

    /// Standard content rates an estimate is snapped onto. Capture timing jitter and
    /// partially repeated pictures make the raw ratio hop between neighbouring values —
    /// the same 30 FPS game measured 20, 30, 37.5 and 41.25 across runs — and a hopping
    /// estimate drags the temporal multiplier with it. Snapping keeps the choice stable
    /// and still reports a rate the source could plausibly be running at.
    static let standardRates: [Double] = [20, 23.976, 24, 25, 29.97, 30, 40, 45, 48, 50, 60]

    static func quantizedRate(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0 else { return nil }
        // Snap to the nearest standard rate. An earlier version biased downward to offset the
        // capture noise that inflated the estimate, but that pushed a 59 FPS source down to 50
        // because the 50-to-60 gap is wide. The inflation itself is fixed at its source now:
        // measurement tolerates the device's own encoding noise instead of counting it as new
        // content, so the value that arrives here is already close to the true rate.
        return standardRates.min { abs($0 - rate) < abs($1 - rate) }
    }

    static func targetRate(contentFPS: Double, supportedRates: [Double]) -> Double? {
        guard contentFPS.isFinite, contentFPS > 0 else { return nil }
        let rates = supportedRates.filter { $0.isFinite && $0 > 0 }.sorted()
        return rates.first { $0 >= contentFPS - frameRateTolerance } ?? rates.last
    }

    /// Accept a unique-endpoint interval when it is one to three stable capture periods.
    /// This covers 30→60 and the alternating one/two-tick intervals of 40→60 while
    /// rejecting stale or irregular PTS pairs for interpolation.
    static func uniquePairPeriod(previousPTS: Double, currentPTS: Double, signalFPS: Double) -> Double? {
        guard previousPTS.isFinite, currentPTS.isFinite, currentPTS > previousPTS,
              let signalRate = FrameInterpolationPolicy.nominalInputFPS(signalFPS) else { return nil }
        let period = currentPTS - previousPTS
        let signalPeriod = 1 / signalRate
        let ticks = period / signalPeriod
        let nearestTicks = ticks.rounded()
        guard period <= 0.1, nearestTicks >= 1, nearestTicks <= 3,
              abs(ticks - nearestTicks) <= max(0.12, nearestTicks * 0.12) else { return nil }
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
