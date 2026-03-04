// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AtlBrowserFeature",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "AtlBrowserFeature",
            targets: ["AtlBrowserFeature"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.26.0")),
    ],
    targets: [
        .target(
            name: "AtlBrowserFeature",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ]
        ),
        .testTarget(
            name: "AtlBrowserFeatureTests",
            dependencies: [
                "AtlBrowserFeature"
            ]
        ),
    ]
)
