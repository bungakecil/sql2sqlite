import Testing
@testable import SQL2SQLiteKit

private func load(_ fixture: String, chunkSize: Int = 1 << 16,
                  options: ConverterOptions = ConverterOptions(),
                  diagnostics: Diagnostics = .discarding())
    throws -> (SQLiteWriter, ConversionSummary) {
    var o = options
    o.chunkSize = chunkSize
    let writer = try SQLiteWriter(path: ":memory:")
    let converter = Converter(writer: writer, diagnostics: diagnostics, options: o)
    let source = ArrayByteSource(try Fixture.bytes(fixture), chunkSize: chunkSize)
    return (writer, try converter.run(source: source))
}
private func text(_ w: SQLiteWriter, _ sql: String) throws -> String? {
    guard case .text(let b)? = try w.queryRow(sql)?.first else { return nil }
    return String(decoding: b, as: UTF8.self)
}

@Test func escapesRoundTripExactly() throws {
    let (w, s) = try load("escapes.sql")
    #expect(s.rows == 15)
    #expect(try text(w, "SELECT v FROM escapes WHERE id=1") == "it's; complicated")
    #expect(try text(w, "SELECT v FROM escapes WHERE id=2") == "doubled ' quote")
    #expect(try text(w, "SELECT v FROM escapes WHERE id=3") == #"back\slash"#)
    #expect(try text(w, "SELECT v FROM escapes WHERE id=4") == #"say "hi""#)
    #expect(try w.queryRow("SELECT v FROM escapes WHERE id=5")?[0]
            == .text(Array("nul".utf8) + [0x00] + Array("byte".utf8)))
    #expect(try text(w, "SELECT v FROM escapes WHERE id=10") == #"like\%pattern"#)
    #expect(try text(w, "SELECT v FROM escapes WHERE id=13") == "-- not a comment")
    #expect(try text(w, "SELECT v FROM escapes WHERE id=14") == "/* not a comment */")
    #expect(try text(w, "SELECT v FROM escapes WHERE id=15") == "# not a comment")
}

@Test func unicodeRoundTripsByteForByte() throws {
    let (w, s) = try load("unicode.sql")
    #expect(s.rows == 5)
    #expect(try text(w, "SELECT v FROM unicode WHERE id=1")?.contains("日本語") == true)
    #expect(try text(w, "SELECT v FROM unicode WHERE id=2")?.contains("👨‍👩‍👧‍👦") == true)
    #expect(try text(w, "SELECT v FROM unicode WHERE id=4")?.contains("مرحبا") == true)
}

@Test func blobLiteralsBecomeBlobs() throws {
    let (w, _) = try load("blobs.sql")
    #expect(try w.queryRow("SELECT b FROM blobs WHERE id=1")?[0] == .blob(Array("AB".utf8)))
    #expect(try w.queryRow("SELECT b FROM blobs WHERE id=2")?[0] == .blob(Array("Hello".utf8)))
    #expect(try w.queryRow("SELECT vb FROM blobs WHERE id=3")?[0] == .blob([0x00, 0xFF, 0x00]))
    #expect(try w.queryRow("SELECT b FROM blobs WHERE id=4")?[0] == .blob([]))
    #expect(try text(w, "SELECT typeof(b) FROM blobs WHERE id=1") == "blob")
    #expect(try w.queryRow("SELECT b FROM blobs WHERE id=5")?[0] == .null)
}

@Test func numericsPreserveWhatSQLiteCanRepresent() throws {
    let (w, _) = try load("numerics.sql")
    #expect(try text(w, "SELECT typeof(small_dec) FROM numerics WHERE id=1") == "real")
    #expect(try text(w, "SELECT CAST(big_int AS TEXT) FROM numerics WHERE id=1") != nil)
    // A value inside Int64 must stay an exact integer.
    #expect(try w.queryRow("SELECT big_int FROM numerics WHERE id=3")?[0]
            == .number(Array("9223372036854775807".utf8)))
    // b'10101010' is 170.
    #expect(try w.queryRow("SELECT bits FROM numerics WHERE id=1")?[0]
            == .number(Array("170".utf8)))
    #expect(try w.queryRow("SELECT sci FROM numerics WHERE id=1")?[0]
            == .number(Array("1500.0".utf8)))
}

