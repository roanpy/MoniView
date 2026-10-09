import Foundation

enum WindowCapturePolicyTests {
    private static var checks = 0

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    static func run() {
        let displays = [
            MacWindowCapturePolicy.Display(id: 11, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            MacWindowCapturePolicy.Display(id: 22, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
        ]
        let secondaryDisplayWindow = CGRect(x: 2400, y: 200, width: 800, height: 500)
        check(MacWindowCapturePolicy.displayID(forWindowFrame: secondaryDisplayWindow, among: displays) == 22,
              "A window on a secondary display selects that display")

        let spanningWindow = CGRect(x: 1700, y: 100, width: 800, height: 500)
        check(MacWindowCapturePolicy.displayID(forWindowFrame: spanningWindow, among: displays) == 22,
              "A window spanning displays selects the display with the larger visible area")
        check(MacWindowCapturePolicy.displayID(forWindowFrame: .zero, among: displays) == nil,
              "An empty window frame has no display")

        check(MacWindowCapturePolicy.pixelSize(forWindowFrameSize: CGSize(width: 800, height: 500),
                                               backingScaleFactor: 2) == CGSize(width: 1600, height: 1000),
              "Retina logical points are converted to backing pixels")
        check(MacWindowCapturePolicy.pixelSize(forWindowFrameSize: CGSize(width: 800, height: 500),
                                               backingScaleFactor: 1) == CGSize(width: 800, height: 500),
              "A 1x display keeps its native pixel size")
        check(MacWindowCapturePolicy.pixelSize(forWindowFrameSize: CGSize(width: 3000, height: 1000),
                                               backingScaleFactor: 2) == CGSize(width: 3840, height: 1280),
              "The output width cap preserves the source aspect ratio")
        check(MacWindowCapturePolicy.pixelSize(forWindowFrameSize: CGSize(width: 799, height: 501),
                                               backingScaleFactor: 2).width.truncatingRemainder(dividingBy: 2) == 0,
              "Configured output dimensions stay even")

        check(MacWindowCapturePolicy.boundedRefreshRate(120) == 120,
              "A high-refresh source display keeps its reported rate")
        check(MacWindowCapturePolicy.boundedRefreshRate(0) == 60,
              "An unavailable display rate uses the safe default")

        let currentStream = NSObject()
        let oldStream = NSObject()
        check(MacWindowCapturePolicy.acceptsCallback(callbackStream: currentStream,
                                                     activeStream: currentStream,
                                                     activeGeneration: 8,
                                                     generation: 8),
              "Callbacks from the active stream and epoch are accepted")
        check(!MacWindowCapturePolicy.acceptsCallback(callbackStream: oldStream,
                                                      activeStream: currentStream,
                                                      activeGeneration: 8,
                                                      generation: 9),
              "A late callback from a previous stream is rejected")
        check(!MacWindowCapturePolicy.acceptsCallback(callbackStream: currentStream,
                                                      activeStream: currentStream,
                                                      activeGeneration: 8,
                                                      generation: 9),
              "A callback from a superseded epoch is rejected")
        check(!MacWindowCapturePolicy.acceptsCallback(callbackStream: oldStream,
                                                      activeStream: nil,
                                                      activeGeneration: nil,
                                                      generation: 8),
              "Callbacks are rejected when no stream is active")

        print("Window capture policy: \(checks) checks passed (CPU-only; no capture session opened).")
    }
}

WindowCapturePolicyTests.run()
