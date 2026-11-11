// swift-tools-version: 5.9
import PackageDescription
import Foundation
let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? (FileManager.default.fileExists(atPath: "/opt/homebrew") ? "/opt/homebrew" : "/usr/local")
let package = Package(
    name: "AndroidTransfer", platforms: [.macOS("26.0")],
    products: [.executable(name: "AndroidTransfer", targets: ["AndroidTransfer"])],
    targets: [
        .target(name: "MTPBridge", cSettings: [.unsafeFlags(["-I\(prefix)/include"])],
                linkerSettings: [.unsafeFlags(["-L\(prefix)/lib"]), .linkedLibrary("mtp")]),
        .target(name: "TransferCore"),
        .target(name: "WirelessCore", dependencies: ["TransferCore"], resources: [.copy("Resources/index.html")]),
        .executableTarget(name: "AndroidTransfer", dependencies: ["MTPBridge", "TransferCore", "WirelessCore"]),
        .executableTarget(name: "WirelessChecks", dependencies: ["WirelessCore"], path: "WirelessChecks", exclude: ["integration.py"]),
        .executableTarget(name: "TransferChecks", dependencies: ["TransferCore", "MTPBridge"], path: "Checks")
    ])
