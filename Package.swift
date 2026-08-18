// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .executable(name: "dshprobe", targets: ["dshprobe"]),
        .executable(name: "DSHMacApp", targets: ["DSHMacApp"]),
    ],
    targets: [
        // Transport + contract layer: no UI, no AppKit. Verifiable headlessly.
        .target(name: "DSHKit"),
        // CLI smoke test that drives DSHKit against a live harness.
        .executableTarget(name: "dshprobe", dependencies: ["DSHKit"]),
        // The native SwiftUI client.
        .executableTarget(name: "DSHMacApp", dependencies: ["DSHKit"]),
        // Contract tests over captured wire shapes.
        .testTarget(name: "DSHKitTests", dependencies: ["DSHKit"]),
    ]
)
