import Foundation

@main
struct ContentCadencePolicyTests {
    static var checks = 0

    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        checks += 1
    }

    static func main() {
        check(ContentCadencePolicy.nextStabilityStreak(previous: nil, current: 30, streak: 4) == 0,
              "First cadence sample starts a fresh streak")
        check(ContentCadencePolicy.nextStabilityStreak(previous: 29.97, current: 29.975, streak: 4) == 5,
              "Small fractional-rate noise retains the stable streak")
        check(ContentCadencePolicy.nextStabilityStreak(previous: 29.97, current: 30.02, streak: 4) == 0,
              "A changed cadence resets stability")
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
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal60, signalFPS: 60) == 2 * signal60,
              "30-in-60 unique endpoints retain their two-tick PTS interval")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: signal60, signalFPS: 60) == signal60 &&
              ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 2 * signal60, signalFPS: 60) == 2 * signal60,
              "40-in-60 accepts its alternating one/two-tick intervals")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 1, currentPTS: 1, signalFPS: 60) == nil,
              "Non-increasing PTS is rejected")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 4 * signal60, signalFPS: 60) == nil,
              "A stale four-tick endpoint is rejected")
        check(ContentCadencePolicy.uniquePairPeriod(previousPTS: 0, currentPTS: 1.5 * signal60, signalFPS: 60) == nil,
              "Irregular non-tick endpoint spacing is rejected")

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

                // Snapping: jitter between standard rates must resolve to the nearest one.
        check(ContentCadencePolicy.quantizedRate(30.0) == 30, "An exact standard rate is unchanged")
        check(ContentCadencePolicy.quantizedRate(29.97) == 29.97, "Fractional standard rate is preserved")
        check(ContentCadencePolicy.quantizedRate(30.4) == 30, "Slight overshoot resolves to 30")
        check(ContentCadencePolicy.quantizedRate(37.5) == 30, "Midpoint drift resolves downward, since jitter only inflates the estimate")
        check(ContentCadencePolicy.quantizedRate(41.25) == 40, "Clear overshoot still resolves to 40")
        check(ContentCadencePolicy.quantizedRate(20.2) == 20, "Low content resolves to 20")
        check(ContentCadencePolicy.quantizedRate(33.0) == 30, "33 FPS resolves to 30")
        for invalid in [0.0, -5, Double.nan, Double.infinity] {
            check(ContentCadencePolicy.quantizedRate(invalid) == nil, "Invalid rate is not quantized")
        }
        let missing: Double? = nil
        check(ContentCadencePolicy.quantizedRate(missing) == nil, "Missing rate is not quantized")
print("ContentCadencePolicy: \(checks) checks passed (stability, fractional rate selection, unique PTS cadence, and presentation qualification).")
    }
}
