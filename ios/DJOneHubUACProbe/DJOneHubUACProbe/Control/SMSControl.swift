import Combine
import CryptoKit
import Foundation
import Network

enum SMSControlOperation: UInt8, Sendable {
    case status = 1
    case list = 2
    case read = 3
    case sendRaw = 4
    case delete = 5
}

enum SMSControlStatus: UInt8, Sendable {
    case ok = 0
    case malformed = 1
    case authenticationFailed = 2
    case precondition = 3
    case qmiFailed = 4
    case internalError = 5
    case forbidden = 6
    case limitExceeded = 7
}

enum SMSStorage: UInt8, CaseIterable, Sendable {
    case sim = 0
    case nv = 1

    var title: String { self == .sim ? "SIM" : "模块" }
}

struct SMSMessageReference: Hashable, Sendable {
    let storage: SMSStorage
    let index: UInt32
    let tag: UInt8
}

struct ModuleSMSMessage: Identifiable, Hashable, Sendable {
    var id: String { "\(storage.rawValue)-\(index)" }
    let storage: SMSStorage
    let index: UInt32
    let tag: UInt8
    let format: UInt8
    let pdu: Data

    var title: String {
        decoded?.sender ?? "短信 #\(index)"
    }

    var preview: String {
        decoded?.text ?? "原始 PDU · \(pdu.count) 字节"
    }

    var decoded: SMSDeliverSummary? { SMSPDU.decodeDeliver(pdu) }
    var rawHex: String { pdu.map { String(format: "%02X", $0) }.joined() }
}

struct SMSDeliverSummary: Hashable, Sendable {
    let sender: String
    let text: String
}

enum SMSControlProtocolError: Error, LocalizedError {
    case invalidPairingKey
    case invalidFrame
    case invalidPayload
    case responseStatus(SMSControlStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPairingKey: return "短信 pairing key 必须为 32 字节"
        case .invalidFrame: return "模块短信响应帧无效"
        case .invalidPayload: return "模块短信响应数据无效"
        case .responseStatus(.authenticationFailed): return "模块拒绝了短信配对凭据"
        case .responseStatus(.qmiFailed): return "模块短信 WMS 请求失败"
        case .responseStatus(.forbidden): return "当前短信网关为只读模式"
        case .responseStatus(let status): return "模块返回短信错误（\(status.rawValue)）"
        }
    }
}

private enum SMSControlProtocol {
    static let magic: UInt32 = 0x444A4F53
    static let version: UInt8 = 1
    static let headerBytes = 20
    static let nonceBytes = 32
    static let tagBytes = 32
    static let helloBytes = headerBytes + nonceBytes
    static let maxResponsePayload = 1024

    static func decodeHello(_ frame: Data) throws -> Data {
        guard frame.count == helloBytes,
              uint32(frame, 0) == magic,
              frame[4] == version,
              frame[5] == 1,
              frame[6] == 0,
              frame[7] == 0,
              uint16(frame, 8) == nonceBytes,
              frame[10] == 0,
              frame[11] == 0,
              uint64(frame, 12) == 0 else {
            throw SMSControlProtocolError.invalidFrame
        }
        return frame.subdata(in: headerBytes..<helloBytes)
    }

