// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PGNToolsSwiftSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PGNTools", targets: ["PGNTools"]),
        .executable(name: "pgntools", targets: ["PGNToolsCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NSStudent/fischer-core.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "PGNTools",
            dependencies: [
                .product(name: "FischerCore", package: "fischer-core"),
            ],
            resources: [.copy("Resources/openings.tsv")]
        ),
        .executableTarget(
            name: "PGNToolsCLI",
            dependencies: ["PGNTools"]
        ),
        .testTarget(
            name: "PGNToolsTests",
            dependencies: ["PGNTools"],
            resources: [.copy("Resources")]
        ),
    ]
)
