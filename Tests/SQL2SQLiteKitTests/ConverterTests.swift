import Testing
@testable import SQL2SQLiteKit

private func convert(_ sql: String,
                     options: ConverterOptions = ConverterOptions(),
                     diagnostics: Diagnostics = .discarding())
    throws -> (SQLiteWriter, ConversionSummary) {
    let writer = try SQLiteWriter(path: ":memory:")
    let converter = Converter(writer: writer, diagnostics: diagnostics, options: options)
    let summary = try converter.run(source: ArrayByteSource(Array(sql.utf8)))
    return (writer, summary)
}
private func txt(_ s: String) -> RawValue { .text(Array(s.utf8)) }
private func num(_ s: String) -> RawValue { .number(Array(s.utf8)) }

@Test func convertsSchemaAndDataEndToEnd() throws {
    let (w, s) = try convert("""
    /*!40101 SET NAMES utf8mb4 */;
    DROP TABLE IF EXISTS `users`;
    CREATE TABLE `users` (
      `id` int unsigned NOT NULL AUTO_INCREMENT,
      `email` varchar(255) NOT NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_email` (`email`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    LOCK TABLES `users` WRITE;
    INSERT INTO `users` VALUES (1,'a@b'),(2,'c@d');
    UNLOCK TABLES;
    """)
    #expect(s.tables == 1 && s.rows == 2 && s.indexes == 1)
    #expect(try w.queryRow("SELECT COUNT(*) FROM users")?[0] == num("2"))
    #expect(try w.queryRow("SELECT email FROM users WHERE id = 2")?[0] == txt("c@d"))
    #expect(try w.queryRow("PRAGMA integrity_check")?[0] == txt("ok"))
}

@Test func insertsWithoutAColumnListUseTheParsedColumnOrder() throws {
    let (w, _) = try convert("""
    CREATE TABLE t (`a` int, `b` varchar(10), `c` int);
    INSERT INTO t VALUES (1,'x',3);
    """)
    #expect(try w.queryRow("SELECT a, b, c FROM t") == [num("1"), txt("x"), num("3")])
}

@Test func insertsWithAnExplicitColumnListBindPositionally() throws {
    let (w, _) = try convert("""
    CREATE TABLE t (`a` int, `b` varchar(10), `c` int);
    INSERT INTO t (`c`,`a`) VALUES (3,1);
    """)
    #expect(try w.queryRow("SELECT a, b, c FROM t") == [num("1"), .null, num("3")])
}

@Test func arityMismatchIsAnError() {
    #expect(throws: ConversionError.self) {
        _ = try convert("CREATE TABLE t (a int, b int); INSERT INTO t VALUES (1,2,3);")
    }
}

@Test func indexesAreCreatedAfterTheDataLoad() throws {
    let (w, s) = try convert("""
    CREATE TABLE t (`a` int, KEY `k` (`a`));
    INSERT INTO t VALUES (1),(2);
    """)
    #expect(s.indexes == 1)
    #expect(try w.queryRow("SELECT name FROM sqlite_master WHERE type='index' AND name='t_k'")?[0]
            == txt("t_k"))
}

// The confirmed decision: duplicate data must not abort the conversion.
@Test func aFailingUniqueIndexWarnsAndTheRunStillSucceeds() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let (w, s) = try convert("""
    CREATE TABLE t (`e` varchar(10), UNIQUE KEY `uq` (`e`));
    INSERT INTO t VALUES ('dup'),('dup');
    """, diagnostics: d)
    #expect(s.rows == 2 && s.indexes == 0)
    #expect(rec.lines.contains { $0.contains("skipped index") })
    #expect(try w.queryRow("SELECT COUNT(*) FROM t")?[0] == num("2"))
}

