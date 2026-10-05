import Foundation

/// Small cross-queue revision token. Advancing/checking never holds the lock during device work.
/// An in-progress operation may finish, but a superseded result must not publish UI state.
final class ConfigurationRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    @discardableResult
    func advance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == candidate
    }
}
