// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopranoWeb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SopranoWeb",
            path: "Sources/SopranoWeb",
            exclude: ["Vendored/SOPRANO_COMMIT"],
            resources: [
                .copy("Resources/AppIcon.icns"),
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
