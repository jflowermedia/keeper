// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Keeper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Keeper", path: "Sources/Keeper")
    ]
)
