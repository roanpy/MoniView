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
        print("FrameInterpolationPolicy: \(checks) checks passed (admission/sizing/processing interval only; no renderer, GPU or presentation claim).")
    }
}
