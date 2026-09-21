public struct TranslatedColumn: Equatable {
    public var name: String
    public var affinity: SQLiteAffinity

    public init(name: String, affinity: SQLiteAffinity) {
        self.name = name
        self.affinity = affinity
    }
}

public struct TranslatedIndex: Equatable {
    public var name: String
    public var sql: String

    public init(name: String, sql: String) {
        self.name = name
        self.sql = sql
    }
}

public struct TranslatedTable: Equatable {
    public var name: String
    public var createSQL: String
    public var indexSQL: [TranslatedIndex]   // deferred to end of run
    public var columns: [TranslatedColumn]   // drives INSERT binding

    public init(name: String, createSQL: String,
                indexSQL: [TranslatedIndex], columns: [TranslatedColumn]) {
        self.name = name
        self.createSQL = createSQL
        self.indexSQL = indexSQL
        self.columns = columns
    }
}

/// A class rather than an enum because it owns the run-global set of emitted
/// index names: SQLite index names are schema-global, unlike MySQL's per-table ones.
public final class SchemaTranslator {
    private let diagnostics: Diagnostics
    private var emittedIndexNames: Set<String> = []

    public init(diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
    }

    private func quoted(_ s: String) -> String { StringEscapes.quoteIdentifier(s) }

    /// SQLite has only NOCASE and BINARY. A MySQL `*_ci` collation maps to the
    /// former and `*_bin` to the latter; anything else is dropped.
    private func mapCollation(_ collation: String, table: String, column: String,
                              location: (offset: Int, line: Int)) throws -> String? {
        let lower = collation.lowercased()
        if lower.hasSuffix("_ci") { return "NOCASE" }
        if lower.hasSuffix("_bin") || lower == "binary" { return "BINARY" }
        try diagnostics.warn(.droppedAttribute,
            "dropped COLLATE \(collation) on `\(table)`.`\(column)`; SQLite has only NOCASE and BINARY",
            offset: location.offset, line: location.line)
        return nil
    }

