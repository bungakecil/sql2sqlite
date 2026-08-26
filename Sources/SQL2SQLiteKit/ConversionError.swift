public enum ConversionError: Error, CustomStringConvertible {
    case io(String)
    case parse(message: String, byteOffset: Int, line: Int)
    case sqlite(message: String, sql: String)
    case schema(String)
    case usage(String)
    case strict(Warning)

    public var description: String {
        switch self {
        case .io(let m):
            return m
        case .parse(let m, let off, let line):
            return "\(m) (line \(line), byte offset \(off))"
        case .sqlite(let m, let sql):
            return "\(m)\n  while executing: \(SQLPreview.short(sql))"
        case .schema(let m):
            return m
        case .usage(let m):
            return m
        case .strict(let w):
            return "\(w.description) (--strict)"
        }
    }
}

enum SQLPreview {
    /// Trims long generated SQL so error messages stay readable.
    static func short(_ sql: String, limit: Int = 200) -> String {
        sql.count <= limit ? sql : String(sql.prefix(limit)) + "\u{2026}"
    }
}
