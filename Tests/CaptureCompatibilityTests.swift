import Foundation

@main
struct CaptureCompatibilityTests {
    static func option(_ rate: Double) -> CaptureFormatOption {
        CaptureFormatOption(id: 0, width: 1920, height: 1080, minimumFPS: Int(rate.rounded()), maximumFPS: Int(rate.rounded()), rates: [rate...rate])
    }
    static func main() {
        precondition(UpscaleMethod.ai.availableMethod(aiSupported: false) == .metalFX)
        precondition(UpscaleMethod.ai.availableMethod(aiSupported: true) == .ai)
        precondition(UpscaleMethod.lanczos.availableMethod(aiSupported: false) == .lanczos)
        let fractional = option(59.94), sixty = option(60.00024)
        precondition(fractional.supportsFrameRate(59.94) && !fractional.supportsFrameRate(60))
        precondition(sixty.supportsFrameRate(60) && !sixty.supportsFrameRate(59.94))
        precondition(!fractional.prefers(over: sixty, nativeNV12: true))
        precondition(sixty.prefers(over: fractional, nativeNV12: false))
        precondition(sixty.prefers(over: sixty, nativeNV12: true))
        for rate in [24.0, 25, 29.97, 30, 50, 59.94, 60, 90, 120, 144] {
            precondition(option(rate).supportsFrameRate(rate))
        }
        let variable = CaptureFormatOption(id: 1, width: 3840, height: 2160, minimumFPS: 24, maximumFPS: 60, rates: [24...60])
        precondition(variable.supportsFrameRate(59.94) && variable.supportsFrameRate(0))
        precondition(!variable.supportsFrameRate(120) && !variable.supportsFrameRate(.nan))
        precondition(UpscaleTarget.fullHD.resolvedLongEdge(screenLongEdge: 3024, sourceLongEdge: 1280) == 1920)
        precondition(UpscaleTarget.uhd.resolvedLongEdge(screenLongEdge: 3024, sourceLongEdge: 1280) == 3840)
        precondition(UpscaleTarget.screen.resolvedLongEdge(screenLongEdge: 3024, sourceLongEdge: 1280) == 3024)
        precondition(UpscaleTarget.screen.resolvedLongEdge(screenLongEdge: 5120, sourceLongEdge: 1920) == 5120)
        precondition(UpscaleTarget.screen.resolvedLongEdge(screenLongEdge: nil, sourceLongEdge: 1920) == 1920)
        precondition(UpscaleTarget.native.resolvedLongEdge(screenLongEdge: 5120, sourceLongEdge: 2160) == 2160)
        print("Capture compatibility tests passed: fractional/discrete/variable rates, representative priority, 1080p/4K/display targets.")
    }
}