    /// SQLite index names live in one schema-wide namespace, so a MySQL index
    /// name is prefixed with its table and de-duplicated on collision.
    private func uniqueIndexName(_ base: String) -> String {
        if emittedIndexNames.insert(base).inserted { return base }
        var n = 2
        while true {
            let candidate = "\(base)_\(n)"
            if emittedIndexNames.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    public func translate(_ table: Table,
                          location: (offset: Int, line: Int)) throws -> TranslatedTable {
        let primaryKeyNames = Set(table.primaryKey.map(\.name))

        // AUTOINCREMENT is only legal on a lone INTEGER PRIMARY KEY.
        var autoIncrementColumn: String? = nil
        if table.primaryKey.count == 1,
           let pkColumn = table.column(named: table.primaryKey[0].name),
           pkColumn.isAutoIncrement,
           TypeMapper.map(pkColumn.type).affinity == .integer {
            autoIncrementColumn = pkColumn.name
        }
        if autoIncrementColumn == nil, let orphan = table.columns.first(where: \.isAutoIncrement) {
            try diagnostics.warn(.unsupportedConstruct,
                "dropped AUTO_INCREMENT on `\(table.name)`.`\(orphan.name)`; SQLite allows it only on a lone INTEGER PRIMARY KEY",
                offset: location.offset, line: location.line)
        }

        var lines: [String] = []
        var translatedColumns: [TranslatedColumn] = []

        for column in table.columns {
            let mapped = TypeMapper.map(column.type)
            if mapped.isUnknown {
                try diagnostics.warn(.unknownType,
                    "unknown type \(column.type.base) on `\(table.name)`.`\(column.name)`; storing as TEXT",
                    offset: location.offset, line: location.line)
            }
            translatedColumns.append(TranslatedColumn(name: column.name, affinity: mapped.affinity))

            var piece = "\(quoted(column.name)) \(mapped.declaredType)"
            if column.name == autoIncrementColumn {
                piece += " PRIMARY KEY AUTOINCREMENT"
            }
            // MySQL primary key columns are implicitly NOT NULL; SQLite's are not.
            if column.isNotNull || primaryKeyNames.contains(column.name) {
                piece += " NOT NULL"
            }
            if let value = column.defaultSQL, column.generatedExpression == nil {
                switch DefaultValueMapper.map(value) {
                case .keep(let sql):
                    piece += " DEFAULT \(sql)"
                case .unsupported:
                    try diagnostics.warn(.droppedAttribute,
                        "dropped DEFAULT \(value) on `\(table.name)`.`\(column.name)`; SQLite has no equivalent function",
                        offset: location.offset, line: location.line)
                }
            }
            if let collation = column.collation,
               let mappedCollation = try mapCollation(collation, table: table.name,
                                                      column: column.name, location: location) {
                piece += " COLLATE \(mappedCollation)"
            }
            if let expression = column.generatedExpression {
                piece += " GENERATED ALWAYS AS (\(expression)) \(column.generatedIsStored ? "STORED" : "VIRTUAL")"
                try diagnostics.warn(.unsupportedConstruct,
                    "passing generated column `\(table.name)`.`\(column.name)` through unchanged; its expression may use MySQL-only functions",
                    offset: location.offset, line: location.line)
            }
            if let values = mapped.enumValues, !values.isEmpty {
                piece += " CHECK (\(quoted(column.name)) IN (\(values.joined(separator: ", "))))"
            }
            lines.append(piece)
        }

        if !table.primaryKey.isEmpty && autoIncrementColumn == nil {
            let cols = table.primaryKey.map { quoted($0.name) }.joined(separator: ", ")
            lines.append("PRIMARY KEY (\(cols))")
        }

        for check in table.checks {
            lines.append("CHECK (\(check))")
        }

        for fk in table.foreignKeys {
            var piece = "FOREIGN KEY (\(fk.columns.map(quoted).joined(separator: ", ")))"
            piece += " REFERENCES \(quoted(fk.referencedTable))"
            piece += " (\(fk.referencedColumns.map(quoted).joined(separator: ", ")))"
            if let onDelete = fk.onDelete { piece += " ON DELETE \(onDelete)" }
            if let onUpdate = fk.onUpdate { piece += " ON UPDATE \(onUpdate)" }
            lines.append(piece)
        }

        let createSQL = "CREATE TABLE \(quoted(table.name)) (\n"
            + lines.map { "  " + $0 }.joined(separator: ",\n")
            + "\n)"

        let indexSQL = try translateIndexes(table, location: location)
        return TranslatedTable(name: table.name, createSQL: createSQL,
                               indexSQL: indexSQL, columns: translatedColumns)
    }

    private func translateIndexes(_ table: Table,
                                  location: (offset: Int, line: Int)) throws -> [TranslatedIndex] {
        var out: [TranslatedIndex] = []
        var unnamedCounter = 0

        for index in table.indexes {
            if index.kind != .normal {
                let label = index.kind == .fulltext ? "FULLTEXT" : "SPATIAL"
                try diagnostics.warn(.skippedIndex,
                    "skipped \(label) index on `\(table.name)`; SQLite has no equivalent",
                    offset: location.offset, line: location.line)
                continue
            }

            let baseName: String
            if let name = index.name {
                baseName = "\(table.name)_\(name)"
            } else {
                unnamedCounter += 1
                baseName = "\(table.name)_idx_\(unnamedCounter)"
            }
            let finalName = uniqueIndexName(baseName)

            var columnPieces: [String] = []
            for column in index.columns {
                if column.prefixLength != nil {
                    try diagnostics.warn(.droppedAttribute,
                        "dropped index prefix length on `\(table.name)`.`\(column.name)`; SQLite indexes the whole value",
                        offset: location.offset, line: location.line)
                }
                columnPieces.append(quoted(column.name) + (column.descending ? " DESC" : ""))
            }

            let unique = index.isUnique ? "UNIQUE " : ""
            let sql = "CREATE \(unique)INDEX \(quoted(finalName)) ON \(quoted(table.name))"
                + " (\(columnPieces.joined(separator: ", ")))"
            out.append(TranslatedIndex(name: finalName, sql: sql))
        }
        return out
    }
}