@Test func handlesTheMysqldumpViewPlaceholderPattern() throws {
    let (w, s) = try convert("""
    CREATE TABLE `t` (`id` int NOT NULL, `active` int, PRIMARY KEY (`id`));
    INSERT INTO `t` VALUES (1,1),(2,0);
    CREATE TABLE `v` (`id` int);
    DROP TABLE IF EXISTS `v`;
    /*!50001 CREATE ALGORITHM=UNDEFINED DEFINER=`r`@`h` SQL SECURITY DEFINER \
    VIEW `v` AS select `t`.`id` AS `id` from `t` where (`t`.`active` = 1) */;
    """)
    #expect(s.views == 1)
    #expect(try w.queryRow("SELECT COUNT(*) FROM v")?[0] == num("1"))
}

// A DROP TABLE after the CREATE must take that table's queued indexes with it.
@Test func droppingATablePurgesItsDeferredIndexes() throws {
    let (w, s) = try convert("""
    CREATE TABLE `v` (`id` int, KEY `k` (`id`));
    DROP TABLE `v`;
    """)
    #expect(s.indexes == 0)
    #expect(try w.queryRow("SELECT COUNT(*) FROM sqlite_master WHERE name='v_k'")?[0] == num("0"))
}

@Test func viewsAreRetriedSoDependencyOrderDoesNotMatter() throws {
    let (w, s) = try convert("""
    CREATE TABLE `t` (`id` int);
    INSERT INTO `t` VALUES (1);
    CREATE VIEW `outer_v` AS select * from `inner_v`;
    CREATE VIEW `inner_v` AS select * from `t`;
    """)
    #expect(s.views == 2)
    #expect(try w.queryRow("SELECT COUNT(*) FROM outer_v")?[0] == num("1"))
}

@Test func aViewThatCannotBeCreatedWarnsRatherThanAborting() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    let (_, s) = try convert("CREATE VIEW `v` AS select * from `nonexistent`;", diagnostics: d)
    #expect(s.views == 0)
    #expect(rec.lines.contains { $0.contains("view failed") })
}

@Test func skipsRoutinesWithAWarning() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    _ = try convert("""
    DELIMITER ;;
    CREATE TRIGGER `tr` BEFORE INSERT ON `t` FOR EACH ROW BEGIN SET @a = 1; END ;;
    DELIMITER ;
    """, diagnostics: d)
    #expect(rec.lines.contains { $0.contains("skipped routine") })
}

@Test func duplicateTableNamesAcrossDatabasesAreAHardError() {
    #expect(throws: ConversionError.self) {
        _ = try convert("""
        USE `a`; CREATE TABLE `t` (`x` int);
        USE `b`; CREATE TABLE `t` (`y` int);
        """)
    }
}

@Test func schemaOnlySkipsInserts() throws {
    var o = ConverterOptions(); o.schemaOnly = true
    let (w, s) = try convert("CREATE TABLE t (a int); INSERT INTO t VALUES (1);", options: o)
    #expect(s.rows == 0)
    #expect(try w.queryRow("SELECT COUNT(*) FROM t")?[0] == num("0"))
}

@Test func dataOnlyBindsAgainstAPreexistingTable() throws {
    let writer = try SQLiteWriter(path: ":memory:")
    try writer.exec(#"CREATE TABLE "t" ("a" INTEGER, "b" TEXT)"#)
    var o = ConverterOptions(); o.dataOnly = true
    let converter = Converter(writer: writer, diagnostics: .discarding(), options: o)
    let s = try converter.run(source: ArrayByteSource(Array("""
    CREATE TABLE t (a int, b varchar(10));
    INSERT INTO t VALUES (1,'x');
    """.utf8)))
    #expect(s.tables == 0 && s.rows == 1)
    #expect(try writer.queryRow("SELECT a, b FROM t") == [num("1"), txt("x")])
}

@Test func batchingCommitsPeriodicallyAndLoadsEveryRow() throws {
    var o = ConverterOptions(); o.batchSize = 10
    var sql = "CREATE TABLE t (`a` int);\n"
    for i in 0..<250 { sql += "INSERT INTO t VALUES (\(i));\n" }
    let (w, s) = try convert(sql, options: o)
    #expect(s.rows == 250)
    #expect(try w.queryRow("SELECT COUNT(*) FROM t")?[0] == num("250"))
}

@Test func checkForeignKeysReportsViolations() throws {
    final class Recorder { var lines: [String] = [] }
    let rec = Recorder()
    let d = Diagnostics(strict: false, quiet: false) { rec.lines.append($0) }
    var o = ConverterOptions(); o.checkForeignKeys = true
    _ = try convert("""
    CREATE TABLE `p` (`id` int NOT NULL, PRIMARY KEY (`id`));
    CREATE TABLE `c` (`p` int, CONSTRAINT `fk` FOREIGN KEY (`p`) REFERENCES `p` (`id`));
    INSERT INTO `c` VALUES (99);
    """, options: o, diagnostics: d)
    #expect(rec.lines.contains { $0.contains("foreign key violation") })
}

@Test func strictModeTurnsTheFirstWarningIntoAnError() {
    #expect(throws: ConversionError.self) {
        _ = try convert("CREATE TABLE t (a GEOMETRY);", diagnostics: .discarding(strict: true))
    }
}

