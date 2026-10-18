// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Keeper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Keeper", path: "Sources/Keeper"),
        // `swift test` only. The app build never touches this, so a test that won't compile
        // can't stop a release going out — but then nor does it catch anything, so run it.
        .testTarget(name: "KeeperTests", dependencies: ["Keeper"], path: "Tests/KeeperTests")
    ]
)
