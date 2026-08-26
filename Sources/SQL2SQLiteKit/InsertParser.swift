/// Yields one value tuple at a time. A single extended INSERT can reach
/// net_buffer_length (~16 MB), so there is no reason to materialise every
/// decoded tuple at once. Values become typed RawValues and are later bound -
/// INSERT text is never re-emitted as SQL.
public struct InsertParser {
    public let table: String
    public let columns: [String]?     // nil when the dump gave no column list
    public let byteOffset: Int
    public let line: Int

    private let lexemes: [Lexeme]
    private let diagnostics: Diagnostics
    private var index: Int
    private var exhausted = false

    public init(statement: Statement, diagnostics: Diagnostics) throws {
        let lexemes = Lexer.lexAll(statement.bytes)
        self.lexemes = lexemes
        self.diagnostics = diagnostics
        self.byteOffset = statement.byteOffset
        self.line = statement.line

        func fail(_ message: String) -> ConversionError {
            .parse(message: message, byteOffset: statement.byteOffset, line: statement.line)
        }
        func keyword(_ i: Int) -> String? {
            guard i < lexemes.count, case .word(let w) = lexemes[i].token else { return nil }
            return w.uppercased()
        }

        var i = 0
        guard let head = keyword(0), head == "INSERT" || head == "REPLACE" else {
            throw fail("not an INSERT statement")
        }
        i += 1
        while let w = keyword(i), ["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE"].contains(w) {
            i += 1
        }
        if keyword(i) == "INTO" { i += 1 }

        guard i < lexemes.count, var name = lexemes[i].token.identifierValue else {
            throw fail("expected a table name in INSERT")
        }
        i += 1
        // Drop a `db.` qualifier so multi-database dumps land in one namespace.
        while i < lexemes.count, lexemes[i].token.isPunct("."),
              i + 1 < lexemes.count, let part = lexemes[i + 1].token.identifierValue {
            name = part
            i += 2
        }
        self.table = name

        // An optional parenthesised column list.
        var parsedColumns: [String]? = nil
        if i < lexemes.count, lexemes[i].token.isPunct("(") {
            i += 1
            var names: [String] = []
            while i < lexemes.count, !lexemes[i].token.isPunct(")") {
                if lexemes[i].token.isPunct(",") { i += 1; continue }
                guard let column = lexemes[i].token.identifierValue else {
                    throw fail("malformed column list in INSERT INTO `\(name)`")
                }
                names.append(column)
                i += 1
            }
            guard i < lexemes.count else { throw fail("unterminated column list in INSERT") }
            i += 1                              // the closing `)`
            parsedColumns = names
        }
        self.columns = parsedColumns

        guard keyword(i) == "VALUES" || keyword(i) == "VALUE" else {
            throw fail("expected VALUES in INSERT INTO `\(name)`")
        }
        i += 1
        self.index = i
    }

    private func fail(_ message: String) -> ConversionError {
        .parse(message: message, byteOffset: byteOffset, line: line)
    }

    private func peek(_ ahead: Int = 0) -> Token? {
        let i = index + ahead
        return i < lexemes.count ? lexemes[i].token : nil
    }

    /// The next value tuple, or nil when the statement is exhausted.
    public mutating func nextRow() throws -> [RawValue]? {
        if exhausted { return nil }
        guard let token = peek() else { exhausted = true; return nil }
        // A statement may trail `ON DUPLICATE KEY UPDATE ...`, which ends the tuples.
        if case .word = token { exhausted = true; return nil }
        guard token.isPunct("(") else {
            throw fail("expected '(' starting a value tuple in INSERT INTO `\(table)`")
        }
        index += 1

        var row: [RawValue] = []
        if peek()?.isPunct(")") == true {
            index += 1
        } else {
            while true {
                row.append(try parseValue())
                if peek()?.isPunct(",") == true { index += 1; continue }
                guard peek()?.isPunct(")") == true else {
                    throw fail("malformed value tuple in INSERT INTO `\(table)`")
                }
                index += 1
                break
            }
        }

        if peek()?.isPunct(",") == true { index += 1 } else { exhausted = true }
        return row
    }

    private mutating func parseValue() throws -> RawValue {
        // A leading sign is its own token; fold it into the numeric literal.
        var sign = ""
        if peek()?.isPunct("-") == true { sign = "-"; index += 1 }
        else if peek()?.isPunct("+") == true { sign = "+"; index += 1 }

        guard let token = peek() else {
            throw fail("unexpected end of INSERT INTO `\(table)`")
        }
        index += 1

        switch token {
        case .number(let digits):
            let literal = sign + digits
            try warnIfBeyondInt64(literal)
            return .number(Array(literal.utf8))

        case .string(let raw):
            return .text(StringEscapes.decode(raw))

        case .hexLiteral(let bytes):
            return .blob(bytes)

        case .bitLiteral(let digits):
            return .number(Array(String(UInt64(digits, radix: 2) ?? 0).utf8))

        case .quotedIdent(let name):
            // A backticked run in value position is not valid MySQL, but treat it
            // as text rather than losing the row.
            return .text(Array(name.utf8))

        case .word(let word):
            let upper = word.uppercased()
            if upper == "NULL" { return .null }
            if upper == "TRUE" { return .number(Array("1".utf8)) }
            if upper == "FALSE" { return .number(Array("0".utf8)) }
            if upper == "DEFAULT" {
                try diagnostics.warn(.unsupportedConstruct,
                    "DEFAULT in a value tuple for `\(table)` became NULL",
                    offset: byteOffset, line: line)
                return .null
            }
            // A charset introducer: _binary 'x', _utf8mb4 'x'.
            if word.hasPrefix("_"), case .string(let raw)? = peek() {
                index += 1
                let payload = StringEscapes.decode(raw)
                return upper == "_BINARY" ? .blob(payload) : .text(payload)
            }
            // A bareword such as CURRENT_TIMESTAMP: store its text.
            return .text(Array(word.utf8))

        case .punct:
            throw fail("unexpected token in a value tuple for `\(table)`")
        }
    }

    /// SQLite has no unsigned 64-bit integer, so anything wider than Int64 is
    /// stored as a double. Warn once for the whole run.
    private func warnIfBeyondInt64(_ literal: String) throws {
        guard !literal.contains("."), !literal.lowercased().contains("e") else { return }
        guard Int64(literal) == nil else { return }
        try diagnostics.warnOnce(.numericPrecision,
            "value \(literal) does not fit a 64-bit integer; SQLite will store it as a double",
            offset: byteOffset, line: line)
    }
}
