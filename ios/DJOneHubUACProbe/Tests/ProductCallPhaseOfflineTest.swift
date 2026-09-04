import Foundation

@main
struct ProductCallPhaseOfflineTest {
    static func main() {
        expect(.needsPairing, configured: false)
        expect(.needsControlPairing, control: false)
        expect(.connecting, busy: true)
        expect(.ready, busy: true, polling: true)
        expect(.placingCall, busy: true, state: "拨号中…")
        expect(.incoming(2), polling: true, calls: [call(2, state: 0x02)])
        expect(.answering(2), busy: true, calls: [call(2, state: 0x02)], state: "接听中…")
        expect(.dialing(3), polling: true, calls: [call(3, state: 0x05)])
        expect(.dialing(3), polling: true, calls: [call(3, state: 0x0A)])
        expect(.active(4), polling: true, calls: [call(4, state: 0x03), call(2, state: 0x02)])
        expect(.ending, busy: true, calls: [call(4, state: 0x03)], state: "挂断中…")
        expect(.ending, polling: true, calls: [call(4, state: 0x08)])
        expect(
            .recovering("等待 USB ECM 和模块服务重新响应"),
            calls: [call(4, state: 0x03)],
            state: "模块已响应 STATUS"
        )
        expect(
            .recovering("等待 USB ECM 和模块服务重新响应"),
            state: "模块已响应 STATUS"
        )
        expect(.recovering("控制请求超时"), state: "控制请求超时")
        verifyAudioLifecycleHints()
        verifyMediaRecoveryGate()
        print("ProductCallPhaseOfflineTest: PASS")
    }

    private static func verifyMediaRecoveryGate() {
        var gate = StatusConfirmedMediaRecoveryGate()
        precondition(gate.isOpen)
        gate.requireNewStatus(after: 7)
        precondition(!gate.isOpen)
        precondition(gate.minimumStatusGeneration == 8)
        gate.observeStatusGeneration(7)
        precondition(!gate.isOpen)
        gate.observeStatusGeneration(8)
        precondition(gate.isOpen)
        gate.requireNewStatus(after: 20)
        gate.reset()
        precondition(gate.isOpen)

        gate.observeControlState(isStatusPollingHealthy: false, statusGeneration: 30)
        precondition(!gate.isOpen)
        precondition(gate.minimumStatusGeneration == 31)
        gate.observeControlState(isStatusPollingHealthy: true, statusGeneration: 30)
        precondition(!gate.isOpen)
        gate.observeControlState(isStatusPollingHealthy: true, statusGeneration: 31)
        precondition(gate.isOpen)
    }

    private static func verifyAudioLifecycleHints() {
        for phase in [
            ProductCallPhase.placingCall,
            .dialing(1),
            .answering(1),
            .active(1),
        ] {
            precondition(phase.shouldPrepareCallAudio, "\(phase) should prewarm audio")
        }
        for phase in [
            ProductCallPhase.ready,
            .incoming(1),
            .ending,
        ] {
            precondition(!phase.shouldPrepareCallAudio, "\(phase) must not prewarm audio")
        }
        precondition(ProductCallPhase.active(1).shouldEnableUplink)
        precondition(ProductCallPhase.active(1).shouldEnableDownlink)
        precondition(!ProductCallPhase.dialing(1).shouldEnableUplink)
        precondition(ProductCallPhase.dialing(1).shouldEnableDownlink)
        precondition(ProductCallPhase.dialing(1).shouldGenerateLocalRingback(
            calls: [call(1, state: 0x05)]
        ))
        precondition(!ProductCallPhase.dialing(1).shouldGenerateLocalRingback(
            calls: [call(1, state: 0x01)]
        ))
        precondition(!ProductCallPhase.answering(1).shouldEnableUplink)
        precondition(ProductCallPhase.answering(1).shouldEnableDownlink)
        precondition(ProductCallPhase.dialing(1).prefersFastStatusPolling)
        precondition(ProductCallPhase.incoming(1).prefersFastStatusPolling)
        precondition(!ProductCallPhase.active(1).prefersFastStatusPolling)
    }

    private static func expect(
        _ expected: ProductCallPhase,
        configured: Bool = true,
        control: Bool = true,
        busy: Bool = false,
        polling: Bool = false,
        calls: [VoiceCallSnapshot] = [],
        state: String = ""
    ) {
        let actual = ProductCallPhase.derive(
            isConfigured: configured,
            canControlCalls: control,
            isBusy: busy,
            shouldPollStatus: polling,
            calls: calls,
            stateText: state
        )
        precondition(actual == expected, "phase mismatch: expected \(expected), got \(actual)")
    }

    private static func call(_ id: UInt8, state: UInt8) -> VoiceCallSnapshot {
        VoiceCallSnapshot(
            id: id,
            state: state,
            type: 0,
            direction: 0,
            mode: 0,
            multipart: 0,
            als: 0
        )
    }
}