// MARK: - Generated columns

private func parseError(_ body: () throws -> Void) -> (message: String, byteOffset: Int, line: Int)? {
    do { try body() } catch ConversionError.parse(let m, let off, let line) {
        return (m, off, line)
    } catch { return nil }
    return nil
}

@Test func fullWidthTuplesDropTheSuppliedGeneratedValue() throws {
    let (w, s) = try convert("""
    CREATE TABLE t (`a` int, `g` int GENERATED ALWAYS AS (`a`+1) STORED, `z` int);
    INSERT INTO t VALUES (1,999,9);
    """)
    #expect(s.rows == 1)
    #expect(try w.queryRow("SELECT a, g, z FROM t") == [num("1"), num("2"), num("9")])
}

@Test(arguments: ["STORED", "VIRTUAL"])
func generatedColumnsAtEveryPositionDoNotShiftLaterValues(kind: String) throws {
    let (w, s) = try convert("""
    CREATE TABLE lead (`g` int GENERATED ALWAYS AS (`a`*10) \(kind), `a` int, `b` varchar(5));
    CREATE TABLE mid (`a` int, `g` int GENERATED ALWAYS AS (`a`*10) \(kind), `b` varchar(5));
    CREATE TABLE tail (`a` int, `b` varchar(5), `g` int GENERATED ALWAYS AS (`a`*10) \(kind));
    INSERT INTO lead VALUES (0,1,'x'),(0,2,'y');
    INSERT INTO mid VALUES (1,0,'x'),(2,0,'y');
    INSERT INTO tail VALUES (1,'x',0),(2,'y',0);
    """)
    #expect(s.rows == 6)
    for table in ["lead", "mid", "tail"] {
        #expect(try w.queryRow("SELECT a, b, g FROM \(table) WHERE a = 1") == [num("1"), txt("x"), num("10")])
        #expect(try w.queryRow("SELECT a, b, g FROM \(table) WHERE a = 2") == [num("2"), txt("y"), num("20")])
    }
}

@Test func multipleGeneratedColumnsOfBothKinds() throws {
    let (w, _) = try convert("""
    CREATE TABLE t (`a` int, `s` int GENERATED ALWAYS AS (`a`+1) STORED, `b` int,
                    `v` int AS (`b`*2) VIRTUAL, `c` int);
    INSERT INTO t VALUES (1,0,2,0,3);
    INSERT INTO t VALUES (4,5,6);
    """)
    #expect(try w.queryRow("SELECT a, s, b, v, c FROM t WHERE a = 1")
            == [num("1"), num("2"), num("2"), num("4"), num("3")])
    #expect(try w.queryRow("SELECT a, s, b, v, c FROM t WHERE a = 4")
            == [num("4"), num("5"), num("5"), num("10"), num("6")])
}

@Test func writableOnlyImplicitTuplesStillWork() throws {
    let (w, s) = try convert("""
    CREATE TABLE t (`a` int, `g` int GENERATED ALWAYS AS (`a`+1) STORED, `z` int);
    INSERT INTO t VALUES (1,9),(2,8);
    """)
    #expect(s.rows == 2)
    #expect(try w.queryRow("SELECT a, g, z FROM t WHERE a = 2") == [num("2"), num("3"), num("8")])
}

