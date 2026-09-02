import SwiftUI

@main
@MainActor
struct DJOneHubApp: App {
    @StateObject private var voiceControl: VoiceControlModel
    @StateObject private var pcmBridge: UplinkPCMProbeModel
    @StateObject private var lifecycle: CallLifecycleCoordinator

    init() {
        let voiceControl = VoiceControlModel()
        let pcmBridge = UplinkPCMProbeModel()
        _voiceControl = StateObject(wrappedValue: voiceControl)
        _pcmBridge = StateObject(wrappedValue: pcmBridge)
        _lifecycle = StateObject(
            wrappedValue: CallLifecycleCoordinator(
                voiceControl: voiceControl,
                pcmBridge: pcmBridge
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            DJOneHubRootView()
                .environmentObject(voiceControl)
                .environmentObject(pcmBridge)
                .environmentObject(lifecycle)
        }
    }
}

