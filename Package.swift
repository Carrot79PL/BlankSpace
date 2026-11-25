// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "BlankSpace",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "BlankSpace", path: "Sources/BlankSpace",
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
