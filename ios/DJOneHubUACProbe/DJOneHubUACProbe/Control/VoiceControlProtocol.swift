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
    case usbAudio = 5
    case internet = 6
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
    let remoteNumberPresentation: UInt8?
    let remoteNumber: String?

    var presentedRemoteNumber: String? {
        guard remoteNumberPresentation == 0,
              let remoteNumber,
              !remoteNumber.isEmpty else { return nil }
        return remoteNumber
    }

    var remotePartyDisplayText: String {
        if let presentedRemoteNumber { return presentedRemoteNumber }
        return remoteNumberPresentation == 1 ? "私人号码" : "未知号码"
    }
}

struct ModuleRadioStatus: Equatable, Sendable {
    let dbm: Int
    let technology: UInt8

    var networkType: String {
        switch technology {
        case 1: return "2G"
        case 2: return "3G"
        case 4: return "2G"
        case 5, 9: return "3G"
        case 8: return "4G"
        case 12: return "5G"
        default: return "蜂窝"
        }
    }

    // RSSI presentation only; this is not an RSRP or throughput estimate.
    var bars: Int {
        if dbm >= -75 { return 4 }
        if dbm >= -85 { return 3 }
        if dbm >= -95 { return 2 }
        return 1
    }
}

struct VoiceControlResult: Equatable, Sendable {
    let operation: VoiceControlOperation
    let actionCallID: UInt8
    let confirmed: Bool
    let calls: [VoiceCallSnapshot]
    var radio: ModuleRadioStatus? = nil
    var internetEnabled: Bool? = nil
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
    static let maxRemoteNumberBytes = 81
    static let resultExtensionHeaderBytes = 3
    static let remotePartyNumbersExtensionType: UInt8 = 1
    static let maxSnapshotBytes = snapshotBaseBytes + maxCalls * callRecordBytes
        + resultExtensionHeaderBytes + 1 + maxCalls * (3 + maxRemoteNumberBytes) + 10
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

    static func payload(
        for operation: VoiceControlOperation,
        phoneNumber: String? = nil,
        callID: UInt8? = nil,
        usbAudioEnabled: Bool? = nil,
        internetEnabled: Bool? = nil
    ) throws -> Data {
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
        case .internet:
            guard let internetEnabled else { return Data() }
            return Data([internetEnabled ? 1 : 0])
        case .usbAudio:
            guard let usbAudioEnabled else { return Data() }
            return Data([usbAudioEnabled ? 1 : 0])
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
        case .usbAudio, .internet:
            guard payload.isEmpty || (payload.count == 1 && payload[0] <= 1) else {
                throw VoiceControlProtocolError.invalidOperation
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
        case .internet:
            guard result.confirmed, let enabled = result.internetEnabled,
                  result.actionCallID == (enabled ? 1 : 0) else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
        case .usbAudio:
            guard result.actionCallID <= 1, result.confirmed else {
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
        let fixedRecordsEnd = snapshotBaseBytes + count * callRecordBytes
        guard count <= maxCalls, payload.count >= fixedRecordsEnd else {
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
                als: payload[offset + 6],
                remoteNumberPresentation: nil,
                remoteNumber: nil
            ))
        }

        var radio: ModuleRadioStatus?
        var internetEnabled: Bool?
        var extensionOffset = fixedRecordsEnd
        while extensionOffset < payload.count {
            guard payload.count - extensionOffset >= resultExtensionHeaderBytes else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
            let extensionType = payload[extensionOffset]
            let extensionLength = Int(readBE16(payload, extensionOffset + 1))
            extensionOffset += resultExtensionHeaderBytes
            guard extensionLength <= payload.count - extensionOffset else {
                throw VoiceControlProtocolError.invalidSnapshot
            }
            let extensionEnd = extensionOffset + extensionLength
            if extensionType == remotePartyNumbersExtensionType {
                guard extensionLength >= 1 else {
                    throw VoiceControlProtocolError.invalidSnapshot
                }
                let numberCount = Int(payload[extensionOffset])
                extensionOffset += 1
                guard numberCount <= maxCalls else {
                    throw VoiceControlProtocolError.invalidSnapshot
                }
                var seenNumberCallIDs = Set<UInt8>()
                for _ in 0..<numberCount {
                    guard extensionEnd - extensionOffset >= 3 else {
                        throw VoiceControlProtocolError.invalidSnapshot
                    }
                    let callID = payload[extensionOffset]
                    let presentation = payload[extensionOffset + 1]
                    let numberLength = Int(payload[extensionOffset + 2])
                    extensionOffset += 3
                    guard callID != 0,
                          seenNumberCallIDs.insert(callID).inserted,
                          numberLength <= maxRemoteNumberBytes,
                          numberLength <= extensionEnd - extensionOffset,
                          let callIndex = calls.firstIndex(where: { $0.id == callID }) else {
                        throw VoiceControlProtocolError.invalidSnapshot
                    }
                    let numberData = payload.subdata(
                        in: extensionOffset..<(extensionOffset + numberLength)
                    )
                    guard let number = String(data: numberData, encoding: .utf8),
                          number.isEmpty || isSafeRemoteNumber(number) else {
                        throw VoiceControlProtocolError.invalidSnapshot
                    }
                    let call = calls[callIndex]
                    calls[callIndex] = VoiceCallSnapshot(
                        id: call.id,
                        state: call.state,
                        type: call.type,
                        direction: call.direction,
                        mode: call.mode,
                        multipart: call.multipart,
                        als: call.als,
                        remoteNumberPresentation: presentation,
                        remoteNumber: number.isEmpty ? nil : number
                    )
                    extensionOffset += numberLength
                }
                guard extensionOffset == extensionEnd else {
                    throw VoiceControlProtocolError.invalidSnapshot
                }
            } else if extensionType == 3 {
                guard extensionLength == 1, internetEnabled == nil,
                      (1...2).contains(payload[extensionOffset]) else {
                    throw VoiceControlProtocolError.invalidSnapshot
                }
                internetEnabled = payload[extensionOffset] == 2
                extensionOffset = extensionEnd
            } else if extensionType == 2 {
                guard extensionLength == 3, radio == nil,
                      payload[extensionOffset] == 1 else {
                    throw VoiceControlProtocolError.invalidSnapshot
                }
                let dbm = Int(Int8(bitPattern: payload[extensionOffset + 1]))
                let technology = payload[extensionOffset + 2]
                guard (-125 ... -1).contains(dbm), technology != 0 else {
                    throw VoiceControlProtocolError.invalidSnapshot
                }
                radio = ModuleRadioStatus(dbm: dbm, technology: technology)
                extensionOffset = extensionEnd
            } else {
                extensionOffset = extensionEnd
            }
        }

        return VoiceControlResult(
            operation: operation,
            actionCallID: payload[1],
            confirmed: payload[2] != 0,
            calls: calls,
            radio: radio,
            internetEnabled: internetEnabled
        )
    }

    private static func isSafeRemoteNumber(_ number: String) -> Bool {
        let bytes = Array(number.utf8)
        guard !bytes.isEmpty, bytes.count <= maxRemoteNumberBytes else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            (0x30...0x39).contains(byte)
                || byte == 0x2A
                || byte == 0x23
                || (byte == 0x2B && index == 0 && bytes.count > 1)
        }
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
