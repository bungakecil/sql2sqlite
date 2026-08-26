import Testing
@testable import SQL2SQLiteKit

@Test func reportsSystemSQLiteVersion() {
    let version = sqliteLibraryVersion()
    #expect(version.hasPrefix("3."))
}
