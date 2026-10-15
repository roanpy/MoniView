import Foundation

struct AudioSelectionIntent: Equatable {
    let id: String
    let persist: Bool
}

enum AudioAuthorizationState: Equatable {
    case authorized
    case notDetermined
    case denied
}

enum AudioPermissionPolicy {
    static func shouldRequestAccess(for state: AudioAuthorizationState, requestInFlight: Bool) -> Bool {
        state == .notDetermined && !requestInFlight
    }

    /// A denied selection stays pending until both the same device is still selected and
    /// macOS reports authorization. Returning the original intent preserves its persist flag.
    static func restorableSelection(
        pending: AudioSelectionIntent?,
        selectedID: String?,
        authorization: AudioAuthorizationState,
        deviceAvailable: Bool
    ) -> AudioSelectionIntent? {
        guard let pending, pending.id == selectedID,
              authorization == .authorized, deviceAvailable else { return nil }
        return pending
    }
}

/// When the shared capture session must run. The session owns every input, so audio and
/// video share one lifetime: stopping it for a video-only reason (switching the preview to
/// a Mac window, clearing the video device) also silences an audio input the user selected,
/// and a session holding no input at all is still a running session that does nothing.
enum CaptureSessionPolicy {
    /// An input is the only thing worth running for. Both source kinds leave audio on this
    /// session, so window mode keeps a running session for audio alone.
    static func shouldRun(inputCount: Int) -> Bool {
        inputCount > 0
    }

    /// Action to take so the session matches its inputs, or nil when it already does.
    /// Kept separate from `shouldRun` so a caller cannot read the predicate and forget the
    /// start half: the window path previously stopped the session on every switch and never
    /// started it again, which left listening and audio recording dead for the whole session.
    enum Action: Equatable { case start, stop }

    static func action(isRunning: Bool, inputCount: Int) -> Action? {
        let wanted = shouldRun(inputCount: inputCount)
        if wanted, !isRunning { return .start }
        if !wanted, isRunning { return .stop }
        return nil
    }

    /// Compare the requested selection with the actual input while on sessionQueue.
    static func audioInputNeedsConfiguration(actualID: String?, requestedID: String?) -> Bool {
        actualID != requestedID
    }

    /// Window recordings require a running ScreenCaptureKit stream and its configured size.
    static func canRecordWindowCapture(isRunning: Bool, width: Int, height: Int) -> Bool {
        isRunning && width >= 2 && height >= 2
    }
}
