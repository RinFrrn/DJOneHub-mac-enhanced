import Combine
import CryptoKit
import Foundation
import Network
import OSLog

/// Shared by the product app and the diagnostic probe; entries stay in memory.
@MainActor
final class ConnectionLog: ObservableObject {
    static let shared = ConnectionLog()
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let elapsed: Double
        let message: String
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var noWiredInterface: Bool?
    private var started = ContinuousClock.now
    private let wiredMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let monitorQueue = DispatchQueue(label: "DJOneHub.WiredNetworkDiagnostics")
    private var monitoringStarted = false
    private var lastWiredPath: String?

    func startNetworkMonitoring() {
        guard !monitoringStarted else { return }
        monitoringStarted = true
        wiredMonitor.pathUpdateHandler = { [weak self] path in
            let summary = Self.describeWiredPath(path)
            let absent = path.status == .unsatisfied && path.unsatisfiedReason == .notAvailable &&
                !path.availableInterfaces.contains { $0.type == .wiredEthernet }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.noWiredInterface = absent
                guard self.lastWiredPath != summary else { return }
                self.lastWiredPath = summary
                self.append("独立有线网络监测：\(summary)")
            }
        }
        wiredMonitor.start(queue: monitorQueue)
    }

    func recordNetworkSnapshot() {
        append("前台有线网络快照：\(Self.describeWiredPath(wiredMonitor.currentPath))")
    }

    nonisolated private static func describeWiredPath(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "路径可用"
        case .requiresConnection: status = "路径等待建立"
        case .unsatisfied:
            status = path.unsatisfiedReason == .localNetworkDenied
                ? "本地网络权限被拒绝" : "路径不可用"
        @unknown default: status = "路径状态未知"
        }
        let count = path.availableInterfaces.filter { $0.type == .wiredEthernet }.count
        return "\(status)；系统报告可用有线接口 \(count) 个；IPv4 支持\(path.supportsIPv4 ? "有" : "无")"
    }

    func append(_ message: String) {
        let duration = started.duration(to: .now).components
        entries.append(Entry(date: Date(),
                             elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                             message: message))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }

    func clear() {
        entries.removeAll()
        started = .now
    }

    var exportText: String {
        (["DJOneHub 连接日志（本次 App 运行，最多 300 条）"] + entries.map {
            "\($0.date.formatted(.iso8601)) +\(String(format: "%.3f", $0.elapsed))s \($0.message)"
        }).joined(separator: "\n")
    }
}

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
    var trackingID: String {
        let digest = SHA256.hash(data: pdu).prefix(8)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return "\(storage.rawValue)-\(index)-\(fingerprint)"
    }
}

struct SMSDeliverSummary: Hashable, Sendable {
    let sender: String
    let text: String
    let concatenation: SMSConcatenation?
    let timestamp: Date?
    let coding: UInt8
    let protocolID: UInt8
    let otherHeader: Data
}

struct SMSConcatenation: Hashable, Sendable {
    let reference: UInt16
    let referenceBits: Int
    let total: Int
    let sequence: Int
}

/// One visible message can own multiple module storage records. Keep every
/// record so read state and raw diagnostics continue to refer to real PDUs.
struct ModuleSMSDisplayMessage: Identifiable, Sendable {
    let parts: [ModuleSMSMessage]
    let title: String
    let preview: String
    let receivedParts: Int
    let expectedParts: Int
    var id: String { parts[0].id }
    var storageTitle: String {
        Set(parts.map(\.storage)).count > 1 ? "SIM / 模块" : parts[0].storage.title
    }
    var incompleteText: String? {
        receivedParts < expectedParts ? "长短信尚未收齐（\(receivedParts)/\(expectedParts) 段）" : nil
    }

