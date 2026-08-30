import Foundation
import CryptoKit

enum VoiceControlProtocolError: Error, Equatable {
    case invalidPairingKeyLength
    case invalidNonceLength
    case invalidHeader
    case invalidFrameLength
    case invalidRequestID
    case invalidOperation
    case invalidPhoneNumber
    case invalidCallID
    case authenticationFailed
    case invalidSnapshot
    case operationMismatch
}

enum VoiceControlOperation: UInt8, Sendable {
    case status = 1
    case dial = 2
    case answer = 3
    case end = 4
}

enum VoiceControlStatus: UInt8, Sendable {
    case ok = 0
    case malformed = 1
    case authenticationFailed = 2
    case precondition = 3
    case qmiFailed = 4
    case confirmationTimeout = 5
    case internalError = 6
    case forbidden = 7
}

struct VoiceCallSnapshot: Equatable, Sendable {
    let id: UInt8
    let state: UInt8
    let type: UInt8
    let direction: UInt8
    let mode: UInt8
    let multipart: UInt8
    let als: UInt8
}

struct VoiceControlResult: Equatable, Sendable {
    let operation: VoiceControlOperation
    let actionCallID: UInt8
    let confirmed: Bool
    let calls: [VoiceCallSnapshot]
}

struct VoiceControlReply: Equatable, Sendable {
    let status: VoiceControlStatus
    let result: VoiceControlResult?
}

enum VoiceControlProtocol {
    static let magic: UInt32 = 0x444A4F48
    static let version: UInt8 = 1
    static let headerBytes = 20
    static let nonceBytes = 32
    static let tagBytes = 32
    static let helloBytes = headerBytes + nonceBytes
    static let maxCalls = 8
    static let callRecordBytes = 7
    static let snapshotBaseBytes = 4
    static let maxSnapshotBytes = snapshotBaseBytes + maxCalls * callRecordBytes
    static let maxPayloadBytes = 81
    static let maxDialBytes = 80
    static let maxResponseFrameBytes = headerBytes + maxSnapshotBytes + tagBytes

    private enum FrameType: UInt8 {
        case hello = 1
        case request = 2
        case response = 3
    }

    struct Header: Equatable {
        let type: UInt8
        let code: UInt8
        let payloadLength: UInt16
        let requestID: UInt64
    }

    static func decodeHello(_ frame: Data) throws -> Data {
        let header = try decodeHeader(frame, expectedType: FrameType.hello.rawValue)
        guard header.code == 0,
              header.requestID == 0,
              header.payloadLength == nonceBytes,
              frame.count == helloBytes else {
            throw VoiceControlProtocolError.invalidFrameLength
        }
        return frame.subdata(in: headerBytes..<helloBytes)
    }

    static func encodeRequest(
        pairingKey: Data,
        nonce: Data,
        operation: VoiceControlOperation,
        requestID: UInt64,
        payload: Data
    ) throws -> Data {
        try validatePairingMaterial(pairingKey: pairingKey, nonce: nonce)
        guard requestID != 0 else { throw VoiceControlProtocolError.invalidRequestID }
        try validatePayload(operation: operation, payload: payload)

        var unsigned = encodeHeader(
            type: FrameType.request.rawValue,
            code: operation.rawValue,
            payloadLength: UInt16(payload.count),
            requestID: requestID
        )
        unsigned.append(payload)
        let tag = authenticationTag(pairingKey: pairingKey, nonce: nonce, unsignedFrame: unsigned)
        return unsigned + tag
    }

    static func decodeResponse(
        pairingKey: Data,
        nonce: Data,
        frame: Data,
        expectedRequestID: UInt64,
        expectedOperation: VoiceControlOperation
    ) throws -> VoiceControlReply {
        try validatePairingMaterial(pairingKey: pairingKey, nonce: nonce)
        guard expectedRequestID != 0 else { throw VoiceControlProtocolError.invalidRequestID }

        let header = try decodeHeader(frame, expectedType: FrameType.response.rawValue)
        guard header.requestID == expectedRequestID else {
            throw VoiceControlProtocolError.invalidRequestID
        }
        guard let status = VoiceControlStatus(rawValue: header.code) else {
            throw VoiceControlProtocolError.invalidHeader
        }
        guard Int(header.payloadLength) <= maxSnapshotBytes else {
            throw VoiceControlProtocolError.invalidFrameLength
        }

        let unsignedLength = headerBytes + Int(header.payloadLength)
        guard frame.count == unsignedLength + tagBytes else {
            throw VoiceControlProtocolError.invalidFrameLength
        }

        let unsigned = frame.prefix(unsignedLength)
        let receivedTag = frame.suffix(tagBytes)
        let expectedTag = authenticationTag(
            pairingKey: pairingKey,
            nonce: nonce,
            unsignedFrame: Data(unsigned)
        )
        guard timingSafeEqual(Data(receivedTag), expectedTag) else {
            throw VoiceControlProtocolError.authenticationFailed
        }

        if status != .ok {
            guard header.payloadLength == 0 else {
                throw VoiceControlProtocolError.invalidFrameLength
            }
            return VoiceControlReply(status: status, result: nil)
        }

        let payload = frame.subdata(in: headerBytes..<unsignedLength)
        let result = try decodeResultPayload(payload)
        guard result.operation == expectedOperation else {
            throw VoiceControlProtocolError.operationMismatch
        }
        try validateResultSemantics(result)
        return VoiceControlReply(status: status, result: result)
    }

