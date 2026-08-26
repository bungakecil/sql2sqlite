import Testing
@testable import SQL2SQLiteKit

private func translate(_ sql: String,
                       diagnostics: Diagnostics = .discarding()) throws -> TranslatedTable {
    let stmt = Statement(bytes: Array(sql.utf8), byteOffset: 0, line: 1)
    let table = try CreateTableParser.parse(stmt, diagnostics: diagnostics)
    let translator = SchemaTranslator(diagnostics: diagnostics)
    return try translator.translate(table, location: (0, 1))
}

@Test func translatesALoneIntegerAutoIncrementPrimaryKey() throws {
    let t = try translate("""
    CREATE TABLE `users` (
      `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
      `email` varchar(255) NOT NULL,
      `bio` text,
      PRIMARY KEY (`id`)
    ) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4
    """)
    #expect(t.createSQL == """
    CREATE TABLE "users" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      "email" TEXT NOT NULL,
      "bio" TEXT
    )
    """)
    #expect(t.indexSQL.isEmpty)
    #expect(t.columns == [
        TranslatedColumn(name: "id", affinity: .integer),
        TranslatedColumn(name: "email", affinity: .text),
        TranslatedColumn(name: "bio", affinity: .text),
    ])
}

@Test func compositePrimaryKeyBecomesATableConstraintAndForcesNotNull() throws {
    let t = try translate("CREATE TABLE t (a int, b int, PRIMARY KEY (`a`,`b`))")
    #expect(t.createSQL.contains(#""a" INTEGER NOT NULL"#))
    #expect(t.createSQL.contains(#""b" INTEGER NOT NULL"#))
    #expect(t.createSQL.contains(#"PRIMARY KEY ("a", "b")"#))
    #expect(t.createSQL.contains("AUTOINCREMENT") == false)
}

@Test func autoIncrementOnANonLoneIntegerKeyIsDroppedWithAWarning() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let t = try translate(
        "CREATE TABLE t (a int NOT NULL AUTO_INCREMENT, b int NOT NULL, PRIMARY KEY (`a`,`b`))",
        diagnostics: d)
    #expect(t.createSQL.contains("AUTOINCREMENT") == false)
    #expect(rec.lines.contains { $0.contains("AUTO_INCREMENT") })
}

@Test func indexesAreDeferredAndPrefixedWithTheTableName() throws {
    let t = try translate("""
    CREATE TABLE `posts` (
      `id` int NOT NULL, `slug` varchar(255), `author` int,
      PRIMARY KEY (`id`),
      UNIQUE KEY `idx_name` (`slug`),
      KEY `idx_author` (`author`)
    )
    """)
    #expect(t.indexSQL.map(\.name) == ["posts_idx_name", "posts_idx_author"])
    #expect(t.indexSQL[0].sql == #"CREATE UNIQUE INDEX "posts_idx_name" ON "posts" ("slug")"#)
    #expect(t.indexSQL[1].sql == #"CREATE INDEX "posts_idx_author" ON "posts" ("author")"#)
}

// SQLite index names are schema-global; two MySQL tables may both have `idx_name`.
@Test func indexNameCollisionsAcrossTablesAreDisambiguated() throws {
    let d = Diagnostics.discarding()
    let translator = SchemaTranslator(diagnostics: d)
    func t(_ sql: String) throws -> TranslatedTable {
        let stmt = Statement(bytes: Array(sql.utf8), byteOffset: 0, line: 1)
        return try translator.translate(try CreateTableParser.parse(stmt, diagnostics: d),
                                        location: (0, 1))
    }
    let a = try t("CREATE TABLE `a_x` (n int, KEY `i` (`n`))")
    let b = try t("CREATE TABLE `a` (n int, KEY `x_i` (`n`))")   // both want "a_x_i"
    #expect(a.indexSQL[0].name == "a_x_i")
    #expect(b.indexSQL[0].name == "a_x_i_2")
}

@Test func unnamedIndexesGetASyntheticName() throws {
    let t = try translate("CREATE TABLE t (a int, b int, KEY (`a`), KEY (`b`))")
    #expect(t.indexSQL.map(\.name) == ["t_idx_1", "t_idx_2"])
}

@Test func indexPrefixLengthsAreDroppedWithAWarning() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let t = try translate("CREATE TABLE t (a varchar(255), KEY `k` (`a`(10)))", diagnostics: d)
    #expect(t.indexSQL[0].sql == #"CREATE INDEX "t_k" ON "t" ("a")"#)
    #expect(rec.lines.contains { $0.contains("prefix length") })
}

@Test func fulltextAndSpatialIndexesAreSkippedWithAWarning() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let t = try translate("""
    CREATE TABLE t (a text, b text, FULLTEXT KEY `ft` (`a`), KEY `ok` (`b`(5)))
    """, diagnostics: d)
    #expect(t.indexSQL.map(\.name) == ["t_ok"])
    #expect(rec.lines.contains { $0.contains("FULLTEXT") })
}

@Test func foreignKeysAreKeptInlineWithTheirActions() throws {
    let t = try translate("""
    CREATE TABLE `c` (
      `id` int NOT NULL, `p` int,
      PRIMARY KEY (`id`),
      CONSTRAINT `fk` FOREIGN KEY (`p`) REFERENCES `c` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT
    )
    """)
    #expect(t.createSQL.contains(
        #"FOREIGN KEY ("p") REFERENCES "c" ("id") ON DELETE CASCADE ON UPDATE RESTRICT"#))
}

@Test func caseInsensitiveCollationsBecomeNocase() throws {
    let t = try translate("CREATE TABLE t (a varchar(10) COLLATE utf8mb4_general_ci)")
    #expect(t.createSQL.contains(#""a" TEXT COLLATE NOCASE"#))
}

@Test func binaryCollationsBecomeBinary() throws {
    let t = try translate("CREATE TABLE t (a varchar(10) COLLATE utf8mb4_bin)")
    #expect(t.createSQL.contains("COLLATE BINARY"))
}

@Test func enumsGainACheckConstraint() throws {
    let t = try translate("CREATE TABLE t (`s` enum('new','done') NOT NULL DEFAULT 'new')")
    #expect(t.createSQL.contains(#""s" TEXT NOT NULL DEFAULT 'new' CHECK ("s" IN ('new', 'done'))"#))
}

@Test func generatedColumnsArePassedThroughWithAWarning() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let t = try translate(
        "CREATE TABLE t (a int, b int, `tot` int GENERATED ALWAYS AS (`a`+`b`) STORED)",
        diagnostics: d)
    #expect(t.createSQL.contains(#""tot" INTEGER GENERATED ALWAYS AS ("a"+"b") STORED"#))
    #expect(rec.lines.contains { $0.contains("generated") })
}

@Test func theGeneratedDDLIsAcceptedBySQLite() throws {
    // The real acceptance test: hand it to SQLite and see if it parses.
    let t = try translate("""
    CREATE TABLE `everything` (
      `id` int unsigned NOT NULL AUTO_INCREMENT,
      `name` varchar(100) COLLATE utf8mb4_general_ci NOT NULL DEFAULT 'x',
      `kind` enum('a','b') DEFAULT 'a',
      `amount` decimal(10,2) DEFAULT '0.00',
      `blob` longblob,
      `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
      `parent` int unsigned DEFAULT NULL,
      PRIMARY KEY (`id`),
      KEY `k_parent` (`parent`),
      CONSTRAINT `fk_p` FOREIGN KEY (`parent`) REFERENCES `everything` (`id`) ON DELETE SET NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)
    let writer = try SQLiteWriter(path: ":memory:")
    try writer.exec(t.createSQL)
    for index in t.indexSQL { try writer.exec(index.sql) }
}
