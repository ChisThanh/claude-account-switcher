// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ClaudeSwitcher", path: "Sources/ClaudeSwitcher")
    ],
    swiftLanguageModes: [.v5]
)
