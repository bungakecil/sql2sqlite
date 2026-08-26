public struct TranslatedView: Equatable {
    public var name: String
    public var createSQL: String

    public init(name: String, createSQL: String) {
        self.name = name
        self.createSQL = createSQL
    }
}

public enum ViewTranslator {
    /// Strips ALGORITHM, DEFINER, SQL SECURITY and a trailing WITH CHECK OPTION,
    /// then requotes the body so backtick identifiers and MySQL double-quoted
    /// strings become valid SQLite.
    public static func translate(_ statement: Statement,
                                 diagnostics: Diagnostics) throws -> TranslatedView {
        let bytes = statement.bytes
        let lexemes = Lexer.lexAll(bytes)

        func fail(_ message: String) -> ConversionError {
            .parse(message: message, byteOffset: statement.byteOffset, line: statement.line)
        }
        func keyword(_ i: Int) -> String? {
            guard i < lexemes.count, case .word(let w) = lexemes[i].token else { return nil }
            return w.uppercased()
        }
        func isPunct(_ i: Int, _ c: UnicodeScalar) -> Bool {
            i < lexemes.count && lexemes[i].token.isPunct(c)
        }
        func isValue(_ i: Int) -> Bool {
            guard i < lexemes.count else { return false }
            switch lexemes[i].token {
            case .word, .quotedIdent, .string: return true
            default:                           return false
            }
        }

        guard keyword(0) == "CREATE" else { throw fail("not a CREATE VIEW statement") }
        var i = 1

        // Skip the modifiers mysqldump puts between CREATE and VIEW.
        loop: while i < lexemes.count {
            switch keyword(i) {
            case "OR" where keyword(i + 1) == "REPLACE":
                i += 2
            case "ALGORITHM", "DEFINER":
                i += 1
                if isPunct(i, "=") { i += 1 }
                if isValue(i) { i += 1 }
                while isPunct(i, "@") {
                    i += 1
                    if isValue(i) { i += 1 }
                }
                if isPunct(i, "("), isPunct(i + 1, ")") { i += 2 }
            case "SQL" where keyword(i + 1) == "SECURITY":
                i += 3
            default:
                break loop
            }
        }

        guard keyword(i) == "VIEW" else { throw fail("not a CREATE VIEW statement") }
        i += 1

        guard i < lexemes.count, var name = lexemes[i].token.identifierValue else {
            throw fail("expected a view name")
        }
        i += 1
        // Drop a `db.` qualifier so multi-database dumps land in one namespace.
        while isPunct(i, "."), i + 1 < lexemes.count,
              let part = lexemes[i + 1].token.identifierValue {
            name = part
            i += 2
        }

        // SQLite has supported an explicit view column list since 3.9.
        var columnList = ""
        if isPunct(i, "(") {
            i += 1
            var names: [String] = []
            while i < lexemes.count, !lexemes[i].token.isPunct(")") {
                if lexemes[i].token.isPunct(",") { i += 1; continue }
                guard let column = lexemes[i].token.identifierValue else {
                    throw fail("malformed column list on view `\(name)`")
                }
                names.append(column)
                i += 1
            }
            guard i < lexemes.count else { throw fail("unterminated column list on view `\(name)`") }
            i += 1
            columnList = " (" + names.map(StringEscapes.quoteIdentifier).joined(separator: ", ") + ")"
        }

        guard keyword(i) == "AS" else { throw fail("expected AS in CREATE VIEW `\(name)`") }
        i += 1
        guard i < lexemes.count else { throw fail("empty body in CREATE VIEW `\(name)`") }

        // A trailing WITH [CASCADED|LOCAL] CHECK OPTION has no SQLite equivalent.
        var end = lexemes.count
        for n in i..<lexemes.count where keyword(n) == "WITH" {
            var k = n + 1
            if keyword(k) == "CASCADED" || keyword(k) == "LOCAL" { k += 1 }
            if keyword(k) == "CHECK", keyword(k + 1) == "OPTION" {
                end = n
                break
            }
        }

        let bodyStart = lexemes[i].range.lowerBound
        let bodyEnd = end > i ? lexemes[end - 1].range.upperBound : bodyStart
        let body = requoteIdentifiers(Array(bytes[bodyStart..<bodyEnd]))

        let sql = "CREATE VIEW \(StringEscapes.quoteIdentifier(name))\(columnList) AS \(body)"
        return TranslatedView(name: name, createSQL: sql)
    }
}
