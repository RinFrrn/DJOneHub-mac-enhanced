import SwiftUI

@main
struct DJOneHubUACProbeApp: App {
    @StateObject private var audioProbe = AudioProbeModel()
    @StateObject private var networkProbe = ModuleNetworkProbe()
    @StateObject private var voiceControl = VoiceControlModel()
    @StateObject private var uplinkProbe = CallAudioCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioProbe)
                .environmentObject(networkProbe)
                .environmentObject(voiceControl)
                .environmentObject(uplinkProbe)
                .task {
                    voiceControl.restorePairings()
                }
        }
    }
}
