import Testing
@testable import SQL2SQLiteKit

private func tokens(_ sql: String) -> [Token] {
    Lexer.lexAll(Array(sql.utf8)).map(\.token)
}

@Test func lexesIdentifiersKeywordsAndPunctuation() {
    #expect(tokens("CREATE TABLE `my tbl` (") == [
        .word("CREATE"), .word("TABLE"), .quotedIdent("my tbl"), .punct(UInt8(ascii: "(")),
    ])
}

@Test func unescapesDoubledBackticks() {
    #expect(tokens("`a``b`") == [.quotedIdent("a`b")])
}

@Test func lexesDoubleQuotedRunsAsStringsNotIdentifiers() {
    #expect(tokens(#""hello""#) == [.string(Array(#""hello""#.utf8))])
}

@Test func lexesNumbers() {
    #expect(tokens("12 1.5 1.5e3 1.5E-3") ==
        [.number("12"), .number("1.5"), .number("1.5e3"), .number("1.5E-3")])
}

@Test func lexesBlobAndBitLiterals() {
    #expect(tokens("0x48656C6C6F") == [.hexLiteral(Array("Hello".utf8))])
    #expect(tokens("X'4869'")      == [.hexLiteral(Array("Hi".utf8))])
    #expect(tokens("0b0101")       == [.bitLiteral("0101")])
    #expect(tokens("b'0101'")      == [.bitLiteral("0101")])
}

@Test func charsetIntroducersLexAsWordThenString() {
    #expect(tokens("_binary 'abc'") == [.word("_binary"), .string(Array("'abc'".utf8))])
}

@Test func recordsSourceRanges() {
    let lexemes = Lexer.lexAll(Array("a  bb".utf8))
    #expect(lexemes[0].range == 0..<1)
    #expect(lexemes[1].range == 3..<5)
}

@Test func requotesBacktickIdentifiersAsDoubleQuotes() {
    let out = requoteIdentifiers(Array("select `a`.`b` from `t` where `x` = 1".utf8))
    #expect(out == #"select "a"."b" from "t" where "x" = 1"#)
}

@Test func requotesMySQLDoubleQuotedStringsAsSingleQuoted() {
    // In MySQL "abc" is a string; in SQLite it would be an identifier.
    let out = requoteIdentifiers(Array(#"select "abc" as `x`"#.utf8))
    #expect(out == #"select 'abc' as "x""#)
}

@Test func requotingPreservesSpacingAndUnrelatedText() {
    let out = requoteIdentifiers(Array("select\n  `a`,\n  1 + 2\nfrom `t`".utf8))
    #expect(out == "select\n  \"a\",\n  1 + 2\nfrom \"t\"")
}
