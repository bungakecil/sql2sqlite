import Testing
@testable import SQL2SQLiteKit

private func classify(_ sql: String) -> StatementKind {
    StatementClassifier.classify(Lexer.lexAll(Array(sql.utf8)))
}

@Test func classifiesCreateTable() {
    #expect(classify("CREATE TABLE `users` (`id` int)") == .createTable(name: "users"))
    #expect(classify("CREATE TABLE IF NOT EXISTS users (id int)") == .createTable(name: "users"))
    #expect(classify("CREATE TEMPORARY TABLE t (id int)") == .createTable(name: "t"))
}

@Test func classifiesCreateViewThroughAlgorithmAndDefinerNoise() {
    let sql = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v` AS select 1"
    #expect(classify(sql) == .createView)
}

@Test func classifiesRoutines() {
    #expect(classify("CREATE DEFINER=`r`@`h` TRIGGER `t` BEFORE INSERT ON x FOR EACH ROW SET @a=1")
            == .createRoutine(kind: "TRIGGER"))
    #expect(classify("CREATE PROCEDURE p() BEGIN END")  == .createRoutine(kind: "PROCEDURE"))
    #expect(classify("CREATE FUNCTION f() RETURNS INT RETURN 1") == .createRoutine(kind: "FUNCTION"))
    #expect(classify("CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO SET @a=1") == .createRoutine(kind: "EVENT"))
}

@Test func classifiesInsertAndReplace() {
    #expect(classify("INSERT INTO `t` VALUES (1)")          == .insert(table: "t"))
    #expect(classify("REPLACE INTO t (a,b) VALUES (1,2)")   == .insert(table: "t"))
    #expect(classify("INSERT IGNORE INTO `t` VALUES (1)")   == .insert(table: "t"))
}

@Test func classifiesDropTable() {
    #expect(classify("DROP TABLE IF EXISTS `a`,`b`") == .dropTable(names: ["a", "b"]))
}

@Test func classifiesDumpBoilerplateAsIgnorable() {
    #expect(classify("SET NAMES utf8mb4")                          == .boilerplate)
    #expect(classify("SET @saved = @@character_set_client")         == .boilerplate)
    #expect(classify("LOCK TABLES `t` WRITE")                       == .boilerplate)
    #expect(classify("UNLOCK TABLES")                               == .boilerplate)
    #expect(classify("ALTER TABLE `t` DISABLE KEYS")                == .boilerplate)
    #expect(classify("ALTER TABLE `t` ENABLE KEYS")                 == .boilerplate)
}

@Test func classifiesDatabaseStatements() {
    #expect(classify("USE `mydb`")                        == .useDatabase)
    #expect(classify("CREATE DATABASE IF NOT EXISTS `d`") == .createDatabase)
}

@Test func classifiesAnythingElseAsUnknown() {
    #expect(classify("GRANT ALL ON *.* TO 'x'") == .unknown(leadingWords: "GRANT ALL"))
}

// An ALTER TABLE that is not the DISABLE/ENABLE KEYS boilerplate must not be
// silently swallowed - it may carry constraints we are dropping on the floor.
@Test func nonBoilerplateAlterTableIsUnknown() {
    if case .unknown = classify("ALTER TABLE `t` ADD CONSTRAINT fk FOREIGN KEY (a) REFERENCES u(b)") {
        // expected
    } else {
        Issue.record("ALTER TABLE ADD CONSTRAINT should not classify as boilerplate")
    }
}
