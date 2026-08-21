// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DSHCore", targets: ["DSHCore"]),
        .executable(name: "DSHMacApp", targets: ["DSHMacApp"]),
    ],
    targets: [
        // Agent engine: LLM clients, tool execution, permissions, sessions.
        // No UI, no AppKit — verifiable headlessly.
        .target(name: "DSHCore"),
        // The native SwiftUI app — it IS the harness.
        .executableTarget(name: "DSHMacApp", dependencies: ["DSHCore"]),
        // Engine tests (tools, permissions, Qwen XML parser, loop).
        .testTarget(name: "DSHCoreTests", dependencies: ["DSHCore"]),
    ]
)