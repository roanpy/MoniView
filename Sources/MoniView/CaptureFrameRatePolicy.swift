import Foundation

/// Chooses a compact set of useful frame-rate shortcuts from the rates actually
/// advertised by the selected capture format. The full advertised list remains the
/// caller's responsibility for the complete format dropdown.
enum CaptureFrameRatePolicy {
    /// Fractional rates stay visible rather than being rounded to another hardware mode.
    static func shortcutTitle(_ rate: Double) -> String {
        rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%.2f", rate)
    }
    private static let fractional30 = 29.97
    private static let integer30 = 30.0
    private static let fractional60 = 59.94
    private static let integer60 = 60.0

    /// Auto is represented by a non-positive or invalid selected rate and is not a
    /// shortcut. A supported non-Auto selection is always retained when `limit` is > 0.
    /// The 29.97/30 and 59.94/60 pairs share one slot; the fractional value wins unless
    /// the corresponding integer rate is selected.
    static func shortcuts(supportedRates: [Double], selectedRate: Double,
                          limit: Int = 4) -> [Double] {
        let maximumCount = min(max(limit, 0), 4)
        guard maximumCount > 0 else { return [] }

        var rates = Array(Set(supportedRates.filter { $0.isFinite && $0 > 0 })).sorted()
        rates = collapseNearDuplicate(fractional: fractional30, integer: integer30,
                                      rates: rates, selectedRate: selectedRate)
        rates = collapseNearDuplicate(fractional: fractional60, integer: integer60,
                                      rates: rates, selectedRate: selectedRate)

        var result: [Double] = []
        func append(_ rate: Double?) {
            guard let rate, result.count < maximumCount,
                  rates.contains(rate), !result.contains(rate) else { return }
            result.append(rate)
        }

        if selectedRate.isFinite, selectedRate > 0, rates.contains(selectedRate) {
            append(selectedRate)
        }

        append(representative(fractional: fractional30, integer: integer30, in: rates))
        append(rates.contains(50) ? 50 : nil)
        append(representative(fractional: fractional60, integer: integer60, in: rates))

        // Keep the device's actual high-frame-rate ceiling available, including rates
        // such as 90, 120, or a device-specific value above them.
        append(rates.last(where: { $0 >= 90 }))

        // Fill remaining slots from this format's real advertised rates. This retains
        // useful 20/40 FPS modes and device-specific values when standard anchors are absent.
        for rate in rates where result.count < maximumCount && !result.contains(rate) {
            result.append(rate)
        }

        return result.sorted()
    }

    private static func collapseNearDuplicate(fractional: Double,
                                              integer: Double,
                                              rates: [Double],
                                              selectedRate: Double) -> [Double] {
        guard rates.contains(fractional), rates.contains(integer) else { return rates }
        let retained = selectedRate == integer ? integer : fractional
        return (rates.filter { $0 != fractional && $0 != integer } + [retained]).sorted()
    }

    private static func representative(fractional: Double,
                                       integer: Double,
                                       in rates: [Double]) -> Double? {
        if rates.contains(fractional) { return fractional }
        if rates.contains(integer) { return integer }
        return nil
    }
}