@Test func schemaFixtureProducesAValidDatabase() throws {
    let (w, s) = try load("schema.sql")
    #expect(s.tables == 3)
    #expect(try text(w, "PRAGMA integrity_check") == "ok")
    #expect(try w.foreignKeyViolations().isEmpty)
    // The AUTO_INCREMENT PK became a real INTEGER PRIMARY KEY AUTOINCREMENT.
    #expect(try text(w, "SELECT sql FROM sqlite_master WHERE name='articles'")?
            .contains("INTEGER PRIMARY KEY AUTOINCREMENT") == true)
    // A generated column is computed by SQLite, not loaded from the dump.
    #expect(try w.queryRow("SELECT double_count FROM articles WHERE id=1")?[0]
            == .number(Array("6".utf8)))
    // `by_name` appears in all three tables; SQLite index names are schema-global.
    #expect(try w.queryRow("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE '%by_name%'")?[0]
            == .number(Array("3".utf8)))
    #expect(try text(w, "SELECT status FROM articles WHERE id=2") == "review")
}

@Test func viewsAreCreatedAndQueryable() throws {
    let (w, s) = try load("views.sql")
    #expect(s.views == 2)
    #expect(try w.queryRow("SELECT COUNT(*) FROM sqlite_master WHERE type='view'")?[0]
            == .number(Array("\(s.views)".utf8)))
    #expect(try w.queryRow("SELECT COUNT(*) FROM active_posts")?[0] == .number(Array("2".utf8)))
    // active_titles depends on active_posts and was declared first.
    #expect(try text(w, "SELECT title FROM active_titles ORDER BY title LIMIT 1") == "first")
}

@Test func skippedConstructsWarnWithoutDerailingTheRun() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let (w, s) = try load("skipped.sql", diagnostics: d)
    #expect(s.tables == 2)
    #expect(rec.lines.contains { $0.contains("skipped routine") })
    #expect(rec.lines.contains { $0.contains("FULLTEXT") })
    #expect(rec.lines.contains { $0.contains("SPATIAL") })
    #expect(try text(w, "PRAGMA integrity_check") == "ok")
    // The tables around the skipped routines still loaded.
    #expect(try w.queryRow("SELECT COUNT(*) FROM docs")?[0] == .number(Array("3".utf8)))
    #expect(try w.queryRow("SELECT COUNT(*) FROM shapes")?[0] == .number(Array("1".utf8)))
}

@Test func skippedFixtureFailsUnderStrict() throws {
    #expect(throws: ConversionError.self) {
        _ = try load("skipped.sql", diagnostics: .discarding(strict: true))
    }
}

@Test func mariaDBFixtureProducesAValidDatabase() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let (w, s) = try load("mariadb.sql", diagnostics: d)
    #expect(s.tables == 1)
    #expect(s.rows == 3)
    #expect(try text(w, "PRAGMA integrity_check") == "ok")
    #expect(rec.lines.contains { $0.contains("dropped attribute") && $0.contains("uuid") })
    let sql = try text(w, "SELECT sql FROM sqlite_master WHERE name='events'") ?? ""
    #expect(sql.contains(#""created_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP"#))
    #expect(sql.contains(#""updated_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP"#))
    #expect(sql.contains(#""event_date" TEXT DEFAULT CURRENT_DATE"#))
    #expect(sql.contains(#""tracking_id" TEXT"#))
    #expect(sql.contains("uuid") == false)
    #expect(sql.contains("()") == false)
}

@Test func mariaDBFixtureFailsUnderStrict() throws {
    #expect(throws: ConversionError.self) {
        _ = try load("mariadb.sql", diagnostics: .discarding(strict: true))
    }
}

// The whole reason ByteScanner exists: identical results at any chunk size.
@Test(arguments: [1, 7, 64, 512, 1 << 16])
func everyFixtureConvertsIdenticallyAtAnyChunkSize(chunkSize: Int) throws {
    for fixture in ["escapes.sql", "unicode.sql", "blobs.sql",
                    "numerics.sql", "schema.sql", "chunkboundary.sql",
                    "mariadb.sql"] {
        let (_, small) = try load(fixture, chunkSize: chunkSize)
        let (_, big) = try load(fixture, chunkSize: 1 << 16)
        #expect(small == big, "\(fixture) differed at chunkSize \(chunkSize)")
    }
}

@Test func chunkBoundaryFixtureLoadsEveryRow() throws {
    let (w, s) = try load("chunkboundary.sql", chunkSize: 64)
    #expect(s.rows == 200)
    #expect(try w.queryRow("SELECT COUNT(*) FROM chunky")?[0] == .number(Array("200".utf8)))
    #expect(try text(w, "SELECT v FROM chunky WHERE id=7")
            == #"delims: ; -- /* */ # ` " ' \ end"#)
    #expect(try text(w, "SELECT v FROM chunky WHERE id=99")
            == "doubled ' quote and ;semicolon;")
}
