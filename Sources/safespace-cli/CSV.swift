import Foundation

// RFC 4180 reading and writing (contract §7.1 CSV rules).
enum CSV {
    static func cell(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    static func row(_ cells: [String]) -> String { cells.map(cell).joined(separator: ",") + "\r\n" }
    /// `%.6f`, or an empty cell for null.
    static func number(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "" }

    /// Parses a whole file into rows. Leading byte-order marks are ignored.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false
        var chars = Substring(text)
        while chars.first == "\u{FEFF}" { chars = chars.dropFirst() }
        var iterator = chars.makeIterator()
        while let ch = iterator.next() {
            if quoted {
                if ch == "\"" { quoted = false; afterQuote = true } else { field.append(ch) }
                continue
            }
            switch ch {
            case "\"":
                if afterQuote { field.append("\"") }
                quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n":
                row.append(field); field = ""
                rows.append(row); row = []
            case "\r": break
            default: field.append(ch)
            }
            afterQuote = false
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { $0 != [""] }
    }
}
