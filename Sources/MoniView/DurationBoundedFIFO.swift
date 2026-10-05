import Foundation

/// Caller supplies synchronization. Bounds both retained media and its timestamp span;
/// the item cap is a safety net for extremely small or malformed audio packets.
struct DurationBoundedFIFO<Value> {
    private struct Entry {
        let value: Value
        let duration: Double
        let timestamp: Double
    }
    private let maximumDuration: Double
    private let maximumCount: Int
    private var storage: [Entry?] = []
    private var head = 0
    private var lastTimestamp: Double?
    private(set) var duration = 0.0
    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }
    var first: Value? { isEmpty ? nil : storage[head]?.value }

    init(maximumDuration: Double, maximumCount: Int = 2048) {
        precondition(maximumDuration.isFinite && maximumDuration > 0 && maximumCount > 0)
        self.maximumDuration = maximumDuration
        self.maximumCount = maximumCount
    }

    /// Returns the number of discarded entries, including an invalid incoming entry.
    @discardableResult
    mutating func append(_ value: Value, duration: Double, timestamp: Double) -> Int {
        let end = timestamp + duration
        guard duration.isFinite, duration > 0, timestamp.isFinite, end.isFinite,
              lastTimestamp.map({ timestamp >= $0 }) ?? true else { return 1 }
        lastTimestamp = timestamp
        storage.append(Entry(value: value, duration: duration, timestamp: timestamp))
        self.duration += duration
        var dropped = 0
        while !isEmpty {
            let span = end - storage[head]!.timestamp
            guard self.duration > maximumDuration + 1e-9 || span > maximumDuration + 1e-9 || count > maximumCount else { break }
            _ = popFirst()
            dropped += 1
        }
        return dropped
    }

    mutating func popFirst() -> Value? {
        guard !isEmpty, let entry = storage[head] else { return nil }
        duration = max(0, duration - entry.duration)
        storage[head] = nil // Release the sample now, not at the next array compaction.
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
            duration = 0
        } else if head >= 64 && head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
        return entry.value
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        duration = 0
        lastTimestamp = nil
    }
}
