import CSQLite

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// SQLITE_TRANSIENT is a macro C exposes as a function pointer cast, which does
/// not survive into Swift; `nonisolated(unsafe)` is required because a C function
/// pointer is not Sendable.
nonisolated(unsafe) private let SQLITE_TRANSIENT =
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum RawValue: Equatable {
    case null
    case number([UInt8])   // raw literal bytes, bound as text; affinity converts
    case text([UInt8])     // decoded string payload
    case blob([UInt8])
}

public struct ColumnInfo: Equatable {
    public var name: String
    public var declaredType: String

    public init(name: String, declaredType: String) {
        self.name = name
        self.declaredType = declaredType
    }
}

/// A column as an INSERT sees it: generated columns keep their position in the
/// table but cannot be written to.
struct InsertColumnInfo: Equatable {
    var name: String
    var declaredType: String
    var isWritable: Bool
}

public final class SQLiteWriter {
    private var db: OpaquePointer?
    /// Keyed by table plus its column list, so an extended INSERT of 10 000 rows
    /// prepares exactly once.
    private var insertStatements: [String: OpaquePointer] = [:]
    private var inTransaction = false
    private var closed = false

    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle)
            throw ConversionError.sqlite(message: "cannot open \(path): \(message)", sql: "")
        }
        db = handle
        // Bulk-load pragmas. foreign_keys stays OFF because dumps are not
        // topologically ordered. journal_mode returns a row, so these go through
        // sqlite3_exec, which tolerates result rows.
        for pragma in ["PRAGMA journal_mode=OFF",
                       "PRAGMA synchronous=OFF",
                       "PRAGMA foreign_keys=OFF",
                       "PRAGMA cache_size=-64000",
                       "PRAGMA temp_store=MEMORY"] {
            try exec(pragma)
        }
    }

    deinit { close() }

    private func errorMessage() -> String {
        guard let db else { return "database is closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    public func exec(_ sql: String) throws {
        guard let db else { throw ConversionError.sqlite(message: "database is closed", sql: sql) }
        var raw: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &raw)
        if rc != SQLITE_OK {
            let message = raw.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(raw)
            throw ConversionError.sqlite(message: message, sql: sql)
        }
        sqlite3_free(raw)
    }

    public func beginTransaction() throws {
        guard !inTransaction else { return }
        try exec("BEGIN")
        inTransaction = true
    }

    public func commit() throws {
        guard inTransaction else { return }
        try exec("COMMIT")
        inTransaction = false
    }

    private func prepared(table: String, columns: [String]) throws -> OpaquePointer {
        let key = StringEscapes.quoteIdentifier(table) + "(" + columns.joined(separator: "\u{1}") + ")"
        if let cached = insertStatements[key] { return cached }

        let sql: String
        if columns.isEmpty {
            // `INSERT INTO t () VALUES ()` is MySQL-only syntax.
            sql = "INSERT INTO \(StringEscapes.quoteIdentifier(table)) DEFAULT VALUES"
        } else {
            let quotedColumns = columns.map(StringEscapes.quoteIdentifier).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
            sql = "INSERT INTO \(StringEscapes.quoteIdentifier(table)) (\(quotedColumns)) VALUES (\(placeholders))"
        }

        guard let db else { throw ConversionError.sqlite(message: "database is closed", sql: sql) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ConversionError.sqlite(message: errorMessage(), sql: sql)
        }
        insertStatements[key] = stmt
        return stmt
    }

    /// Text is bound with an explicit byte count so embedded NULs survive, and
    /// SQLite does not validate UTF-8 on bind, so latin1 bytes round-trip intact.
    private func bind(_ stmt: OpaquePointer, _ position: Int32,
                      _ value: RawValue, affinity: SQLiteAffinity) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(stmt, position)
        case .number(let bytes):
            // Bound as text; the column's affinity performs the conversion.
            return bindText(stmt, position, bytes)
        case .text(let bytes):
            if affinity == .blob { return bindBlob(stmt, position, bytes) }
            return bindText(stmt, position, bytes)
        case .blob(let bytes):
            return bindBlob(stmt, position, bytes)
        }
    }

    private func bindText(_ stmt: OpaquePointer, _ position: Int32, _ bytes: [UInt8]) -> Int32 {
        bytes.withUnsafeBufferPointer { buffer in
            sqlite3_bind_text(stmt, position,
                              buffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                              Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer, _ position: Int32, _ bytes: [UInt8]) -> Int32 {
        // sqlite3_bind_blob with a null pointer binds NULL, not an empty blob.
        guard !bytes.isEmpty else { return sqlite3_bind_zeroblob(stmt, position, 0) }
        return bytes.withUnsafeBufferPointer { buffer in
            sqlite3_bind_blob(stmt, position, buffer.baseAddress,
                              Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }

    public func insertRow(table: String, columns: [String],
                          affinities: [SQLiteAffinity], values: [RawValue]) throws {
        // A short value list would otherwise leave trailing parameters bound
        // to NULL, silently.
        guard values.count == columns.count, affinities.count == columns.count else {
            throw ConversionError.schema(
                "INSERT INTO `\(table)` has \(columns.count) columns, \(affinities.count) affinities "
                + "and \(values.count) values")
        }
        let stmt = try prepared(table: table, columns: columns)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)

        for (n, value) in values.enumerated() {
            let rc = bind(stmt, Int32(n + 1), value, affinity: affinities[n])
            if rc != SQLITE_OK {
                throw ConversionError.sqlite(message: errorMessage(),
                                             sql: "INSERT INTO \(table)")
            }
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            let message = errorMessage()
            sqlite3_reset(stmt)
            throw ConversionError.sqlite(message: message, sql: "INSERT INTO \(table)")
        }
        sqlite3_reset(stmt)
    }

    public func tableInfo(_ table: String) throws -> [ColumnInfo] {
        let sql = "PRAGMA table_info(\(StringEscapes.quoteIdentifier(table)))"
        var out: [ColumnInfo] = []
        try forEachRow(sql) { stmt in
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let declared = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            out.append(ColumnInfo(name: name, declaredType: declared))
        }
        return out
    }

    /// Every column in declaration order, generated ones included. The hidden
    /// flag from table_xinfo is 0 for an ordinary column, 1 for a virtual
    /// table's hidden column (skipped), and 2 or 3 for VIRTUAL or STORED
    /// generated columns.
    func insertColumnInfo(_ table: String) throws -> [InsertColumnInfo] {
        let sql = "PRAGMA table_xinfo(\(StringEscapes.quoteIdentifier(table)))"
        var out: [InsertColumnInfo] = []
        try forEachRow(sql) { stmt in
            let hidden = sqlite3_column_int(stmt, 6)
            guard hidden != 1 else { return }
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let declared = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            out.append(InsertColumnInfo(name: name, declaredType: declared, isWritable: hidden == 0))
        }
        return out
    }

    public func foreignKeyViolations() throws -> [String] {
        // The bulk-load pragma leaves enforcement off, so turn it on just to check.
        try exec("PRAGMA foreign_keys=ON")
        defer { try? exec("PRAGMA foreign_keys=OFF") }
        var out: [String] = []
        try forEachRow("PRAGMA foreign_key_check") { stmt in
            let child = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "?"
            let rowid = sqlite3_column_int64(stmt, 1)
            let parent = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "?"
            out.append("`\(child)` rowid \(rowid) references a missing row in `\(parent)`")
        }
        return out
    }

    private func forEachRow(_ sql: String, _ body: (OpaquePointer) -> Void) throws {
        guard let db else { throw ConversionError.sqlite(message: "database is closed", sql: sql) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ConversionError.sqlite(message: errorMessage(), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { body(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw ConversionError.sqlite(message: errorMessage(), sql: sql)
        }
    }

    /// Test and inspection helper: the first row of a query, as storage classes.
    public func queryRow(_ sql: String) throws -> [RawValue]? {
        guard let db else { throw ConversionError.sqlite(message: "database is closed", sql: sql) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ConversionError.sqlite(message: errorMessage(), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw ConversionError.sqlite(message: errorMessage(), sql: sql)
        }

        var out: [RawValue] = []
        for i in 0..<sqlite3_column_count(stmt) {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL:
                out.append(.null)
            case SQLITE_INTEGER, SQLITE_FLOAT:
                // Reported as the decimal text of the value, which keeps test
                // assertions readable without losing the storage class.
                let text = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                out.append(.number(Array(text.utf8)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(stmt, i))
                if let base = sqlite3_column_blob(stmt, i), count > 0 {
                    let buffer = UnsafeRawBufferPointer(start: base, count: count)
                    out.append(.blob([UInt8](buffer)))
                } else {
                    out.append(.blob([]))
                }
            default:
                let count = Int(sqlite3_column_bytes(stmt, i))
                if let base = sqlite3_column_text(stmt, i), count > 0 {
                    let buffer = UnsafeRawBufferPointer(start: base, count: count)
                    out.append(.text([UInt8](buffer)))
                } else {
                    out.append(.text([]))
                }
            }
        }
        return out
    }

    /// Commits and restores a normal journal mode so the output is a clean
    /// single file. The handle stays open so callers can still query it.
    public func finalizeWrites() throws {
        try commit()
        try exec("PRAGMA journal_mode=DELETE")
    }

    /// Finalizes and closes. Callers that still need to read the database
    /// should call `finalizeWrites()` instead.
    public func finish() throws {
        try finalizeWrites()
        close()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for (_, stmt) in insertStatements { sqlite3_finalize(stmt) }
        insertStatements.removeAll()
        sqlite3_close(db)
        db = nil
    }
}
