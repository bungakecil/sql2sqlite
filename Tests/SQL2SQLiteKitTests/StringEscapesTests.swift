import Testing
@testable import SQL2SQLiteKit

private func decode(_ literal: String) -> [UInt8] {
    StringEscapes.decode(Array(literal.utf8))
}
private func text(_ literal: String) -> String {
    String(decoding: decode(literal), as: UTF8.self)
}

@Test(arguments: [
    (#"'plain'"#,        "plain"),
    (#"'it\'s'"#,        "it's"),
    (#"'it''s'"#,        "it's"),
    (#"'say \"hi\"'"#,   #"say "hi""#),
    (#"'back\\slash'"#,  #"back\slash"#),
    (#"'a;b'"#,          "a;b"),
    (#"'tab\there'"#,    "tab\there"),
    (#"'nl\nhere'"#,     "nl\nhere"),
    (#"'cr\rhere'"#,     "cr\rhere"),
    (#"'unknown\qesc'"#, "unknownqesc"),
    (#""dq""ed""#,       #"dq"ed"#),
    (#"''"#,             ""),
])
func decodesMySQLStringLiterals(literal: String, expected: String) {
    #expect(text(literal) == expected)
}

@Test func decodesControlCharacterEscapes() {
    #expect(decode(#"'\0'"#)  == [0x00])
    #expect(decode(#"'\b'"#)  == [0x08])
    #expect(decode(#"'\Z'"#)  == [0x1A])
    #expect(decode(#"'a\0b'"#) == [0x61, 0x00, 0x62])
}

// Per the MySQL manual, \% and \_ decode to the two-byte sequences \% and \_,
// because they exist for LIKE patterns rather than as character escapes.
@Test func retainsBackslashForLikeWildcardEscapes() {
    #expect(text(#"'50\%'"#) == #"50\%"#)
    #expect(text(#"'a\_b'"#) == #"a\_b"#)
}

@Test func preservesInvalidUTF8Bytes() {
    // A latin1 0xE9 ("e-acute") is not valid UTF-8 and must survive untouched.
    let literal: [UInt8] = [0x27, 0x63, 0xE9, 0x27]   // 'c<0xE9>'
    #expect(StringEscapes.decode(literal) == [0x63, 0xE9])
}

@Test func quotesForGeneratedSQL() {
    #expect(StringEscapes.quoteSQLiteText("it's") == "'it''s'")
    #expect(StringEscapes.quoteIdentifier(#"we"ird"#) == #""we""ird""#)
}
