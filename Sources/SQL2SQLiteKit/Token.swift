public enum Token: Equatable {
    case word(String)          // bareword: keyword or unquoted identifier, original case
    case quotedIdent(String)   // `x` - already unescaped
    case string([UInt8])       // raw literal bytes INCLUDING the quotes
    case number(String)        // 12, 1.5, 1.5e3 - sign is a separate punct token
    case hexLiteral([UInt8])   // 0xDEAD or X'DEAD' - decoded bytes
    case bitLiteral(String)    // 0b0101 or b'0101' - the digits
    case punct(UInt8)
}

extension Token {
    public var wordValue: String? {
        if case .word(let w) = self { return w }
        return nil
    }

    /// A bareword or a backticked identifier, whichever this token is.
    public var identifierValue: String? {
        switch self {
        case .word(let w):        return w
        case .quotedIdent(let w): return w
        default:                  return nil
        }
    }

    public func isKeyword(_ kw: String) -> Bool {
        guard case .word(let w) = self else { return false }
        return w.lowercased() == kw.lowercased()
    }

    public func isPunct(_ c: UnicodeScalar) -> Bool {
        guard case .punct(let b) = self else { return false }
        return b == UInt8(ascii: c)
    }
}

public struct Lexeme: Equatable {
    public let token: Token
    public let range: Range<Int>   // byte range in the source slice

    public init(token: Token, range: Range<Int>) {
        self.token = token
        self.range = range
    }
}

@inlinable
func isASCIIDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

@inlinable
func isHexDigit(_ b: UInt8) -> Bool {
    isASCIIDigit(b) || (b | 0x20) >= 0x61 && (b | 0x20) <= 0x66
}

/// Bareword start: letters, `_`, `$`, and any byte >= 0x80 so that UTF-8
/// identifiers and latin1 bytes both lex as one word rather than fragmenting.
@inlinable
func isWordStart(_ b: UInt8) -> Bool {
    let lower = b | 0x20
    return (lower >= 0x61 && lower <= 0x7A) || b == UInt8(ascii: "_") || b == UInt8(ascii: "$") || b >= 0x80
}

@inlinable
func isWordContinue(_ b: UInt8) -> Bool { isWordStart(b) || isASCIIDigit(b) }