    static func assemble(_ records: [ModuleSMSMessage]) -> [Self] {
        struct Key: Hashable {
            let sender: String
            let reference: UInt16
            let bits: Int
            let total: Int
            let coding: UInt8
            let protocolID: UInt8
            let otherHeader: Data
        }
        var groups: [[ModuleSMSMessage]] = []
        var candidates: [Key: [Int]] = [:]
        var decodedRecords: [String: SMSDeliverSummary] = [:]
        for record in records { decodedRecords[record.id] = record.decoded }
        let ordered = records.sorted {
            let left = decodedRecords[$0.id]?.timestamp ?? .distantPast
            let right = decodedRecords[$1.id]?.timestamp ?? .distantPast
            if left != right { return left < right }
            if $0.storage != $1.storage { return $0.storage.rawValue < $1.storage.rawValue }
            return $0.index < $1.index
        }
        for record in ordered {
            guard let decoded = decodedRecords[record.id], let concat = decoded.concatenation else {
                groups.append([record])
                continue
            }
            let key = Key(sender: decoded.sender, reference: concat.reference,
                          bits: concat.referenceBits, total: concat.total,
                          coding: decoded.coding, protocolID: decoded.protocolID,
                          otherHeader: decoded.otherHeader)
            let matches = (candidates[key] ?? []).filter { index in
                guard let first = decodedRecords[groups[index][0].id] else { return false }
                // References are reused. Do not combine unrelated old messages;
                // conflicting copies of a sequence must remain separate.
                if let a = first.timestamp, let b = decoded.timestamp,
                   abs(a.timeIntervalSince(b)) > 600 { return false }
                return !groups[index].contains {
                    guard let existing = decodedRecords[$0.id],
                          existing.concatenation?.sequence == concat.sequence else { return false }
                    return existing.text != decoded.text
                }
            }
            if matches.count == 1, let index = matches.first {
                groups[index].append(record)
            } else {
                candidates[key, default: []].append(groups.count)
                groups.append([record])
            }
        }
        return groups.reversed().map { records in
            let parts = records.sorted {
                let left = decodedRecords[$0.id]?.concatenation?.sequence ?? 1
                let right = decodedRecords[$1.id]?.concatenation?.sequence ?? 1
                if left != right { return left < right }
                return $0.id < $1.id
            }
            let first = parts[0]
            guard let concat = decodedRecords[first.id]?.concatenation else {
                return Self(parts: parts, title: first.title, preview: first.preview, receivedParts: 1, expectedParts: 1)
            }
            var bySequence: [Int: String] = [:]
            for part in parts {
                if let decoded = decodedRecords[part.id], let sequence = decoded.concatenation?.sequence {
                    bySequence[sequence] = decoded.text
                }
            }
            let text = (1...concat.total).map { bySequence[$0] ?? "〔缺少第 \($0) 段〕" }.joined()
            return Self(parts: parts, title: first.title, preview: text,
                        receivedParts: bySequence.count, expectedParts: concat.total)
        }
    }
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

enum SMSControlProtocol {
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
        // A cold QMI client and a LIST compatibility retry can each consume
        // another five seconds before the daemon can send its response.
        var responseTimeout: Duration = .seconds(20)
        var handshakeTimeout: Duration = .seconds(20)
    }

    enum ClientError: Error, LocalizedError {
        case connectionFailed(String)
        case connectionClosed
        case timeout
        case stageTimeout(String)
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let text): return "连接模块短信网关失败：\(text)"
            case .connectionClosed: return "模块提前关闭了短信连接"
            case .timeout: return "模块短信请求超时"
            case .stageTimeout(let stage): return "模块短信\(stage)超时"
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
            tag: payload[5] == 0xFF ? reference.tag : payload[5],
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
        let hello = try await withTimeout(configuration.handshakeTimeout, stage: "握手", onCancel: { connection.cancel() }) {
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
        try await withTimeout(configuration.ioTimeout, stage: "发送请求", onCancel: { connection.cancel() }) {
            try await connection.smsSend(request)
        }
        let header = try await withTimeout(configuration.responseTimeout, stage: "等待响应（\(operation)）", onCancel: { connection.cancel() }) {
            try await connection.smsReceiveExactly(SMSControlProtocol.headerBytes)
        }
        let payloadLength = Int(SMSControlProtocol.uint16(header, 8))
        guard payloadLength <= SMSControlProtocol.maxResponsePayload else {
            throw SMSControlProtocolError.invalidFrame
        }
        let tail = try await withTimeout(configuration.ioTimeout, stage: "接收数据", onCancel: { connection.cancel() }) {
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
                try await withTimeout(configuration.attemptTimeout, onCancel: { connection.cancel() }) {
                    try await connection.smsStart()
                }
                return connection
            } catch {
                connection.cancel()
                try Task.checkCancellation()
                lastError = error
            }
            try await Task.sleep(for: configuration.retryDelay)
        }
        throw lastError
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        stage: String = "建立连接",
        onCancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let started = ContinuousClock.now
        defer {
            let elapsed = started.duration(to: .now)
            Logger(subsystem: "DJOneHub", category: "SMS").info("stage=\(stage, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)")
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: duration)
                    onCancel()
                    throw ClientError.stageTimeout(stage)
                }
                guard let result = try await group.next() else { throw ClientError.timeout }
                group.cancelAll()
                return result
            }
        } onCancel: {
            onCancel()
        }
    }
}

