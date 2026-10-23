import Foundation

@main
struct ContentCadencePolicyTests {
    static var checks = 0

    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        checks += 1
    }

    static func main() {
        check(ContentCadencePolicy.boundedObservedRate(61, signalFPS: 60) == 60,
              "Window-edge overshoot cannot exceed the delivered sampling rate")
        check(ContentCadencePolicy.boundedObservedRate(40, signalFPS: 60) == 40,
              "Nonstandard content cadence is preserved")
        check(ContentCadencePolicy.boundedObservedRate(30, signalFPS: 20) == 20,
              "A low capture rate cannot establish faster content updates")
        check(ContentCadencePolicy.boundedObservedRate(nil, signalFPS: 60) == nil &&
              ContentCadencePolicy.boundedObservedRate(.nan, signalFPS: 60) == nil,
              "Invalid or absent observations stay unknown")
        check(ContentCadencePolicy.boundedObservedRate(29.97, signalFPS: nil) == 29.97,
              "An absent stable signal rate does not invent a replacement")
        var invalidTracker = ContentCadencePolicy.StabilityTracker()
        check(invalidTracker.observe(nil) == nil && invalidTracker.streak == 0 &&
              invalidTracker.reference == nil,
              "Missing statistics clear the tracker reference and streak")
        var fractionalTracker = ContentCadencePolicy.StabilityTracker()
        for _ in 0..<4 {
            check(fractionalTracker.observe(29.97) == nil, "Fractional cadence warms up below threshold")
        }
        check(fractionalTracker.observe(29.975) == 29.97,
              "Small fractional-rate noise stabilizes against the fixed reference")
        check(fractionalTracker.observe(30.02) == nil &&
              fractionalTracker.reference == 30.02 && fractionalTracker.streak == 1,
              "Cumulative change beyond tolerance resets stability and starts a new reference")
        check(ContentCadencePolicy.stableRate(29.97, streak: 4) == nil &&
              ContentCadencePolicy.stableRate(29.97, streak: 5) == 29.97,
              "Stable cadence is published only at the threshold")

        check(ContentCadencePolicy.targetRate(contentFPS: 29.97, supportedRates: [29.97, 59.94]) == 29.97,
              "29.97 selects the matching fractional capture rate")
        check(ContentCadencePolicy.targetRate(contentFPS: 23.976, supportedRates: [24, 29.97]) == 24,
              "23.976 selects nominal 24")
        check(ContentCadencePolicy.targetRate(contentFPS: 30, supportedRates: [29.97, 59.94]) == 59.94,
              "A rate below content is not selected outside tolerance")
        check(ContentCadencePolicy.targetRate(contentFPS: 30, supportedRates: [20, 25]) == 25,
              "When no supported rate reaches content, use the highest advertised rate")
        check(ContentCadencePolicy.targetRate(contentFPS: 30, supportedRates: []) == nil,
              "Missing supported rates do not produce a target")

        let signal60 = 1.0 / 60
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal60, samplingFPS: 60) == 2 * signal60,
              "30-in-60 unique endpoints retain their two-tick PTS interval")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: signal60, samplingFPS: 60) == signal60 &&
              ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal60, samplingFPS: 60) == 2 * signal60,
              "40-in-60 accepts its alternating one/two-tick intervals")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 1, currentPTS: 1, samplingFPS: 60) == nil,
              "Non-increasing PTS is rejected")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 4 * signal60, samplingFPS: 60) == nil,
              "A four-tick endpoint without fresh content evidence is rejected")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 1.5 * signal60, samplingFPS: 60) == nil,
              "Irregular non-tick endpoint spacing is rejected")
        let lagging30 = ContentCadencePolicy.PairCadenceEvidence(
            contentFPS: 30, measurementEndPTS: signal60, freshForCurrentEpoch: true)
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: signal60,
              samplingFPS: 60, contentEvidence: lagging30, endpointsStrictlyUnique: false) == signal60,
              "A 60 Hz capture-adjacent pair is not vetoed by a lagging 30 FPS Follow estimate")
        let content40 = ContentCadencePolicy.PairCadenceEvidence(
            contentFPS: 40, measurementEndPTS: 2 * signal60, freshForCurrentEpoch: true)
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: signal60,
              samplingFPS: 60, contentEvidence: content40) == signal60 &&
              ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal60,
              samplingFPS: 60, contentEvidence: content40) == 2 * signal60,
              "40-in-60 alternating one/two-tick PTS remains independent of the rolling estimate")

        let signal120 = 1.0 / 120
        let twentyIn120 = 6 * signal120
        let fresh20 = ContentCadencePolicy.PairCadenceEvidence(
            contentFPS: 20, measurementEndPTS: twentyIn120, freshForCurrentEpoch: true)
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: twentyIn120,
              samplingFPS: 120, contentEvidence: fresh20, endpointsStrictlyUnique: true) == twentyIn120,
              "20-in-120 uses its real six-tick PTS period with fresh same-epoch evidence")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: twentyIn120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 19.98, measurementEndPTS: twentyIn120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == twentyIn120,
              "A slightly under-nominal 19.98 FPS evidence estimate still admits the real 20 FPS pair")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: twentyIn120,
              samplingFPS: 120) == nil,
              "20-in-120 without evidence stays rejected")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal120,
              samplingFPS: 120) == nil,
              "A two-tick pair at high sampling cannot be admitted without repeat evidence")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 60, measurementEndPTS: 2 * signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == 2 * signal120,
              "Confirmed 60 FPS content can use its real two-tick period at 120 Hz sampling")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 60, measurementEndPTS: 2 * signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: false) == nil,
              "High-rate sampling requires strictly unique endpoints even with matching evidence")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 120, measurementEndPTS: 2 * signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == nil,
              "Genuine 120 FPS evidence remains outside the supported content range")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: twentyIn120,
              samplingFPS: 120, contentEvidence: fresh20, endpointsStrictlyUnique: false) == nil,
              "Long repeated-sampling periods require strict unique endpoints")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: twentyIn120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 20, measurementEndPTS: twentyIn120, freshForCurrentEpoch: false),
              endpointsStrictlyUnique: true) == nil,
              "Stale or epoch-mismatched evidence cannot admit a long pair")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: twentyIn120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 20, measurementEndPTS: twentyIn120 + signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == nil,
              "Evidence measured after the pair endpoint is not causal")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: twentyIn120, currentPTS: 0,
              samplingFPS: 120, contentEvidence: fresh20, endpointsStrictlyUnique: true) == nil,
              "Out-of-order PTS is rejected even with matching content evidence")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 4 * signal120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 30, measurementEndPTS: 4 * signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == 4 * signal120,
              "30-in-120 uses its four-tick PTS period with fresh 30 FPS evidence")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 5 * signal120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 20, measurementEndPTS: 5 * signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == 5 * signal120,
              "A five-tick display-boundary jitter remains admissible for fresh 20 FPS content")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 10 * signal120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 20, measurementEndPTS: 10 * signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == nil,
              "Fresh content evidence rejects a long PTS pair that skipped its real unique period")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 12 * signal120,
              samplingFPS: 120,
              contentEvidence: .init(contentFPS: 10, measurementEndPTS: 12 * signal120,
                                     freshForCurrentEpoch: true),
              endpointsStrictlyUnique: true) == nil,
              "Unsupported 10 FPS content cannot use fresh evidence to enter the long-pair path")

        let base120 = 1.0 / 120
        let jitteredDelivery = [base120, base120, base120, base120 * 1.8,
                                base120, base120, base120, base120, base120,
                                base120 * 2.2, base120, base120]
        check(abs((ContentCadencePolicy.samplingFPS(from: jitteredDelivery) ?? 0) - 120) < 0.001,
              "Sparse delivery outliers do not erase a stable 120 Hz PTS clock")
        check(ContentCadencePolicy.samplingFPS(from: Array(repeating: base120, count: 7)) == nil,
              "Seven sampling intervals remain insufficient")
        let unstableDelivery = Array(repeating: base120, count: 6) +
            Array(repeating: base120 * 2, count: 6)
        check(ContentCadencePolicy.samplingFPS(from: unstableDelivery) == nil,
              "A genuinely mixed delivery cadence does not invent one clock")
        let afterRateSwitch = Array(repeating: base120, count: 9) +
            Array(repeating: base120 * 2, count: 3)
        check(ContentCadencePolicy.samplingFPS(from: afterRateSwitch) == nil,
              "Three new intervals cannot leave the estimator returning the old sampling rate")
        let settledAt60 = Array(repeating: base120, count: 3) +
            Array(repeating: base120 * 2, count: 9)
        check(abs((ContentCadencePolicy.samplingFPS(from: settledAt60) ?? 0) - 60) < 0.001,
              "A stable replacement sampling window re-establishes 60 Hz")

        let midpoint = 1.0
        let slot = 1.0 / 120
        check(ContentCadencePolicy.presentedPairIsTimely(midpointTime: midpoint, midpointDeadline: midpoint,
              endpointTime: midpoint + slot, endpointDeadline: midpoint + slot,
              slot: slot, presentationIntervalP95: slot * 1.1),
              "An on-time midpoint/endpoint pair with paced P95 qualifies")
        check(!ContentCadencePolicy.presentedPairIsTimely(midpointTime: midpoint, midpointDeadline: midpoint,
              endpointTime: midpoint + slot * 2,
              endpointDeadline: midpoint + slot, slot: slot, presentationIntervalP95: slot),
              "A late endpoint does not qualify")
        check(!ContentCadencePolicy.presentedPairIsTimely(midpointTime: midpoint + slot, midpointDeadline: midpoint,
              endpointTime: midpoint + 2 * slot,
              endpointDeadline: midpoint + 2 * slot, slot: slot, presentationIntervalP95: slot),
              "A late midpoint does not qualify even if its endpoint follows evenly")
        check(!ContentCadencePolicy.presentedPairIsTimely(midpointTime: midpoint, midpointDeadline: midpoint,
              endpointTime: midpoint + slot,
              endpointDeadline: midpoint + slot, slot: slot, presentationIntervalP95: slot * 1.5),
              "Poor presentation P95 does not qualify")

        // Statistics normalization is local and conservative; it never participates in renderer admission.
        check(ContentCadencePolicy.normalizedStatisticsRate(30.0) == 30, "An exact standard rate is unchanged")
        check(ContentCadencePolicy.normalizedStatisticsRate(29.97) == 29.97, "29.97 is preserved")
        check(ContentCadencePolicy.normalizedStatisticsRate(23.976) == 23.976, "23.976 is preserved")
        check(ContentCadencePolicy.normalizedStatisticsRate(59.94) == 59.94, "59.94 is preserved")
        check(ContentCadencePolicy.normalizedStatisticsRate(30.4) == 30, "Small jitter around 30 is normalized")
        check(ContentCadencePolicy.normalizedStatisticsRate(30.01) == 30 &&
              ContentCadencePolicy.normalizedStatisticsRate(24.01) == 24,
              "Nearby noise follows the nearest standard rate without fractional bias")
        check(ContentCadencePolicy.normalizedStatisticsRate(37.0) == 37, "Arbitrary 37 FPS remains 37")
        check(ContentCadencePolicy.normalizedStatisticsRate(37.5) == 37.5, "37.5 is not snapped to 40")
        check(ContentCadencePolicy.normalizedStatisticsRate(41.25) == 41.25, "41.25 is not snapped to 40")
        check(ContentCadencePolicy.normalizedStatisticsRate(59.0) == 59, "A distant 59 reading is not asserted as 60")
        check(ContentCadencePolicy.normalizedStatisticsRate(59.4) == 59.94,
              "Nearest-neighbor normalization keeps a close 59.4 reading on 59.94")
        check(ContentCadencePolicy.normalizedStatisticsRate(47.5) == 48, "47.5 resolves to 48")
        check(ContentCadencePolicy.normalizedStatisticsRate(50.5) == 50, "50.5 resolves to 50")
        check(ContentCadencePolicy.normalizedStatisticsRate(20.2) == 20, "Low content resolves to 20")
        let stable20a = ContentCadencePolicy.normalizedStatisticsRate(20.017)
        let stable20b = ContentCadencePolicy.normalizedStatisticsRate(20.031)
        check(stable20a == 20 && stable20b == 20,
              "Both noisy 20 FPS statistic samples normalize before exact stability comparison")
        var normalizedTracker = ContentCadencePolicy.StabilityTracker()
        for _ in 0..<4 {
            check(normalizedTracker.observe(stable20a) == nil,
                  "Normalized 20 FPS warms up below the stability threshold")
        }
        check(normalizedTracker.observe(stable20b) == 20,
              "Normalized 20.017 and 20.031 samples share the fixed reference and stabilize")

        var driftTracker = ContentCadencePolicy.StabilityTracker()
        check(driftTracker.observe(37) == nil &&
              driftTracker.reference == 37 && driftTracker.streak == 1,
              "Nonstandard 37 FPS establishes its own fixed reference")
        check(driftTracker.observe(37.004) == nil &&
              driftTracker.observe(37.008) == nil,
              "Small steps within tolerance keep the original 37 FPS reference")
        check(driftTracker.observe(37.012) == nil &&
              driftTracker.reference == 37.012 && driftTracker.streak == 1,
              "Cumulative nonstandard drift beyond 0.01 resets instead of walking to a stable false rate")

        var constant37 = ContentCadencePolicy.StabilityTracker()
        for _ in 0..<4 {
            check(constant37.observe(37) == nil, "Constant 37 FPS warms up")
        }
        check(constant37.observe(37.005) == 37,
              "Constant nonstandard 37 FPS remains stable at its reference")
        constant37.reset()
        check(constant37.reference == nil && constant37.streak == 0 &&
              constant37.observe(37) == nil,
              "Tracker reset drops the reference so a new source cannot inherit stability")
        for invalid in [0.0, -5, Double.nan, Double.infinity] {
            check(ContentCadencePolicy.normalizedStatisticsRate(invalid) == nil, "Invalid statistic is not normalized")
        }
        let missing: Double? = nil
        check(ContentCadencePolicy.normalizedStatisticsRate(missing) == nil, "Missing statistic is not normalized")
print("ContentCadencePolicy: \(checks) checks passed (split sampling/content cadence, fresh PTS evidence, statistics normalization, and presentation qualification).")
    }
}