    static func encodeRequest(
        key: Data,
        nonce: Data,
        operation: SMSControlOperation,
        requestID: UInt64,
        payload: Data
    ) throws -> Data {
        guard key.count == tagBytes else { throw SMSControlProtocolError.invalidPairingKey }
        guard nonce.count == nonceBytes, requestID != 0, payload.count <= 515 else {
            throw SMSControlProtocolError.invalidPayload
        }
        var frame = Data()
        frame.appendBE(magic)
        frame.append(version)
        frame.append(2)
        frame.append(operation.rawValue)
        frame.append(0)
        frame.appendBE(UInt16(payload.count))
        frame.append(contentsOf: [0, 0])
        frame.appendBE(requestID)
        frame.append(payload)
        let authenticated = nonce + frame
        frame.append(Data(HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: key)
        )))
        return frame
    }

    static func decodeResponse(
        key: Data,
        nonce: Data,
        header: Data,
        tail: Data,
        requestID: UInt64,
        operation: SMSControlOperation
    ) throws -> Data {
        guard key.count == tagBytes,
              nonce.count == nonceBytes,
              header.count == headerBytes,
              uint32(header, 0) == magic,
              header[4] == version,
              header[5] == 3,
              header[7] == operation.rawValue,
              header[10] == 0,
              header[11] == 0,
              uint64(header, 12) == requestID else {
            throw SMSControlProtocolError.invalidFrame
        }
        let payloadLength = Int(uint16(header, 8))
        guard payloadLength <= maxResponsePayload,
              tail.count == payloadLength + tagBytes,
              let status = SMSControlStatus(rawValue: header[6]) else {
            throw SMSControlProtocolError.invalidFrame
        }
        let payload = Data(tail.prefix(payloadLength))
        let unsigned = header + payload
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: nonce + unsigned,
            using: SymmetricKey(data: key)
        ))
        guard expected == Data(tail.suffix(tagBytes)) else {
            throw SMSControlProtocolError.invalidFrame
        }
        guard status == .ok else { throw SMSControlProtocolError.responseStatus(status) }
        return Data(payload)
    }

    static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in data[offset..<(offset + 8)] { value = value << 8 | UInt64(byte) }
        return value
    }
}

actor SMSControlClient {
    struct Configuration: Sendable {
        var host = "192.168.225.1"
        var port: UInt16 = 45752
        var connectTimeout: Duration = .seconds(12)
        var attemptTimeout: Duration = .seconds(1)
        var retryDelay: Duration = .milliseconds(500)
        var ioTimeout: Duration = .seconds(5)
    }

    enum ClientError: Error, LocalizedError {
        case connectionFailed(String)
        case connectionClosed
        case timeout
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let text): return "连接模块短信网关失败：\(text)"
            case .connectionClosed: return "模块提前关闭了短信连接"
            case .timeout: return "模块短信请求超时"
            case .invalidPort: return "模块短信端口无效"
            }
        }
    }

    private let key: Data
    private let configuration: Configuration

    init(pairingKey: Data, configuration: Configuration = .init()) throws {
        guard pairingKey.count == 32 else { throw SMSControlProtocolError.invalidPairingKey }
        key = pairingKey
        self.configuration = configuration
    }

    func status() async throws {
        let payload = try await perform(.status, payload: Data())
        guard payload.count == 6,
              payload[2] <= 1,
              payload[3] == 1,
              payload[4] != 0,
              payload[5] != 0 else {
            throw SMSControlProtocolError.invalidPayload
        }
    }

    func list(_ storage: SMSStorage) async throws -> [SMSMessageReference] {
        let payload = try await perform(.list, payload: Data([storage.rawValue]))
        guard payload.count >= 3,
              payload[0] == storage.rawValue else {
            throw SMSControlProtocolError.invalidPayload
        }
        let count = Int(SMSControlProtocol.uint16(payload, 1))
        guard count <= 128, payload.count == 3 + count * 5 else {
            throw SMSControlProtocolError.invalidPayload
        }
        return (0..<count).map { item in
            let offset = 3 + item * 5
            return SMSMessageReference(
                storage: storage,
                index: SMSControlProtocol.uint32(payload, offset),
                tag: payload[offset + 4]
            )
        }
    }

    func read(_ reference: SMSMessageReference) async throws -> ModuleSMSMessage {
        var request = Data([reference.storage.rawValue])
        request.appendBE(reference.index)
        let payload = try await perform(.read, payload: request)
        guard payload.count >= 9,
              payload[0] == reference.storage.rawValue,
              SMSControlProtocol.uint32(payload, 1) == reference.index else {
            throw SMSControlProtocolError.invalidPayload
        }
        let pduLength = Int(SMSControlProtocol.uint16(payload, 7))
        guard payload.count == 9 + pduLength, pduLength > 0 else {
            throw SMSControlProtocolError.invalidPayload
        }
        return ModuleSMSMessage(
            storage: reference.storage,
            index: reference.index,
            tag: payload[5],
            format: payload[6],
            pdu: payload.subdata(in: 9..<payload.count)
        )
    }

    private func perform(_ operation: SMSControlOperation, payload: Data) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ClientError.invalidPort
        }
        let connection = try await connect(port)
        defer { connection.cancel() }
        let hello = try await withTimeout(configuration.ioTimeout) {
            try await connection.smsReceiveExactly(SMSControlProtocol.helloBytes)
        }
        let nonce = try SMSControlProtocol.decodeHello(hello)
        var requestID: UInt64 = 0
        while requestID == 0 { requestID = UInt64.random(in: 1...UInt64.max) }
        let request = try SMSControlProtocol.encodeRequest(
            key: key,
            nonce: nonce,
            operation: operation,
            requestID: requestID,
            payload: payload
        )
        try await withTimeout(configuration.ioTimeout) { try await connection.smsSend(request) }
        let header = try await withTimeout(configuration.ioTimeout) {
            try await connection.smsReceiveExactly(SMSControlProtocol.headerBytes)
        }
        let payloadLength = Int(SMSControlProtocol.uint16(header, 8))
        guard payloadLength <= SMSControlProtocol.maxResponsePayload else {
            throw SMSControlProtocolError.invalidFrame
        }
        let tail = try await withTimeout(configuration.ioTimeout) {
            try await connection.smsReceiveExactly(payloadLength + SMSControlProtocol.tagBytes)
        }
        return try SMSControlProtocol.decodeResponse(
            key: key,
            nonce: nonce,
            header: header,
            tail: tail,
            requestID: requestID,
            operation: operation
        )
    }

    private func connect(_ port: NWEndpoint.Port) async throws -> NWConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.connectTimeout)
        var lastError: Error = ClientError.timeout
        while clock.now < deadline {
            try Task.checkCancellation()
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wiredEthernet
            let connection = NWConnection(
                host: NWEndpoint.Host(configuration.host),
                port: port,
                using: parameters
            )
            do {
                try await withTimeout(configuration.attemptTimeout) {
                    try await connection.smsStart()
                }
                return connection
            } catch {
                connection.cancel()
                lastError = error
            }
            try await Task.sleep(for: configuration.retryDelay)
        }
        throw lastError
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw ClientError.timeout
            }
            guard let result = try await group.next() else { throw ClientError.timeout }
            group.cancelAll()
            return result
        }
    }
}

