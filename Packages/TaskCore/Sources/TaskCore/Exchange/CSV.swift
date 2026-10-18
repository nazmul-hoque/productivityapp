import Foundation

/// Comma-separated values as in RFC 4180: fields may be quoted, quotes inside are doubled, and
/// quoted fields may contain commas and line breaks.
public enum CSV {
    /// Rows of fields. A byte-order mark is ignored; CRLF, LF and CR all end rows; blank lines are skipped.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")  // so the last row always ends
        var i = 0
        func endRow() {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
            field = ""
        }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty: quoted = true
                case ",":
                    row.append(field)
                    field = ""
                case "\r\n", "\n", "\r": endRow()
                default: field.append(c)
                }
            }
            i += 1
        }
        return rows
    }

    /// Rows as CSV text, quoting fields only when needed. Lines end with CRLF, as spreadsheets expect.
    public static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func quote(_ field: String) -> String {
        // Scalars, not Characters: "\r\n" is a single Character, so a lone "\n" wouldn't match it.
        let special = Set(",\"\r\n".unicodeScalars)
        guard field.unicodeScalars.contains(where: special.contains) || field.first == " " || field.last == " " else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// CSV rows looked up by column name.
struct CSVTable {
    var header: [String]
    var rows: [[String]]
    private var index: [String: Int]

    /// Uses the first row whose cells include `requiredColumn` as the header (some exports put
    /// notes above it), and the rows after it.
    init?(_ text: String, headerContaining requiredColumn: String) {
        let all = CSV.parse(text)
        guard let start = all.firstIndex(where: { $0.contains(requiredColumn) }) else { return nil }
        header = all[start].map { $0.trimmingCharacters(in: .whitespaces) }
        rows = Array(all[(start + 1)...])
        index = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func value(_ column: String, in row: [String]) -> String {
        guard let i = index[column], i < row.count else { return "" }
        return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
