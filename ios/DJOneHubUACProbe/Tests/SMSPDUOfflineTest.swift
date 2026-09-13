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
        testMultipart()
        print("SMSPDUOfflineTest: ok")
    }

    static func deliver(_ body: [UInt8], header: [UInt8] = [], coding: UInt8 = 8,
                        userLength: Int? = nil, day: UInt8 = 0x31, sender: UInt8 = 0x21) -> Data {
        // 2026-09-13 09:00:00, UTC+8. No SMSC address.
        Data([0, header.isEmpty ? 0x04 : 0x44, 4, 0x91, sender, 0x43, 0, coding,
              0x62, 0x90, day, 0x90, 0, 0, 0x23, UInt8(userLength ?? (header.count + body.count))]
             + header + body)
    }

    static func record(_ pdu: Data, index: UInt32, storage: SMSStorage = .nv) -> ModuleSMSMessage {
        ModuleSMSMessage(storage: storage, index: index, tag: 1, format: 6, pdu: pdu)
    }

    @MainActor
    static func testMultipart() {
        let firstPDU = deliver([0x4F, 0x60], header: [5, 0, 3, 42, 2, 1])
        let secondPDU = deliver([0x59, 0x7D], header: [5, 0, 3, 42, 2, 2])
        precondition(SMSPDU.decodeDeliver(firstPDU)?.text == "你", "UCS2 UDH must not become text")
        let first = record(firstPDU, index: 10)
        let second = record(secondPDU, index: 3)
        let combined = ModuleSMSDisplayMessage.assemble([second, first])
        precondition(combined.count == 1 && combined[0].preview == "你好", "Order by segment number, not storage index")
        precondition(combined[0].incompleteText == nil && combined[0].parts.count == 2)

        let wide = deliver([0x4F, 0x60], header: [6, 8, 4, 0x12, 0x34, 2, 1])
        let decodedWide = SMSPDU.decodeDeliver(wide)
        precondition(decodedWide?.text == "你", "Odd-sized 16-bit UDH must not shift UTF16 alignment")
        precondition(decodedWide?.concatenation?.reference == 0x1234)
        let wideSecond = record(deliver([0x59, 0x7D], header: [6, 8, 4, 0x12, 0x34, 2, 2]), index: 11)
        precondition(ModuleSMSDisplayMessage.assemble([record(wide, index: 12), wideSecond])[0].preview == "你好")

        // Six UDH bytes use seven septets; one fill bit precedes the first A.
        let sevenBit = deliver([0x82], header: [5, 0, 3, 7, 2, 1], coding: 0, userLength: 8)
        precondition(SMSPDU.decodeDeliver(sevenBit)?.text == "A")
        let sevenBitWide = deliver([0x41], header: [6, 8, 4, 0, 7, 2, 1], coding: 0, userLength: 9)
        precondition(SMSPDU.decodeDeliver(sevenBitWide)?.text == "A")
        precondition(ModuleSMSDisplayMessage.assemble([record(sevenBit, index: 21), record(sevenBitWide, index: 22)]).count == 2,
                     "8-bit and 16-bit references must not collide")

        let missing = ModuleSMSDisplayMessage.assemble([second])
        precondition(missing[0].incompleteText != nil && missing[0].preview.contains("缺少第 1 段"))
        let duplicate = record(firstPDU, index: 99, storage: .sim)
        let deduplicated = ModuleSMSDisplayMessage.assemble([first, second, duplicate])
        precondition(deduplicated.count == 1 && deduplicated[0].preview == "你好")
        precondition(deduplicated[0].parts.count == 3, "Retain duplicate storage records for read state")
        let unrelated = record(deliver([0x59, 0x7D], header: [5, 0, 3, 42, 2, 2], sender: 0x65), index: 30)
        precondition(ModuleSMSDisplayMessage.assemble([first, unrelated]).count == 2)
        let tomorrow = record(deliver([0x59, 0x7D], header: [5, 0, 3, 42, 2, 2], day: 0x41), index: 31)
        precondition(ModuleSMSDisplayMessage.assemble([first, tomorrow]).count == 2, "Do not reuse an old reference")
        let conflicting = record(deliver([0x4E, 0x16], header: [5, 0, 3, 42, 2, 1]), index: 32)
        precondition(ModuleSMSDisplayMessage.assemble([first, conflicting]).count == 2)

        precondition(SMSPDU.decodeDeliver(deliver([0x41], header: [5, 0, 3, 7, 2, 0])) == nil)
        precondition(SMSPDU.decodeDeliver(deliver([], header: [5, 0, 3, 7, 2, 1], coding: 0, userLength: 6)) == nil)
        precondition(SMSPDU.decodeDeliver(deliver([], header: [5, 0, 4, 7, 2, 1])) == nil)
        precondition(SMSPDU.decodeDeliver(Data(firstPDU.dropLast())) == nil)
        precondition(SMSPDU.decodeDeliver(deliver([0x4F, 0x60], header: [3, 0x70, 1, 0xAA]))?.text == "你")
        precondition(SMSPDU.decodeDeliver(deliver([0x41], header: [5, 0, 3, 7, 2, 1], coding: 4))?.text == "A")

        let suite = "DJOneHub.SMSPDUOfflineTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([first.trackingID, second.trackingID, duplicate.trackingID], forKey: "DJOneHub.moduleSMS.unread.v1")
        let model = SMSControlModel(defaults: defaults)
        precondition(model.isUnread(deduplicated[0]))
        model.markRead(deduplicated[0])
        precondition(!model.isUnread(deduplicated[0]))
        precondition(defaults.stringArray(forKey: "DJOneHub.moduleSMS.read.v1")?.count == 3)
    }
}
