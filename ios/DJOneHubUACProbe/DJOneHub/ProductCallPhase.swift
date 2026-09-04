import Foundation

struct StatusConfirmedMediaRecoveryGate {
    private(set) var minimumStatusGeneration: UInt64?

    var isOpen: Bool { minimumStatusGeneration == nil }

    mutating func requireNewStatus(after generation: UInt64) {
        minimumStatusGeneration = generation &+ 1
    }

    mutating func observeStatusGeneration(_ generation: UInt64) {
        guard let minimumStatusGeneration,
              generation >= minimumStatusGeneration else { return }
        self.minimumStatusGeneration = nil
    }

    mutating func observeControlState(
        isStatusPollingHealthy: Bool,
        statusGeneration: UInt64
    ) {
        guard isStatusPollingHealthy else {
            requireNewStatus(after: statusGeneration)
            return
        }
        observeStatusGeneration(statusGeneration)
    }

    mutating func reset() {
        minimumStatusGeneration = nil
    }
}

struct ActiveCallDurationTracker {
    private var callID: UInt8?
    private var startedAt: ContinuousClock.Instant?

    mutating func update(
        phase: ProductCallPhase,
        now: ContinuousClock.Instant
    ) -> UInt64 {
        switch phase {
        case .active(let activeCallID):
            if callID != activeCallID || startedAt == nil {
                callID = activeCallID
                startedAt = now
                return 0
            }
            return elapsedSeconds(at: now)
        case .connecting, .recovering:
            return elapsedSeconds(at: now)
        default:
            reset()
            return 0
        }
    }

    mutating func reset() {
        callID = nil
        startedAt = nil
    }

    private func elapsedSeconds(at now: ContinuousClock.Instant) -> UInt64 {
        guard let startedAt else { return 0 }
        let seconds = startedAt.duration(to: now).components.seconds
        return seconds > 0 ? UInt64(seconds) : 0
    }
}

enum ProductCallPhase: Equatable {
    case needsPairing
    case needsControlPairing
    case connecting
    case ready
    case placingCall
    case dialing(UInt8)
    case incoming(UInt8)
    case answering(UInt8)
    case active(UInt8)
    case ending
    case recovering(String)

    var title: String {
        switch self {
        case .needsPairing: return "添加模块"
        case .needsControlPairing: return "需要控制凭据"
        case .connecting: return "正在连接模块"
        case .ready: return "可以拨号"
        case .placingCall: return "正在拨号"
        case .dialing: return "正在呼叫"
        case .incoming: return "来电"
        case .answering: return "正在接听"
        case .active: return "通话中"
        case .ending: return "正在挂断"
        case .recovering: return "正在恢复连接"
        }
    }

    var systemImage: String {
        switch self {
        case .needsPairing, .needsControlPairing: return "key.fill"
        case .connecting, .recovering: return "cable.connector.horizontal"
        case .ready: return "checkmark.circle.fill"
        case .placingCall, .dialing: return "phone.arrow.up.right.fill"
        case .incoming: return "phone.arrow.down.left.fill"
        case .answering, .active: return "phone.fill"
        case .ending: return "phone.down.fill"
        }
    }

    var callID: UInt8? {
        switch self {
        case .dialing(let id), .incoming(let id), .answering(let id), .active(let id): return id
        default: return nil
        }
    }

    var shouldPrepareCallAudio: Bool {
        switch self {
        case .placingCall, .dialing, .answering, .active:
            return true
        default:
            return false
        }
    }

    var shouldEnableUplink: Bool {
        if case .active = self { return true }
        return false
    }

    var shouldEnableDownlink: Bool {
        switch self {
        case .placingCall, .dialing, .answering, .active:
            return true
        default:
            return false
        }
    }

    func shouldGenerateLocalRingback(calls: [VoiceCallSnapshot]) -> Bool {
        guard case .dialing(let callID) = self else { return false }
        return calls.contains { $0.id == callID && $0.state == 0x05 }
    }

    var prefersFastStatusPolling: Bool {
        switch self {
        case .placingCall, .dialing, .incoming, .answering, .ending:
            return true
        default:
            return false
        }
    }

    static func derive(
        isConfigured: Bool,
        canControlCalls: Bool,
        isBusy: Bool,
        shouldPollStatus: Bool,
        calls: [VoiceCallSnapshot],
        stateText: String
    ) -> ProductCallPhase {
        guard isConfigured else { return .needsPairing }
        guard canControlCalls else { return .needsControlPairing }

        if isBusy, stateText.hasPrefix("拨号中") {
            return .placingCall
        }
        if isBusy, stateText.hasPrefix("接听中"),
           let call = calls.first(where: { $0.state == 0x02 || $0.state == 0x07 }) {
            return .answering(call.id)
        }
        if isBusy, stateText.hasPrefix("挂断中") {
            return .ending
        }
        // Once STATUS polling has failed, call snapshots are no longer
        // authoritative. Do not keep presenting or driving audio from a stale
        // dialing/active state while the control connection is being restored.
        if !shouldPollStatus {
            if isBusy { return .connecting }
            let reason = stateText.contains("失败") || stateText.contains("超时")
                ? stateText
                : "等待 USB ECM 和模块服务重新响应"
            return .recovering(reason)
        }
        if let call = calls.first(where: { $0.state == 0x03 }) {
            return .active(call.id)
        }
        if let call = calls.first(where: { $0.state == 0x02 || $0.state == 0x07 }) {
            return .incoming(call.id)
        }
        if calls.contains(where: { $0.state == 0x08 }) {
            return .ending
        }
        if let call = calls.first(where: { [UInt8(0x01), 0x04, 0x05, 0x0A].contains($0.state) }) {
            return .dialing(call.id)
        }
        return .ready
    }
}
