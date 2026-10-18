/// String keys that sort lexicographically and always leave room for a key in
/// between, so reordering one item never rewrites its neighbours (sync-friendly).
///
/// Keys use base-62 digits and never end in the zero digit.
public enum FractionalIndex {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = digits.count

    /// A reasonable key for the first item in an empty list.
    public static let first = "V"

    /// A key strictly between `a` and `b`. `nil` means the start / end of the list.
    public static func between(_ a: String?, _ b: String?) -> String {
        let lower = a ?? ""
        if let b { precondition(lower < b, "between: \(lower) must sort before \(b)") }
        return midpoint(Array(lower), b.map(Array.init))
    }

    /// `count` ascending keys between `a` and `b`.
    public static func keys(between a: String?, _ b: String?, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var result: [String] = []
        var previous = a
        for _ in 0..<count {
            let key = between(previous, b)
            result.append(key)
            previous = key
        }
        return result
    }

    private static func value(_ c: Character) -> Int {
        digits.firstIndex(of: c)!
    }

    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            // Skip the shared prefix (treating a missing digit in `a` as zero).
            var n = 0
            while n < b.count && (n < a.count ? a[n] : digits[0]) == b[n] { n += 1 }
            if n > 0 {
                return String(b[0..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let digitA = a.first.map(value) ?? 0
        let digitB = b?.first.map(value) ?? base
        if digitB - digitA > 1 {
            return String(digits[(digitA + digitB + 1) / 2])
        }
        if let b, b.count > 1 {
            return String(b[0])
        }
        return String(digits[digitA]) + midpoint(Array(a.dropFirst()), nil)
    }
}
