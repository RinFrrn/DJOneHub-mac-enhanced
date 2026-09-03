import Foundation

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

    var shouldEnableCallMedia: Bool {
        if case .active = self { return true }
        return false
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
        if let call = calls.first(where: { $0.state == 0x03 }) {
            return .active(call.id)
        }
        if let call = calls.first(where: { $0.state == 0x02 || $0.state == 0x07 }) {
            return .incoming(call.id)
        }
        if let call = calls.first(where: { [UInt8(0x01), 0x04, 0x05].contains($0.state) }) {
            return .dialing(call.id)
        }
        if isBusy, !shouldPollStatus {
            return .connecting
        }
        if shouldPollStatus {
            return .ready
        }
        let reason = stateText.contains("失败") || stateText.contains("超时")
            ? stateText
            : "等待 USB ECM 和模块服务重新响应"
        return .recovering(reason)
    }
}
