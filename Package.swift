// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The Azure Live Interpreter route links Microsoft's Speech SDK when scripts/fetch-azure-speech-sdk.sh
// has placed it in Vendor/ (ignored by Git). Without it, the app builds without the Azure route.
let azureSpeech = "Vendor/AzureSpeech/MicrosoftCognitiveServicesSpeech.xcframework"
let hasAzureSpeech = FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + azureSpeech)
var appDependencies: [Target.Dependency] = ["BridgeCore"]
var extraTargets: [Target] = []
if hasAzureSpeech {
    appDependencies.append("MicrosoftCognitiveServicesSpeech")
    extraTargets.append(.binaryTarget(name: "MicrosoftCognitiveServicesSpeech", path: azureSpeech))
}

let package = Package(
    name: "Babelfin",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Babelfin", targets: ["Babelfin"])],
    targets: [
        .target(name: "CAtomicMixer", publicHeadersPath: "include"),
        .target(name: "BridgeCore", dependencies: ["CAtomicMixer"]),
        .executableTarget(name: "Babelfin", dependencies: appDependencies,
                          linkerSettings: hasAzureSpeech ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []),
        .executableTarget(name: "CoreChecks", dependencies: ["BridgeCore"], path: "Checks")
    ] + extraTargets,
    cLanguageStandard: .c11
)