    static func payload(for operation: VoiceControlOperation, phoneNumber: String? = nil, callID: UInt8? = nil) throws -> Data {
        switch operation {
        case .status:
            return Data()
        case .dial:
            guard let phoneNumber else { throw VoiceControlProtocolError.invalidPhoneNumber }
            let bytes = Array(phoneNumber.utf8)
            guard !bytes.isEmpty, bytes.count <= maxDialBytes else {
                throw VoiceControlProtocolError.invalidPhoneNumber
            }
            var hasDigit = false
            for (index, byte) in bytes.enumerated() {
                let valid = (0x30...0x39).contains(byte)
                    || byte == 0x2A
                    || byte == 0x23
                    || (byte == 0x2B && index == 0 && bytes.count > 1)
                guard valid else { throw VoiceControlProtocolError.invalidPhoneNumber }
                if (0x30...0x39).contains(byte) { hasDigit = true }
            }
            guard hasDigit else { throw VoiceControlProtocolError.invalidPhoneNumber }
            return Data(bytes)
        case .answer, .end:
            guard let callID, callID != 0 else { throw VoiceControlProtocolError.invalidCallID }
            return Data([callID])
        }
    }

    private static func validatePairingMaterial(pairingKey: Data, nonce: Data) throws {
        guard pairingKey.count == tagBytes else { throw VoiceControlProtocolError.invalidPairingKeyLength }
        guard nonce.count == nonceBytes else { throw VoiceControlProtocolError.invalidNonceLength }
    }

    private static func validatePayload(operation: VoiceControlOperation, payload: Data) throws {
        switch operation {
        case .status:
            guard payload.isEmpty else { throw VoiceControlProtocolError.invalidOperation }
        case .dial:
            guard payload.count <= maxDialBytes,
                  let number = String(data: payload, encoding: .utf8) else {
                throw VoiceControlProtocolError.invalidPhoneNumber
            }
            _ = try self.payload(for: .dial, phoneNumber: number)
        case .answer, .end:
            guard payload.count == 1, payload[0] != 0 else {
                throw VoiceControlProtocolError.invalidCallID
            }
        }
    }


    private static func validateResultSemantics(_ result: VoiceControlResult) throws {
        switch result.operation {
        case .status:
            guard result.actionCallID == 0, !result.confirmed else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
        case .dial:
            guard result.actionCallID != 0, result.confirmed,
                  let call = result.calls.first(where: { $0.id == result.actionCallID }),
                  [UInt8(0x01), 0x03, 0x04, 0x05].contains(call.state) else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
        case .answer:
            guard result.actionCallID != 0, result.confirmed,
                  result.calls.contains(where: { $0.id == result.actionCallID && $0.state == 0x03 }) else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
        case .end:
            guard result.actionCallID != 0, result.confirmed else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
            if let call = result.calls.first(where: { $0.id == result.actionCallID }), call.state != 0x09 {
                throw VoiceControlProtocolError.invalidSnapshot
            }
        }
    }

    private static func decodeResultPayload(_ payload: Data) throws -> VoiceControlResult {
        guard payload.count >= snapshotBaseBytes,
              let operation = VoiceControlOperation(rawValue: payload[0]),
              payload[2] <= 1 else {
            throw VoiceControlProtocolError.invalidSnapshot
        }

        let count = Int(payload[3])
        guard count <= maxCalls,
              payload.count == snapshotBaseBytes + count * callRecordBytes else {
            throw VoiceControlProtocolError.invalidSnapshot
        }

        var calls: [VoiceCallSnapshot] = []
        var seen = Set<UInt8>()
        for index in 0..<count {
            let offset = snapshotBaseBytes + index * callRecordBytes
            let callID = payload[offset]
            let state = payload[offset + 1]
            guard callID != 0, state <= 0x0A, seen.insert(callID).inserted else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
            calls.append(VoiceCallSnapshot(
                id: callID,
                state: state,
                type: payload[offset + 2],
                direction: payload[offset + 3],
                mode: payload[offset + 4],
                multipart: payload[offset + 5],
                als: payload[offset + 6]
            ))
        }

        return VoiceControlResult(
            operation: operation,
            actionCallID: payload[1],
            confirmed: payload[2] != 0,
            calls: calls
        )
    }

    private static func decodeHeader(_ frame: Data, expectedType: UInt8) throws -> Header {
        guard frame.count >= headerBytes,
              readBE32(frame, 0) == magic,
              frame[4] == version,
              frame[5] == expectedType,
              frame[7] == 0,
              frame[10] == 0,
              frame[11] == 0 else {
            throw VoiceControlProtocolError.invalidHeader
        }
        return Header(
            type: frame[5],
            code: frame[6],
            payloadLength: readBE16(frame, 8),
            requestID: readBE64(frame, 12)
        )
    }

    private static func encodeHeader(type: UInt8, code: UInt8, payloadLength: UInt16, requestID: UInt64) -> Data {
        var data = Data(capacity: headerBytes)
        appendBE32(magic, to: &data)
        data.append(version)
        data.append(type)
        data.append(code)
        data.append(0)
        appendBE16(payloadLength, to: &data)
        data.append(0)
        data.append(0)
        appendBE64(requestID, to: &data)
        return data
    }

    private static func authenticationTag(pairingKey: Data, nonce: Data, unsignedFrame: Data) -> Data {
        let key = SymmetricKey(data: pairingKey)
        var authenticated = Data(capacity: nonce.count + unsignedFrame.count)
        authenticated.append(nonce)
        authenticated.append(unsignedFrame)
        return Data(HMAC<SHA256>.authenticationCode(for: authenticated, using: key))
    }

    private static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func readBE16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readBE64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    private static func appendBE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendBE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value >> 24))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendBE64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
