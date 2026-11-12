// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Absolute rpath (derived from this manifest's location) so `swift run` finds the vendored
// MacCAN dylib during dev. Run scripts/fetch-pcbusb.sh first (macOS). The installer
// (scripts/install-macos.sh) bakes in its own rpath for the installed binary.
let pcbusbDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".tools/pcbusb").path

let package = Package(
    name: "austro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AustroCore", targets: ["AustroCore"]),
        .executable(name: "austro", targets: ["austro"])
    ],
    targets: [
        // Platform-independent: .ae3 decode, broadcast decode, health metrics.
        .target(name: "AustroCore"),

        // Fixed-width C shim over the prebuilt MacCAN/PCBUSB library (macOS only).
        .target(name: "CPCBUSB"),

        // SocketCAN C shim (Linux/WSL only; compiles to stubs elsewhere).
        .target(name: "CSocketCAN"),

        // CAN transport + KWP2000/ISO-TP. Backend chosen per-platform: PCBUSB on macOS,
        // SocketCAN on Linux. All read-only; never writes ECU flash.
        .target(name: "AustroCAN", dependencies: [
            "AustroCore",
            .target(name: "CPCBUSB", condition: .when(platforms: [.macOS])),
            .target(name: "CSocketCAN", condition: .when(platforms: [.linux]))
        ]),

        // The CLI: dump / live / faults. Builds on macOS (PCBUSB) and Linux/WSL (SocketCAN).
        .executableTarget(
            name: "austro",
            dependencies: ["AustroCore", "AustroCAN"],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(pcbusbDir)", "-lPCBUSB",
                    "-Xlinker", "-rpath", "-Xlinker", pcbusbDir
                ], .when(platforms: [.macOS]))
            ]
        ),

        .testTarget(name: "AustroCoreTests", dependencies: ["AustroCore"]),
        .testTarget(
            name: "AustroCANTests",
            dependencies: ["AustroCAN"],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(pcbusbDir)", "-lPCBUSB",
                    "-Xlinker", "-rpath", "-Xlinker", pcbusbDir
                ], .when(platforms: [.macOS]))
            ]
        )
    ]
)