@Test func explicitReorderedListsKeepPositionalMeaning() throws {
    let (w, _) = try convert("""
    CREATE TABLE t (`a` int, `g` int GENERATED ALWAYS AS (`a`+1) STORED, `z` varchar(5));
    INSERT INTO t (`z`,`g`,`a`) VALUES ('x',999,1),('y',999,2);
    INSERT INTO t (`g`,`z`,`a`) VALUES (999,'w',3);
    """)
    #expect(try w.queryRow("SELECT a, g, z FROM t WHERE a = 1") == [num("1"), num("2"), txt("x")])
    #expect(try w.queryRow("SELECT a, g, z FROM t WHERE a = 2") == [num("2"), num("3"), txt("y")])
    #expect(try w.queryRow("SELECT a, g, z FROM t WHERE a = 3") == [num("3"), num("4"), txt("w")])
}

@Test func explicitGeneratedOnlyListsInsertDefaults() throws {
    let (w, s) = try convert("""
    CREATE TABLE t (`a` int DEFAULT 7, `g` int GENERATED ALWAYS AS (`a`+1) STORED);
    INSERT INTO t (`g`) VALUES (999),(998);
    """)
    #expect(s.rows == 2)
    #expect(try w.queryRow("SELECT COUNT(*), MIN(a), MAX(g) FROM t") == [num("2"), num("7"), num("8")])
}

@Test func unknownExplicitColumnsStillFailInSQLite() {
    #expect(throws: ConversionError.self) {
        _ = try convert("""
        CREATE TABLE t (`a` int, `g` int GENERATED ALWAYS AS (`a`+1) STORED);
        INSERT INTO t (`a`,`nope`) VALUES (1,2);
        """)
    }
}