@MainActor
final class SMSControlModel: ObservableObject {
    @Published private(set) var messages: [ModuleSMSMessage] = []
    @Published private(set) var stateText = "等待连接模块"
    @Published private(set) var isLoading = false
    private var refreshTask: Task<Void, Never>?

    deinit { refreshTask?.cancel() }

    func refresh(pairingKey: Data?) {
        refreshTask?.cancel()
        guard let pairingKey else {
            messages = []
            stateText = "请先连接已配对模块"
            isLoading = false
            return
        }
        isLoading = true
        stateText = "正在读取短信…"
        refreshTask = Task {
            do {
                let client = try SMSControlClient(pairingKey: pairingKey)
                try await client.status()
                var references: [SMSMessageReference] = []
                for storage in SMSStorage.allCases {
                    references.append(contentsOf: try await client.list(storage))
                }
                var loaded: [ModuleSMSMessage] = []
                for reference in references {
                    try Task.checkCancellation()
                    loaded.append(try await client.read(reference))
                }
                messages = loaded.sorted {
                    if $0.storage != $1.storage { return $0.storage.rawValue < $1.storage.rawValue }
                    return $0.index > $1.index
                }
                stateText = messages.isEmpty ? "模块中暂无短信" : "已读取 \(messages.count) 条短信"
            } catch is CancellationError {
                return
            } catch {
                messages = []
                stateText = error.localizedDescription
            }
            isLoading = false
        }
    }
}

