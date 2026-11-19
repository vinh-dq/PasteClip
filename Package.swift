// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PasteClip",
    platforms: [.macOS("15.0")],
    targets: [
        // Clip model, pasteboard capture and on-disk history. No UI.
        .target(
            name: "PasteClipCore",
            path: "Sources/PasteClipCore"
        ),
        // OS integration: global hotkey and synthetic ⌘V.
        .target(
            name: "PasteClipSystem",
            path: "Sources/PasteClipSystem",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        // Menu bar app, the floating shelf, the paste stack and settings.
        .executableTarget(
            name: "PasteClip",
            dependencies: ["PasteClipCore", "PasteClipSystem"],
            path: "Sources/PasteClip"
        ),
        .testTarget(
            name: "PasteClipCoreTests",
            dependencies: ["PasteClipCore"],
            path: "Tests/PasteClipCoreTests"
        ),
    ]
)
