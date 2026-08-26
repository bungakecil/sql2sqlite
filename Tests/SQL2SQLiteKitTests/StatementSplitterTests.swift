import Testing
@testable import SQL2SQLiteKit

private func split(_ sql: String, chunkSize: Int = 1 << 16) throws -> [String] {
    let scanner = ByteScanner(source: ArrayByteSource(Array(sql.utf8), chunkSize: chunkSize))
    let splitter = StatementSplitter(scanner: scanner, diagnostics: .discarding())
    var out: [String] = []
    while let s = try splitter.next() { out.append(s.text) }
    return out
}

@Test func splitsOnSemicolonsAndTrimsWhitespace() throws {
    #expect(try split("SELECT 1;\n\nSELECT 2;\n") == ["SELECT 1", "SELECT 2"])
}

@Test func emitsATrailingStatementWithNoTerminator() throws {
    #expect(try split("SELECT 1;\nSELECT 2") == ["SELECT 1", "SELECT 2"])
}

@Test func ignoresStraySemicolons() throws {
    #expect(try split(";;SELECT 1;;;") == ["SELECT 1"])
}

@Test func doesNotSplitOnSemicolonsInsideSingleQuotes() throws {
    let sql = #"INSERT INTO t VALUES ('it\'s; complicated','a;b','x''y;z');"#
    let parts = try split(sql)
    #expect(parts.count == 1)
    #expect(parts[0] == #"INSERT INTO t VALUES ('it\'s; complicated','a;b','x''y;z')"#)
}

@Test func doesNotSplitOnSemicolonsInsideDoubleQuotesOrBackticks() throws {
    #expect(try split(#"INSERT INTO `we;ird` VALUES ("a;b");"#).count == 1)
    #expect(try split("SELECT `a``b;c` FROM t;").count == 1)
}

@Test func aTrailingBackslashBeforeTheClosingQuoteEscapesIt() throws {
    // '\\' is a complete string holding one backslash; the following ; terminates.
    #expect(try split(#"INSERT INTO t VALUES ('\\');"#).count == 1)
    // '\' escapes the quote, so the string runs on and swallows the first ;
    let parts = try split(#"INSERT INTO t VALUES ('\';'); SELECT 1;"#)
    #expect(parts.count == 2)
    #expect(parts[1] == "SELECT 1")
}

@Test func backticksDoNotHonourBackslashEscapes() throws {
    // In MySQL `a\` is a complete identifier: the backslash is literal.
    let parts = try split("SELECT `a\\` FROM t; SELECT 2;")
    #expect(parts.count == 2)
}

@Test func dropsLineComments() throws {
    #expect(try split("-- a comment; not a statement\nSELECT 1;") == ["SELECT 1"])
    #expect(try split("# hash comment; here\nSELECT 1;") == ["SELECT 1"])
}

@Test func doubleDashWithoutWhitespaceIsNotAComment() throws {
    #expect(try split("SELECT 1--2;") == ["SELECT 1--2"])
}

@Test func dropsInertBlockCommentsAndLeavesASeparator() throws {
    #expect(try split("SELECT/* inner ; comment */1;") == ["SELECT 1"])
}

@Test func unwrapsExecutableComments() throws {
    let sql = "/*!40101 SET @s = @@character_set_client */;\nSELECT 1;"
    #expect(try split(sql) == ["SET @s = @@character_set_client", "SELECT 1"])
}

@Test func unwrapsSplitExecutableCommentsIntoOneStatement() throws {
    let sql = "/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `t` BEFORE INSERT ON `x` FOR EACH ROW SET @a = 1 */;"
    let parts = try split(sql)
    #expect(parts.count == 1)
    #expect(parts[0].hasPrefix("CREATE"))
    #expect(parts[0].contains("TRIGGER"))
}

@Test func treatsTheMariaDBSandboxSentinelAsAnInertComment() throws {
    let sql = "/*!999999\\- enable the sandbox mode */\nSELECT 1;"
    #expect(try split(sql) == ["SELECT 1"])
}

@Test func honoursDelimiterChanges() throws {
    let sql = """
    DELIMITER ;;
    CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN SET @a = 1; SET @b = 2; END ;;
    DELIMITER ;
    SELECT 1;
    """
    let parts = try split(sql)
    #expect(parts.count == 2)
    #expect(parts[0].contains("SET @a = 1; SET @b = 2"))
    #expect(parts[1] == "SELECT 1")
}

@Test func delimiterIsOnlyRecognisedAtStatementStart() throws {
    #expect(try split("SELECT delimiter FROM t;").count == 1)
}

@Test func reportsByteOffsetAndLineOfEachStatement() throws {
    let scanner = ByteScanner(source: ArrayByteSource(Array("SELECT 1;\n\nSELECT 2;".utf8)))
    let splitter = StatementSplitter(scanner: scanner, diagnostics: .discarding())
    let first = try #require(try splitter.next())
    let second = try #require(try splitter.next())
    #expect(first.byteOffset == 0 && first.line == 1)
    #expect(second.byteOffset == 11 && second.line == 3)
}

// The whole point of ByteScanner's transparent lookahead: results must not
// depend on where chunk boundaries land.
@Test(arguments: [1, 2, 3, 5, 17, 64, 1 << 16])
func resultsAreIndependentOfChunkSize(chunkSize: Int) throws {
    let sql = """
    /*!40101 SET NAMES utf8mb4 */;
    -- a comment; with a semicolon
    CREATE TABLE `t` (`a` int, `b` varchar(10) DEFAULT 'x;y');
    DELIMITER ;;
    CREATE TRIGGER `tr` BEFORE INSERT ON `t` FOR EACH ROW BEGIN SET @a = 1; END ;;
    DELIMITER ;
    INSERT INTO `t` VALUES (1,'it\\'s; fine'),(2,"d;q");
    """
    let reference = try split(sql, chunkSize: 1 << 16)
    #expect(try split(sql, chunkSize: chunkSize) == reference)
    // Four statements: SET NAMES, CREATE TABLE, CREATE TRIGGER, INSERT.
    // The two DELIMITER lines are client commands, not statements.
    #expect(reference.count == 4)
}
