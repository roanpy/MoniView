import Foundation

enum ContentCadencePolicy {
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
