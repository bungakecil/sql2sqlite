import ArgumentParser
import Foundation
import SQL2SQLiteKit

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct SQL2SQLiteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sql2sqlite",
        abstract: "Convert a mysqldump/mariadb-dump SQL file into a SQLite database.",
        discussion: """
        Reads a MySQL dump and writes a SQLite database, either to stdout \
        (redirect it) or to the path given by --output.

          sql2sqlite dump.sql > converted.sqlite
          sql2sqlite dump.sql -o converted.sqlite

        Schema, data and views are converted. Triggers, stored routines and \
        events are skipped with a warning on stderr.
        """,
        version: "1.0.0")

    @Argument(help: ArgumentHelp("The dump to read. Omit it, or pass \"-\", to read stdin.",
                                 valueName: "file.sql"))
    var input: String?

    @Option(name: [.short, .long], help: "Write the database directly to this path.")
    var output: String?

    @Flag(help: "Treat warnings as errors.")
    var strict = false

    @Flag(help: "Suppress per-warning output; the summary is still printed.")
    var quiet = false

    @Flag(name: .customLong("schema-only"), help: "Skip INSERT statements.")
    var schemaOnly = false

    @Flag(name: .customLong("data-only"), help: "Skip DDL; the target tables must already exist.")
    var dataOnly = false

    @Flag(name: .customLong("check-fk"), help: "Run PRAGMA foreign_key_check at the end.")
    var checkForeignKeys = false

    @Option(name: .customLong("batch-size"), help: "Rows per transaction.")
    var batchSize = 100_000

    func run() throws {
        if schemaOnly && dataOnly {
            throw ConversionError.usage("--schema-only and --data-only are mutually exclusive")
        }
        if batchSize < 1 {
            throw ConversionError.usage("--batch-size must be at least 1")
        }
        // A SQLite database is binary; dumping it into a terminal helps nobody.
        if output == nil && isatty(1) != 0 {
            throw ConversionError.usage(
                "refusing to write a SQLite database to a terminal; "
                + "redirect with `> out.sqlite` or use `-o out.sqlite`")
        }

        let source = try openInput()

        var temp: TempDatabase? = nil
        let databasePath: String
        if let output {
            // An existing database would be appended to rather than replaced.
            unlink(output)
            databasePath = output
        } else {
            let scratch = try TempDatabase()
            temp = scratch
            databasePath = scratch.path
        }
        defer { temp?.remove() }

        var options = ConverterOptions()
        options.schemaOnly = schemaOnly
        options.dataOnly = dataOnly
        options.checkForeignKeys = checkForeignKeys
        options.batchSize = batchSize

        // stdout carries database bytes, so every diagnostic goes to stderr.
        let diagnostics = Diagnostics(strict: strict, quiet: quiet) { line in
            FileHandle.standardError.write(Data("sql2sqlite: \(line)\n".utf8))
        }

        let writer = try SQLiteWriter(path: databasePath)
        let converter = Converter(writer: writer, diagnostics: diagnostics, options: options)
        let summary: ConversionSummary
        do {
            summary = try converter.run(source: source)
        } catch {
            writer.close()
            throw error
        }
        try writer.finish()

        // --quiet silences per-warning lines but keeps the end-of-run summary.
        FileHandle.standardError.write(
            Data("sql2sqlite: \(summary.describe(diagnostics: diagnostics))\n".utf8))

        if let temp {
            try temp.streamToStdout()
            temp.remove()
        }
    }

    private func openInput() throws -> any ByteSource {
        guard let input, input != "-" else {
            return FileByteSource(fileDescriptor: 0, closeWhenDone: false)
        }
        return try FileByteSource.open(path: input)
    }
}

@main
struct Runner {
    static func main() {
        do {
            var command = try SQL2SQLiteCommand.parseAsRoot()
            try command.run()
            exit(0)
        } catch let error as ConversionError {
            if case .usage(let message) = error {
                FileHandle.standardError.write(Data("sql2sqlite: \(message)\n".utf8))
                exit(2)
            }
            FileHandle.standardError.write(
                Data("sql2sqlite: error: \(error.description)\n".utf8))
            exit(1)
        } catch {
            // --help and --version arrive here with a .success exit code.
            let text = SQL2SQLiteCommand.fullMessage(for: error)
            if SQL2SQLiteCommand.exitCode(for: error) == .success {
                print(text)
                exit(0)
            }
            FileHandle.standardError.write(Data((text + "\n").utf8))
            exit(2)
        }
    }
}
