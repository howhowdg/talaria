// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesNative",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HermesProtocol", targets: ["HermesProtocol"]),
        .library(name: "HermesTransport", targets: ["HermesTransport"]),
        .library(name: "HermesCore", targets: ["HermesCore"]),
        .library(name: "HermesUI", targets: ["HermesUI"]),
        .library(name: "HermesMacServices", targets: ["HermesMacServices"]),
        .executable(name: "hermes-smoke", targets: ["HermesSmoke"])
    ],
    targets: [
        .target(name: "HermesProtocol"),
        .target(name: "HermesTransport", dependencies: ["HermesProtocol"]),
        .target(name: "HermesCore", dependencies: ["HermesProtocol", "HermesTransport"]),
        .target(name: "HermesUI", dependencies: ["HermesCore", "HermesProtocol", "HermesTransport"],
                resources: [.process("Resources")]),
        .target(name: "HermesMacServices"),
        .executableTarget(name: "HermesSmoke", dependencies: ["HermesCore", "HermesTransport", "HermesProtocol", "HermesMacServices"]),
        .testTarget(name: "HermesProtocolTests", dependencies: ["HermesProtocol"]),
        .testTarget(name: "HermesTransportTests", dependencies: ["HermesTransport", "HermesProtocol"]),
        .testTarget(name: "HermesCoreTests", dependencies: ["HermesCore", "HermesProtocol", "HermesTransport"]),
        .testTarget(name: "HermesMacServicesTests", dependencies: ["HermesMacServices"]),
        .testTarget(name: "HermesUITests", dependencies: ["HermesUI", "HermesCore", "HermesProtocol"])
    ]
)
