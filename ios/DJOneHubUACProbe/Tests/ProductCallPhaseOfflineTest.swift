import Foundation

@main
struct ProductCallPhaseOfflineTest {
    static func main() {
        expect(.needsPairing, configured: false)
        expect(.needsControlPairing, control: false)
        expect(.connecting, busy: true)
        expect(.ready, busy: true, polling: true)
        expect(.placingCall, busy: true, state: "拨号中…")
        expect(.incoming(2), calls: [call(2, state: 0x02)])
        expect(.answering(2), busy: true, calls: [call(2, state: 0x02)], state: "接听中…")
        expect(.dialing(3), calls: [call(3, state: 0x05)])
        expect(.active(4), calls: [call(4, state: 0x03), call(2, state: 0x02)])
        expect(.ending, busy: true, calls: [call(4, state: 0x03)], state: "挂断中…")
        expect(
            .recovering("等待 USB ECM 和模块服务重新响应"),
            state: "模块已响应 STATUS"
        )
        expect(.recovering("控制请求超时"), state: "控制请求超时")
        print("ProductCallPhaseOfflineTest: PASS")
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
