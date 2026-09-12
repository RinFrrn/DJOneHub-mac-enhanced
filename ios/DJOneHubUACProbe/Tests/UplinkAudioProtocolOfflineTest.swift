import CryptoKit
import Foundation

@main
struct UplinkAudioProtocolOfflineTest {
    static func main() throws {
        let key = Data((0 ..< 32).map(UInt8.init))
        let pcm = Data((0 ..< UplinkAudioProtocol.pcmBytes).map { UInt8(truncatingIfNeeded: $0) })
        let packet = try UplinkAudioProtocol.encodeUplink(
            pairingKey: key,
            sessionID: 0x01020304,
            sequence: 0x05060708,
            pcm: pcm
        )

        precondition(packet.count == UplinkAudioProtocol.packetBytes)
        precondition(packet.prefix(20) == Data(hex: "444a4f4101010100010203040506070883038400"))
        precondition(packet[20 ..< 276] == pcm)
        let expectedTag = HMAC<SHA256>.authenticationCode(
            for: packet.prefix(276),
            using: SymmetricKey(data: key)
        )
        precondition(packet.suffix(16) == Data(expectedTag.prefix(16)))

        var downlink = Data(packet.prefix(276))
        downlink[5] = UplinkAudioProtocol.directionDownlink
        let downlinkTag = HMAC<SHA256>.authenticationCode(
            for: downlink,
            using: SymmetricKey(data: key)
        )
        downlink.append(contentsOf: downlinkTag.prefix(16))
        let decoded = try UplinkAudioProtocol.decodeDownlink(
            downlink,
            pairingKey: key,
            sessionID: 0x01020304
        )
        precondition(decoded.sequence == 0x05060708)
        precondition(decoded.pcm == pcm)

        downlink[20] ^= 0xff
        do {
            _ = try UplinkAudioProtocol.decodeDownlink(
                downlink,
                pairingKey: key,
                sessionID: 0x01020304
            )
            preconditionFailure("tampered downlink accepted")
        } catch UplinkAudioProtocol.ProtocolError.invalidDownlinkPacket {
        }

        for invalid in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 33)] {
            do {
                _ = try UplinkAudioProtocol.encodeUplink(
                    pairingKey: invalid,
                    sessionID: 1,
                    sequence: 1,
                    pcm: Data(repeating: 0, count: 256)
                )
                preconditionFailure("invalid key accepted")
            } catch UplinkAudioProtocol.ProtocolError.invalidPairingKey {
            }
        }

        print("UplinkAudioProtocolOfflineTest: PASS")
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        precondition(hex.count.isMultiple(of: 2))
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
    }
}