private func dataOnlyConvert(_ sql: String) throws -> (SQLiteWriter, ConversionSummary) {
    let writer = try SQLiteWriter(path: ":memory:")
    try writer.exec(#"""
    CREATE TABLE "t" ("a" INTEGER, "g" INTEGER GENERATED ALWAYS AS ("a" + 1) STORED,
                      "v" INTEGER GENERATED ALWAYS AS ("a" * 3) VIRTUAL, "z" TEXT)
    """#)
    var o = ConverterOptions(); o.dataOnly = true
    let converter = Converter(writer: writer, diagnostics: .discarding(), options: o)
    let s = try converter.run(source: ArrayByteSource(Array(sql.utf8)))
    return (writer, s)
}

@Test func dataOnlyAcceptsFullWidthTuplesForExistingGeneratedColumns() throws {
    let (w, s) = try dataOnlyConvert("INSERT INTO t VALUES (1,0,0,'x'),(2,0,0,'y');")
    #expect(s.rows == 2)
    #expect(try w.queryRow("SELECT a, g, v, z FROM t WHERE a = 2") == [num("2"), num("3"), num("6"), txt("y")])
}

@Test func dataOnlyAcceptsWritableOnlyTuplesForExistingGeneratedColumns() throws {
    let (w, s) = try dataOnlyConvert("INSERT INTO t VALUES (1,'x'); INSERT INTO t (`g`,`z`,`a`) VALUES (0,'q',5);")
    #expect(s.rows == 2)
    #expect(try w.queryRow("SELECT a, g, v, z FROM t WHERE a = 1") == [num("1"), num("2"), num("3"), txt("x")])
    #expect(try w.queryRow("SELECT a, g, v, z FROM t WHERE a = 5") == [num("5"), num("6"), num("15"), txt("q")])
}

private let generatedTable = "CREATE TABLE t (`a` int, `g` int GENERATED ALWAYS AS (`a`+1) STORED, `z` int);\n"

@Test(arguments: [
    ("INSERT INTO t VALUES (1);", "supplies 1 values"),
    ("INSERT INTO t VALUES (1,2,3,4);", "supplies 4 values"),
    ("INSERT INTO t VALUES (1,2,3),(1,2);", "supplies 2 values"),
    ("INSERT INTO t VALUES (1,2),(1,2,3);", "supplies 3 values"),
    ("INSERT INTO t (`a`,`g`) VALUES (1,2),(3);", "supplies 1 values"),
])
func malformedTupleWidthsAreParseErrors(insert: String, fragment: String) throws {
    let sql = generatedTable + insert
    let error = try #require(parseError { _ = try convert(sql) })
    #expect(error.message.contains("`t`"))
    #expect(error.message.contains(fragment))
    #expect(error.line == 2)
    #expect(error.byteOffset == generatedTable.utf8.count)
}

@Test func implicitWidthErrorsNameBothAcceptedLayouts() throws {
    let error = try #require(parseError { _ = try convert(generatedTable + "INSERT INTO t VALUES (1);") })
    #expect(error.message.contains("3 columns"))
    #expect(error.message.contains("2 writable"))
}

@Test func malformedLaterTuplesAreNeverPaddedOrTruncated() throws {
    let writer = try SQLiteWriter(path: ":memory:")
    let converter = Converter(writer: writer, diagnostics: .discarding(), options: ConverterOptions())
    #expect(throws: ConversionError.self) {
        _ = try converter.run(source: ArrayByteSource(Array(
            (generatedTable + "INSERT INTO t VALUES (1,0,2),(3,4);").utf8)))
    }
    // The first tuple went in before the second was found malformed; nothing
    // was padded or truncated into a row.
    #expect(try writer.queryRow("SELECT COUNT(*) FROM t WHERE z IS NULL")?[0] == num("0"))
}

@Test func softDeleteActiveSlugIsRecomputedAndStaysUnique() throws {
    let (w, s) = try convert("""
    CREATE TABLE `categories` (
      `id` char(36) NOT NULL,
      `slug` varchar(255) NOT NULL,
      `deleted_at` timestamp NULL DEFAULT NULL,
      `active_slug` varchar(255) GENERATED ALWAYS AS (case when `deleted_at` is null then `slug` else NULL end) STORED,
      PRIMARY KEY (`id`),
      UNIQUE KEY `categories_active_slug_unique` (`active_slug`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    INSERT INTO `categories` VALUES ('c1','tours',NULL,'tours'),
      ('c2','tours','2026-01-01 00:00:00',NULL),
      ('c3','cruises','2026-02-01 00:00:00',NULL),
      ('c4','cruises',NULL,'cruises'),
      ('c5','walks',NULL,'bogus');
    """)
    #expect(s.rows == 5 && s.indexes == 1)
    #expect(try w.queryRow("SELECT COUNT(*) FROM categories")?[0] == num("5"))
    #expect(try w.queryRow("""
        SELECT COUNT(*) FROM categories
        WHERE active_slug IS NOT (CASE WHEN deleted_at IS NULL THEN slug ELSE NULL END)
        """)?[0] == num("0"))
    #expect(try w.queryRow("SELECT active_slug FROM categories WHERE id = 'c5'")?[0] == txt("walks"))
    #expect(try w.queryRow("""
        SELECT COUNT(*) FROM pragma_index_list('categories') AS l,
                             pragma_index_info(l.name) AS i
        WHERE l."unique" = 1 AND l.origin = 'c' AND i.name = 'active_slug'
        """)?[0] == num("1"))
    #expect(try w.queryRow("PRAGMA integrity_check")?[0] == txt("ok"))

    try w.exec("UPDATE categories SET deleted_at = '2026-03-01 00:00:00' WHERE id = 'c1'")
    #expect(try w.queryRow("SELECT active_slug FROM categories WHERE id = 'c1'")?[0] == .null)
    try w.exec("UPDATE categories SET deleted_at = NULL WHERE id = 'c2'")
    #expect(try w.queryRow("SELECT active_slug FROM categories WHERE id = 'c2'")?[0] == txt("tours"))
    // The unique index still guards the recomputed values.
    #expect(throws: ConversionError.self) {
        try w.exec("UPDATE categories SET deleted_at = NULL WHERE id = 'c3'")
    }
}
