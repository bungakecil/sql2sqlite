import Testing
@testable import SQL2SQLiteKit

@Test(arguments: [
    "current_timestamp()",
    "CURRENT_TIMESTAMP(3)",
    "now()",
    "NOW()",
    "localtime()",
    "utc_timestamp()",
    "sysdate()",
])
func mapsTimestampFunctionsToCurrentTimestamp(input: String) {
    #expect(DefaultValueMapper.map(input) == .keep("CURRENT_TIMESTAMP"))
}

@Test(arguments: [
    "curdate()",
    "current_date()",
    "utc_date()",
])
func mapsDateFunctionsToCurrentDate(input: String) {
    #expect(DefaultValueMapper.map(input) == .keep("CURRENT_DATE"))
}

@Test(arguments: [
    "curtime()",
    "utc_time()",
])
func mapsTimeFunctionsToCurrentTime(input: String) {
    #expect(DefaultValueMapper.map(input) == .keep("CURRENT_TIME"))
}

@Test(arguments: [
    "CURRENT_TIMESTAMP",
    "NULL",
    "0",
    "-1",
    "'text'",
    "''",
    "'(,)'",
    "'now()'",
    "X'AB'",
    "(1+2)",
    #"("a"+"b")"#,
    "(CURRENT_TIMESTAMP)",
])
func negativesReturnKeepInputIdentically(input: String) {
    #expect(DefaultValueMapper.map(input) == .keep(input))
}

@Test(arguments: [
    "uuid()",
    "(uuid())",
    "rand()",
    "date_add(now(), interval 1 day)",
    "now(precision)",
])
func unsupportedFunctionsReturnUnsupported(input: String) {
    #expect(DefaultValueMapper.map(input) == .unsupported)
}

@Test(arguments: [
    "(current_timestamp())",
    "((current_timestamp()))",
])
func peelsWrapperParens(input: String) {
    #expect(DefaultValueMapper.map(input) == .keep("CURRENT_TIMESTAMP"))
}

@Test func degenerateAndUnbalancedInputs() {
    #expect(DefaultValueMapper.map("()") == .unsupported)
    #expect(DefaultValueMapper.map("foo(") == .keep("foo("))
}
