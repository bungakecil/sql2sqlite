@inlinable
func asciiLower(_ b: UInt8) -> UInt8 {
    (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
}

@inlinable
func isSQLSpace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
}

public final class ByteScanner {
    private let source: any ByteSource
    private var buffer: [UInt8] = []
    private var pos = 0
    private var exhausted = false

    /// Absolute byte offset of the next unconsumed byte.
    public private(set) var offset = 0
    /// 1-based line number of the next unconsumed byte.
    public private(set) var line = 1

    public init(source: any ByteSource) { self.source = source }

    /// Makes at least `count` bytes available ahead of the cursor if the input has them.
    @discardableResult
    private func ensure(_ count: Int) throws -> Bool {
        while !exhausted && buffer.count - pos < count {
            guard let chunk = try source.nextChunk() else { exhausted = true; break }
            // Reclaim consumed bytes so memory stays bounded on long inputs.
            if pos >= 4096 {
                buffer.removeFirst(pos)
                pos = 0
            }
            buffer.append(contentsOf: chunk)
        }
        return buffer.count - pos >= count
    }

    public func peek(_ ahead: Int = 0) throws -> UInt8? {
        try ensure(ahead + 1)
        let i = pos + ahead
        return i < buffer.count ? buffer[i] : nil
    }

    @discardableResult
    public func advance() throws -> UInt8? {
        guard let c = try peek() else { return nil }
        pos += 1
        offset += 1
        if c == 0x0A { line += 1 }
        return c
    }

    public func skip(_ n: Int) throws {
        for _ in 0..<n {
            if try advance() == nil { return }
        }
    }

    /// Compares the upcoming bytes against `word` without consuming anything.
    public func matches(_ word: [UInt8], caseInsensitive: Bool = true) throws -> Bool {
        guard try ensure(word.count) else { return false }
        for (i, w) in word.enumerated() {
            let b = buffer[pos + i]
            if caseInsensitive {
                if asciiLower(b) != asciiLower(w) { return false }
            } else if b != w {
                return false
            }
        }
        return true
    }
}
