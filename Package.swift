// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ChatType",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ChatType", targets: ["ChatType"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/jaywcjlove/PermissionFlow.git",
            revision: "3c5ae16337d3448e8561e00352a01b68f92fe974"
        ),
    ],
    targets: [
        .target(name: "COpusBridge", path: "Sources/COpusBridge", publicHeadersPath: "include"),
        .executableTarget(
            name: "ChatType",
            dependencies: [
                "COpusBridge",
                .product(name: "PermissionFlow", package: "PermissionFlow"),
                .product(name: "SystemSettingsKit", package: "PermissionFlow"),
            ],
            path: "Sources/ChatType",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "ChatTypeTests",
            dependencies: ["ChatType"],
            path: "Tests/ChatTypeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
