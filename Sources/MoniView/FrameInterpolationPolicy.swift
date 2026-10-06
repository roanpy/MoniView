import Foundation

enum FrameInterpolationMode: String, CaseIterable, Identifiable, Codable {
    case off = "关闭"
    case efficient = "流畅 · 720p"
    case quality = "清晰 · 1080p"

    var id: String { rawValue }
    // Preserve the persisted raw value from early development builds.
    var title: String { self == .efficient ? "流畅 · 自适应" : rawValue }
    var longEdgeCap: Int? {
        switch self {
        case .off: return nil
        case .efficient: return 1280
        case .quality: return 1920
        }
    }
}

/// Pure admission and input sizing policy. The renderer owns displayLink, buffers and its
/// ONE shared GPU semaphore. No queue, timer, platform capability inference or fake frames.
enum FrameInterpolationPolicy {
    static let defaultEnabled = false
    static let phase = 0.5
    static let budgetFraction = 0.9
    static let pairBudgetFraction = 0.8
    static let overloadCooldownSeconds = 2.0

    /// Endpoints are usually much cheaper than inference. Keep a 10% per-slot
    /// deadline margin and 20% for the complete midpoint + source cycle.
    static func costsFit(midpoint: Double, source: Double, slot: Double) -> Bool {
        guard midpoint.isFinite, source.isFinite, slot.isFinite,
              midpoint >= 0, source >= 0, slot > 0 else { return false }
        return midpoint <= slot * budgetFraction && source <= slot * budgetFraction &&
            midpoint + source <= 2 * slot * pairBudgetFraction
    }

    struct Dimensions: Equatable {
        let width: Int
        let height: Int
    }

    /// Preserve aspect ratio up to <2 pixels of downward even rounding on each axis.
    /// Portrait uses the same long-edge budget. Never upscale a small source.
    static func targetDimensions(width: Int, height: Int, mode: FrameInterpolationMode, inputFPS: Double? = nil, maximumLongEdge: Int? = nil) -> Dimensions? {
        guard width >= 2, height >= 2, var cap = mode.longEdgeCap else { return nil }
        // Higher input cadence halves the useful inference budget. A smaller working
        // frame keeps Smooth inexpensive; runtime measurements still gate admission.
        if mode == .efficient, let fps = inputFPS, fps.isFinite, fps > 40 { cap = min(cap, 960) }
        if let maximumLongEdge { guard maximumLongEdge >= 2 else { return nil }; cap = min(cap, maximumLongEdge) }
        let scale = min(1, Double(cap) / Double(max(width, height)))
        let targetWidth = Int((Double(width) * scale / 2).rounded(.down)) * 2
        let targetHeight = Int((Double(height) * scale / 2).rounded(.down)) * 2
        guard targetWidth >= 2, targetHeight >= 2 else { return nil }
        return Dimensions(width: targetWidth, height: targetHeight)
    }

    static func reducedLongEdge(after current: Int) -> Int? {
        [1280, 960, 854, 640].first { $0 < current }
    }

    /// Preserve fractional broadcast rates; normalize only the small UVC overshoot
    /// around nominal 60. Callers should prefer configured rate / precise PTS cadence
    /// over integer FPS counters, and use the result consistently for slot timing.
    static func nominalInputFPS(_ inputFPS: Double) -> Double? {
        guard inputFPS.isFinite, inputFPS >= 20, inputFPS <= 60.25 else { return nil }
        return min(inputFPS, 60)
    }

    /// inputValid includes stable measured cadence, valid increasing PTS and no stream
    /// discontinuity. The 0.5 Hz tolerance admits nominal clock differences only; actual
    /// missed presentation slots must still fall back, never count duplicated frames.
    static func eligibility(runtimeSupported: Bool, inputFPS: Double,
                            displayFPS: Double, inputValid: Bool) -> Bool {
        guard runtimeSupported, inputValid, let nominal = nominalInputFPS(inputFPS),
              displayFPS.isFinite, displayFPS > 0 else { return false }
        return 2 * nominal <= displayFPS + 0.5
    }

}
