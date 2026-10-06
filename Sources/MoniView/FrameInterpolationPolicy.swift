import Foundation

enum FrameInterpolationMode: String, CaseIterable, Identifiable, Codable {
    case off = "关闭"
    case efficient = "流畅 · 720p"
    case balanced = "均衡 · 720p"
    case quality = "清晰 · 1080p"

    var id: String { rawValue }
    // Preserve the persisted raw value from early development builds.
    var title: String {
        switch self {
        case .off: return rawValue
        case .efficient: return "低 · 自适应"
        case .balanced: return "中 · 最高720p"
        case .quality: return "高 · 最高1080p"
        }
    }
    var longEdgeCap: Int? {
        switch self {
        case .off: return nil
        case .efficient, .balanced: return 1280
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
    static let pairBudgetFraction = 0.9
    static let midpointBudgetFraction = 1.5
    static let overloadCooldownSeconds = 2.0

    /// FrameProcessor work/queue waits can outlive the command's GPU timestamp span.
    /// Use encode start through completion callback, including command/queue waits.
    /// This excludes drawable acquisition, actual presentation, main-thread completion
    /// bookkeeping and capture transport; it is not total renderer slot occupancy.
    static func processingCost(cpu: Double, gpu: Double, encodeToCompletion: Double) -> Double {
        guard cpu.isFinite, gpu.isFinite, encodeToCompletion.isFinite,
              cpu >= 0, gpu >= 0, encodeToCompletion >= 0 else { return .infinity }
        return max(cpu + gpu, encodeToCompletion)
    }

    /// Inference may span more than one display slot when encoded ahead of its
    /// presentation. Bound that lead AND the whole pair; the cheap endpoint still
    /// needs to fit its own slot. Deadline checks in the renderer remain mandatory.
    static func costsFit(midpoint: Double, source: Double, slot: Double) -> Bool {
        guard midpoint.isFinite, source.isFinite, slot.isFinite,
              midpoint >= 0, source >= 0, slot > 0 else { return false }
        return midpoint <= slot * midpointBudgetFraction && source <= slot * budgetFraction &&
            midpoint + source <= 2 * slot * pairBudgetFraction
    }

    /// Force ignores measured budget only. A finite measurement and a feasible
    /// presentation deadline are still required; display/input eligibility is separate.
    static func allowsMeasuredPair(midpoint: Double, source: Double, slot: Double, force: Bool, deadlineFits: Bool) -> Bool {
        guard deadlineFits, midpoint.isFinite, source.isFinite, slot.isFinite,
              midpoint >= 0, source >= 0, slot > 0 else { return false }
        return force || costsFit(midpoint: midpoint, source: source, slot: slot)
    }

    /// Force can retry a budget failure immediately, but cannot clear an active
    /// GPU failure cooldown. A real mode/session change has its own reset lifecycle.
    static func preserveFailureCooldown(forceChanged: Bool, modeChanged: Bool, failureActive: Bool, until: Double, now: Double) -> Double {
        guard forceChanged, !modeChanged, failureActive, until.isFinite, now.isFinite, until > now else { return 0 }
        return until
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
        // Below 854px, enlarged midpoints visibly pulse between soft and sharp.
        [1280, 960, 854].first { $0 < current }
    }

    /// Next higher working-size rung after a step-down; nil means the mode ceiling.
    static func raisedLongEdge(after current: Int) -> Int? {
        [640, 854, 960, 1280].first { $0 > current }
    }

    /// Effective long-edge ceiling for a mode at a given input cadence. Mirrors the
    /// >40 FPS efficient-tier cap in targetDimensions so callers can compare rungs.
    static func ceilingLongEdge(mode: FrameInterpolationMode, inputFPS: Double?) -> Int? {
        guard var cap = mode.longEdgeCap else { return nil }
        if mode == .efficient, let fps = inputFPS, fps.isFinite, fps > 40 { cap = min(cap, 960) }
        return cap
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
