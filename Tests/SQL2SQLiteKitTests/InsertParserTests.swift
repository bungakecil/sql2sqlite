import Testing
@testable import SQL2SQLiteKit

private func rows(_ sql: String,
                  diagnostics: Diagnostics = .discarding()) throws -> (InsertParser, [[RawValue]]) {
    let stmt = Statement(bytes: Array(sql.utf8), byteOffset: 0, line: 1)
    var parser = try InsertParser(statement: stmt, diagnostics: diagnostics)
    var out: [[RawValue]] = []
    while let row = try parser.nextRow() { out.append(row) }
    return (parser, out)
}
private func txt(_ s: String) -> RawValue { .text(Array(s.utf8)) }
private func num(_ s: String) -> RawValue { .number(Array(s.utf8)) }

@Test func parsesTableNameAndColumnList() throws {
    let (p, r) = try rows("INSERT INTO `users` (`id`, `email`) VALUES (1,'a@b')")
    #expect(p.table == "users")
    #expect(p.columns == ["id", "email"])
    #expect(r == [[num("1"), txt("a@b")]])
}

@Test func columnListIsNilWhenTheDumpOmitsIt() throws {
    let (p, _) = try rows("INSERT INTO `t` VALUES (1)")
    #expect(p.columns == nil)
}

@Test func parsesExtendedInsertsWithManyTuples() throws {
    let (_, r) = try rows("INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')")
    #expect(r.count == 3)
    #expect(r[2] == [num("3"), txt("c")])
}

@Test func parsesNullAndBooleans() throws {
    let (_, r) = try rows("INSERT INTO t VALUES (NULL,TRUE,FALSE,null)")
    #expect(r[0] == [.null, num("1"), num("0"), .null])
}

@Test func parsesSignedAndScientificNumbers() throws {
    let (_, r) = try rows("INSERT INTO t VALUES (-4, 1.5e3, +7, -0.25)")
    #expect(r[0] == [num("-4"), num("1.5e3"), num("+7"), num("-0.25")])
}

@Test func decodesStringEscapesAndSemicolonsInsideValues() throws {
    let (_, r) = try rows(#"INSERT INTO t VALUES ('it\'s; fine','a''b','line\nbreak')"#)
    #expect(r[0] == [txt("it's; fine"), txt("a'b"), txt("line\nbreak")])
}

@Test func decodesNulAndControlEscapesIntoRealBytes() throws {
    let (_, r) = try rows(#"INSERT INTO t VALUES ('a\0b','x\Zy')"#)
    #expect(r[0] == [.text([0x61, 0x00, 0x62]), .text([0x78, 0x1A, 0x79])])
}

@Test func parsesEveryBlobLiteralForm() throws {
    let (_, r) = try rows("INSERT INTO t VALUES (_binary 'AB', 0x4142, X'4142', x'4142')")
    #expect(r[0] == [.blob([0x41, 0x42]), .blob([0x41, 0x42]),
                     .blob([0x41, 0x42]), .blob([0x41, 0x42])])
}

@Test func binaryIntroducerHandlesEscapedBytes() throws {
    let (_, r) = try rows(#"INSERT INTO t VALUES (_binary 'a\0\\b')"#)
    #expect(r[0] == [.blob([0x61, 0x00, 0x5C, 0x62])])
}

@Test func nonBinaryCharsetIntroducersYieldText() throws {
    let (_, r) = try rows("INSERT INTO t VALUES (_utf8mb4 'h\u{e9}llo')")
    #expect(r[0] == [txt("h\u{e9}llo")])
}

@Test func parsesBitLiteralsAsIntegers() throws {
    let (_, r) = try rows("INSERT INTO t VALUES (b'0101', 0b0101, b'')")
    #expect(r[0] == [num("5"), num("5"), num("0")])
}

@Test func preservesUnicodeAndEmojiExactly() throws {
    let (_, r) = try rows("INSERT INTO t VALUES ('\u{65e5}\u{672c}\u{8a9e} \u{1f389}')")
    #expect(r[0] == [txt("\u{65e5}\u{672c}\u{8a9e} \u{1f389}")])
}

@Test func handlesReplaceIntoAndInsertIgnore() throws {
    #expect(try rows("REPLACE INTO `t` VALUES (1)").0.table == "t")
    #expect(try rows("INSERT IGNORE INTO `t` VALUES (1)").0.table == "t")
}

@Test func warnsOnceWhenAnIntegerExceedsInt64() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let (_, r) = try rows("INSERT INTO t VALUES (18446744073709551615),(18446744073709551614)",
                          diagnostics: d)
    #expect(r.count == 2)
    #expect(rec.lines.count == 1)
    #expect(rec.lines[0].contains("numeric precision"))
}

@Test func throwsOnAMalformedTuple() {
    #expect(throws: ConversionError.self) {
        _ = try rows("INSERT INTO t VALUES (1,")
    }
}

@Test func throwsOnAStatementThatIsNotAnInsert() {
    #expect(throws: ConversionError.self) {
        _ = try rows("SELECT 1")
    }
}
