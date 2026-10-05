import Foundation

@main
struct DurationBoundedFIFOTests {
    static func main() {
        var fifo = DurationBoundedFIFO<Int>(maximumDuration: 2)
        for i in 0..<4 { precondition(fifo.append(i, duration: 0.5, timestamp: Double(i) * 0.5) == 0) }
        precondition(fifo.count == 4 && fifo.duration == 2)
        precondition(fifo.append(4, duration: 0.5, timestamp: 2) == 1)
        precondition(fifo.popFirst() == 1)
        precondition(fifo.popFirst() == 2)
        precondition(fifo.popFirst() == 3)
        precondition(fifo.popFirst() == 4 && fifo.isEmpty && fifo.duration == 0)
        precondition(fifo.append(5, duration: 0.1, timestamp: 1) == 1) // Regressing PTS, even after draining.
        fifo.removeAll()
        precondition(fifo.append(0, duration: 0.1, timestamp: 0) == 0)
        precondition(fifo.append(1, duration: 0.1, timestamp: 10) == 1) // Timestamp gap evicts stale media.
        precondition(fifo.first == 1)
        precondition(fifo.append(2, duration: 3, timestamp: 11) == 2) // Oversized packet also evicts itself.
        precondition(fifo.isEmpty)
        for invalid in [0.0, -1, .nan, .infinity] {
            precondition(fifo.append(3, duration: invalid, timestamp: 12) == 1)
            precondition(fifo.isEmpty)
        }
        precondition(fifo.append(4, duration: 0.1, timestamp: .nan) == 1)
        var tiny = DurationBoundedFIFO<Int>(maximumDuration: 2, maximumCount: 3)
        for i in 0..<10 { _ = tiny.append(i, duration: 0.00001, timestamp: Double(i) * 0.00001) }
        precondition(tiny.count == 3 && tiny.popFirst() == 7)
        fifo.removeAll()
        var drops = 0
        for i in 0..<10_000 {
            drops += fifo.append(i, duration: 0.01, timestamp: Double(i) * 0.01)
            precondition(fifo.count <= 200 && fifo.duration <= 2 + 1e-9)
        }
        precondition(drops == 9_800 && fifo.popFirst() == 9_800)
        fifo.removeAll()
        precondition(fifo.isEmpty && fifo.duration == 0 && fifo.first == nil)
        precondition(fifo.append(0, duration: 0.1, timestamp: 0) == 0)
        print("DurationBoundedFIFO tests passed (ordering, duration/span/count limits, invalid input, reset, compaction).")
    }
}
