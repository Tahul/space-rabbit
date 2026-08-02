// swift-tools-version:6.0
// This manifest exists solely for SourceKit-LSP (IDE code intelligence).
// The actual build is done by the Makefile using swiftc directly.
import PackageDescription

let package = Package(
    name: "SpaceRabbit",
    platforms: [
        .macOS(.v15) // keep in sync with MACOS_MIN in Makefile
    ],
    targets: [
        .executableTarget(
            name: "SpaceRabbit",
            path: "App",
            exclude: ["Info.plist"],
            swiftSettings: [
                // Match the Makefile's swiftc invocation (Swift 5 language
                // mode) so the LSP doesn't report Swift 6 strict-concurrency
                // diagnostics the real build never sees
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
