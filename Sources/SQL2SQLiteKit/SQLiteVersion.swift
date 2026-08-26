import CSQLite

/// The version of the system libsqlite3 this binary is linked against.
public func sqliteLibraryVersion() -> String {
    String(cString: sqlite3_libversion())
}
