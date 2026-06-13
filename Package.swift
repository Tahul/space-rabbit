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
