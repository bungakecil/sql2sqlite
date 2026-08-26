import Testing
@testable import SQL2SQLiteKit

private func parse(_ sql: String) throws -> Table {
    let stmt = Statement(bytes: Array(sql.utf8), byteOffset: 0, line: 1)
    return try CreateTableParser.parse(stmt, diagnostics: .discarding())
}

@Test func parsesColumnsWithTypesAndArguments() throws {
    let t = try parse("""
    CREATE TABLE `users` (
      `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
      `email` varchar(255) NOT NULL,
      `bio` text,
      `score` decimal(10,2) DEFAULT '0.00',
      PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)
    #expect(t.name == "users")
    #expect(t.columns.map(\.name) == ["id", "email", "bio", "score"])
    #expect(t.columns[0].type.base == "INT")
    #expect(t.columns[0].type.args == ["10"])
    #expect(t.columns[0].type.isUnsigned)
    #expect(t.columns[0].isNotNull && t.columns[0].isAutoIncrement)
    #expect(t.columns[2].isNotNull == false)
    #expect(t.columns[3].type == MySQLType(base: "DECIMAL", args: ["10", "2"], isUnsigned: false))
    #expect(t.columns[3].defaultSQL == "'0.00'")
    #expect(t.primaryKey.map(\.name) == ["id"])
}

@Test func parsesCompositePrimaryKey() throws {
    let t = try parse("CREATE TABLE t (a int NOT NULL, b int NOT NULL, PRIMARY KEY (`a`,`b`))")
    #expect(t.primaryKey.map(\.name) == ["a", "b"])
}

@Test func parsesInlinePrimaryKeyOnAColumn() throws {
    let t = try parse("CREATE TABLE t (`id` bigint NOT NULL PRIMARY KEY, x int)")
    #expect(t.primaryKey.map(\.name) == ["id"])
}

@Test func parsesIndexesIncludingPrefixLengthsAndDirection() throws {
    let t = try parse("""
    CREATE TABLE t (
      a varchar(255), b int, c int,
      KEY `idx_a` (`a`(10)),
      UNIQUE KEY `uq_bc` (`b`,`c` DESC),
      KEY (`c`) USING BTREE,
      FULLTEXT KEY `ft` (`a`)
    )
    """)
    #expect(t.indexes.count == 4)
    #expect(t.indexes[0].name == "idx_a")
    #expect(t.indexes[0].columns[0].prefixLength == 10)
    #expect(t.indexes[1].isUnique)
    #expect(t.indexes[1].columns[1].descending)
    #expect(t.indexes[2].name == nil)
    #expect(t.indexes[3].kind == .fulltext)
}

@Test func parsesForeignKeysWithReferentialActions() throws {
    let t = try parse("""
    CREATE TABLE t (
      a int, b int,
      CONSTRAINT `fk_a` FOREIGN KEY (`a`) REFERENCES `u` (`id`)
        ON DELETE CASCADE ON UPDATE SET NULL
    )
    """)
    #expect(t.foreignKeys.count == 1)
    #expect(t.foreignKeys[0].columns == ["a"])
    #expect(t.foreignKeys[0].referencedTable == "u")
    #expect(t.foreignKeys[0].referencedColumns == ["id"])
    #expect(t.foreignKeys[0].onDelete == "CASCADE")
    #expect(t.foreignKeys[0].onUpdate == "SET NULL")
}

// The reason this is a parser and not a regex.
@Test func commasInsideLiteralsAndTypeArgumentsDoNotSplitElements() throws {
    let t = try parse("""
    CREATE TABLE t (
      `kind` enum('a,b','c') NOT NULL DEFAULT 'a,b',
      `paren` varchar(10) DEFAULT '(,)',
      `flags` set('x','y,z')
    )
    """)
    #expect(t.columns.count == 3)
    #expect(t.columns[0].type.base == "ENUM")
    #expect(t.columns[0].type.args == ["'a,b'", "'c'"])
    #expect(t.columns[0].defaultSQL == "'a,b'")
    #expect(t.columns[1].defaultSQL == "'(,)'")
    #expect(t.columns[2].type.args == ["'x'", "'y,z'"])
}

@Test func parsesGeneratedColumns() throws {
    let t = try parse("""
    CREATE TABLE t (
      a int, b int,
      `total` int GENERATED ALWAYS AS (`a` + `b`) STORED,
      `virt` int AS (`a` * 2) VIRTUAL
    )
    """)
    #expect(t.columns[2].generatedExpression == #""a" + "b""#)
    #expect(t.columns[2].generatedIsStored)
    #expect(t.columns[3].generatedExpression == #""a" * 2"#)
    #expect(t.columns[3].generatedIsStored == false)
}

@Test func parsesCollationAndCharacterSetAttributes() throws {
    let t = try parse("CREATE TABLE t (a varchar(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci)")
    #expect(t.columns[0].collation == "utf8mb4_general_ci")
}

@Test func parsesTableLevelChecks() throws {
    let t = try parse("CREATE TABLE t (a int, CHECK (`a` > 0))")
    #expect(t.checks == [#""a" > 0"#])
}

@Test func parsesDefaultCurrentTimestampAndOnUpdate() throws {
    let t = try parse("""
    CREATE TABLE t (
      `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
      `updated` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                          ON UPDATE CURRENT_TIMESTAMP(3)
    )
    """)
    #expect(t.columns[0].defaultSQL == "CURRENT_TIMESTAMP")
    #expect(t.columns[1].defaultSQL == "CURRENT_TIMESTAMP(3)")
}

@Test func warnsButKeepsParsingOnUnrecognisedColumnAttributes() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let stmt = Statement(
        bytes: Array("CREATE TABLE t (a int WEIRDATTR 3, b int)".utf8), byteOffset: 0, line: 1)
    let t = try CreateTableParser.parse(stmt, diagnostics: d)
    #expect(t.columns.map(\.name) == ["a", "b"])
    #expect(rec.lines.count == 1)
    #expect(rec.lines[0].contains("WEIRDATTR"))
}

@Test func throwsOnAStatementThatIsNotCreateTable() {
    #expect(throws: ConversionError.self) { try parse("SELECT 1") }
}
