import Foundation

@main
struct AudioRouteRecoveryStateOfflineTest {
    static func main() {
        ignoresHealthyAndIdleRoutes()
        rejectsStaleSettleChecks()
        preservesImmediatePauseAcrossFollowUpNotifications()
        requestsOneRecoveryForASettledInvalidRoute()
        defersToAudioInterruptionRecovery()
        resetInvalidatesOutstandingChecks()
        callKitActivationGatesMediaAcrossCalls()
        print("AudioRouteRecoveryStateOfflineTest: PASS")
    }

    private static func callKitActivationGatesMediaAcrossCalls() {
        var state = CallKitAudioOwnership.app
        precondition(state.canStartMedia && !state.isSystemManaged)
        state.begin()
        precondition(state.isSystemManaged && !state.canStartMedia)
        state.activate()
        precondition(state.canStartMedia && state.isSystemManaged)
        state.begin() // A repeated incoming snapshot must not suspend a live call.
        precondition(state.canStartMedia)
        state.deactivate()
        precondition(!state.canStartMedia && state.isSystemManaged)
        state.activate()
        precondition(state.canStartMedia)
        state = .app
        state.deactivate() // A late end callback must not block the next outgoing call.
        precondition(state.canStartMedia && !state.isSystemManaged)
        state.activate()
        precondition(!state.isSystemManaged)
        state.begin() // The next incoming call needs its own activation.
        precondition(!state.canStartMedia)
    }

    private static func ignoresHealthyAndIdleRoutes() {
        var state = AudioRouteRecoveryState()
        let healthy = state.noteRouteChange(requiresRecovery: false)
        precondition(state.settledDecision(
            revision: healthy,
            hasMediaResources: true,
            routeMatchesPolicy: true,
            isInterrupted: false
        ) == .ignore)

        let idle = state.noteRouteChange(requiresRecovery: false)
        precondition(state.settledDecision(
            revision: idle,
            hasMediaResources: false,
            routeMatchesPolicy: false,
            isInterrupted: false
        ) == .ignore)
    }

    private static func rejectsStaleSettleChecks() {
        var state = AudioRouteRecoveryState()
        let stale = state.noteRouteChange(requiresRecovery: false)
        _ = state.noteRouteChange(requiresRecovery: false)
        precondition(state.settledDecision(
            revision: stale,
            hasMediaResources: true,
            routeMatchesPolicy: false,
            isInterrupted: false
        ) == .ignore)
    }

    private static func preservesImmediatePauseAcrossFollowUpNotifications() {
        var state = AudioRouteRecoveryState()
        _ = state.noteRouteChange(requiresRecovery: true)
        let settled = state.noteRouteChange(requiresRecovery: false)
        precondition(state.isRecoveryPending)
        precondition(state.settledDecision(
            revision: settled,
            hasMediaResources: false,
            routeMatchesPolicy: false,
            isInterrupted: false
        ) == .requestRecovery)
        precondition(!state.isRecoveryPending)
    }

    private static func requestsOneRecoveryForASettledInvalidRoute() {
        var state = AudioRouteRecoveryState()
        let revision = state.noteRouteChange(requiresRecovery: false)
        precondition(state.settledDecision(
            revision: revision,
            hasMediaResources: true,
            routeMatchesPolicy: false,
            isInterrupted: false
        ) == .pauseAndRequestRecovery)
        precondition(state.settledDecision(
            revision: revision,
            hasMediaResources: true,
            routeMatchesPolicy: false,
            isInterrupted: false
        ) == .ignore)
    }

    private static func defersToAudioInterruptionRecovery() {
        var state = AudioRouteRecoveryState()
        let revision = state.noteRouteChange(requiresRecovery: true)
        precondition(state.settledDecision(
            revision: revision,
            hasMediaResources: false,
            routeMatchesPolicy: false,
            isInterrupted: true
        ) == .ignore)
        precondition(!state.isRecoveryPending)
    }

    private static func resetInvalidatesOutstandingChecks() {
        var state = AudioRouteRecoveryState()
        let revision = state.noteRouteChange(requiresRecovery: true)
        state.reset()
        precondition(state.settledDecision(
            revision: revision,
            hasMediaResources: true,
            routeMatchesPolicy: false,
            isInterrupted: false
        ) == .ignore)
        precondition(!state.isRecoveryPending)
    }
}
