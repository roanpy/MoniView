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
        for invalid in [-1.0, .nan, .infinity] {
            check(!P.costsFit(midpoint: invalid, source: 0.001, slot: 1/120), "Invalid inference cost")
            check(!P.costsFit(midpoint: 0.001, source: invalid, slot: 1/120), "Invalid endpoint cost")
            check(!P.costsFit(midpoint: 0.001, source: 0.001, slot: invalid), "Invalid slot")
        }
        check(P.targetDimensions(width: 1920, height: 1080, mode: .efficient, inputFPS: 60, maximumLongEdge: 854) == P.Dimensions(width: 854, height: 480), "Adaptive size respects aspect and even rounding")
        check(P.targetDimensions(width: 1920, height: 1080, mode: .efficient, maximumLongEdge: 1) == nil, "Invalid adaptive cap")
        check(P.reducedLongEdge(after: 960) == 854 && P.reducedLongEdge(after: 854) == nil, "No excessive soft-midpoint downscaling")
        check(FrameInterpolationMode.allCases.count == 3, "Off plus two cost tiers")
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
            for mode in [FrameInterpolationMode.efficient, .quality] {
                let result = P.targetDimensions(width: width, height: height, mode: mode)!
                check(result.width % 2 == 0 && result.height % 2 == 0, "Both planes even")
                check(result.width <= width && result.height <= height, "No upscaling")
                check(max(result.width, result.height) <= mode.longEdgeCap!, "Long-edge cap")
                let scale = min(1, Double(mode.longEdgeCap!) / Double(max(width, height)))
                check(abs(Double(result.width) - Double(width) * scale) < 2.000001 &&
                      abs(Double(result.height) - Double(height) * scale) < 2.000001, "Aspect within even-rounding error")
            }
        }
        print("FrameInterpolationPolicy: \(checks) checks passed (admission/sizing only; no renderer, GPU or presentation claim).")
    }
}
