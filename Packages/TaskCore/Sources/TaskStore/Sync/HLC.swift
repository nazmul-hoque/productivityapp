import Foundation

/// A hybrid logical clock value: wall-clock milliseconds, a counter, and the device's node id,
/// formatted so that plain string comparison orders them (`0001729234567890-0003-1a2b3c4d`).
///
/// Wall time keeps clocks meaningful to people; the counter orders several changes within one
/// millisecond; observing remote clocks (`receive`) keeps a device whose wall clock is behind from
/// losing every conflict; the node id breaks exact ties between devices.
public struct HLC: Comparable, Sendable, CustomStringConvertible {
    public var milliseconds: Int64
    public var counter: Int
    public var node: String

    public init(milliseconds: Int64, counter: Int, node: String) {
        self.milliseconds = milliseconds
        self.counter = counter
        self.node = node
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, let ms = Int64(parts[0]), let counter = Int(parts[1]) else { return nil }
        self.init(milliseconds: ms, counter: counter, node: String(parts[2]))
    }

    public var description: String {
        String(format: "%016lld-%04d-", milliseconds, counter) + node
    }

    /// The clock for a local change made at `now`, after `last`.
    public static func tick(after last: HLC?, now: Date, node: String) -> HLC {
        let wall = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        guard let last, last.milliseconds >= wall else { return HLC(milliseconds: wall, counter: 0, node: node) }
        // The counter has four digits; borrow a millisecond rather than overflow it.
        if last.counter >= 9999 { return HLC(milliseconds: last.milliseconds + 1, counter: 0, node: node) }
        return HLC(milliseconds: last.milliseconds, counter: last.counter + 1, node: node)
    }

    /// `last` advanced past a clock seen from another device, so later local changes beat it.
    public static func receive(_ remote: HLC, last: HLC?, node: String) -> HLC {
        guard let last, last >= remote else { return HLC(milliseconds: remote.milliseconds, counter: remote.counter, node: node) }
        return last
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        lhs.description < rhs.description
    }

    public static func == (lhs: HLC, rhs: HLC) -> Bool {
        lhs.description == rhs.description
    }
}
