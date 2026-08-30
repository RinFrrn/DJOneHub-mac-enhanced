import Foundation
import CryptoKit

@main
struct VoiceControlProtocolOfflineTest {
    static func main() throws {
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((0x20..<0x40).map(UInt8.init))
        let requestID: UInt64 = 0x0102030405060708

        let statusRequest = try VoiceControlProtocol.encodeRequest(
            pairingKey: key,
            nonce: nonce,
            operation: .status,
            requestID: requestID,
            payload: Data()
        )
        let expectedRequest = Data(hex: "444a4f48010201000000000001020304050607082b1e51c2c396d82484f7d93af35eb3562658ded867963af2b36fe614b1f75bc4")
        precondition(statusRequest == expectedRequest, "STATUS request vector mismatch")

        let dialPayload = try VoiceControlProtocol.payload(for: .dial, phoneNumber: "+18005551212")
        let dialRequest = try VoiceControlProtocol.encodeRequest(
            pairingKey: key, nonce: nonce, operation: .dial, requestID: 9, payload: dialPayload
        )
        precondition(dialRequest == Data(hex: "444a4f4801020200000c000000000000000000092b313830303535353132313204ada4b11fa1f5f82f3bc26f5aa2ce09f7a768ccb5f8185afe3ff4a85de1abb2"), "DIAL request vector mismatch")

        let answerPayload = try VoiceControlProtocol.payload(for: .answer, callID: 1)
        let answerRequest = try VoiceControlProtocol.encodeRequest(
            pairingKey: key, nonce: nonce, operation: .answer, requestID: 10, payload: answerPayload
        )
        precondition(answerRequest == Data(hex: "444a4f480102030000010000000000000000000a01f10581982223eec2059f1dc25fd6ccaaa7ae31062a2e3f3d31a2cb7e2ebfbbdb"), "ANSWER request vector mismatch")

        let endPayload = try VoiceControlProtocol.payload(for: .end, callID: 1)
        let endRequest = try VoiceControlProtocol.encodeRequest(
            pairingKey: key, nonce: nonce, operation: .end, requestID: 11, payload: endPayload
        )
        precondition(endRequest == Data(hex: "444a4f480102040000010000000000000000000b018b91dab5088e4d375757b14feb23b1ea6c4dc35acbbf8cb075348e856de39eab"), "END request vector mismatch")

        let response = Data(hex: "444a4f48010300000012000001020304050607080100000201020001000000020300020000005d47e52caa5a9ab5c4c1d430d84b014f11ae06f5cc2a28f6167f9e8f53bbb9d6")
        let decoded = try VoiceControlProtocol.decodeResponse(
            pairingKey: key,
            nonce: nonce,
            frame: response,
            expectedRequestID: requestID,
            expectedOperation: .status
        )
        precondition(decoded.status == .ok)
        precondition(decoded.result?.calls.count == 2)
        precondition(decoded.result?.calls[0].id == 1)
        precondition(decoded.result?.calls[0].state == 2)
        precondition(decoded.result?.calls[1].id == 2)
        precondition(decoded.result?.calls[1].state == 3)

        var tampered = response
        tampered[tampered.count - 1] ^= 0x01
        do {
            _ = try VoiceControlProtocol.decodeResponse(
                pairingKey: key,
                nonce: nonce,
                frame: tampered,
                expectedRequestID: requestID,
                expectedOperation: .status
            )
            preconditionFailure("tampered tag accepted")
        } catch VoiceControlProtocolError.authenticationFailed {
        }

        for badNumber in ["", "+", "12 34", "abc", String(repeating: "1", count: 81)] {
            do {
                _ = try VoiceControlProtocol.payload(for: .dial, phoneNumber: badNumber)
                preconditionFailure("invalid number accepted: \(badNumber)")
            } catch VoiceControlProtocolError.invalidPhoneNumber {
            }
        }
        _ = try VoiceControlProtocol.payload(for: .dial, phoneNumber: "+18005551212")

        do {
            _ = try VoiceControlProtocol.payload(for: .answer, callID: 0)
            preconditionFailure("call ID 0 accepted")
        } catch VoiceControlProtocolError.invalidCallID {
        }

        print("VoiceControlProtocolOfflineTest: PASS")
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        precondition(hex.count.isMultiple(of: 2))
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}
