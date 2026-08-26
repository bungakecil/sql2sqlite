import Testing
@testable import SQL2SQLiteKit

private func map(_ base: String, _ args: [String] = [], unsigned: Bool = false) -> MappedType {
    TypeMapper.map(MySQLType(base: base, args: args, isUnsigned: unsigned))
}

@Test(arguments: ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER",
                  "BIGINT", "BIT", "BOOL", "BOOLEAN", "YEAR", "SERIAL"])
func integerTypesMapToInteger(base: String) {
    #expect(map(base).declaredType == "INTEGER")
    #expect(map(base).affinity == .integer)
}

@Test(arguments: ["FLOAT", "DOUBLE", "REAL"])
func floatingTypesMapToReal(base: String) {
    #expect(map(base).affinity == .real)
}

@Test(arguments: ["DECIMAL", "NUMERIC", "FIXED"])
func decimalTypesMapToNumeric(base: String) {
    #expect(map(base, ["30", "4"]).declaredType == "NUMERIC")
    #expect(map(base, ["30", "4"]).affinity == .numeric)
}

@Test(arguments: ["CHAR", "VARCHAR", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "JSON"])
func stringTypesMapToText(base: String) {
    #expect(map(base, ["255"]).affinity == .text)
}

@Test(arguments: ["BINARY", "VARBINARY", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB"])
func binaryTypesMapToBlob(base: String) {
    #expect(map(base).declaredType == "BLOB")
    #expect(map(base).affinity == .blob)
}

@Test(arguments: ["DATE", "DATETIME", "TIMESTAMP", "TIME"])
func temporalTypesMapToTextSoSortingKeepsWorking(base: String) {
    #expect(map(base).affinity == .text)
}

@Test func enumCarriesItsValuesForACheckConstraint() {
    let m = map("ENUM", ["'a'", "'b,c'"])
    #expect(m.declaredType == "TEXT")
    #expect(m.enumValues == ["'a'", "'b,c'"])
}

@Test func setMapsToTextWithoutACheck() {
    #expect(map("SET", ["'x'", "'y'"]).enumValues == nil)
    #expect(map("SET", ["'x'", "'y'"]).affinity == .text)
}

@Test func unknownTypesFallBackToTextAndAreFlagged() {
    let m = map("GEOMETRY")
    #expect(m.affinity == .text)
    #expect(m.isUnknown)
}

@Test func enumValuesAreRequotedForSQLite() {
    // MySQL's backslash escape must become SQLite's doubled quote.
    let m = map("ENUM", [#"'it\'s'"#])
    #expect(m.enumValues == ["'it''s'"])
}
