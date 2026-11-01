// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RefWare",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RefWareCore", targets: ["RefWareCore"]),
        .executable(name: "refware", targets: ["refware"]),
        .executable(name: "RefWareCapture", targets: ["RefWareCapture"]),
    ],
    targets: [
        .target(name: "RefWareCore"),
        // macOS-only helpers: Word/RTF reading and WebKit page snapshots.
        .target(name: "RefWareMac", dependencies: ["RefWareCore"]),
        .executableTarget(name: "refware", dependencies: ["RefWareCore", "RefWareMac"]),
        // Handles refware:// links (bookmarklet, claims report) — bundled as "RefWare Capture.app".
        .executableTarget(name: "RefWareCapture", dependencies: ["RefWareCore", "RefWareMac"]),
        .testTarget(
            name: "RefWareCoreTests",
            dependencies: ["RefWareCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
