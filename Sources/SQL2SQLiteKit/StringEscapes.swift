import Foundation

public enum StringEscapes {
    /// Decodes a MySQL string literal - surrounding quotes included - to its raw bytes.
    /// Handles backslash escapes and quote doubling, both of which are live in MySQL.
    public static func decode(_ literal: [UInt8]) -> [UInt8] {
        guard literal.count >= 2 else { return literal }
        let quote = literal[0]
        guard quote == UInt8(ascii: "'") || quote == UInt8(ascii: "\"") else { return literal }
        let body = literal.dropFirst().dropLast()

        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if c == UInt8(ascii: "\\"), body.index(after: i) < body.endIndex {
                let e = body[body.index(after: i)]
                switch e {
                case UInt8(ascii: "0"): out.append(0x00)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "Z"): out.append(0x1A)
                // \% and \_ keep their backslash - they are LIKE pattern escapes.
                case UInt8(ascii: "%"), UInt8(ascii: "_"):
                    out.append(UInt8(ascii: "\\"))
                    out.append(e)
                // \\ \' \" and every other \X yield X.
                default: out.append(e)
                }
                i = body.index(i, offsetBy: 2)
                continue
            }
            if c == quote, body.index(after: i) < body.endIndex, body[body.index(after: i)] == quote {
                out.append(quote)
                i = body.index(i, offsetBy: 2)
                continue
            }
            out.append(c)
            i = body.index(after: i)
        }
        return out
    }

    /// Wraps a string as a SQLite text literal for generated DDL.
    public static func quoteSQLiteText(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Wraps a string as a SQLite quoted identifier.
    public static func quoteIdentifier(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
