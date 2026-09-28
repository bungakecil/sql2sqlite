import Foundation
import Testing
@testable import SQL2SQLiteKit

private func writer() throws -> SQLiteWriter { try SQLiteWriter(path: ":memory:") }

@Test func createsATableAndReadsBackBoundValues() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("i" INTEGER, "r" REAL, "s" TEXT, "b" BLOB)"#)
    try w.insertRow(table: "t", columns: ["i", "r", "s", "b"],
                    affinities: [.integer, .real, .text, .blob],
                    values: [.number(Array("42".utf8)),
                             .number(Array("1.5".utf8)),
                             .text(Array("hello".utf8)),
                             .blob([0x00, 0xFF, 0x41])])
    let row = try #require(try w.queryRow("SELECT i, r, s, b FROM t"))
    #expect(row[0] == .number(Array("42".utf8)))
    #expect(row[2] == .text(Array("hello".utf8)))
    #expect(row[3] == .blob([0x00, 0xFF, 0x41]))
}

@Test func numericLiteralsAreConvertedByColumnAffinity() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("i" INTEGER, "s" TEXT)"#)
    try w.insertRow(table: "t", columns: ["i", "s"], affinities: [.integer, .text],
                    values: [.number(Array("42".utf8)), .number(Array("42".utf8))])
    #expect(try w.queryRow("SELECT typeof(i), typeof(s) FROM t").map { row in
        row.map { if case .text(let b) = $0 { String(decoding: b, as: UTF8.self) } else { "?" } }
    } == ["integer", "text"])
}

@Test func textBoundToABlobColumnIsStoredAsABlob() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("b" BLOB)"#)
    try w.insertRow(table: "t", columns: ["b"], affinities: [.blob],
                    values: [.text([0x41, 0x00, 0x42])])
    #expect(try w.queryRow("SELECT b FROM t")?[0] == .blob([0x41, 0x00, 0x42]))
}

@Test func anEmptyBlobIsStoredAsAnEmptyBlobNotNull() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("b" BLOB)"#)
    try w.insertRow(table: "t", columns: ["b"], affinities: [.blob], values: [.blob([])])
    #expect(try w.queryRow("SELECT b FROM t")?[0] == .blob([]))
    #expect(try w.queryRow("SELECT b IS NULL FROM t")?[0] == .number(Array("0".utf8)))
}

@Test func embeddedNulBytesSurviveInTextColumns() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("s" TEXT)"#)
    try w.insertRow(table: "t", columns: ["s"], affinities: [.text],
                    values: [.text([0x61, 0x00, 0x62])])
    #expect(try w.queryRow("SELECT s FROM t")?[0] == .text([0x61, 0x00, 0x62]))
}

@Test func invalidUTF8SurvivesUntouched() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("s" TEXT)"#)
    try w.insertRow(table: "t", columns: ["s"], affinities: [.text], values: [.text([0x63, 0xE9])])
    #expect(try w.queryRow("SELECT s FROM t")?[0] == .text([0x63, 0xE9]))
}

@Test func nullsBind() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("s" TEXT)"#)
    try w.insertRow(table: "t", columns: ["s"], affinities: [.text], values: [.null])
    #expect(try w.queryRow("SELECT s FROM t")?[0] == .null)
}

@Test func reusesOnePreparedStatementAcrossManyRows() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("i" INTEGER)"#)
    try w.beginTransaction()
    for i in 0..<1000 {
        try w.insertRow(table: "t", columns: ["i"], affinities: [.integer],
                        values: [.number(Array(String(i).utf8))])
    }
    try w.commit()
    #expect(try w.queryRow("SELECT COUNT(*) FROM t")?[0] == .number(Array("1000".utf8)))
}

@Test func reportsSQLErrorsWithTheOffendingStatement() {
    #expect(throws: ConversionError.self) {
        let w = try writer()
        try w.exec("CREATE TABLE (")
    }
}

@Test func readsTableInfoForDataOnlyRuns() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("a" INTEGER, "b" TEXT, "c" BLOB)"#)
    let info = try w.tableInfo("t")
    #expect(info.map(\.name) == ["a", "b", "c"])
    #expect(info.map(\.declaredType) == ["INTEGER", "TEXT", "BLOB"])
}

