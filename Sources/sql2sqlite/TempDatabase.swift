import Foundation
import SQL2SQLiteKit

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The path a signal handler must unlink. It is a raw C string because only
/// async-signal-safe calls are legal from a handler, and `nonisolated(unsafe)`
/// because Swift 6 otherwise rejects a mutable global.
nonisolated(unsafe) private var tempPathForCleanup: UnsafeMutablePointer<CChar>?

private let cleanupHandler: @convention(c) (Int32) -> Void = { sig in
    if let p = tempPathForCleanup { unlink(p) }   // unlink is async-signal-safe
    signal(sig, SIG_DFL)
    raise(sig)                                    // preserve the exit status
}

/// SQLite needs a seekable file descriptor and cannot write to a pipe, so the
/// stdout path builds the database in a temp file and streams it out afterwards.
/// Peak disk is about 2x the database size; `-o` avoids that entirely.
final class TempDatabase {
    let path: String
    private var removed = false

    init() throws {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        // mkstemp creates the file mode 0600 and guarantees exclusivity, which a
        // hand-rolled name would not: that is a symlink race.
        var template = Array("\(dir)/sql2sqlite-XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else {
            throw ConversionError.io(
                "cannot create a temporary file in \(dir): \(String(cString: strerror(errno)))")
        }
        close(fd)                                   // sqlite3_open reopens it by path
        path = String(cString: template)

        tempPathForCleanup = strdup(path)
        signal(SIGINT, cleanupHandler)
        signal(SIGTERM, cleanupHandler)
        signal(SIGHUP, cleanupHandler)
    }

    deinit { remove() }

    func remove() {
        guard !removed else { return }
        removed = true
        unlink(path)
        if let p = tempPathForCleanup {
            tempPathForCleanup = nil
            free(p)
        }
    }

    /// Copies the finished database to fd 1, handling partial writes and EINTR.
    func streamToStdout() throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw ConversionError.io("cannot reopen \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        let chunkSize = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            var readCount = 0
            try buffer.withUnsafeMutableBytes { raw in
                var r = 0
                repeat {
                    r = read(fd, raw.baseAddress, raw.count)
                } while r < 0 && errno == EINTR
                if r < 0 {
                    throw ConversionError.io("read failed: \(String(cString: strerror(errno)))")
                }
                readCount = r
            }
            if readCount == 0 { return }

            var written = 0
            while written < readCount {
                let w = buffer.withUnsafeBytes { raw -> Int in
                    write(1, raw.baseAddress!.advanced(by: written), readCount - written)
                }
                if w < 0 {
                    if errno == EINTR { continue }
                    throw ConversionError.io("write to stdout failed: \(String(cString: strerror(errno)))")
                }
                written += w
            }
        }
    }
}
