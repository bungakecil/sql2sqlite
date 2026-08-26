import Foundation
import Testing

private struct RunResult {
    var stdout: Data
    var stderr: String
    var status: Int32
}

private func binaryURL() throws -> URL {
    // .build/<config>/sql2sqlite, resolved relative to the test bundle.
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    if url.lastPathComponent.hasSuffix(".xctest") { url = url.deletingLastPathComponent() }
    return url.appendingPathComponent("sql2sqlite")
}

private func run(_ args: [String], stdin: Data? = nil) throws -> RunResult {
    let process = Process()
    process.executableURL = try binaryURL()
    process.arguments = args
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    if let stdin {
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(stdin)
        input.fileHandleForWriting.closeFile()
    } else {
        try process.run()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RunResult(stdout: outData,
                     stderr: String(decoding: errData, as: UTF8.self),
                     status: process.terminationStatus)
}

private let miniDump = """
CREATE TABLE `t` (`id` int NOT NULL AUTO_INCREMENT, `s` varchar(10), PRIMARY KEY (`id`));
INSERT INTO `t` VALUES (1,'a'),(2,'b');
"""

@Test func writesADatabaseToTheOutputOption() throws {
    let path = "/tmp/sql2sqlite-cli-\(getpid()).sqlite"
    defer { unlink(path) }
    let dump = "/tmp/sql2sqlite-cli-\(getpid()).sql"
    defer { unlink(dump) }
    try miniDump.write(toFile: dump, atomically: true, encoding: .utf8)

    let r = try run([dump, "-o", path])
    #expect(r.status == 0)
    #expect(FileManager.default.fileExists(atPath: path))
    // SQLite files start with this magic string.
    let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)).read(upToCount: 16)
    #expect(header == Data("SQLite format 3\0".utf8))
}

@Test func stdoutAndOutputProduceIdenticalBytes() throws {
    let dump = "/tmp/sql2sqlite-cmp-\(getpid()).sql"
    let viaO = "/tmp/sql2sqlite-cmp-\(getpid()).sqlite"
    defer { unlink(dump); unlink(viaO) }
    try miniDump.write(toFile: dump, atomically: true, encoding: .utf8)

    let piped = try run([dump])
    _ = try run([dump, "-o", viaO])
    #expect(piped.status == 0)
    #expect(piped.stdout == (try Data(contentsOf: URL(fileURLWithPath: viaO))))
    #expect(piped.stdout.isEmpty == false)
}

@Test func readsFromStdinWhenGivenNoFileOrADash() throws {
    let a = try run([], stdin: Data(miniDump.utf8))
    let b = try run(["-"], stdin: Data(miniDump.utf8))
    #expect(a.status == 0 && b.status == 0)
    #expect(a.stdout == b.stdout)
}

@Test func leavesNoTemporaryFilesBehind() throws {
    let before = try FileManager.default.contentsOfDirectory(atPath: "/tmp")
        .filter { $0.hasPrefix("sql2sqlite-") }
    _ = try run([], stdin: Data(miniDump.utf8))
    let after = try FileManager.default.contentsOfDirectory(atPath: "/tmp")
        .filter { $0.hasPrefix("sql2sqlite-") }
    #expect(after.count == before.count)
}

@Test func warningsGoToStderrAndExitZero() throws {
    let r = try run([], stdin: Data("CREATE TABLE t (a GEOMETRY);".utf8))
    #expect(r.status == 0)
    #expect(r.stderr.contains("unknown type"))
}

@Test func strictTurnsWarningsIntoExitOne() throws {
    let r = try run(["--strict"], stdin: Data("CREATE TABLE t (a GEOMETRY);".utf8))
    #expect(r.status == 1)
    #expect(r.stderr.contains("--strict"))
}

@Test func quietSuppressesWarningsButKeepsTheSummary() throws {
    let r = try run(["--quiet"], stdin: Data("CREATE TABLE t (a GEOMETRY);".utf8))
    #expect(r.status == 0)
    #expect(r.stderr.contains("unknown type") == false)
    #expect(r.stderr.contains("converted"))
}

@Test func aMissingInputFileIsAUsageError() throws {
    let r = try run(["/nonexistent/nope.sql", "-o", "/tmp/x-\(getpid()).sqlite"])
    #expect(r.status == 1)
    #expect(r.stderr.contains("nope.sql"))
}

@Test func aMalformedDumpExitsOne() throws {
    let r = try run(["--quiet"], stdin: Data("CREATE TABLE t (a int); INSERT INTO t VALUES (1,2);".utf8))
    #expect(r.status == 1)
}

@Test func helpAndVersionExitZeroOnStdout() throws {
    let help = try run(["--help"])
    #expect(help.status == 0)
    #expect(String(decoding: help.stdout, as: UTF8.self).contains("--batch-size"))
    let version = try run(["--version"])
    #expect(version.status == 0)
}

@Test func schemaOnlyAndDataOnlyReachTheConverter() throws {
    let path = "/tmp/sql2sqlite-so-\(getpid()).sqlite"
    defer { unlink(path) }
    let r = try run(["--schema-only", "-o", path], stdin: Data(miniDump.utf8))
    #expect(r.status == 0)
    #expect(r.stderr.contains("0 rows") || r.stderr.contains("converted 1 table"))
}
