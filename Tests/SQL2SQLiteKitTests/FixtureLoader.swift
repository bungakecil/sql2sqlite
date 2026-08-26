import Foundation

/// Fixtures are located by #filePath rather than Bundle.module: no `resources:`
/// declaration in Package.swift, and no Linux resource-bundle quirks.
enum Fixture {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }
    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: directory.appendingPathComponent(name)))
    }
    static func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }
}
