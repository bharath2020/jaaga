// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Jaaga",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JaagaProtocol", targets: ["JaagaProtocol"]),
        .library(name: "JaagaCore", targets: ["JaagaCore"]),
        .library(name: "JaagaLayout", targets: ["JaagaLayout"]),
        .library(name: "JaagaDaemon", targets: ["JaagaDaemon"]),
        .executable(name: "jaagad", targets: ["jaagad"]),
        .executable(name: "JaagaApp", targets: ["JaagaApp"]),
    ],
    targets: [
        // The wire protocol: request/response/event frames plus the shared data model.
        // Deliberately free of scanning or UI code so a CLI or MCP server can link it alone.
        .target(name: "JaagaProtocol"),

        // Everything that touches the filesystem: allocated-size accounting, the usual-suspects
        // catalog, verdict rules, watched-folder history and growth analysis.
        .target(
            name: "JaagaCore",
            dependencies: ["JaagaProtocol"],
            resources: [.process("Resources")]
        ),

        // Pure presentation maths (squarified treemap, byte formatting, tonal shade ranking).
        // The app links this instead of JaagaCore so it structurally cannot walk the filesystem.
        .target(name: "JaagaLayout", dependencies: ["JaagaProtocol"]),

        // The daemon's socket server and request router, kept in a library so tests can drive it.
        .target(name: "JaagaDaemon", dependencies: ["JaagaCore", "JaagaProtocol"]),

        .executableTarget(name: "jaagad", dependencies: ["JaagaDaemon"]),

        // The renderer. It speaks the protocol and never walks the filesystem itself.
        .executableTarget(name: "JaagaApp", dependencies: ["JaagaProtocol", "JaagaLayout"]),

        .testTarget(name: "JaagaProtocolTests", dependencies: ["JaagaProtocol"]),
        .testTarget(name: "JaagaCoreTests", dependencies: ["JaagaCore"]),
        .testTarget(name: "JaagaLayoutTests", dependencies: ["JaagaLayout"]),
        .testTarget(name: "JaagaDaemonTests", dependencies: ["JaagaDaemon"]),
    ]
)
