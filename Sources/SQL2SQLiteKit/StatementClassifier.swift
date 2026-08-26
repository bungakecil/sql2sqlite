public enum StatementKind: Equatable {
    case createTable(name: String)
    case createView
    case createRoutine(kind: String)     // TRIGGER, PROCEDURE, FUNCTION, EVENT
    case insert(table: String)
    case dropTable(names: [String])
    case boilerplate                     // SET, LOCK/UNLOCK TABLES, ALTER ... KEYS
    case useDatabase
    case createDatabase
    case unknown(leadingWords: String)
}

public enum StatementClassifier {
    /// Strips a `db.` qualifier so multi-database dumps land in one namespace.
    static func unqualified(_ name: String) -> String {
        if let dot = name.lastIndex(of: ".") { return String(name[name.index(after: dot)...]) }
        return name
    }

    private static func keyword(_ lexemes: [Lexeme], _ i: Int) -> String? {
        guard i < lexemes.count, case .word(let w) = lexemes[i].token else { return nil }
        return w.uppercased()
    }

    private static func identifier(_ lexemes: [Lexeme], _ i: Int) -> String? {
        guard i < lexemes.count else { return nil }
        return lexemes[i].token.identifierValue
    }

    private static func isPunct(_ lexemes: [Lexeme], _ i: Int, _ c: UnicodeScalar) -> Bool {
        i < lexemes.count && lexemes[i].token.isPunct(c)
    }

    /// A bareword, backticked identifier or string - the shapes a DEFINER or
    /// ALGORITHM value can take.
    private static func isValueToken(_ lexemes: [Lexeme], _ i: Int) -> Bool {
        guard i < lexemes.count else { return false }
        switch lexemes[i].token {
        case .word, .quotedIdent, .string: return true
        default:                           return false
        }
    }

    /// Reads a possibly `db`.`table` qualified name starting at `i`, returning the
    /// bare table name and the index just past it.
    private static func qualifiedName(_ lexemes: [Lexeme], _ i: Int) -> (name: String, next: Int)? {
        guard var name = identifier(lexemes, i) else { return nil }
        var j = i + 1
        while isPunct(lexemes, j, "."), let part = identifier(lexemes, j + 1) {
            name = part
            j += 2
        }
        return (name, j)
    }

    /// Skips the noise MySQL puts between CREATE and the object keyword.
    private static func skipCreateModifiers(_ lexemes: [Lexeme], _ start: Int) -> Int {
        var i = start
        loop: while i < lexemes.count {
            switch keyword(lexemes, i) {
            case "OR" where keyword(lexemes, i + 1) == "REPLACE":
                i += 2
            case "TEMPORARY", "ONLINE", "OFFLINE":
                i += 1
            case "ALGORITHM", "DEFINER":
                // ALGORITHM=UNDEFINED, DEFINER=`root`@`localhost`, DEFINER=CURRENT_USER
                i += 1
                if isPunct(lexemes, i, "=") { i += 1 }
                if isValueToken(lexemes, i) { i += 1 }
                // A user spec continues as `@host`, and the host may be quoted.
                while isPunct(lexemes, i, "@") {
                    i += 1
                    if isValueToken(lexemes, i) { i += 1 }
                }
                // DEFINER=CURRENT_USER() carries an empty argument list.
                if isPunct(lexemes, i, "("), isPunct(lexemes, i + 1, ")") { i += 2 }
            case "SQL" where keyword(lexemes, i + 1) == "SECURITY":
                i += 3   // SQL SECURITY DEFINER|INVOKER
            default:
                break loop
            }
        }
        return i
    }

    private static func leadingWords(_ lexemes: [Lexeme], count: Int = 2) -> String {
        var words: [String] = []
        for lexeme in lexemes.prefix(count) {
            guard case .word(let w) = lexeme.token else { break }
            words.append(w.uppercased())
        }
        return words.joined(separator: " ")
    }

    public static func classify(_ lexemes: [Lexeme]) -> StatementKind {
        guard let head = keyword(lexemes, 0) else {
            return .unknown(leadingWords: leadingWords(lexemes))
        }

        switch head {
        case "SET", "LOCK", "UNLOCK", "START", "COMMIT", "ROLLBACK", "FLUSH", "BEGIN":
            return .boilerplate

        case "ALTER":
            // Only mysqldump's DISABLE/ENABLE KEYS bracketing is safe to ignore.
            if keyword(lexemes, 1) == "TABLE" {
                for (n, lexeme) in lexemes.enumerated() where n > 1 {
                    guard case .word(let w) = lexeme.token else { continue }
                    let upper = w.uppercased()
                    if upper == "DISABLE" || upper == "ENABLE" {
                        if keyword(lexemes, n + 1) == "KEYS" { return .boilerplate }
                    }
                }
            }
            return .unknown(leadingWords: leadingWords(lexemes))

        case "USE":
            return .useDatabase

        case "INSERT", "REPLACE":
            var i = 1
            while let w = keyword(lexemes, i),
                  ["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE"].contains(w) {
                i += 1
            }
            if keyword(lexemes, i) == "INTO" { i += 1 }
            if let found = qualifiedName(lexemes, i) { return .insert(table: found.name) }
            return .unknown(leadingWords: leadingWords(lexemes))

        case "DROP":
            guard keyword(lexemes, 1) == "TABLE" || keyword(lexemes, 1) == "VIEW" else {
                return .unknown(leadingWords: leadingWords(lexemes))
            }
            var i = 2
            if keyword(lexemes, i) == "IF" && keyword(lexemes, i + 1) == "EXISTS" { i += 2 }
            var names: [String] = []
            while let found = qualifiedName(lexemes, i) {
                names.append(found.name)
                i = found.next
                if isPunct(lexemes, i, ",") { i += 1 } else { break }
            }
            return .dropTable(names: names)

        case "CREATE":
            let i = skipCreateModifiers(lexemes, 1)
            switch keyword(lexemes, i) {
            case "TABLE":
                var j = i + 1
                if keyword(lexemes, j) == "IF" && keyword(lexemes, j + 1) == "NOT"
                    && keyword(lexemes, j + 2) == "EXISTS" { j += 3 }
                if let found = qualifiedName(lexemes, j) { return .createTable(name: found.name) }
                return .unknown(leadingWords: leadingWords(lexemes))
            case "VIEW":
                return .createView
            case "TRIGGER", "PROCEDURE", "FUNCTION", "EVENT":
                return .createRoutine(kind: keyword(lexemes, i)!)
            case "DATABASE", "SCHEMA":
                return .createDatabase
            case "INDEX", "UNIQUE", "FULLTEXT", "SPATIAL":
                return .unknown(leadingWords: leadingWords(lexemes))
            default:
                return .unknown(leadingWords: leadingWords(lexemes))
            }

        default:
            return .unknown(leadingWords: leadingWords(lexemes))
        }
    }
}
