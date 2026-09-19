// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Bassline",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "CBasslineAtomics"),
        .target(
            name: "BasslineCore",
            dependencies: ["CBasslineAtomics"],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "Bassline",
            dependencies: ["BasslineCore"],
            path: "Sources/Bassline",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Metal"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Verification runner that does not need XCTest, so it works with the
        // Command Line Tools alone: swift run -c release BasslineCheck
        .executableTarget(
            name: "BasslineCheck",
            dependencies: ["BasslineCore"]
        ),
        // Requires full Xcode. Skipped automatically when XCTest is missing.
        .testTarget(
            name: "BasslineCoreTests",
            dependencies: ["BasslineCore"]
        ),
    ]
)
