// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LGTVControl",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LGTVControl", targets: ["LGTVControl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "LGTVControl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/LGTVControl",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
