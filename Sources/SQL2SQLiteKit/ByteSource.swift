#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public protocol ByteSource: AnyObject {
    /// The next chunk of input, or nil at end of input. Never returns an empty chunk.
    func nextChunk() throws -> [UInt8]?
}

public final class ArrayByteSource: ByteSource {
    private let bytes: [UInt8]
    private let chunkSize: Int
    private var pos = 0

    public init(_ bytes: [UInt8], chunkSize: Int = 1 << 16) {
        self.bytes = bytes
        self.chunkSize = max(1, chunkSize)
    }

    public func nextChunk() throws -> [UInt8]? {
        guard pos < bytes.count else { return nil }
        let end = min(pos + chunkSize, bytes.count)
        defer { pos = end }
        return Array(bytes[pos..<end])
    }
}

public final class FileByteSource: ByteSource {
    private let fd: Int32
    private let chunkSize: Int
    private let closeWhenDone: Bool
    private var closed = false

    public init(fileDescriptor: Int32, chunkSize: Int = 1 << 16, closeWhenDone: Bool) {
        self.fd = fileDescriptor
        self.chunkSize = max(1, chunkSize)
        self.closeWhenDone = closeWhenDone
    }

    deinit { if closeWhenDone && !closed { close(fd) } }

    public func nextChunk() throws -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: chunkSize)
        var n = 0
        try buf.withUnsafeMutableBytes { raw in
            var r = 0
            repeat {
                r = read(fd, raw.baseAddress, raw.count)
            } while r < 0 && errno == EINTR
            if r < 0 { throw ConversionError.io("read failed: \(String(cString: strerror(errno)))") }
            n = r
        }
        guard n > 0 else {
            if closeWhenDone && !closed { close(fd); closed = true }
            return nil
        }
        buf.removeLast(chunkSize - n)
        return buf
    }

    /// Opens `path` for reading, or throws a readable IO error.
    public static func open(path: String, chunkSize: Int = 1 << 16) throws -> FileByteSource {
#if canImport(Glibc)
        let fd = path.withCString { Glibc.open($0, O_RDONLY) }
#else
        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
#endif
        guard fd >= 0 else {
            throw ConversionError.io("cannot open \(path): \(String(cString: strerror(errno)))")
        }
        return FileByteSource(fileDescriptor: fd, chunkSize: chunkSize, closeWhenDone: true)
    }
}
