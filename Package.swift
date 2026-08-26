// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sql2sqlite",
    products: [
        .executable(name: "sql2sqlite", targets: ["sql2sqlite"]),
        .library(name: "SQL2SQLiteKit", targets: ["SQL2SQLiteKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"]),
                .yum(["sqlite-devel"]),
            ]
        ),
        .target(name: "SQL2SQLiteKit", dependencies: ["CSQLite"]),
        .executableTarget(
            name: "sql2sqlite",
            dependencies: [
                "SQL2SQLiteKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SQL2SQLiteKitTests", dependencies: ["SQL2SQLiteKit"]),
    ]
)
