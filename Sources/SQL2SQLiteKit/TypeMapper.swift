public enum SQLiteAffinity: String, Equatable, Sendable {
    case integer = "INTEGER"
    case real    = "REAL"
    case numeric = "NUMERIC"
    case text    = "TEXT"
    case blob    = "BLOB"
}

public struct MappedType: Equatable {
    public var declaredType: String     // what goes in the CREATE TABLE
    public var affinity: SQLiteAffinity // how values get bound/stored
    public var enumValues: [String]?    // requoted SQLite literals, for a CHECK
    public var isUnknown: Bool

    public init(declaredType: String, affinity: SQLiteAffinity,
                enumValues: [String]? = nil, isUnknown: Bool = false) {
        self.declaredType = declaredType
        self.affinity = affinity
        self.enumValues = enumValues
        self.isUnknown = isUnknown
    }
}

public enum TypeMapper {
    private static let integerTypes: Set<String> = [
        "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER",
        "BIGINT", "BIT", "BOOL", "BOOLEAN", "YEAR", "SERIAL",
    ]
    private static let realTypes: Set<String> = [
        "FLOAT", "DOUBLE", "DOUBLE PRECISION", "REAL",
    ]
    private static let numericTypes: Set<String> = ["DECIMAL", "NUMERIC", "FIXED", "DEC"]
    private static let textTypes: Set<String> = [
        "CHAR", "VARCHAR", "CHARACTER", "CHARACTER VARYING", "NATIONAL CHAR", "NATIONAL VARCHAR",
        "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "JSON", "UUID", "INET6",
    ]
    private static let blobTypes: Set<String> = [
        "BINARY", "VARBINARY", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB",
        "LONG VARBINARY",
    ]
    // Dates map to TEXT so string comparison and sorting keep working on
    // ISO-8601-shaped values.
    private static let temporalTypes: Set<String> = ["DATE", "DATETIME", "TIMESTAMP", "TIME"]

    public static func map(_ type: MySQLType) -> MappedType {
        let base = type.base.uppercased()

        if integerTypes.contains(base) {
            return MappedType(declaredType: "INTEGER", affinity: .integer)
        }
        if realTypes.contains(base) {
            return MappedType(declaredType: "REAL", affinity: .real)
        }
        // DECIMAL is always declared NUMERIC: queryable, at the cost of degrading
        // wide decimals to double precision.
        if numericTypes.contains(base) {
            return MappedType(declaredType: "NUMERIC", affinity: .numeric)
        }
        if blobTypes.contains(base) {
            return MappedType(declaredType: "BLOB", affinity: .blob)
        }
        if textTypes.contains(base) || temporalTypes.contains(base) {
            return MappedType(declaredType: "TEXT", affinity: .text)
        }
        if base == "ENUM" {
            return MappedType(declaredType: "TEXT", affinity: .text,
                              enumValues: requotedValues(type.args))
        }
        if base == "SET" {
            // A SET column holds a comma-joined subset, so its members are not a
            // value whitelist and cannot become a CHECK.
            return MappedType(declaredType: "TEXT", affinity: .text)
        }
        return MappedType(declaredType: "TEXT", affinity: .text, isUnknown: true)
    }

    /// MySQL escaping in an ENUM member must become SQLite escaping before it
    /// can appear inside a generated CHECK constraint.
    private static func requotedValues(_ args: [String]) -> [String] {
        args.map { arg in
            let raw = Array(arg.utf8)
            guard raw.first == UInt8(ascii: "'") || raw.first == UInt8(ascii: "\"") else {
                return StringEscapes.quoteSQLiteText(arg)
            }
            let payload = StringEscapes.decode(raw)
            var out: [UInt8] = [UInt8(ascii: "'")]
            for b in payload {
                if b == UInt8(ascii: "'") { out.append(b) }
                out.append(b)
            }
            out.append(UInt8(ascii: "'"))
            return String(decoding: out, as: UTF8.self)
        }
    }
}
