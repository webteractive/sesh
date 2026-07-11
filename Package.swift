// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHConfigCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SSHConfigCore", targets: ["SSHConfigCore"]),
    ],
    targets: [
        .target(
            name: "SSHConfigCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SSHConfigCoreTests",
            dependencies: ["SSHConfigCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
