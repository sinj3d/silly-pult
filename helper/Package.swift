// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SillypultHelper",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "SillypultHelper",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "SillypultHelperTests",
            dependencies: ["SillypultHelper"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
