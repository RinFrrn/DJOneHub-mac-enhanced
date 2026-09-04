import Foundation

enum AudioRouteRecoveryDecision: Equatable {
    case ignore
    case requestRecovery
    case pauseAndRequestRecovery
}

struct AudioRouteRecoveryState {
    private(set) var revision: UInt64 = 0
    private(set) var isRecoveryPending = false
    private var handledRevision: UInt64?

    mutating func noteRouteChange(requiresRecovery: Bool) -> UInt64 {
        revision &+= 1
        isRecoveryPending = isRecoveryPending || requiresRecovery
        return revision
    }

    mutating func settledDecision(
        revision: UInt64,
        hasMediaResources: Bool,
        routeMatchesPolicy: Bool,
        isInterrupted: Bool
    ) -> AudioRouteRecoveryDecision {
        guard revision == self.revision else { return .ignore }
        guard handledRevision != revision else { return .ignore }
        guard !isInterrupted else {
            isRecoveryPending = false
            handledRevision = revision
            return .ignore
        }
        if isRecoveryPending {
            isRecoveryPending = false
            handledRevision = revision
            return .requestRecovery
        }
        guard hasMediaResources, !routeMatchesPolicy else { return .ignore }
        handledRevision = revision
        return .pauseAndRequestRecovery
    }

    mutating func reset() {
        revision &+= 1
        isRecoveryPending = false
        handledRevision = nil
    }
}