@Test func detectsForeignKeyViolations() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE p ("id" INTEGER PRIMARY KEY)"#)
    try w.exec(#"CREATE TABLE c ("p" INTEGER, FOREIGN KEY ("p") REFERENCES "p" ("id"))"#)
    try w.insertRow(table: "c", columns: ["p"], affinities: [.integer],
                    values: [.number(Array("99".utf8))])
    #expect(try w.foreignKeyViolations().isEmpty == false)
}

@Test func writesAFileThatSQLiteCanReopen() throws {
    let path = "/tmp/sql2sqlite-writer-test-\(getpid()).sqlite"
    defer { unlink(path) }
    let w = try SQLiteWriter(path: path)
    try w.exec(#"CREATE TABLE t ("a" INTEGER)"#)
    try w.insertRow(table: "t", columns: ["a"], affinities: [.integer],
                    values: [.number(Array("7".utf8))])
    try w.finish()

    let reopened = try SQLiteWriter(path: path)
    #expect(try reopened.queryRow("SELECT a FROM t")?[0] == .number(Array("7".utf8)))
    #expect(try reopened.queryRow("PRAGMA integrity_check")?[0] == .text(Array("ok".utf8)))
}

@Test func insertColumnInfoKeepsGeneratedColumnsInOrderAndMarksThemNonwritable() throws {
    let w = try writer()
    try w.exec("""
    CREATE TABLE t ("a" INTEGER, "s" INTEGER GENERATED ALWAYS AS (a + 1) STORED,
                    "b" TEXT, "v" INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL, "c" REAL)
    """)
    #expect(try w.insertColumnInfo("t") == [
        InsertColumnInfo(name: "a", declaredType: "INTEGER", isWritable: true),
        InsertColumnInfo(name: "s", declaredType: "INTEGER", isWritable: false),
        InsertColumnInfo(name: "b", declaredType: "TEXT", isWritable: true),
        InsertColumnInfo(name: "v", declaredType: "INTEGER", isWritable: false),
        InsertColumnInfo(name: "c", declaredType: "REAL", isWritable: true),
    ])
    // The public view is unchanged: table_info omits generated columns.
    #expect(try w.tableInfo("t").map(\.name) == ["a", "b", "c"])
}

@Test func insertRowRejectsFewerValuesThanColumnsWithoutInserting() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("a" INTEGER, "b" INTEGER)"#)
    #expect(throws: ConversionError.self) {
        try w.insertRow(table: "t", columns: ["a", "b"], affinities: [.integer, .integer],
                        values: [.number(Array("1".utf8))])
    }
    #expect(try w.queryRow("SELECT COUNT(*) FROM t")?[0] == .number(Array("0".utf8)))
}

@Test func insertRowRejectsMoreValuesThanColumnsWithoutInserting() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("a" INTEGER, "b" INTEGER)"#)
    #expect(throws: ConversionError.self) {
        try w.insertRow(table: "t", columns: ["a"], affinities: [.integer],
                        values: [.number(Array("1".utf8)), .number(Array("2".utf8))])
    }
    #expect(try w.queryRow("SELECT COUNT(*) FROM t")?[0] == .number(Array("0".utf8)))
}

@Test func insertRowRejectsAnAffinityCountMismatchWithoutInserting() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("a" INTEGER, "b" INTEGER)"#)
    #expect(throws: ConversionError.self) {
        try w.insertRow(table: "t", columns: ["a", "b"], affinities: [.integer],
                        values: [.number(Array("1".utf8)), .number(Array("2".utf8))])
    }
    #expect(try w.queryRow("SELECT COUNT(*) FROM t")?[0] == .number(Array("0".utf8)))
}

@Test func insertRowWithNoColumnsInsertsDefaults() throws {
    let w = try writer()
    try w.exec(#"CREATE TABLE t ("a" INTEGER DEFAULT 7, "g" INTEGER GENERATED ALWAYS AS (a + 1))"#)
    try w.insertRow(table: "t", columns: [], affinities: [], values: [])
    #expect(try w.queryRow("SELECT a, g FROM t") == [.number(Array("7".utf8)), .number(Array("8".utf8))])
}
