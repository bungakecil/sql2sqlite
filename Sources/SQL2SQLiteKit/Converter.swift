public struct ConverterOptions {
    public var schemaOnly = false
    public var dataOnly = false
    public var checkForeignKeys = false
    public var batchSize = 100_000
    public var chunkSize = 1 << 16

    public init() {}
}

public struct ConversionSummary: Equatable {
    public var tables = 0
    public var rows = 0
    public var indexes = 0
    public var views = 0
    public var warnings = 0

    public init() {}

    private static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out: [Character] = []
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return String(out)
    }

    private static func plural(_ n: Int, _ singular: String) -> String {
        "\(grouped(n)) \(singular)\(n == 1 ? "" : "s")"
    }

    /// e.g. "converted 14 tables, 812,043 rows, 9 indexes, 2 views; 2 skipped routine"
    public func describe(diagnostics: Diagnostics) -> String {
        var text = "converted "
            + [Self.plural(tables, "table"), Self.plural(rows, "row"),
               Self.plural(indexes, "index").replacingIndexPlural(indexes),
               Self.plural(views, "view")].joined(separator: ", ")
        if let fragment = diagnostics.summaryFragment() {
            text += "; \(fragment)"
        }
        return text
    }
}

extension String {
    /// "1 indexs" is not a word.
    fileprivate func replacingIndexPlural(_ n: Int) -> String {
        n == 1 ? self : replacingOccurrences(of: " indexs", with: " indexes")
    }

    fileprivate func replacingOccurrences(of target: String, with replacement: String) -> String {
        guard let range = self.range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}

/// A table the run has created, or discovered in the target under --data-only.
private struct RegisteredTable {
    var columns: [TranslatedColumn]
    /// Generated columns cannot be written to, so they never take a bind slot.
    var insertableColumns: [String]
    var affinities: [String: SQLiteAffinity]
}

public final class Converter {
    private let writer: SQLiteWriter
    private let diagnostics: Diagnostics
    private let options: ConverterOptions
    private let translator: SchemaTranslator

    private var tables: [String: RegisteredTable] = [:]
    /// CREATE INDEX is deferred to after the data load: a large speedup, at the
    /// cost of having to purge a table's pending indexes when it is dropped.
    private var pendingIndexes: [(table: String, index: TranslatedIndex)] = []
    private var pendingViews: [TranslatedView] = []
    private var summary = ConversionSummary()
    private var rowsInBatch = 0
    private var transactionOpen = false

    public init(writer: SQLiteWriter, diagnostics: Diagnostics, options: ConverterOptions) {
        self.writer = writer
        self.diagnostics = diagnostics
        self.options = options
        self.translator = SchemaTranslator(diagnostics: diagnostics)
    }

    public func run(source: any ByteSource) throws -> ConversionSummary {
        let scanner = ByteScanner(source: source)
        let splitter = StatementSplitter(scanner: scanner, diagnostics: diagnostics)

        while let statement = try splitter.next() {
            try dispatch(statement)
        }

        try commitBatch()
        try createDeferredIndexes()
        try createDeferredViews()
        if options.checkForeignKeys { try reportForeignKeyViolations() }
        try writer.finalizeWrites()

        summary.warnings = diagnostics.total
        return summary
    }

    // MARK: - Dispatch

    private func dispatch(_ statement: Statement) throws {
        let lexemes = Lexer.lexAll(statement.bytes)
        switch StatementClassifier.classify(lexemes) {
        case .createTable:
            guard !options.dataOnly else { return }
            try handleCreateTable(statement)

        case .insert:
            guard !options.schemaOnly else { return }
            try handleInsert(statement)

        case .createView:
            let view = try ViewTranslator.translate(statement, diagnostics: diagnostics)
            pendingViews.append(view)

        case .dropTable(let names):
            for name in names { try handleDropTable(name) }

        case .createRoutine(let kind):
            try diagnostics.warn(.skippedRoutine,
                "skipped \(kind); SQLite cannot express MySQL routines",
                offset: statement.byteOffset, line: statement.line)

        case .boilerplate:
            return

        case .useDatabase, .createDatabase:
            try diagnostics.warnOnce(.multiDatabase,
                "the dump spans more than one database; all tables are flattened into one namespace",
                offset: statement.byteOffset, line: statement.line)

        case .unknown(let leading):
            try diagnostics.warn(.unsupportedConstruct,
                "skipped unsupported statement: \(leading)",
                offset: statement.byteOffset, line: statement.line)
        }
    }

    private func handleCreateTable(_ statement: Statement) throws {
        let parsed = try CreateTableParser.parse(statement, diagnostics: diagnostics)
        guard tables[parsed.name] == nil else {
            throw ConversionError.schema(
                "duplicate table `\(parsed.name)` at line \(statement.line); "
                + "multi-database dumps are flattened into one namespace")
        }
        let translated = try translator.translate(
            parsed, location: (statement.byteOffset, statement.line))
        try writer.exec(translated.createSQL)

        let generated = Set(parsed.columns.filter { $0.generatedExpression != nil }.map(\.name))
        var affinities: [String: SQLiteAffinity] = [:]
        for column in translated.columns { affinities[column.name] = column.affinity }
        tables[parsed.name] = RegisteredTable(
            columns: translated.columns,
            insertableColumns: translated.columns.map(\.name).filter { !generated.contains($0) },
            affinities: affinities)

        for index in translated.indexSQL {
            pendingIndexes.append((table: parsed.name, index: index))
        }
        summary.tables += 1
    }

