import Foundation

@main
struct ConfigurationRevisionTests {
    static func main() {
        let revision = ConfigurationRevision()
        let first = revision.advance()
        precondition(first == 1 && revision.isCurrent(first))
        let second = revision.advance()
        precondition(second == 2 && !revision.isCurrent(first) && revision.isCurrent(second))
        let count = 20_000
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            _ = revision.advance()
        }
        let final = revision.advance()
        precondition(final == UInt64(count + 3))
        precondition(revision.isCurrent(final) && !revision.isCurrent(second))
        _ = revision.advance()
        precondition(!revision.isCurrent(final))
        print("ConfigurationRevision tests passed (supersession and concurrent advancement).")
    }
}
