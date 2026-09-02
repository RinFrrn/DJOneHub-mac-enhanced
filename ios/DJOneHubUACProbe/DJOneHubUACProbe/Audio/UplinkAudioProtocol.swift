import CryptoKit
import Foundation

enum UplinkAudioProtocol {
    static let magic: UInt32 = 0x444A4F41
    static let version: UInt8 = 1
    static let directionUplink: UInt8 = 1
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

        var errorDescription: String? {
            switch self {
            case .invalidPairingKey: return "PCM pairing key 必须为 32 字节"
            case .invalidSessionID: return "PCM session ID 不能为 0"
            case .invalidSequence: return "PCM sequence 不能为 0"
            case .invalidPCMSize: return "每个 PCM 帧必须恰好为 256 字节"
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
}
