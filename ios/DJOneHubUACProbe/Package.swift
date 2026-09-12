// swift-tools-version: 6.0
import PackageDescription

// Host-only tests for the authorization protocol; app targets remain in Xcode.
let package = Package(
    name: "DJOneHubAuthorization",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "ModuleAuthorization",
            path: "DJOneHubUACProbe/Control",
            exclude: ["PairingKeyStore.swift", "SMSControl.swift", "VoiceControlClient.swift",
                      "VoiceControlProtocol.swift", "VoiceControlRequestArbitration.swift"],
            sources: ["ModuleAuthorization.swift", "ModuleAuthorizationClient.swift"]
        ),
        .testTarget(name: "ModuleAuthorizationTests", dependencies: ["ModuleAuthorization"], path: "AuthorizationTests")
    ]
)
