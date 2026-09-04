import Foundation

@main
struct SMSPDUOfflineTest {
    static func main() {
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
