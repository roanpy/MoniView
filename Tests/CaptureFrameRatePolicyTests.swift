import Foundation

@main
struct CaptureFrameRatePolicyTests {
    private static var checks = 0

    static func main() {
        testCommonRatesAndDeviceCeilings()
        testDifferentAdvertisedRateSets()
        testFractionalPairs()
        testSelectedRateRetention()
        testInvalidAndDuplicateRates()
        testLimits()
        check(CaptureFrameRatePolicy.shortcutTitle(60) == "60", "integer title")
        check(CaptureFrameRatePolicy.shortcutTitle(59.94) == "59.94", "fractional title keeps precision")
        print("CaptureFrameRatePolicy: \(checks) checks passed (device shortcuts, fractional rates, selection retention, and limits).")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            fflush(stderr)
            fatalError("FAIL: \(message)")
        }
        checks += 1
    }

    private static func expect(_ actual: [Double], _ expected: [Double], _ message: String) {
        check(actual == expected, "\(message): expected \(expected), got \(actual)")
    }

    private static func testCommonRatesAndDeviceCeilings() {
        expect(CaptureFrameRatePolicy.shortcuts(supportedRates: [30, 50, 60, 90, 120], selectedRate: 0),
               [30, 50, 60, 120],
               "common anchors retain the highest supported device ceiling")
        expect(CaptureFrameRatePolicy.shortcuts(supportedRates: [30, 50, 60, 90], selectedRate: 0),
               [30, 50, 60, 90],
               "90 FPS device exposes its advertised maximum")
        expect(CaptureFrameRatePolicy.shortcuts(supportedRates: [30, 60], selectedRate: 0),
               [30, 60],
               "shorter supported lists return only available choices")
    }

    private static func testDifferentAdvertisedRateSets() {
        let lowResolutionDevice = [20.0, 40.0]
        expect(CaptureFrameRatePolicy.shortcuts(supportedRates: lowResolutionDevice, selectedRate: 0),
               [20, 40],
               "20/40-only formats fill shortcuts without canonical integer anchors")

        let highResolutionDevice = [24.0, 30.0, 60.0]
        expect(CaptureFrameRatePolicy.shortcuts(supportedRates: highResolutionDevice, selectedRate: 0),
               [24, 30, 60],
               "resolution-specific advertised set is preserved")

        let deviceSpecificModes = [23.5, 37.5, 75.0, 144.0]
        expect(CaptureFrameRatePolicy.shortcuts(supportedRates: deviceSpecificModes, selectedRate: 0),
               [23.5, 37.5, 75, 144],
               "device-specific rates fill open slots and retain the true ceiling")
    }

    private static func testFractionalPairs() {
        let rates = [29.97, 30, 50, 59.94, 60, 120]
        let shortcuts = CaptureFrameRatePolicy.shortcuts(supportedRates: rates, selectedRate: 0)
        expect(shortcuts, [29.97, 50, 59.94, 120],
               "fractional 30/60 equivalents win one slot each")
        check(!shortcuts.contains(30) && !shortcuts.contains(60),
              "fractional aliases do not consume neighboring slots too")
    }

    private static func testSelectedRateRetention() {
        let selectedNonstandard = CaptureFrameRatePolicy.shortcuts(
            supportedRates: [20, 30, 40, 50, 60], selectedRate: 40)
        expect(selectedNonstandard, [30, 40, 50, 60],
               "selected 40 FPS stays in the shortcuts alongside common choices")

        let selectedIntegerAlias = CaptureFrameRatePolicy.shortcuts(
            supportedRates: [29.97, 30, 50, 59.94, 60], selectedRate: 30)
        expect(selectedIntegerAlias, [30, 50, 59.94],
               "selected integer rate wins its fractional alias slot")

        let selectedFractional = CaptureFrameRatePolicy.shortcuts(
            supportedRates: [29.97, 30, 59.94, 60], selectedRate: 59.94)
        expect(selectedFractional, [29.97, 59.94],
               "selected fractional rate remains exact")

        let unsupportedSelection = CaptureFrameRatePolicy.shortcuts(
            supportedRates: [20, 40], selectedRate: 60)
        expect(unsupportedSelection, [20, 40],
               "unsupported selection does not invent a shortcut")
    }

    private static func testInvalidAndDuplicateRates() {
        expect(CaptureFrameRatePolicy.shortcuts(
            supportedRates: [0, -1, .nan, .infinity, -.infinity], selectedRate: 0),
               [],
               "zero, negative, and non-finite rates are removed")

        expect(CaptureFrameRatePolicy.shortcuts(
            supportedRates: [30, 30, 50, 50, 0, .nan], selectedRate: 0),
               [30, 50],
               "duplicate and invalid entries do not create extra choices")

        expect(CaptureFrameRatePolicy.shortcuts(
            supportedRates: [20, 40], selectedRate: .nan),
               [20, 40],
               "invalid selected rate behaves like Auto")
    }

    private static func testLimits() {
        expect(CaptureFrameRatePolicy.shortcuts(
            supportedRates: [20, 30, 40, 50, 60, 120], selectedRate: 40, limit: 2),
               [30, 40],
               "custom limit is honored while retaining selected rate")
        expect(CaptureFrameRatePolicy.shortcuts(
            supportedRates: [20, 30, 40, 50, 60, 120], selectedRate: 20, limit: 8),
               [20, 30, 50, 60],
               "shortcut count stays capped at four")
        expect(CaptureFrameRatePolicy.shortcuts(
            supportedRates: [20, 30], selectedRate: 20, limit: 0),
               [],
               "zero limit produces no shortcuts")
        expect(CaptureFrameRatePolicy.shortcuts(
            supportedRates: [20, 30], selectedRate: 20, limit: -1),
               [],
               "negative limit is treated as zero")
    }
}
