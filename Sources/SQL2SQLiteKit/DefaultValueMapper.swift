/// The SQLite rendering of one MySQL DEFAULT clause.
public enum MappedDefault: Equatable, Sendable {
    /// Emit ` DEFAULT <payload>` — usually the original text, unchanged.
    case keep(String)
    /// Drop the clause; the caller warns, naming the original text.
    case unsupported
}

public enum DefaultValueMapper {
    private static let timestampFunctions: Set<String> = [
        "CURRENT_TIMESTAMP", "NOW", "LOCALTIME", "LOCALTIMESTAMP", "UTC_TIMESTAMP", "SYSDATE",
    ]
    private static let dateFunctions: Set<String> = [
        "CURDATE", "CURRENT_DATE", "UTC_DATE",
    ]
    private static let timeFunctions: Set<String> = [
        "CURTIME", "CURRENT_TIME", "UTC_TIME",
    ]

    private static func sqliteKeyword(for name: String) -> String? {
        if timestampFunctions.contains(name) { return "CURRENT_TIMESTAMP" }
        if dateFunctions.contains(name) { return "CURRENT_DATE" }
        if timeFunctions.contains(name) { return "CURRENT_TIME" }
        return nil
    }

    private static func matchingClose(_ slice: ArraySlice<Lexeme>, from openIndex: ArraySlice<Lexeme>.Index) -> ArraySlice<Lexeme>.Index? {
        guard slice[openIndex].token.isPunct("(") else { return nil }
        var depth = 0
        for idx in slice.indices[openIndex...] {
            if slice[idx].token.isPunct("(") {
                depth += 1
            } else if slice[idx].token.isPunct(")") {
                depth -= 1
                if depth == 0 {
                    return idx
                }
            }
        }
        return nil
    }

    private static func peeled(_ slice: ArraySlice<Lexeme>) -> ArraySlice<Lexeme>? {
        guard let firstIdx = slice.indices.first,
              let lastIdx = slice.indices.last,
              firstIdx < lastIdx,
              slice[firstIdx].token.isPunct("("),
              matchingClose(slice, from: firstIdx) == lastIdx
        else {
            return nil
        }
        return slice[slice.index(after: firstIdx)..<lastIdx]
    }

    /// `defaultSQL` is the parser's faithful, requoted MySQL text.
    public static func map(_ defaultSQL: String) -> MappedDefault {
        let bytes = Array(defaultSQL.utf8)
        guard bytes.contains(UInt8(ascii: "(")) else {
            return .keep(defaultSQL)
        }

        var slice = Lexer.lexAll(bytes)[...]

        // 1. Peel wrapper parens, but only when the first '(' closes at the last lexeme.
        //    "(uuid())" -> "uuid()"   "(1+2)" -> "1+2"   "(a)+(b)" -> no peel
        while let inner = peeled(slice) {
            slice = inner
        }
        if slice.isEmpty {
            return .unsupported      // degenerate "DEFAULT ()"
        }

        // 2. Is the whole remaining slice exactly one call?
        guard slice.count >= 3,
              let firstIdx = slice.indices.first,
              case .word(let name) = slice[firstIdx].token
        else {
            return .keep(defaultSQL) // the ORIGINAL text, not the peeled one
        }
        let secondIdx = slice.index(after: firstIdx)
        let lastIdx = slice.index(before: slice.endIndex)
        guard slice[secondIdx].token.isPunct("("),
              matchingClose(slice, from: secondIdx) == lastIdx
        else {
            return .keep(defaultSQL)
        }

        // 3. Name lookup, case-insensitive.
        guard let keyword = sqliteKeyword(for: name.uppercased()) else {
            return .unsupported
        }

        // 4. Only a bare fsp literal is ignorable. Anything else is meaning we would be
        //    silently discarding, so refuse rather than guess.
        let args = slice[slice.index(after: secondIdx)..<lastIdx]
        guard args.isEmpty || (args.count == 1 && isNumber(args.first?.token)) else {
            return .unsupported
        }

        return .keep(keyword)
    }

    private static func isNumber(_ token: Token?) -> Bool {
        if case .number = token { return true }
        return false
    }
}
