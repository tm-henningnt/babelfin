// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Babelfin",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Babelfin", targets: ["Babelfin"])],
    targets: [
        .target(name: "CAtomicMixer", publicHeadersPath: "include"),
        .target(name: "BridgeCore", dependencies: ["CAtomicMixer"]),
        .executableTarget(name: "Babelfin", dependencies: ["BridgeCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["BridgeCore"], path: "Checks")
    ],
    cLanguageStandard: .c11
)
