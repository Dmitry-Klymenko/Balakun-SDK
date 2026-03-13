// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BalakunMobileSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BalakunMobileSDK",
            targets: ["BalakunMobileSDK"]
        )
    ],
    targets: [
        .target(
            name: "BalakunMobileSDK",
            path: "iOS/Sources/BalakunMobileSDK"
        ),
        .testTarget(
            name: "BalakunMobileSDKTests",
            dependencies: ["BalakunMobileSDK"],
            path: "iOS/Tests/BalakunMobileSDKTests"
        )
    ]
)
