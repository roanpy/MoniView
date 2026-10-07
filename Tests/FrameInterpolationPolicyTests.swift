import Foundation

@main
struct FrameInterpolationPolicyTests {
    typealias P = FrameInterpolationPolicy
    static var checks = 0

    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        checks += 1
    }

    static func admitted(_ fps: Double, _ display: Double,
                         supported: Bool = true, valid: Bool = true) -> Bool {
        P.eligibility(runtimeSupported: supported, inputFPS: fps,
                      displayFPS: display, inputValid: valid)
    }

    static func main() throws {
        check(!P.defaultEnabled && P.phase == 0.5, "Default off, one midpoint")
        check(P.budgetFraction == 0.9 && P.pairBudgetFraction == 0.9 && P.overloadCooldownSeconds == 2, "Renderer budget constants")
        check(P.costsFit(midpoint: 0.007, source: 0.001, slot: 1/120), "Unequal work fits whole pair and both deadlines")
        check(P.costsFit(midpoint: 0.0095, source: 0.0023, slot: 1/120), "Longer inference fits 60-to-120 pair encoded ahead of presentation")
        check(!P.costsFit(midpoint: 0.0145, source: 0.0023, slot: 1/120), "Inference lead and pair overload remain bounded")
        check(!P.costsFit(midpoint: 0.011, source: 0.005, slot: 1/120), "Whole-pair overload rejected")
        check(P.costsFit(midpoint: 0.0145, source: 0.0023, slot: 1/60), "Same 1080p work fits 30-to-60 cadence")
        check(P.preserveFailureCooldown(forceChanged: true, modeChanged: false, failureActive: true, until: 12, now: 10) == 12, "Force retains active GPU failure cooldown")
        check(P.preserveFailureCooldown(forceChanged: true, modeChanged: false, failureActive: false, until: 12, now: 10) == 0, "Force clears budget-only cooldown")
        check(P.preserveFailureCooldown(forceChanged: true, modeChanged: false, failureActive: true, until: 9, now: 10) == 0, "Expired failure cooldown does not persist")
        check(P.preserveFailureCooldown(forceChanged: true, modeChanged: true, failureActive: true, until: 12, now: 10) == 0, "Actual session change resets lifecycle")
        check(P.preserveFailureCooldown(forceChanged: false, modeChanged: false, failureActive: true, until: .nan, now: 10) == 0, "Invalid cooldown cannot persist")
        // The multi-phase overload is what a 3x pair is admitted through, so its own
        // boundaries need to be pinned: two midpoints cost twice as much as one.
        check(P.allowsMeasuredPair(midpoints: [0.005, 0.005], source: 0.006, slot: 0.02, force: false, deadlineFits: true),
              "A 3x pair whose two midpoints fit is admitted")
        // Each midpoint stays under its individual cap (0.03) but their sum with the endpoint
        // exceeds the period budget (3 x 0.02 x 0.9 = 0.054), which is the case a per-midpoint
        // check would have wrongly admitted.
        check(!P.allowsMeasuredPair(midpoints: [0.025, 0.025], source: 0.010, slot: 0.02, force: false, deadlineFits: true),
              "Two midpoints that overrun the period budget are rejected")
        check(P.allowsMeasuredPair(midpoints: [0.025, 0.025], source: 0.010, slot: 0.02, force: true, deadlineFits: true),
              "Force still admits an overrun pair")
        check(!P.allowsMeasuredPair(midpoints: [0.005, 0.005], source: 0.006, slot: 0.02, force: true, deadlineFits: false),
              "Force cannot admit a missed deadline")
        check(!P.allowsMeasuredPair(midpoints: [], source: 0.006, slot: 0.02, force: true, deadlineFits: true),
              "An empty phase list is never admitted")
        check(!P.allowsMeasuredPair(midpoints: [0.005, .nan], source: 0.006, slot: 0.02, force: true, deadlineFits: true),
              "An invalid midpoint rejects the pair")
        check(P.allowsMeasuredPair(midpoint: 0.005, source: 0.006, slot: 0.02, force: false, deadlineFits: true),
              "The single-midpoint overload delegates to the same rule")
        check(P.allowsMeasuredPair(midpoint: 0.030, source: 0.003, slot: 1/120, force: true, deadlineFits: true), "Force ignores measured overload")
        check(!P.allowsMeasuredPair(midpoint: 0.030, source: 0.003, slot: 1/120, force: false, deadlineFits: true), "Automatic protects whole pair budget")
        check(!P.allowsMeasuredPair(midpoint: 0.030, source: 0.003, slot: 1/120, force: true, deadlineFits: false), "Force cannot present an expired pair")
        check(!P.allowsMeasuredPair(midpoint: .nan, source: 0.003, slot: 1/120, force: true, deadlineFits: true), "Force rejects invalid measurement")
        for invalid in [-1.0, .nan, .infinity] {
            check(!P.costsFit(midpoint: invalid, source: 0.001, slot: 1/120), "Invalid inference cost")
            check(!P.costsFit(midpoint: 0.001, source: invalid, slot: 1/120), "Invalid endpoint cost")
            check(!P.costsFit(midpoint: 0.001, source: 0.001, slot: invalid), "Invalid slot")
        }
        check(P.targetDimensions(width: 1920, height: 1080, mode: .efficient, inputFPS: 60, maximumLongEdge: 854) == P.Dimensions(width: 854, height: 480), "Adaptive size respects aspect and even rounding")
        check(P.targetDimensions(width: 1920, height: 1080, mode: .efficient, maximumLongEdge: 1) == nil, "Invalid adaptive cap")
        check(P.reducedLongEdge(after: 960) == 854 && P.reducedLongEdge(after: 854) == nil, "No excessive soft-midpoint downscaling")
        check(FrameInterpolationMode.allCases.count == 5, "Off plus four cost tiers")
        for mode in FrameInterpolationMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(FrameInterpolationMode.self, from: data)
            check(decoded == mode && mode.id == mode.rawValue, "Persisted mode roundtrip")
        }
        for fps in [20.0, 23.976, 24, 25, 29.97, 30, 45, 50, 59.94, 60] {
            check(P.nominalInputFPS(fps) == fps, "Preserve exact/fractional cadence")
            check(admitted(fps, fps * 2), "Full 2x capacity")
        }
        for fps in [60.00024, 60.01, 60.25] {
            check(P.nominalInputFPS(fps) == 60, "Normalize slight UVC 60 overshoot")
            check(admitted(fps, 120), "Nominal 60 to 120 admitted")
            check(!admitted(fps, 60), "60 Hz cannot display nominal 120")
        }
        for invalid in [0.0, -1, 19.99, 60.25001, 90, 120, Double.nan, Double.infinity, -Double.infinity] {
            check(P.nominalInputFPS(invalid) == nil, "Reject unsupported source rate")
            check(!admitted(invalid, 240), "Invalid source never admitted")
        }
        for invalid in [0.0, -1, Double.nan, Double.infinity, -Double.infinity] {
            check(!admitted(30, invalid), "Invalid display never admitted")
        }
        check(admitted(30, 60), "Local 30 to 60 case")
        check(!admitted(45, 60) && !admitted(50, 60), "45/50 source cannot double on a 60 Hz display")
        check(admitted(50, 120), "50 to 100 fits 120 Hz display")
        check(P.targetDimensions(width: 1920, height: 1080, mode: .balanced, inputFPS: 60) == P.Dimensions(width: 1280, height: 720), "Balanced keeps 720p at high cadence")
        check(!admitted(60, 60), "Local display cannot enable 60 to 120")
        check(admitted(29.97, 59.94), "Fractional 30 to 60")
        check(admitted(59.94, 119.88), "Fractional 60 to 120")
        check(admitted(30, 59.5), "Inclusive half-Hz admission tolerance")
        check(!admitted(30, 59.499), "Outside display tolerance")
        check(admitted(60.00024, 119.5), "Tolerance applied to normalized nominal")
        check(!admitted(60.00024, 119.499), "Nominal tolerance remains bounded")
        check(!admitted(30, 60, supported: false), "Unsupported stays unavailable")
        check(!admitted(30, 60, valid: false), "Unstable/invalid PTS cadence stays native")

        check(P.targetDimensions(width: 3840, height: 2160, mode: .efficient, inputFPS: 60) == P.Dimensions(width: 960, height: 540), "High-rate efficient budget")
        check(P.targetDimensions(width: 3840, height: 2160, mode: .flowBlend, inputFPS: 60) == P.Dimensions(width: 1280, height: 720), "High-rate flow-blend holds the measured 720p rung")
        check(P.targetDimensions(width: 3840, height: 2160, mode: .flowBlend, inputFPS: 30) == P.Dimensions(width: 1920, height: 1080), "Flow-blend keeps 1080p at 30 FPS")
        check(P.targetDimensions(width: 1920, height: 1080, mode: .flowBlend, inputFPS: 60) == P.Dimensions(width: 1920, height: 1080), "Flow-blend keeps a 1080p source native at high rate instead of paying the rescale")
        check(P.targetDimensions(width: 1920, height: 1080, mode: .flowBlend, inputFPS: 120) == P.Dimensions(width: 1920, height: 1080), "Native 1080p also holds at 120 FPS input rate")
        check(P.targetDimensions(width: 2560, height: 1440, mode: .flowBlend, inputFPS: 60) == P.Dimensions(width: 1280, height: 720), "Above 1080p still steps down at high rate")
        check(P.targetDimensions(width: 1280, height: 720, mode: .flowBlend, inputFPS: 60) == P.Dimensions(width: 1280, height: 720), "A 720p source is never upscaled")
        check(P.targetDimensions(width: 640, height: 480, mode: .flowBlend, inputFPS: 60) == P.Dimensions(width: 640, height: 480), "Flow-blend no enlargement")
        check(P.targetDimensions(width: 640, height: 480, mode: .efficient, inputFPS: 60) == P.Dimensions(width: 640, height: 480), "High-rate no enlargement")
        check(P.targetDimensions(width: 3840, height: 2160, mode: .quality, inputFPS: 60) == P.Dimensions(width: 1920, height: 1080), "Quality cap unchanged")
        check(P.targetDimensions(width: 3840, height: 2160, mode: .efficient) == P.Dimensions(width: 1280, height: 720), "4K to efficient")
        check(P.targetDimensions(width: 3840, height: 2160, mode: .quality) == P.Dimensions(width: 1920, height: 1080), "4K to quality")
        check(P.targetDimensions(width: 2160, height: 3840, mode: .quality) == P.Dimensions(width: 1080, height: 1920), "Portrait cap")
        check(P.targetDimensions(width: 640, height: 480, mode: .quality) == P.Dimensions(width: 640, height: 480), "No enlargement")
        check(P.targetDimensions(width: 641, height: 481, mode: .quality) == P.Dimensions(width: 640, height: 480), "Even rounding")
        check(P.targetDimensions(width: 1920, height: 1080, mode: .off) == nil, "Disabled dimensions")
        for invalid in [-1, 0, 1] {
            check(P.targetDimensions(width: invalid, height: 1080, mode: .quality) == nil, "Invalid width")
            check(P.targetDimensions(width: 1920, height: invalid, mode: .quality) == nil, "Invalid height")
        }
        check(P.targetDimensions(width: Int.max, height: 2, mode: .quality) == nil, "Extreme aspect safely rejected")
        for (width, height) in [(2, 2), (640, 480), (641, 481), (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (4096, 2160), (2160, 3840), (3440, 1440)] {
            for mode in [FrameInterpolationMode.efficient, .balanced, .quality, .flowBlend] {
                let result = P.targetDimensions(width: width, height: height, mode: mode)!
                check(result.width % 2 == 0 && result.height % 2 == 0, "Both planes even")
                check(result.width <= width && result.height <= height, "No upscaling")
                check(max(result.width, result.height) <= mode.longEdgeCap!, "Long-edge cap")
                let scale = min(1, Double(mode.longEdgeCap!) / Double(max(width, height)))
                check(abs(Double(result.width) - Double(width) * scale) < 2.000001 &&
                      abs(Double(result.height) - Double(height) * scale) < 2.000001, "Aspect within even-rounding error")
            }
        }
        check(P.processingCost(cpu: 2, gpu: 3, encodeToCompletion: 10) == 10, "Queue/processor wait included")
        check(P.processingCost(cpu: 2, gpu: 3, encodeToCompletion: 4) == 5, "GPU span remains a lower bound")
        check(P.processingCost(cpu: 0, gpu: 0, encodeToCompletion: 0) == 0, "Zero interval")
        for invalid in [-1.0, .infinity, .nan] {
            check(P.processingCost(cpu: invalid, gpu: 1, encodeToCompletion: 1).isInfinite, "Invalid CPU rejects")
            check(P.processingCost(cpu: 1, gpu: invalid, encodeToCompletion: 1).isInfinite, "Invalid GPU rejects")
            check(P.processingCost(cpu: 1, gpu: 1, encodeToCompletion: invalid).isInfinite, "Invalid completion interval rejects")
        }
        let elapsedMidpoint = P.processingCost(cpu: 0.0006, gpu: 0.0001, encodeToCompletion: 0.018)
        check(!P.costsFit(midpoint: elapsedMidpoint, source: 0.001, slot: 1.0 / 120), "Tiny GPU span cannot hide 18ms completion")
        check(P.allowsMeasuredPair(midpoint: elapsedMidpoint, source: 0.001, slot: 1.0 / 120, force: true, deadlineFits: true), "Force still bypasses real measured budget")
        // Temporal multiplier selection: the smallest step that reaches the target.
        check(P.multiplier(contentFPS: 30, targetFPS: 60, displayFPS: 120) == 2, "30 FPS content keeps the 2x path")
        check(P.multiplier(contentFPS: 20, targetFPS: 60, displayFPS: 120) == 3, "20 FPS content takes 3x to reach 60")
        check(P.multiplier(contentFPS: 24, targetFPS: 60, displayFPS: 120) == 3, "24 FPS content takes 3x to reach 60")
        check(P.multiplier(contentFPS: 30, targetFPS: 60, displayFPS: 60) == 2, "60 Hz display still allows 30 to 60")
        check(P.multiplier(contentFPS: 20, targetFPS: 60, displayFPS: 60) == 3, "60 Hz display allows 20 to 60")
        check(P.multiplier(contentFPS: 20, targetFPS: 60, displayFPS: 60.0 / 2) == 1, "Unreachable target falls back to no work")
        check(P.multiplier(contentFPS: 45, targetFPS: 60, displayFPS: 120) == 2, "45 FPS content still doubles when the display allows it")
        // lowRateThreshold is documented as never changing a result below 74.5 Hz. Pin the
        // boundary so the comment and the code cannot drift apart: 24.9 FPS still earns the
        // third phase at 74.5 Hz, and 25.0 FPS is held back to 2x at exactly that rate.
        check(P.multiplier(contentFPS: 24.9, targetFPS: 60, displayFPS: 74.5) == 3,
              "Just under the threshold still takes the third phase at the boundary refresh rate")
        check(P.multiplier(contentFPS: 25.0, targetFPS: 60, displayFPS: 74.5) == 2,
              "The threshold itself is held to 2x even where the display could hold 3x")
        check(P.multiplier(contentFPS: 25.0, targetFPS: 60, displayFPS: 74.4) == 2,
              "Below 74.5 Hz the display rejects 3x before the threshold is consulted")
        for invalid in [0.0, -1, Double.nan, Double.infinity] {
            check(P.multiplier(contentFPS: invalid, targetFPS: 60, displayFPS: 120) == 1, "Invalid content rate")
        }
        check(P.midpointPhases(multiplier: 2) == [Float(0.5)], "2x generates one midpoint at the middle")
        check(P.midpointPhases(multiplier: 3) == [Float(1.0) / 3.0, Float(2.0) / 3.0], "3x generates two midpoints")
        for invalid in [1.0, 2.5, 4.0, 0.0, Double.nan] {
            check(P.midpointPhases(multiplier: invalid).isEmpty, "Invalid multiplier yields no phases")
        }
        // The step is chosen from a tolerant cadence estimate while the period comes from
        // measured PTS. Noise that reads a 60 Hz pair as 20 FPS content must not buy a third
        // presentation the display has no room for.
        check(P.multiplierFittingPair(3, pairPeriod: 1.0 / 20, displayFPS: 120) == 3, "20 FPS content fits 3x on a 120 Hz display")
        check(P.multiplierFittingPair(3, pairPeriod: 1.0 / 20, displayFPS: 60) == 3, "20 FPS content fits 3x on a 60 Hz display")
        check(P.multiplierFittingPair(3, pairPeriod: 1.0 / 60, displayFPS: 120) == 2, "A 60 Hz pair only has room for 2x")
        check(P.multiplierFittingPair(3, pairPeriod: 1.0 / 60, displayFPS: 60) == 1, "A 60 Hz pair on a 60 Hz display cannot be interpolated")
        check(P.multiplierFittingPair(2, pairPeriod: 1.0 / 30, displayFPS: 60) == 2, "30 FPS content keeps 2x on a 60 Hz display")
        check(P.multiplierFittingPair(3, pairPeriod: 1.0 / 59.94, displayFPS: 60) == 1, "A 59.94 pair still leaves no slot on a 60 Hz grid")
        check(P.multiplierFittingPair(3, pairPeriod: 1.0 / 29.97, displayFPS: 60) == 2, "A 29.97 pair fits 2x and not 3x")
        // The renderer admits a pair only when the measured period holds two presentations, so
        // every caller that gets past that guard reads 2 or 3 here. These pin the boundary the
        // guard tests, including the PTS jitter window the cadence policy still accepts.
        check(P.multiplierFittingPair(3, pairPeriod: 0.0294, displayFPS: 60) == 1,
              "A jittery 2-tick pair at 29.4 ms holds no midpoint on a 60 Hz panel")
        check(P.multiplierFittingPair(3, pairPeriod: 0.0331, displayFPS: 60) == 2,
              "The same pair at 33.1 ms holds exactly one midpoint")
        check(P.multiplierFittingPair(3, pairPeriod: 0.0147, displayFPS: 120) == 1,
              "A 1-tick pair at 68 Hz content has no room even on a 120 Hz panel")
        check(P.multiplierFittingPair(3, pairPeriod: 0.0334, displayFPS: 120) == 3,
              "A 33.4 ms pair holds all three presentations on a 120 Hz panel")
        check(P.multiplier(contentFPS: 1 / 0.05, targetFPS: 60, displayFPS: 120) == 3,
              "A 50 ms unique-pair PTS interval requests 3x for a 60 FPS target")
        check(P.multiplier(contentFPS: 1 / (1.0 / 60.0), targetFPS: 60, displayFPS: 120) == 2,
              "A 60 Hz signal cadence keeps the 2x request")
        for invalid in [1.0, 0.0, -3, Double.nan] {
            check(P.multiplierFittingPair(invalid, pairPeriod: 1.0 / 20, displayFPS: 120) == 1, "Invalid multiplier yields no step")
        }
        for invalid in [0.0, -1, Double.nan, Double.infinity] {
            check(P.multiplierFittingPair(3, pairPeriod: invalid, displayFPS: 120) == 1, "Invalid pair period yields no step")
            check(P.multiplierFittingPair(3, pairPeriod: 1.0 / 20, displayFPS: invalid) == 1, "Invalid display rate yields no step")
        }
        check(P.costsFit(midpoints: [0.005, 0.005], source: 0.006, slot: 0.02), "Two midpoints fit a long slot")
        check(!P.costsFit(midpoints: [0.04, 0.04], source: 0.006, slot: 0.02), "Midpoints past the individual cap are rejected")
        check(!P.costsFit(midpoints: [], source: 0.001, slot: 0.02), "An empty midpoint list is rejected")
        let flow3Phases = [1.0 / 3.0, 2.0 / 3.0]
        check(P.pairCost(generationBatch: 0.0038, subsequentPresentation: 0.0002,
                         sourceEndpoint: 0.0001, generatedPhaseCount: 2).map { abs($0 - 0.0041) < 1e-12 } ?? false,
              "3x counts the combined generation batch once, then the cached phase and endpoint")
        check(P.costsFit(generationBatch: 0.0038, subsequentPresentation: 0.0002,
                         sourceEndpoint: 0.0001, phases: flow3Phases, pairPeriod: 0.05),
              "3x measured command costs fit their actual slots and the pair budget")
        check(!P.allowsMeasuredPair(generationBatch: 0.0038, subsequentPresentation: nil,
                                    sourceEndpoint: 0.0001, phases: flow3Phases, pairPeriod: 0.05,
                                    force: false, deadlineFits: true),
              "Automatic 3x waits for a measured cached-phase presentation cost")
        check(P.pairCost(generationBatch: 0.004, subsequentPresentation: nil,
                         sourceEndpoint: 0.001, generatedPhaseCount: 1).map { abs($0 - 0.005) < 1e-12 } ?? false,
              "2x keeps one generated command plus its source endpoint")
        check(P.costsFit(generationBatch: 0.004, subsequentPresentation: nil,
                         sourceEndpoint: 0.001, phases: [0.5], pairPeriod: 1.0 / 30.0),
              "2x remains admitted without requiring a cached-phase sample")
        check(P.allowsMeasuredPair(generationBatch: 0.004, subsequentPresentation: nil,
                                   sourceEndpoint: 0.001, phases: [0.5], pairPeriod: 1.0 / 30.0,
                                   force: false, deadlineFits: true),
              "The batch-aware 2x admission path stays enabled")
        check(P.allowsMeasuredPair(generationBatch: 0.03, subsequentPresentation: 0.03,
                                   sourceEndpoint: 0.02, phases: flow3Phases, pairPeriod: 0.05,
                                   force: true, deadlineFits: true),
              "Force bypasses measured cost limits")
        check(!P.allowsMeasuredPair(generationBatch: 0.001, subsequentPresentation: 0.001,
                                    sourceEndpoint: 0.001, phases: flow3Phases, pairPeriod: 0.05,
                                    force: true, deadlineFits: false),
              "Force cannot bypass a missed presentation deadline")
        check(P.costsFit(generationBatch: 0.003, subsequentPresentation: nil,
                         sourceEndpoint: 0.001, phases: [1.0 / 3.0], pairPeriod: 0.05),
              "A partial 3x result keeps its real 1/3 phase interval")
        check(P.prefersAdjacentInputPair(inputFPS: 59.03, signalFPS: 60,
                                         evidenceFreshForCurrentEpoch: true,
                                         adjacentFramesAreDifferent: true),
              "Fresh 60 Hz input evidence keeps raw adjacent pairing when rendering drops frames")
        check(!P.prefersAdjacentInputPair(inputFPS: 30, signalFPS: 60,
                                          evidenceFreshForCurrentEpoch: true,
                                          adjacentFramesAreDifferent: false),
              "Repeated 30 Hz content stays on first-copy unique pairing")
        check(!P.prefersAdjacentInputPair(inputFPS: 30, signalFPS: 60,
                                          evidenceFreshForCurrentEpoch: true,
                                          adjacentFramesAreDifferent: true),
              "A 30 Hz estimate cannot be mistaken for 60 Hz merely on a transition frame")
        check(!P.prefersAdjacentInputPair(inputFPS: 20, signalFPS: 60,
                                          evidenceFreshForCurrentEpoch: true,
                                          adjacentFramesAreDifferent: false),
              "Repeated 20 Hz content does not use the capture-adjacent 60 Hz period")
        check(!P.prefersAdjacentInputPair(inputFPS: nil, signalFPS: 60,
                                          evidenceFreshForCurrentEpoch: false,
                                          adjacentFramesAreDifferent: true) &&
              P.multiplier(contentFPS: 30, targetFPS: 60, displayFPS: 120) == 2,
              "Unknown input cadence cannot promote to 120, while a valid unique pair still doubles")
        check(!P.prefersAdjacentInputPair(inputFPS: 60, signalFPS: 60,
                                          evidenceFreshForCurrentEpoch: false,
                                          adjacentFramesAreDifferent: true),
              "Stale or epoch-mismatched cadence cannot select raw adjacent pairing")
        check(!P.prefersAdjacentInputPair(inputFPS: 60, signalFPS: 60,
                                          evidenceFreshForCurrentEpoch: true,
                                          adjacentFramesAreDifferent: false),
              "Strictly identical adjacent frames never select raw adjacent interpolation")
        check(!P.prefersAdjacentInputPair(inputFPS: 55, signalFPS: 60,
                                          evidenceFreshForCurrentEpoch: true,
                                          adjacentFramesAreDifferent: true),
              "Cadence materially below signal rate stays on unique-content timing")
        check(P.multiplier(contentFPS: 20, targetFPS: 60, displayFPS: 120) == 3,
              "A genuine 20 Hz unique pair still requests 3x for 60 Hz output")
        check(P.eligibility(runtimeSupported: true, inputFPS: 20, displayFPS: 60, inputValid: true, multiplier: 3), "20 FPS to 60 admitted at 3x")
        check(!P.eligibility(runtimeSupported: true, inputFPS: 20, displayFPS: 60, inputValid: true, multiplier: 4), "Out of range multiplier rejected")
        print("FrameInterpolationPolicy: \(checks) checks passed (admission/sizing/processing interval only; no renderer, GPU or presentation claim).")
    }
}
