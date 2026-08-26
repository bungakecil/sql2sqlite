import Testing
@testable import SQL2SQLiteKit

@Test func warningsAreWrittenToTheSinkAndCounted() throws {
    var lines: [String] = []
    let d = Diagnostics(strict: false, quiet: false) { lines.append($0) }
    try d.warn(.skippedRoutine, "skipping TRIGGER `audit`", offset: 120, line: 7)
    #expect(lines.count == 1)
    #expect(lines[0].contains("line 7"))
    #expect(lines[0].contains("audit"))
    #expect(d.counts[.skippedRoutine] == 1)
    #expect(d.total == 1)
}

@Test func quietSuppressesOutputButStillCounts() throws {
    var lines: [String] = []
    let d = Diagnostics(strict: false, quiet: true) { lines.append($0) }
    try d.warn(.droppedAttribute, "dropped ON UPDATE CURRENT_TIMESTAMP", offset: 0, line: 1)
    #expect(lines.isEmpty)
    #expect(d.total == 1)
}

@Test func strictPromotesTheFirstWarningToAnError() {
    let d = Diagnostics(strict: true, quiet: false) { _ in }
    #expect(throws: ConversionError.self) {
        try d.warn(.unknownType, "unknown type GEOMETRY", offset: 5, line: 2)
    }
}

@Test func warnOnceEmitsASingleWarningPerCategory() throws {
    var lines: [String] = []
    let d = Diagnostics(strict: false, quiet: false) { lines.append($0) }
    try d.warnOnce(.numericPrecision, "value exceeds Int64", offset: 1, line: 1)
    try d.warnOnce(.numericPrecision, "value exceeds Int64", offset: 2, line: 1)
    #expect(lines.count == 1)
    #expect(d.counts[.numericPrecision] == 1)
}
