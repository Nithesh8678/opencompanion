// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OpenCompanion",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "OpenCompanion", targets: ["OpenCompanion"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CompanionCore"),
        .target(name: "CompanionStore", dependencies: ["CSQLite"]),
        .executableTarget(name: "OpenCompanion", dependencies: ["CompanionCore", "CompanionStore"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
        .testTarget(name: "CompanionStoreTests", dependencies: ["CompanionStore"])
    ]
)
