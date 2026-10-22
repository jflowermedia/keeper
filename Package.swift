// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Keeper",
    platforms: [.macOS(.v13)],
    // No test target on purpose. XCTest ships with Xcode, not with the Command Line Tools,
    // and the Command Line Tools are all this app needs to build — so a test target can
    // only run on a machine set up differently from the one that builds the app. The checks
    // live in the app instead: `swift run Keeper --self-check`. See SelfCheck.swift.
    targets: [
        .executableTarget(name: "Keeper", path: "Sources/Keeper")
    ]
)