@MainActor
final class SMSControlModel: ObservableObject {
    @Published private(set) var messages: [ModuleSMSDisplayMessage] = []
    @Published private(set) var stateText = "等待连接模块"
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedMessages = false
    var isInitialLoading: Bool { isLoading && !hasLoadedMessages }
    @Published private(set) var unreadCount = 0
    private var refreshTask: Task<Void, Never>?
    private var messageCache: [SMSMessageReference: ModuleSMSMessage] = [:]
    private var retryNotBefore: ContinuousClock.Instant?
    private var consecutiveFailures = 0
    private var loggedSuccessfulQuery = false
    private var unreadMessageIDs: Set<String>
    private var readMessageIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unreadMessageIDs = Set(defaults.stringArray(forKey: Self.unreadDefaultsKey) ?? [])
        readMessageIDs = Set(defaults.stringArray(forKey: Self.readDefaultsKey) ?? [])
    }

    private let defaults: UserDefaults
    private static let unreadDefaultsKey = "DJOneHub.moduleSMS.unread.v1"
    private static let readDefaultsKey = "DJOneHub.moduleSMS.read.v1"

    deinit { refreshTask?.cancel() }

    func refresh(pairingKey: Data?) {
        guard !isLoading else { return }
        guard let pairingKey else {
            messages = []
            unreadCount = 0
            messageCache = [:]
            hasLoadedMessages = false
            stateText = "请先连接已配对模块"
            isLoading = false
            retryNotBefore = nil
            consecutiveFailures = 0
            return
        }
        if let retryNotBefore, ContinuousClock.now < retryNotBefore { return }
        isLoading = true
        if !hasLoadedMessages { stateText = "正在读取短信…" }
        if !loggedSuccessfulQuery || consecutiveFailures > 0 {
            ConnectionLog.shared.append("开始查询模块短信")
        }
        refreshTask = Task {
            defer { isLoading = false }
            do {
                let client = try SMSControlClient(pairingKey: pairingKey)
                try await client.status()
                var references: [SMSMessageReference] = []
                for storage in SMSStorage.allCases {
                    references.append(contentsOf: try await client.list(storage))
                }
                var loaded: [ModuleSMSMessage] = []
                var updatedCache: [SMSMessageReference: ModuleSMSMessage] = [:]
                var loadedPairs: [(SMSMessageReference, ModuleSMSMessage)] = []
                for reference in references {
                    try Task.checkCancellation()
                    let message: ModuleSMSMessage
                    if let cached = messageCache[reference] {
                        message = cached
                    } else {
                        message = try await client.read(reference)
                        // Keep successful reads even when a later request fails.
                        messageCache[reference] = message
                    }
                    loaded.append(message)
                    updatedCache[reference] = message
                    loadedPairs.append((reference, message))
                }
                messages = ModuleSMSDisplayMessage.assemble(loaded)
                messageCache = updatedCache
                hasLoadedMessages = true
                if consecutiveFailures > 0 || !loggedSuccessfulQuery {
                    ConnectionLog.shared.append("短信查询完成")
                    loggedSuccessfulQuery = true
                }
                consecutiveFailures = 0
                retryNotBefore = nil
                updateUnreadState(with: loadedPairs)
                stateText = messages.isEmpty
                    ? "模块中暂无短信 · 自动更新"
                    : "已读取 \(messages.count) 条短信 · 自动更新"
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures = min(consecutiveFailures + 1, 4)
                let delay = min(5 * (1 << consecutiveFailures), 60)
                retryNotBefore = .now.advanced(by: .seconds(delay))
                stateText = "\(error.localizedDescription)，\(delay) 秒后自动重试"
                // Log only our fixed error categories, never arbitrary payloads.
                if case SMSControlClient.ClientError.stageTimeout(let stage) = error {
                    ConnectionLog.shared.append("短信超时：\(stage)；\(delay) 秒后重试")
                } else {
                    ConnectionLog.shared.append("短信查询失败；\(delay) 秒后重试")
                }
            }
        }
    }

    func isUnread(_ message: ModuleSMSDisplayMessage) -> Bool {
        message.parts.contains { unreadMessageIDs.contains($0.trackingID) }
    }

    func markRead(_ message: ModuleSMSDisplayMessage) {
        for part in message.parts {
            unreadMessageIDs.remove(part.trackingID)
            readMessageIDs.insert(part.trackingID)
        }
        persistReadState()
    }

    private func updateUnreadState(with pairs: [(SMSMessageReference, ModuleSMSMessage)]) {
        let currentIDs = Set(pairs.map { $0.1.trackingID })
        unreadMessageIDs.formIntersection(currentIDs)
        readMessageIDs.formIntersection(currentIDs)
        for (reference, message) in pairs
        where reference.tag == 1 && !readMessageIDs.contains(message.trackingID) {
            unreadMessageIDs.insert(message.trackingID)
        }
        persistReadState()
    }

    private func persistReadState() {
        unreadCount = messages.filter { isUnread($0) }.count
        defaults.set(unreadMessageIDs.sorted(), forKey: Self.unreadDefaultsKey)
        defaults.set(readMessageIDs.sorted(), forKey: Self.readDefaultsKey)
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
        if toa & 0x70 == 0x50 {
            guard let name = decodeGSM7(Array(bytes[cursor..<(cursor + addressBytes)]),
                                        septetCount: addressDigits * 4 / 7, hasHeader: false) else { return nil }
            sender = name
        }
        if toa & 0x70 == 0x10 { sender = "+" + sender }
        cursor += addressBytes
        let protocolID = bytes[cursor]
        cursor += 1
        let dcs = bytes[cursor]
        cursor += 1
        let timestamp = decodeTimestamp(Array(bytes[cursor..<(cursor + 7)]))
        cursor += 7 // SCTS
        guard cursor < bytes.count else { return nil }
        let userLength = Int(bytes[cursor])
        cursor += 1
        let isGSM7 = dcs & 0x0C == 0
        let byteLength = isGSM7 ? (userLength * 7 + 7) / 8 : userLength
        guard cursor + byteLength <= bytes.count else { return nil }
        let userData = Array(bytes[cursor..<(cursor + byteLength)])
        let hasHeader = firstOctet & 0x40 != 0
        let headerLength: Int
        var concatenation: SMSConcatenation?
        var otherHeader = Data()
        if hasHeader {
            guard let length = userData.first else { return nil }
            headerLength = Int(length) + 1
            guard headerLength <= userData.count else { return nil }
            var offset = 1
            while offset < headerLength {
                guard offset + 2 <= headerLength else { return nil }
                let identifier = userData[offset]
                let length = Int(userData[offset + 1])
                let end = offset + 2 + length
                guard end <= headerLength else { return nil }
                let info = Array(userData[(offset + 2)..<end])
                if identifier == 0x00 || identifier == 0x08 {
                    guard concatenation == nil else { return nil }
                    if identifier == 0x00, length == 3 {
                        concatenation = SMSConcatenation(reference: UInt16(info[0]), referenceBits: 8,
                                                        total: Int(info[1]), sequence: Int(info[2]))
                    } else if identifier == 0x08, length == 4 {
                        concatenation = SMSConcatenation(reference: UInt16(info[0]) << 8 | UInt16(info[1]),
                                                        referenceBits: 16, total: Int(info[2]), sequence: Int(info[3]))
                    } else { return nil }
                    guard let value = concatenation, value.total > 0,
                          (1...value.total).contains(value.sequence) else { return nil }
                } else {
                    otherHeader.append(contentsOf: userData[offset..<end])
                }
                offset = end
            }
        } else { headerLength = 0 }
        let body = Data(userData.dropFirst(headerLength))
        let text: String?
        if dcs & 0x0C == 0x08 {
            guard body.count.isMultiple(of: 2) else { return nil }
            text = String(data: body, encoding: .utf16BigEndian)
        } else if isGSM7 {
            text = decodeGSM7(userData, septetCount: userLength, hasHeader: hasHeader)
        } else {
            text = String(data: body, encoding: .isoLatin1)
        }
        guard let text else { return nil }
        return SMSDeliverSummary(sender: sender, text: text, concatenation: concatenation,
                                 timestamp: timestamp, coding: dcs, protocolID: protocolID, otherHeader: otherHeader)
    }

    private static func decodeTimestamp(_ bytes: [UInt8]) -> Date? {
        func bcd(_ byte: UInt8) -> Int { Int(byte & 0x0F) * 10 + Int(byte >> 4) }
        guard bytes.prefix(6).allSatisfy({ $0 & 0x0F <= 9 && $0 >> 4 <= 9 }) else { return nil }
        let quarterHours = bcd(bytes[6] & 0xF7)
        let offset = quarterHours * 15 * 60 * (bytes[6] & 0x08 == 0 ? 1 : -1)
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: 2000 + bcd(bytes[0]), month: bcd(bytes[1]),
                                        day: bcd(bytes[2]), hour: bcd(bytes[3]),
                                        minute: bcd(bytes[4]), second: bcd(bytes[5]))
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
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
        guard septetCount >= skipSeptets, septetCount * 7 <= bytes.count * 8 else { return nil }
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

extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
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
