import Foundation

/// Recursive descent over a `CREATE TABLE` statement. A regex cannot do this job:
/// `DEFAULT '(,)'` and `ENUM('a,b','c')` both defeat naive comma splitting.
public struct CreateTableParser {
    private let lexemes: [Lexeme]
    private let bytes: [UInt8]
    private let statement: Statement
    private let diagnostics: Diagnostics
    private var index = 0
    private var table: Table
    /// `ON UPDATE CURRENT_TIMESTAMP` is warned about at most once per table.
    private var warnedOnUpdate = false

    private init(statement: Statement, diagnostics: Diagnostics) {
        self.statement = statement
        self.diagnostics = diagnostics
        self.bytes = statement.bytes
        self.lexemes = Lexer.lexAll(statement.bytes)
        self.table = Table(name: "")
    }

    public static func parse(_ statement: Statement, diagnostics: Diagnostics) throws -> Table {
        var parser = CreateTableParser(statement: statement, diagnostics: diagnostics)
        return try parser.run()
    }

    // MARK: - Cursor helpers

    private func peek(_ ahead: Int = 0) -> Token? {
        let i = index + ahead
        return i < lexemes.count ? lexemes[i].token : nil
    }

    @discardableResult
    private mutating func take() -> Token? {
        guard index < lexemes.count else { return nil }
        defer { index += 1 }
        return lexemes[index].token
    }

    private var atEnd: Bool { index >= lexemes.count }

    private func isPunct(_ ahead: Int, _ c: UnicodeScalar) -> Bool {
        peek(ahead)?.isPunct(c) ?? false
    }

    private mutating func matchPunct(_ c: UnicodeScalar) -> Bool {
        guard isPunct(0, c) else { return false }
        index += 1
        return true
    }

    private mutating func expectPunct(_ c: UnicodeScalar) throws {
        guard matchPunct(c) else {
            throw error("expected '\(c)' in CREATE TABLE")
        }
    }

    /// Consumes the keyword only when it matches.
    private mutating func matchKeyword(_ kw: String) -> Bool {
        guard peek()?.isKeyword(kw) == true else { return false }
        index += 1
        return true
    }

    /// Consumes the whole run only when every keyword matches in order.
    private mutating func matchKeywords(_ kws: [String]) -> Bool {
        for (n, kw) in kws.enumerated() where peek(n)?.isKeyword(kw) != true { return false }
        index += kws.count
        return true
    }

    private mutating func takeIdentifier() throws -> String {
        guard let name = peek()?.identifierValue else {
            throw error("expected an identifier in CREATE TABLE")
        }
        index += 1
        return name
    }

    /// Reads `db`.`name`, keeping only the bare name so multi-database dumps
    /// flatten into a single namespace.
    private mutating func takeQualifiedIdentifier() throws -> String {
        var name = try takeIdentifier()
        while isPunct(0, "."), peek(1)?.identifierValue != nil {
            index += 1
            name = try takeIdentifier()
        }
        return name
    }

    private func error(_ message: String) -> ConversionError {
        .parse(message: message, byteOffset: statement.byteOffset, line: statement.line)
    }

