// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SillyPultHelper",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .target(
            name: "SillyPultHelperKit",
            path: "Sources/SillyPultHelper",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "SillyPultHelper",
            dependencies: ["SillyPultHelperKit"],
            path: "Sources/SillyPultHelperExecutable"
        ),
        .testTarget(
            name: "SillyPultHelperTests",
            dependencies: ["SillyPultHelperKit"],
            path: "Tests/SillyPultHelperTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