    private func handleDropTable(_ name: String) throws {
        let quoted = StringEscapes.quoteIdentifier(name)
        try writer.exec("DROP TABLE IF EXISTS \(quoted)")
        // mysqldump writes a placeholder CREATE VIEW, then DROP VIEW, then the
        // real definition. Dropping only the table would leave the placeholder
        // queued, and the real definition would then fail as a duplicate.
        try writer.exec("DROP VIEW IF EXISTS \(quoted)")
        tables[name] = nil
        // Without this the queued CREATE INDEX statements would fail at the end
        // of the run - which is exactly what mysqldump's view placeholders do.
        pendingIndexes.removeAll { $0.table == name }
        pendingViews.removeAll { $0.name == name }
    }

    private func handleInsert(_ statement: Statement) throws {
        var parser = try InsertParser(statement: statement, diagnostics: diagnostics)
        let registered = try registeredTable(named: parser.table, statement: statement)

        let targetColumns = parser.columns ?? registered.insertableColumns
        let affinities = targetColumns.map { registered.affinities[$0] ?? .text }

        try beginBatch()
        while let row = try parser.nextRow() {
            guard row.count == targetColumns.count else {
                throw ConversionError.parse(
                    message: "INSERT INTO `\(parser.table)` supplies \(row.count) values "
                        + "for \(targetColumns.count) columns",
                    byteOffset: statement.byteOffset, line: statement.line)
            }
            try writer.insertRow(table: parser.table, columns: targetColumns,
                                 affinities: affinities, values: row)
            summary.rows += 1
            rowsInBatch += 1
            if rowsInBatch >= options.batchSize {
                try commitBatch()
                try beginBatch()
            }
        }
    }

    /// Under --data-only the target tables already exist, so their shape comes
    /// from the database rather than from the dump.
    private func registeredTable(named name: String,
                                 statement: Statement) throws -> RegisteredTable {
        if let known = tables[name] { return known }
        guard options.dataOnly else {
            throw ConversionError.schema(
                "INSERT INTO `\(name)` at line \(statement.line) has no matching CREATE TABLE")
        }
        let info = try writer.tableInfo(name)
        guard !info.isEmpty else {
            throw ConversionError.schema(
                "INSERT INTO `\(name)` at line \(statement.line) but no such table exists")
        }
        var affinities: [String: SQLiteAffinity] = [:]
        var columns: [TranslatedColumn] = []
        for column in info {
            let affinity = Self.affinity(forDeclaredType: column.declaredType)
            affinities[column.name] = affinity
            columns.append(TranslatedColumn(name: column.name, affinity: affinity))
        }
        let registered = RegisteredTable(columns: columns,
                                          insertableColumns: info.map(\.name),
                                          affinities: affinities)
        tables[name] = registered
        return registered
    }

    /// SQLite's own affinity rules, applied to a declared type read back from
    /// PRAGMA table_info.
    private static func affinity(forDeclaredType declared: String) -> SQLiteAffinity {
        let upper = declared.uppercased()
        if upper.contains("INT") { return .integer }
        if upper.contains("CHAR") || upper.contains("CLOB") || upper.contains("TEXT") { return .text }
        if upper.isEmpty || upper.contains("BLOB") { return .blob }
        if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") { return .real }
        return .numeric
    }

    // MARK: - Batching

    private func beginBatch() throws {
        guard !transactionOpen else { return }
        try writer.beginTransaction()
        transactionOpen = true
    }

    private func commitBatch() throws {
        guard transactionOpen else { return }
        try writer.commit()
        transactionOpen = false
        rowsInBatch = 0
    }

    // MARK: - Deferred DDL

    private func createDeferredIndexes() throws {
        for pending in pendingIndexes {
            do {
                try writer.exec(pending.index.sql)
                summary.indexes += 1
            } catch let error as ConversionError {
                // A UNIQUE index over duplicate data must not abort the run.
                try diagnostics.warn(.skippedIndex,
                    "skipped index `\(pending.index.name)` on `\(pending.table)`: \(error.description)",
                    offset: 0, line: 0)
            }
        }
        pendingIndexes.removeAll()
    }

    /// Repeated passes until one makes no progress, so a view built on another
    /// view resolves regardless of the order the dump declared them in.
    private func createDeferredViews() throws {
        var remaining = pendingViews
        var lastFailures: [String: String] = [:]
        while !remaining.isEmpty {
            var stillFailing: [TranslatedView] = []
            for view in remaining {
                do {
                    try create(view)
                    summary.views += 1
                } catch let error as ConversionError {
                    lastFailures[view.name] = error.description
                    stillFailing.append(view)
                }
            }
            if stillFailing.count == remaining.count { break }
            remaining = stillFailing
        }
        for view in remaining {
            try diagnostics.warn(.viewFailed,
                "view `\(view.name)` could not be created: \(lastFailures[view.name] ?? "unknown error")",
                offset: 0, line: 0)
        }
        pendingViews.removeAll()
    }

    /// SQLite does not resolve a view body until the view is queried, so
    /// CREATE VIEW alone succeeds even over a missing table. Probing it with a
    /// zero-row select is what actually surfaces an unresolved dependency, and
    /// is what lets the retry pass resolve view-on-view ordering.
    private func create(_ view: TranslatedView) throws {
        try writer.exec(view.createSQL)
        do {
            _ = try writer.queryRow("SELECT * FROM \(StringEscapes.quoteIdentifier(view.name)) LIMIT 0")
        } catch {
            // Leave no half-working view behind for the next pass to trip over.
            try? writer.exec("DROP VIEW IF EXISTS \(StringEscapes.quoteIdentifier(view.name))")
            throw error
        }
    }

    private func reportForeignKeyViolations() throws {
        for violation in try writer.foreignKeyViolations() {
            try diagnostics.warn(.foreignKeyViolation, violation, offset: 0, line: 0)
        }
    }
}
