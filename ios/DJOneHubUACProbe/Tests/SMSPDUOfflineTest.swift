import Foundation

@main
struct SMSPDUOfflineTest {
    static func main() {
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((0x20..<0x40).map(UInt8.init))
        let request = try! SMSControlProtocol.encodeRequest(
            key: key,
            nonce: nonce,
            operation: .status,
            requestID: 0x0102030405060708,
            payload: Data()
        )
        precondition(request.count == 52)
        precondition(request.prefix(20) == Data([
            0x44, 0x4A, 0x4F, 0x53, 0x01, 0x02, 0x01, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08
        ]))

        let ucs2 = Data([
            0x00, 0x04, 0x04, 0x91, 0x21, 0x43, 0x00, 0x08,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x04, 0x4F, 0x60, 0x59, 0x7D
        ])
        let decodedUCS2 = SMSPDU.decodeDeliver(ucs2)
        precondition(decodedUCS2?.sender == "+1234")
        precondition(decodedUCS2?.text == "你好")

        let gsm7 = Data([
            0x00, 0x04, 0x04, 0x91, 0x21, 0x43, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x05, 0xE8, 0x32, 0x9B, 0xFD, 0x06
        ])
        let decodedGSM7 = SMSPDU.decodeDeliver(gsm7)
        precondition(decodedGSM7?.sender == "+1234")
        precondition(decodedGSM7?.text == "hello")

        precondition(SMSPDU.decodeDeliver(Data([0x00])) == nil)
        print("SMSPDUOfflineTest: ok")
    }
}
