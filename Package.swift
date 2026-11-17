// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TikhiyText",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TikhiyText", targets: ["TikhiyText"])],
    targets: [
        .executableTarget(
            name: "TikhiyText",
            path: "Sources/TikhiyText",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