public struct Lexer {
    private let bytes: [UInt8]
    private var i: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.i = 0
    }

    public static func lexAll(_ bytes: [UInt8]) -> [Lexeme] {
        var lexer = Lexer(bytes)
        var out: [Lexeme] = []
        while let l = lexer.next() { out.append(l) }
        return out
    }

    private func hexValue(_ b: UInt8) -> UInt8 {
        if isASCIIDigit(b) { return b - 0x30 }
        return (b | 0x20) - 0x61 + 10
    }

    /// Decodes an even or odd run of hex digits; an odd count left-pads a zero nibble.
    private func decodeHex(_ digits: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var pending: UInt8? = digits.count % 2 == 0 ? nil : 0
        for d in digits {
            let v = hexValue(d)
            if let high = pending {
                out.append(high << 4 | v)
                pending = nil
            } else {
                pending = v
            }
        }
        return out
    }

    /// Consumes whitespace and comments. The splitter already removed comments,
    /// so this is defensive for callers that lex raw fragments.
    private mutating func skipTrivia() {
        while i < bytes.count {
            let c = bytes[i]
            if isSQLSpace(c) { i += 1; continue }
            if c == UInt8(ascii: "#") {
                while i < bytes.count && bytes[i] != 0x0A { i += 1 }
                continue
            }
            if c == UInt8(ascii: "-"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "-"),
               i + 2 >= bytes.count || isSQLSpace(bytes[i + 2]) {
                while i < bytes.count && bytes[i] != 0x0A { i += 1 }
                continue
            }
            if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count && !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) {
                    i += 1
                }
                i = min(i + 2, bytes.count)
                continue
            }
            return
        }
    }

    /// Consumes a quoted run and returns its byte range, quotes included.
    /// `honoursBackslash` is false for backticks, matching MySQL.
    private mutating func consumeQuoted(_ quote: UInt8, honoursBackslash: Bool) {
        i += 1
        while i < bytes.count {
            let c = bytes[i]
            if honoursBackslash, c == UInt8(ascii: "\\"), i + 1 < bytes.count {
                i += 2
                continue
            }
            if c == quote {
                if i + 1 < bytes.count, bytes[i + 1] == quote { i += 2; continue }
                i += 1
                return
            }
            i += 1
        }
    }

    public mutating func next() -> Lexeme? {
        skipTrivia()
        guard i < bytes.count else { return nil }
        let start = i
        let c = bytes[i]

        // Backticked identifier.
        if c == UInt8(ascii: "`") {
            consumeQuoted(c, honoursBackslash: false)
            let inner = bytes[(start + 1)..<max(start + 1, i - 1)]
            var name = ""
            var j = inner.startIndex
            var raw: [UInt8] = []
            while j < inner.endIndex {
                if inner[j] == UInt8(ascii: "`"), inner.index(after: j) < inner.endIndex,
                   inner[inner.index(after: j)] == UInt8(ascii: "`") {
                    raw.append(UInt8(ascii: "`"))
                    j = inner.index(j, offsetBy: 2)
                    continue
                }
                raw.append(inner[j])
                j = inner.index(after: j)
            }
            name = String(decoding: raw, as: UTF8.self)
            return Lexeme(token: .quotedIdent(name), range: start..<i)
        }

        // String literal, single- or double-quoted. mysqldump does not set
        // ANSI_QUOTES, so a double-quoted run is a string, not an identifier.
        if c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") {
            consumeQuoted(c, honoursBackslash: true)
            return Lexeme(token: .string(Array(bytes[start..<i])), range: start..<i)
        }

        // Bareword, or an X'..' / B'..' literal introducer.
        if isWordStart(c) {
            var j = i
            while j < bytes.count && isWordContinue(bytes[j]) { j += 1 }
            let word = String(decoding: bytes[i..<j], as: UTF8.self)
            let lowerWord = word.lowercased()
            if (lowerWord == "x" || lowerWord == "b"), j < bytes.count, bytes[j] == UInt8(ascii: "'") {
                i = j
                consumeQuoted(UInt8(ascii: "'"), honoursBackslash: false)
                let digits = bytes[(j + 1)..<max(j + 1, i - 1)]
                if lowerWord == "x" {
                    return Lexeme(token: .hexLiteral(decodeHex(digits)), range: start..<i)
                }
                return Lexeme(token: .bitLiteral(String(decoding: digits, as: UTF8.self)),
                              range: start..<i)
            }
            i = j
            return Lexeme(token: .word(word), range: start..<i)
        }

        // 0x.. hex blob and 0b.. bit literals.
        if c == UInt8(ascii: "0"), i + 1 < bytes.count {
            let marker = bytes[i + 1] | 0x20
            if marker == UInt8(ascii: "x") {
                var j = i + 2
                while j < bytes.count && isHexDigit(bytes[j]) { j += 1 }
                // `0x` with no digits is MySQL's zero-length blob.
                i = j
                return Lexeme(token: .hexLiteral(decodeHex(bytes[(start + 2)..<j])), range: start..<i)
            }
            if marker == UInt8(ascii: "b"), i + 2 < bytes.count,
               bytes[i + 2] == UInt8(ascii: "0") || bytes[i + 2] == UInt8(ascii: "1") {
                var j = i + 2
                while j < bytes.count && (bytes[j] == UInt8(ascii: "0") || bytes[j] == UInt8(ascii: "1")) { j += 1 }
                i = j
                return Lexeme(token: .bitLiteral(String(decoding: bytes[(start + 2)..<j], as: UTF8.self)),
                              range: start..<i)
            }
        }

        // Number: digits, an optional fraction and an optional exponent.
        if isASCIIDigit(c) || (c == UInt8(ascii: ".") && i + 1 < bytes.count && isASCIIDigit(bytes[i + 1])) {
            var j = i
            while j < bytes.count && isASCIIDigit(bytes[j]) { j += 1 }
            if j < bytes.count, bytes[j] == UInt8(ascii: ".") {
                j += 1
                while j < bytes.count && isASCIIDigit(bytes[j]) { j += 1 }
            }
            if j < bytes.count, (bytes[j] | 0x20) == UInt8(ascii: "e") {
                var k = j + 1
                if k < bytes.count, bytes[k] == UInt8(ascii: "+") || bytes[k] == UInt8(ascii: "-") { k += 1 }
                if k < bytes.count, isASCIIDigit(bytes[k]) {
                    while k < bytes.count && isASCIIDigit(bytes[k]) { k += 1 }
                    j = k
                }
            }
            i = j
            return Lexeme(token: .number(String(decoding: bytes[start..<i], as: UTF8.self)),
                          range: start..<i)
        }

        i += 1
        return Lexeme(token: .punct(c), range: start..<i)
    }
}

/// Rewrites MySQL quoting into SQLite quoting: `x` becomes "x", and a MySQL
/// double-quoted string becomes a single-quoted one. Everything else - spacing,
/// operators, numbers - is copied byte-for-byte so the source formatting survives.
public func requoteIdentifiers(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = []
    var cursor = 0
    for lexeme in Lexer.lexAll(bytes) {
        if lexeme.range.lowerBound > cursor {
            out.append(contentsOf: bytes[cursor..<lexeme.range.lowerBound])
        }
        switch lexeme.token {
        case .quotedIdent(let name):
            out.append(contentsOf: Array(StringEscapes.quoteIdentifier(name).utf8))
        case .string(let raw) where raw.first == UInt8(ascii: "\""):
            let payload = StringEscapes.decode(raw)
            out.append(UInt8(ascii: "'"))
            for b in payload {
                if b == UInt8(ascii: "'") { out.append(b) }
                out.append(b)
            }
            out.append(UInt8(ascii: "'"))
        default:
            out.append(contentsOf: bytes[lexeme.range])
        }
        cursor = lexeme.range.upperBound
    }
    if cursor < bytes.count { out.append(contentsOf: bytes[cursor...]) }
    return String(decoding: out, as: UTF8.self)
}
