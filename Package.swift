// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SopranoWeb",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SopranoWeb",
            path: "Sources/SopranoWeb",
            exclude: ["Vendored/SOPRANO_COMMIT"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                // Readability.js 0.6.0 with its LICENSE and NOTICE (Reader).
                .copy("Resources/Readability"),
            ],
            linkerSettings: [
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "SopranoWebTests",
            dependencies: ["SopranoWeb"],
            path: "Tests/SopranoWebTests",
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .linkedFramework("Testing"),
            ]
        ),
    ]
)
