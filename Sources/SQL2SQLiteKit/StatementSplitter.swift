public struct Statement: Equatable {
    public let bytes: [UInt8]
    public let byteOffset: Int
    public let line: Int

    public init(bytes: [UInt8], byteOffset: Int, line: Int) {
        self.bytes = bytes
        self.byteOffset = byteOffset
        self.line = line
    }

    /// Lossy - for diagnostics and tests only. Never use for data.
    public var text: String { String(decoding: bytes, as: UTF8.self) }
}

public final class StatementSplitter {
    /// Executable comments gated above this version are treated as inert.
    /// MariaDB's `/*!999999\- enable the sandbox mode */` is the reason this exists;
    /// every genuine version gate (max about 110700) is far below it.
    private static let assumedServerVersion = 999_998
    private static let delimiterKeyword = Array("delimiter".utf8)

    private let scanner: ByteScanner
    private let diagnostics: Diagnostics
    private var delimiter: [UInt8] = [UInt8(ascii: ";")]
    private var execDepth = 0

    public init(scanner: ByteScanner, diagnostics: Diagnostics) {
        self.scanner = scanner
        self.diagnostics = diagnostics
    }

    public func next() throws -> Statement? {
        var buf: [UInt8] = []
        var startOffset = 0
        var startLine = 1

        while true {
            let here = scanner.offset
            let hereLine = scanner.line

            guard let c = try scanner.peek() else {
                trimTrailingSpace(&buf)
                if buf.isEmpty { return nil }
                if execDepth > 0 {
                    try diagnostics.warn(.malformed,
                        "unterminated /*! ... */ comment at end of input",
                        offset: here, line: hereLine)
                }
                return Statement(bytes: buf, byteOffset: startOffset, line: startLine)
            }

            // Whitespace before a statement begins is not part of it.
            if buf.isEmpty && isSQLSpace(c) {
                try scanner.skip(1)
                continue
            }

            // `#` line comment.
            if c == UInt8(ascii: "#") {
                try skipToEndOfLine()
                appendSeparator(&buf)
                continue
            }

            // `-- ` line comment. MySQL requires whitespace (or EOF) after the dashes.
            if c == UInt8(ascii: "-"), try scanner.peek(1) == UInt8(ascii: "-") {
                let third = try scanner.peek(2)
                if third == nil || isSQLSpace(third!) {
                    try skipToEndOfLine()
                    appendSeparator(&buf)
                    continue
                }
            }

            // Block comment, executable or inert.
            if c == UInt8(ascii: "/"), try scanner.peek(1) == UInt8(ascii: "*") {
                if try scanner.peek(2) == UInt8(ascii: "!") {
                    try scanner.skip(3)
                    let version = try readVersionDigits()
                    if version > Self.assumedServerVersion {
                        try skipToBlockCommentEnd()
                        appendSeparator(&buf)
                    } else {
                        execDepth += 1   // contents flow into the statement verbatim
                    }
                } else {
                    try scanner.skip(2)
                    try skipToBlockCommentEnd()
                    appendSeparator(&buf)
                }
                continue
            }

            // Closing an unwrapped executable comment.
            if execDepth > 0, c == UInt8(ascii: "*"), try scanner.peek(1) == UInt8(ascii: "/") {
                try scanner.skip(2)
                execDepth -= 1
                appendSeparator(&buf)
                continue
            }

            // `DELIMITER <token>` is a client command, valid only at statement start.
            if buf.isEmpty, try scanner.matches(Self.delimiterKeyword) {
                if let after = try scanner.peek(Self.delimiterKeyword.count), isSQLSpace(after) {
                    try readDelimiterCommand(offset: here, line: hereLine)
                    continue
                }
            }

            // Statement terminator.
            if try scanner.matches(delimiter, caseInsensitive: false) {
                try scanner.skip(delimiter.count)
                trimTrailingSpace(&buf)
                if buf.isEmpty { continue }
                return Statement(bytes: buf, byteOffset: startOffset, line: startLine)
            }

            // Quoted string or identifier: copied verbatim, quotes included.
            if c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") || c == UInt8(ascii: "`") {
                if buf.isEmpty { startOffset = here; startLine = hereLine }
                try copyQuoted(opener: c, into: &buf)
                continue
            }

            // Ordinary byte.
            if buf.isEmpty { startOffset = here; startLine = hereLine }
            buf.append(c)
            try scanner.skip(1)
        }
    }

    /// A dropped comment must not fuse the tokens on either side of it.
    /// Only meaningful once the statement has started; leading separators are noise.
    private func appendSeparator(_ buf: inout [UInt8]) {
        if !buf.isEmpty { buf.append(UInt8(ascii: " ")) }
    }

    private func trimTrailingSpace(_ buf: inout [UInt8]) {
        while let last = buf.last, isSQLSpace(last) { buf.removeLast() }
    }

    private func skipToEndOfLine() throws {
        while let c = try scanner.peek() {
            try scanner.skip(1)
            if c == 0x0A { return }
        }
    }

    /// Assumes the opening `/*` (and, for executable comments, `!NNNNN`) is consumed.
    private func skipToBlockCommentEnd() throws {
        while let c = try scanner.peek() {
            if c == UInt8(ascii: "*"), try scanner.peek(1) == UInt8(ascii: "/") {
                try scanner.skip(2)
                return
            }
            try scanner.skip(1)
        }
    }

    private func readVersionDigits() throws -> Int {
        var digits = ""
        while let c = try scanner.peek(), c >= 0x30, c <= 0x39, digits.count < 6 {
            digits.append(Character(UnicodeScalar(c)))
            try scanner.skip(1)
        }
        return Int(digits) ?? 0
    }

    private func readDelimiterCommand(offset: Int, line: Int) throws {
        try scanner.skip(Self.delimiterKeyword.count)
        while let c = try scanner.peek(), isSQLSpace(c), c != 0x0A { try scanner.skip(1) }
        var token: [UInt8] = []
        while let c = try scanner.peek(), !isSQLSpace(c) {
            token.append(c)
            try scanner.skip(1)
        }
        try skipToEndOfLine()
        if token.isEmpty {
            try diagnostics.warn(.malformed, "DELIMITER with no argument; keeping ';'",
                                 offset: offset, line: line)
        } else {
            delimiter = token
        }
    }

    /// Copies a quoted run verbatim, including its quotes, so downstream parsers
    /// can re-lex it. Backticked identifiers do not honour backslash escapes.
    private func copyQuoted(opener: UInt8, into buf: inout [UInt8]) throws {
        let honoursBackslash = (opener != UInt8(ascii: "`"))
        buf.append(opener)
        try scanner.skip(1)
        while let c = try scanner.peek() {
            if honoursBackslash, c == UInt8(ascii: "\\") {
                buf.append(c)
                try scanner.skip(1)
                if let escaped = try scanner.peek() {
                    buf.append(escaped)
                    try scanner.skip(1)
                }
                continue
            }
            if c == opener {
                if try scanner.peek(1) == opener {      // doubled: still inside
                    buf.append(c); buf.append(c)
                    try scanner.skip(2)
                    continue
                }
                buf.append(c)
                try scanner.skip(1)
                return
            }
            buf.append(c)
            try scanner.skip(1)
        }
        try diagnostics.warn(.malformed,
            "unterminated \(Character(UnicodeScalar(opener)))-quoted literal",
            offset: scanner.offset, line: scanner.line)
    }
}
