// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusOn",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, dependency-free logic — unit tested.
        .target(name: "FocusOnCore"),
        // The menu bar app (AppKit). Compiled into FocusOn.app by build.sh.
        .executableTarget(
            name: "FocusOn",
            dependencies: ["FocusOnCore"]
        ),
        .testTarget(
            name: "FocusOnCoreTests",
            dependencies: ["FocusOnCore"]
        ),
    ]
)