enum SMSPDU {
    static func decodeDeliver(_ pdu: Data) -> SMSDeliverSummary? {
        let bytes = [UInt8](pdu)
        guard !bytes.isEmpty else { return nil }
        let smscLength = Int(bytes[0])
        var cursor = 1 + smscLength
        guard cursor + 3 < bytes.count else { return nil }
        let firstOctet = bytes[cursor]
        guard firstOctet & 0x03 == 0 else { return nil }
        cursor += 1
        let addressDigits = Int(bytes[cursor])
        cursor += 1
        let toa = bytes[cursor]
        cursor += 1
        let addressBytes = (addressDigits + 1) / 2
        guard cursor + addressBytes + 10 <= bytes.count else { return nil }
        var sender = semiOctetDigits(Array(bytes[cursor..<(cursor + addressBytes)]), digits: addressDigits)
        if toa & 0x70 == 0x10 { sender = "+" + sender }
        cursor += addressBytes
        cursor += 1 // PID
        let dcs = bytes[cursor]
        cursor += 1
        cursor += 7 // SCTS
        guard cursor < bytes.count else { return nil }
        let userLength = Int(bytes[cursor])
        cursor += 1
        let userData = Array(bytes[cursor...])
        let text: String?
        if dcs & 0x0C == 0x08 {
            let byteCount = min(userLength, userData.count) & ~1
            text = String(data: Data(userData.prefix(byteCount)), encoding: .utf16BigEndian)
        } else if dcs & 0x0C == 0 {
            text = decodeGSM7(userData, septetCount: userLength, hasHeader: firstOctet & 0x40 != 0)
        } else {
            text = String(data: Data(userData.prefix(min(userLength, userData.count))), encoding: .isoLatin1)
        }
        guard let text else { return nil }
        return SMSDeliverSummary(sender: sender, text: text)
    }

    private static func semiOctetDigits(_ bytes: [UInt8], digits: Int) -> String {
        var result = ""
        for byte in bytes {
            result.append(String(format: "%X", byte & 0x0F))
            if result.count < digits, byte >> 4 != 0x0F {
                result.append(String(format: "%X", byte >> 4))
            }
        }
        return String(result.prefix(digits))
    }

    private static func decodeGSM7(_ bytes: [UInt8], septetCount: Int, hasHeader: Bool) -> String? {
        var skipSeptets = 0
        if hasHeader {
            guard let first = bytes.first, Int(first) + 1 <= bytes.count else { return nil }
            skipSeptets = (Int(first) + 1) * 8 / 7
            if (Int(first) + 1) * 8 % 7 != 0 { skipSeptets += 1 }
        }
        var output = ""
        var escaped = false
        for index in skipSeptets..<septetCount {
            let bit = index * 7
            let byteIndex = bit / 8
            guard byteIndex < bytes.count else { break }
            var value = UInt16(bytes[byteIndex]) >> UInt16(bit % 8)
            if bit % 8 > 1, byteIndex + 1 < bytes.count {
                value |= UInt16(bytes[byteIndex + 1]) << UInt16(8 - bit % 8)
            }
            let septet = UInt8(value & 0x7F)
            if escaped {
                output.append(gsmExtension[septet] ?? " ")
                escaped = false
            } else if septet == 0x1B {
                escaped = true
            } else {
                output.append(gsmBasic[Int(septet)])
            }
        }
        return output
    }

    private static let gsmExtension: [UInt8: Character] = [
        0x0A: "\u{000C}", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
        0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "€"
    ]

    private static let gsmBasic = Array(
        "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{001B}ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
    )
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8(value >> 16))
        append(UInt8(value >> 8)); append(UInt8(value))
    }

    mutating func appendBE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(value >> UInt64(shift)))
        }
    }
}

private extension NWConnection {
    func smsStart() async throws {
        let queue = DispatchQueue(label: "DJOneHub.SMSControl")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = SMSContinuationGate<Void>(continuation)
            stateUpdateHandler = { state in
                switch state {
                case .ready: _ = gate.resume(.success(()))
                case .failed(let error): _ = gate.resume(.failure(SMSControlClient.ClientError.connectionFailed(error.localizedDescription)))
                case .cancelled: _ = gate.resume(.failure(CancellationError()))
                default: break
                }
            }
            start(queue: queue)
        }
    }

    func smsSend(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func smsReceiveExactly(_ count: Int) async throws -> Data {
        var output = Data()
        while output.count < count {
            let remaining = count - output.count
            let chunk: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: SMSControlClient.ClientError.connectionClosed) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            guard !chunk.isEmpty else { throw SMSControlClient.ClientError.connectionClosed }
            output.append(chunk)
        }
        return output
    }
}

private final class SMSContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    @discardableResult
    func resume(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard let continuation else { lock.unlock(); return false }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