    private func sourceText(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// Re-emits a MySQL string literal as a SQLite one: backslash escapes are
    /// decoded and the quote is doubled, because SQLite has no backslash escapes.
    private func requoteStringLiteral(_ raw: [UInt8]) -> String {
        let payload = StringEscapes.decode(raw)
        var out: [UInt8] = [UInt8(ascii: "'")]
        for b in payload {
            if b == UInt8(ascii: "'") { out.append(b) }
            out.append(b)
        }
        out.append(UInt8(ascii: "'"))
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Balanced-paren regions

    /// Consumes a balanced-paren region starting at the current `(` and returns
    /// the requoted source text of its contents.
    private mutating func takeParenthesisedExpression() throws -> String {
        guard isPunct(0, "(") else { throw error("expected '(' starting an expression") }
        let openLexeme = lexemes[index]
        index += 1
        var depth = 1
        var lastInner = openLexeme.range.upperBound
        while index < lexemes.count {
            if isPunct(0, "(") { depth += 1 }
            if isPunct(0, ")") {
                depth -= 1
                if depth == 0 {
                    let closeStart = lexemes[index].range.lowerBound
                    index += 1
                    return requoteIdentifiers(Array(bytes[openLexeme.range.upperBound..<closeStart]))
                }
            }
            lastInner = lexemes[index].range.upperBound
            index += 1
        }
        _ = lastInner
        throw error("unbalanced parentheses in CREATE TABLE")
    }

    /// Skips forward to the next `,` or `)` at depth 0, returning the skipped text.
    private mutating func skipToElementBoundary() -> String {
        let start = index < lexemes.count ? lexemes[index].range.lowerBound : bytes.count
        var end = start
        var depth = 0
        while index < lexemes.count {
            if isPunct(0, "(") { depth += 1 }
            if isPunct(0, ")") {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0 && isPunct(0, ",") { break }
            end = lexemes[index].range.upperBound
            index += 1
        }
        return sourceText(start..<max(start, end))
    }

    // MARK: - Top level

    private mutating func run() throws -> Table {
        try parseHeader()
        try expectPunct("(")
        while true {
            try parseElement()
            if matchPunct(",") { continue }
            break
        }
        try expectPunct(")")
        // Table options (ENGINE=, CHARSET=, AUTO_INCREMENT=, ROW_FORMAT=, COMMENT=)
        // carry nothing SQLite can use, so they are discarded here.
        return table
    }

    private mutating func parseHeader() throws {
        guard matchKeyword("CREATE") else {
            throw error("not a CREATE TABLE statement")
        }
        _ = matchKeyword("TEMPORARY")
        guard matchKeyword("TABLE") else {
            throw error("not a CREATE TABLE statement")
        }
        _ = matchKeywords(["IF", "NOT", "EXISTS"])
        table.name = try takeQualifiedIdentifier()
    }

    // MARK: - Elements

    private mutating func parseElement() throws {
        // A bareword in this position may introduce a table constraint; a
        // backticked name is always a column, even when it reads like a keyword.
        if case .word(let raw)? = peek() {
            switch raw.uppercased() {
            case "PRIMARY":
                index += 1
                _ = matchKeyword("KEY")
                skipIndexType()
                table.primaryKey = try parseIndexedColumnList()
                skipIndexOptions()
                return
            case "UNIQUE":
                index += 1
                _ = matchKeyword("INDEX") || matchKeyword("KEY")
                let name = peek()?.identifierValue != nil && !isPunct(0, "(")
                    ? try takeIdentifier() : nil
                skipIndexType()
                let columns = try parseIndexedColumnList()
                skipIndexOptions()
                table.indexes.append(Index(name: name, columns: columns, isUnique: true))
                return
            case "FULLTEXT", "SPATIAL":
                index += 1
                let kind: IndexKind = raw.uppercased() == "FULLTEXT" ? .fulltext : .spatial
                _ = matchKeyword("INDEX") || matchKeyword("KEY")
                let name = peek()?.identifierValue != nil && !isPunct(0, "(")
                    ? try takeIdentifier() : nil
                let columns = try parseIndexedColumnList()
                skipIndexOptions()
                table.indexes.append(Index(name: name, columns: columns, kind: kind))
                return
            case "KEY", "INDEX":
                index += 1
                let name = peek()?.identifierValue != nil && !isPunct(0, "(")
                    ? try takeIdentifier() : nil
                skipIndexType()
                let columns = try parseIndexedColumnList()
                skipIndexOptions()
                table.indexes.append(Index(name: name, columns: columns))
                return
            case "FOREIGN":
                index += 1
                try parseForeignKey()
                return
            case "CHECK":
                index += 1
                table.checks.append(try takeParenthesisedExpression())
                _ = matchKeyword("NOT")
                _ = matchKeyword("ENFORCED")
                return
            case "CONSTRAINT":
                index += 1
                // An optional constraint name precedes the constraint keyword.
                if peek()?.identifierValue != nil,
                   peek()?.isKeyword("FOREIGN") != true,
                   peek()?.isKeyword("PRIMARY") != true,
                   peek()?.isKeyword("UNIQUE") != true,
                   peek()?.isKeyword("CHECK") != true {
                    index += 1
                }
                try parseElement()
                return
            default:
                break
            }
        }
        try parseColumnDef()
    }

    private mutating func skipIndexType() {
        if matchKeyword("USING") { _ = take() }
    }

    /// Index options SQLite has no equivalent for: USING BTREE|HASH, KEY_BLOCK_SIZE,
    /// COMMENT, WITH PARSER, VISIBLE/INVISIBLE.
    private mutating func skipIndexOptions() {
        while let token = peek() {
            if token.isKeyword("USING") { index += 1; _ = take(); continue }
            if token.isKeyword("COMMENT") { index += 1; _ = take(); continue }
            if token.isKeyword("KEY_BLOCK_SIZE") {
                index += 1
                _ = matchPunct("=")
                _ = take()
                continue
            }
            if token.isKeyword("WITH"), peek(1)?.isKeyword("PARSER") == true {
                index += 2
                _ = take()
                continue
            }
            if token.isKeyword("VISIBLE") || token.isKeyword("INVISIBLE") { index += 1; continue }
            break
        }
    }

    private mutating func parseIndexedColumnList() throws -> [IndexedColumn] {
        try expectPunct("(")
        var out: [IndexedColumn] = []
        repeat {
            let name = try takeIdentifier()
            var prefix: Int? = nil
            if matchPunct("(") {
                if case .number(let digits)? = peek() { prefix = Int(digits); index += 1 }
                try expectPunct(")")
            }
            var descending = false
            if matchKeyword("ASC") { descending = false }
            else if matchKeyword("DESC") { descending = true }
            out.append(IndexedColumn(name: name, prefixLength: prefix, descending: descending))
        } while matchPunct(",")
        try expectPunct(")")
        return out
    }

    private mutating func parseColumnNameList() throws -> [String] {
        try expectPunct("(")
        var out: [String] = []
        repeat {
            out.append(try takeIdentifier())
            // A referenced column may carry a length prefix; SQLite ignores it.
            if matchPunct("(") { _ = take(); try expectPunct(")") }
            _ = matchKeyword("ASC") || matchKeyword("DESC")
        } while matchPunct(",")
        try expectPunct(")")
        return out
    }

    private mutating func parseForeignKey() throws {
        guard matchKeyword("KEY") else { throw error("expected FOREIGN KEY") }
        // An optional index name may sit between KEY and the column list.
        if !isPunct(0, "("), peek()?.identifierValue != nil { index += 1 }
        let columns = try parseColumnNameList()
        guard matchKeyword("REFERENCES") else { throw error("expected REFERENCES in FOREIGN KEY") }
        let referenced = try takeQualifiedIdentifier()
        let referencedColumns = try parseColumnNameList()

        var onDelete: String? = nil
        var onUpdate: String? = nil
        while matchKeyword("ON") {
            let isDelete = matchKeyword("DELETE")
            if !isDelete { _ = matchKeyword("UPDATE") }
            let action = takeReferentialAction()
            if isDelete { onDelete = action } else { onUpdate = action }
        }
        if matchKeyword("MATCH") { _ = take() }

        table.foreignKeys.append(ForeignKey(columns: columns,
                                            referencedTable: referenced,
                                            referencedColumns: referencedColumns,
                                            onDelete: onDelete,
                                            onUpdate: onUpdate))
    }

    private mutating func takeReferentialAction() -> String {
        if matchKeywords(["SET", "NULL"]) { return "SET NULL" }
        if matchKeywords(["SET", "DEFAULT"]) { return "SET DEFAULT" }
        if matchKeywords(["NO", "ACTION"]) { return "NO ACTION" }
        if matchKeyword("CASCADE") { return "CASCADE" }
        if matchKeyword("RESTRICT") { return "RESTRICT" }
        return "NO ACTION"
    }

    // MARK: - Columns

    private mutating func parseColumnDef() throws {
        let name = try takeIdentifier()
        let type = try parseType()
        var column = Column(name: name, type: type)
        try parseColumnAttributes(into: &column)
        table.columns.append(column)
    }

    private static let multiWordTypes: [[String]] = [
        ["DOUBLE", "PRECISION"],
        ["CHARACTER", "VARYING"],
        ["NATIONAL", "CHAR"],
        ["NATIONAL", "VARCHAR"],
        ["LONG", "VARBINARY"],
        ["LONG", "VARCHAR"],
    ]

    private mutating func parseType() throws -> MySQLType {
        guard let first = peek()?.wordValue else {
            throw error("expected a type for column in table `\(table.name)`")
        }
        index += 1
        var base = first.uppercased()
        for pair in Self.multiWordTypes where pair[0] == base {
            if peek()?.isKeyword(pair[1]) == true {
                index += 1
                base = "\(pair[0]) \(pair[1])"
                break
            }
        }

        var args: [String] = []
        if isPunct(0, "(") {
            index += 1
            if !isPunct(0, ")") {
                repeat {
                    let start = index < lexemes.count ? lexemes[index].range.lowerBound : bytes.count
                    var end = start
                    var depth = 0
                    while index < lexemes.count {
                        if isPunct(0, "(") { depth += 1 }
                        if isPunct(0, ")") {
                            if depth == 0 { break }
                            depth -= 1
                        }
                        if depth == 0 && isPunct(0, ",") { break }
                        end = lexemes[index].range.upperBound
                        index += 1
                    }
                    args.append(sourceText(start..<max(start, end)))
                } while matchPunct(",")
            }
            try expectPunct(")")
        }

        var isUnsigned = false
        while let token = peek() {
            if token.isKeyword("UNSIGNED") { isUnsigned = true; index += 1; continue }
            if token.isKeyword("SIGNED") || token.isKeyword("ZEROFILL") { index += 1; continue }
            break
        }
        return MySQLType(base: base, args: args, isUnsigned: isUnsigned)
    }

    private mutating func parseColumnAttributes(into column: inout Column) throws {
        while !atEnd {
            if isPunct(0, ",") || isPunct(0, ")") { return }

            if matchKeywords(["NOT", "NULL"]) { column.isNotNull = true; continue }
            if matchKeyword("NULL") { column.isNotNull = false; continue }
            if matchKeyword("AUTO_INCREMENT") { column.isAutoIncrement = true; continue }

            if matchKeyword("DEFAULT") {
                column.defaultSQL = try parseDefaultValue()
                continue
            }

            if matchKeywords(["PRIMARY", "KEY"]) || matchKeyword("PRIMARY") {
                table.primaryKey = [IndexedColumn(name: column.name)]
                continue
            }

            if matchKeyword("UNIQUE") {
                _ = matchKeyword("KEY")
                table.indexes.append(Index(name: nil,
                                           columns: [IndexedColumn(name: column.name)],
                                           isUnique: true))
                continue
            }

            if matchKeyword("COLLATE") {
                column.collation = peek()?.identifierValue
                _ = take()
                continue
            }

            if matchKeywords(["CHARACTER", "SET"]) || matchKeyword("CHARSET") {
                _ = take()
                continue
            }

            if matchKeyword("COMMENT") { _ = take(); continue }
            if matchKeywords(["SERIAL", "DEFAULT", "VALUE"]) {
                column.isAutoIncrement = true
                continue
            }
            if matchKeyword("VISIBLE") || matchKeyword("INVISIBLE") { continue }

            // ON UPDATE CURRENT_TIMESTAMP has no SQLite equivalent without a trigger.
            if peek()?.isKeyword("ON") == true, peek(1)?.isKeyword("UPDATE") == true {
                index += 2
                _ = take()                                  // the expression head
                if isPunct(0, "(") { _ = try takeParenthesisedExpression() }
                if !warnedOnUpdate {
                    warnedOnUpdate = true
                    try diagnostics.warn(.droppedAttribute,
                        "dropped ON UPDATE on `\(table.name)`.`\(column.name)`; SQLite has no equivalent",
                        offset: statement.byteOffset, line: statement.line)
                }
                continue
            }

            if matchKeywords(["GENERATED", "ALWAYS", "AS"]) || matchKeyword("AS") {
                column.generatedExpression = try takeParenthesisedExpression()
                if matchKeyword("STORED") { column.generatedIsStored = true }
                else { _ = matchKeyword("VIRTUAL"); column.generatedIsStored = false }
                continue
            }

            if matchKeyword("CHECK") {
                table.checks.append(try takeParenthesisedExpression())
                _ = matchKeyword("NOT")
                _ = matchKeyword("ENFORCED")
                continue
            }

            if matchKeywords(["REFERENCES"]) {
                // An inline column reference is a foreign key in table clothing.
                let referenced = try takeQualifiedIdentifier()
                let referencedColumns = try parseColumnNameList()
                var onDelete: String? = nil
                var onUpdate: String? = nil
                while matchKeyword("ON") {
                    let isDelete = matchKeyword("DELETE")
                    if !isDelete { _ = matchKeyword("UPDATE") }
                    let action = takeReferentialAction()
                    if isDelete { onDelete = action } else { onUpdate = action }
                }
                table.foreignKeys.append(ForeignKey(columns: [column.name],
                                                    referencedTable: referenced,
                                                    referencedColumns: referencedColumns,
                                                    onDelete: onDelete,
                                                    onUpdate: onUpdate))
                continue
            }

            // Anything unrecognised must not abort the parse.
            let dropped = skipToElementBoundary()
            if dropped.isEmpty { return }
            try diagnostics.warn(.droppedAttribute,
                "dropped unrecognised attribute on `\(table.name)`.`\(column.name)`: \(dropped)",
                offset: statement.byteOffset, line: statement.line)
        }
    }

    private mutating func parseDefaultValue() throws -> String? {
        if isPunct(0, "(") {
            return "(" + (try takeParenthesisedExpression()) + ")"
        }
        // A leading sign is a separate token: DEFAULT -1
        var sign = ""
        if isPunct(0, "-") { sign = "-"; index += 1 }
        else if isPunct(0, "+") { index += 1 }

        guard let token = take() else { return nil }
        switch token {
        case .string(let raw):
            return requoteStringLiteral(raw)
        case .number(let digits):
            return sign + digits
        case .word(let word):
            // CURRENT_TIMESTAMP(3) keeps its precision argument.
            if isPunct(0, "(") {
                let inner = try takeParenthesisedExpression()
                return inner.isEmpty ? "\(word)()" : "\(word)(\(inner))"
            }
            return word
        case .quotedIdent(let name):
            return StringEscapes.quoteIdentifier(name)
        case .hexLiteral(let raw):
            return "X'" + raw.map { String(format: "%02X", $0) }.joined() + "'"
        case .bitLiteral(let digits):
            return String(UInt64(digits, radix: 2) ?? 0)
        case .punct:
            return nil
        }
    }
}
