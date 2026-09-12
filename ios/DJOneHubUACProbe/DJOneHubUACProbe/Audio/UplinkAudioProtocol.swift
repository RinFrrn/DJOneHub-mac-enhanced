import CryptoKit
import Foundation

enum UplinkAudioProtocol {
    static let magic: UInt32 = 0x444A4F41
    static let version: UInt8 = 1
    static let directionUplink: UInt8 = 1
    static let directionDownlink: UInt8 = 2
    static let headerBytes = 20
    static let pcmBytes = 256
    static let tagBytes = 16
    static let packetBytes = headerBytes + pcmBytes + tagBytes
    static let samplesPerFrame: UInt32 = 128

    enum ProtocolError: Error, LocalizedError {
        case invalidPairingKey
        case invalidSessionID
        case invalidSequence
        case invalidPCMSize
        case invalidDownlinkPacket

        var errorDescription: String? {
            switch self {
            case .invalidPairingKey: return "PCM pairing key 必须为 32 字节"
            case .invalidSessionID: return "PCM session ID 不能为 0"
            case .invalidSequence: return "PCM sequence 不能为 0"
            case .invalidPCMSize: return "每个 PCM 帧必须恰好为 256 字节"
            case .invalidDownlinkPacket: return "模块下行 PCM 包认证或格式无效"
            }
        }
    }

    static func encodeUplink(
        pairingKey: Data,
        sessionID: UInt32,
        sequence: UInt32,
        pcm: Data
    ) throws -> Data {
        guard pairingKey.count == 32 else { throw ProtocolError.invalidPairingKey }
        guard sessionID != 0 else { throw ProtocolError.invalidSessionID }
        guard sequence != 0 else { throw ProtocolError.invalidSequence }
        guard pcm.count == pcmBytes else { throw ProtocolError.invalidPCMSize }

        var packet = Data()
        packet.reserveCapacity(packetBytes)
        append(magic, to: &packet)
        packet.append(version)
        packet.append(directionUplink)
        append(UInt16(pcmBytes), to: &packet)
        append(sessionID, to: &packet)
        append(sequence, to: &packet)
        append(sequence &* samplesPerFrame, to: &packet)
        packet.append(pcm)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: packet,
            using: SymmetricKey(data: pairingKey)
        )
        packet.append(contentsOf: authentication.prefix(tagBytes))
        return packet
    }

    static func decodeDownlink(
        _ packet: Data,
        pairingKey: Data,
        sessionID: UInt32
    ) throws -> (sequence: UInt32, pcm: Data) {
        guard pairingKey.count == 32 else { throw ProtocolError.invalidPairingKey }
        guard sessionID != 0 else { throw ProtocolError.invalidSessionID }
        guard packet.count == packetBytes,
              readUInt32(packet, at: 0) == magic,
              packet[4] == version,
              packet[5] == directionDownlink,
              readUInt16(packet, at: 6) == UInt16(pcmBytes),
              readUInt32(packet, at: 8) == sessionID else {
            throw ProtocolError.invalidDownlinkPacket
        }
        let sequence = readUInt32(packet, at: 12)
        guard sequence != 0,
              readUInt32(packet, at: 16) == sequence &* samplesPerFrame else {
            throw ProtocolError.invalidDownlinkPacket
        }
        let authenticated = packet.prefix(headerBytes + pcmBytes)
        let expected = HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: pairingKey)
        )
        guard packet.suffix(tagBytes) == Data(expected.prefix(tagBytes)) else {
            throw ProtocolError.invalidDownlinkPacket
        }
        return (
            sequence,
            Data(packet[headerBytes ..< headerBytes + pcmBytes])
        )
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
    }
}
