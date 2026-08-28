import SwiftUI

@main
struct DJOneHubUACProbeApp: App {
    @StateObject private var audioProbe = AudioProbeModel()
    @StateObject private var networkProbe = ModuleNetworkProbe()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioProbe)
                .environmentObject(networkProbe)
        }
    }
}
