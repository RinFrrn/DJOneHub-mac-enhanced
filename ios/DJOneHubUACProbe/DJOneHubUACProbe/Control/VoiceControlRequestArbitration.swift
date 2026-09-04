enum VoiceControlRequestPriority: Equatable {
    case backgroundStatus
    case foreground
}

enum VoiceControlRequestDecision: Equatable {
    case start
    case preemptBackground
    case reject
}

struct VoiceControlRequestArbitration {
    private(set) var activePriority: VoiceControlRequestPriority?

    var isForegroundBusy: Bool {
        activePriority == .foreground
    }

    mutating func begin(_ priority: VoiceControlRequestPriority) -> VoiceControlRequestDecision {
        switch (activePriority, priority) {
        case (nil, _):
            activePriority = priority
            return .start
        case (.backgroundStatus, .foreground):
            activePriority = .foreground
            return .preemptBackground
        default:
            return .reject
        }
    }

    mutating func finish(_ priority: VoiceControlRequestPriority) {
        guard activePriority == priority else { return }
        activePriority = nil
    }

    mutating func reset() {
        activePriority = nil
    }
}
