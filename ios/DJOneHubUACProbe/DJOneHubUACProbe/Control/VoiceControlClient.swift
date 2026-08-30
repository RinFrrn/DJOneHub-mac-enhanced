import Foundation
import Network

@MainActor
final class VoiceControlModel: ObservableObject {
    @Published private(set) var stateText = "未配置 pairing key"
    @Published private(set) var detailText = ""
    @Published private(set) var isBusy = false
    @Published private(set) var moduleIdentifier: String?
    @Published private(set) var availableModuleIdentifiers: [String] = []
    @Published var isImportingPairing = false
    @Published var isConfirmingUnpair = false

    private var client: VoiceControlClient?
    private var keyStore: PairingKeyStore?
    private var requestTask: Task<Void, Never>?

    var isConfigured: Bool { client != nil }

    init(client: VoiceControlClient? = nil) {
        self.client = client
        if client != nil {
            stateText = "已配置（内存）"
        }
    }

    deinit {
        requestTask?.cancel()
    }

    /// Injects a key only for the lifetime of this model; it is never persisted.
    /// The production pairing ceremony will call this after authenticating the user.
    func configure(pairingKey: Data) {
        keyStore = nil
        moduleIdentifier = nil
        do {
            client = try VoiceControlClient(pairingKey: pairingKey)
            stateText = "已配置（内存）"
            detailText = ""
        } catch {
            client = nil
            stateText = "pairing key 无效"
            detailText = error.localizedDescription
        }
    }

    /// Loads a key only when the caller explicitly opts into the production
    /// pairing store. The app does not call this during probe startup.
    func configure(from keyStore: PairingKeyStore) {
        do {
            guard let key = try keyStore.load() else {
                client = nil
                self.keyStore = nil
                moduleIdentifier = nil
                stateText = "未找到 pairing key"
                detailText = "请先完成生产配对"
                return
            }
            configure(pairingKey: key)
            self.keyStore = keyStore
            moduleIdentifier = keyStore.moduleIdentifier
            stateText = "已配对 · \(Self.shortIdentifier(keyStore.moduleIdentifier))"
        } catch {
            client = nil
            self.keyStore = nil
            moduleIdentifier = nil
            stateText = "读取 pairing key 失败"
            detailText = error.localizedDescription
        }
    }

    func restorePairings() {
        do {
            let pairings = try PairingKeyStore.loadAll()
            availableModuleIdentifiers = pairings.map(\.moduleIdentifier)
            guard pairings.count == 1, let pairing = pairings.first else {
                clearConfiguration(preservingModuleList: true)
                if pairings.count > 1 {
                    stateText = "请选择模块"
                    detailText = "Keychain 中保存了 \(pairings.count) 个模块"
                }
                return
            }
            try selectPairing(moduleIdentifier: pairing.moduleIdentifier, key: pairing.key)
        } catch {
            clearConfiguration(preservingModuleList: true)
            stateText = "读取 pairing key 失败"
            detailText = error.localizedDescription
        }
    }

    func selectPairing(moduleIdentifier: String) {
        guard !moduleIdentifier.isEmpty else {
            clearConfiguration(preservingModuleList: true)
            if availableModuleIdentifiers.count > 1 {
                stateText = "请选择模块"
                detailText = "Keychain 中保存了 \(availableModuleIdentifiers.count) 个模块"
            }
            return
        }
        do {
            let keyStore = try PairingKeyStore(moduleIdentifier: moduleIdentifier)
            guard let key = try keyStore.load() else {
                throw PairingKeyStoreError.unexpectedData
            }
            try selectPairing(moduleIdentifier: moduleIdentifier, key: key)
        } catch {
            clearConfiguration(preservingModuleList: true)
            stateText = "选择模块失败"
            detailText = error.localizedDescription
        }
    }

    func importDevelopmentPairingBundle(_ data: Data) {
        do {
            let pairing = try DevelopmentPairingBundle.decodeAndValidate(data)
            let keyStore = try PairingKeyStore(moduleIdentifier: pairing.moduleIdentifier)
            try keyStore.save(pairing.pairingKey)
            restorePairings()
            selectPairing(moduleIdentifier: pairing.moduleIdentifier)
            detailText = "测试凭据已保存到本机 Keychain；请删除原始配对文件"
        } catch {
            stateText = "导入测试配对失败"
            detailText = error.localizedDescription
        }
    }

    func reportPairingImportFailure(_ error: Error) {
        stateText = "读取测试配对文件失败"
        detailText = error.localizedDescription
    }

    func unpairCurrentModule() {
        guard let keyStore else { return }
        do {
            try keyStore.delete()
            restorePairings()
            detailText = "已从本机 Keychain 撤销测试凭据"
        } catch {
            stateText = "撤销配对失败"
            detailText = error.localizedDescription
        }
    }

    func clearConfiguration() {
        clearConfiguration(preservingModuleList: false)
    }

    private func clearConfiguration(preservingModuleList: Bool) {
        requestTask?.cancel()
        requestTask = nil
        client = nil
        keyStore = nil
        moduleIdentifier = nil
        if !preservingModuleList {
            availableModuleIdentifiers = []
        }
        isBusy = false
        stateText = "未配置 pairing key"
        detailText = ""
    }

    private func selectPairing(moduleIdentifier: String, key: Data) throws {
        let keyStore = try PairingKeyStore(moduleIdentifier: moduleIdentifier)
        client = try VoiceControlClient(pairingKey: key)
        self.keyStore = keyStore
        self.moduleIdentifier = moduleIdentifier
        stateText = "已配对 · \(Self.shortIdentifier(moduleIdentifier))"
        detailText = ""
    }

    private static func shortIdentifier(_ identifier: String) -> String {
        String(identifier.prefix(8))
    }

    func refreshStatus() {
        guard let client else {
            stateText = "未配置 pairing key"
            detailText = "控制请求被阻止：先完成生产配对流程"
            return
        }
        guard !isBusy else { return }

        isBusy = true
        stateText = "读取中…"
        detailText = ""
        requestTask = Task { [weak self] in
            do {
                let result = try await client.status()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.isBusy = false
                    self?.stateText = "模块已响应 STATUS"
                    self?.detailText = Self.describe(result)
                    self?.requestTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.isBusy = false
                    self?.stateText = "控制请求失败"
                    self?.detailText = error.localizedDescription
                    self?.requestTask = nil
                }
            }
        }
    }

    private static func describe(_ result: VoiceControlResult) -> String {
        guard !result.calls.isEmpty else { return "当前无活动通话" }
        let calls = result.calls.map { call in
            "#\(call.id) \(stateName(call.state))"
        }
        return calls.joined(separator: "，")
    }

    private static func stateName(_ state: UInt8) -> String {
        switch state {
        case 0x01: return "拨号中"
        case 0x02: return "来电"
        case 0x03: return "通话中"
        case 0x04: return "呼叫进展"
        case 0x05: return "振铃"
        case 0x07: return "等待"
        case 0x09: return "结束"
        default: return "状态 0x\(String(state, radix: 16))"
        }
    }
}

actor VoiceControlClient {
    struct Configuration: Sendable {
        var host = "192.168.225.1"
        var port: UInt16 = 45750
        var connectTimeout: Duration = .seconds(5)
        var ioTimeout: Duration = .seconds(5)
    }

    enum ClientError: Error {
        case invalidPort
        case connectionFailed(String)
        case connectionClosed
        case timeout
        case sendFailed(String)
        case receiveFailed(String)
        case responseStatus(VoiceControlStatus)
    }

    private let pairingKey: Data
    private let configuration: Configuration

    init(pairingKey: Data, configuration: Configuration = .init()) throws {
        guard pairingKey.count == VoiceControlProtocol.tagBytes else {
            throw VoiceControlProtocolError.invalidPairingKeyLength
        }
        self.pairingKey = pairingKey
        self.configuration = configuration
    }

    func status() async throws -> VoiceControlResult {
        try await perform(.status, payload: Data())
    }

    func dial(_ number: String) async throws -> VoiceControlResult {
        let payload = try VoiceControlProtocol.payload(for: .dial, phoneNumber: number)
        return try await perform(.dial, payload: payload)
    }

    func answer(callID: UInt8) async throws -> VoiceControlResult {
        let payload = try VoiceControlProtocol.payload(for: .answer, callID: callID)
        return try await perform(.answer, payload: payload)
    }

    func end(callID: UInt8) async throws -> VoiceControlResult {
        let payload = try VoiceControlProtocol.payload(for: .end, callID: callID)
        return try await perform(.end, payload: payload)
    }

    private func perform(_ operation: VoiceControlOperation, payload: Data) async throws -> VoiceControlResult {
        try Task.checkCancellation()
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ClientError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wiredEthernet
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        )
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
            try await withTimeout(configuration.connectTimeout, onTimeout: { connection.cancel() }) {
                try await connection.startAndWaitUntilReady()
            }
            try Task.checkCancellation()

            let hello = try await withTimeout(configuration.ioTimeout, onTimeout: { connection.cancel() }) {
                try await connection.receiveExactly(VoiceControlProtocol.helloBytes)
            }
            let nonce = try VoiceControlProtocol.decodeHello(hello)

            var requestID: UInt64 = 0
            while requestID == 0 {
                requestID = UInt64.random(in: 1...UInt64.max)
            }
            let request = try VoiceControlProtocol.encodeRequest(
                pairingKey: pairingKey,
                nonce: nonce,
                operation: operation,
                requestID: requestID,
                payload: payload
            )

            try await withTimeout(configuration.ioTimeout, onTimeout: { connection.cancel() }) {
                try await connection.sendAll(request)
            }

            let responseHeader = try await withTimeout(configuration.ioTimeout, onTimeout: { connection.cancel() }) {
                try await connection.receiveExactly(VoiceControlProtocol.headerBytes)
            }
            let payloadLength = Int((UInt16(responseHeader[8]) << 8) | UInt16(responseHeader[9]))
            guard payloadLength <= VoiceControlProtocol.maxSnapshotBytes else {
                throw VoiceControlProtocolError.invalidFrameLength
            }
            let responseTail = try await withTimeout(configuration.ioTimeout, onTimeout: { connection.cancel() }) {
                try await connection.receiveExactly(payloadLength + VoiceControlProtocol.tagBytes)
            }
            var response = responseHeader
            response.append(responseTail)

            let reply = try VoiceControlProtocol.decodeResponse(
                pairingKey: pairingKey,
                nonce: nonce,
                frame: response,
                expectedRequestID: requestID,
                expectedOperation: operation
            )
            guard reply.status == .ok, let result = reply.result else {
                throw ClientError.responseStatus(reply.status)
            }
            return result
        } onCancel: {
            connection.cancel()
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        onTimeout: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                onTimeout()
                throw ClientError.timeout
            }
            guard let result = try await group.next() else {
                throw ClientError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

private extension NWConnection {
    func startAndWaitUntilReady() async throws {
        let queue = DispatchQueue(label: "DJOneHub.VoiceControlClient")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate(continuation)

            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if gate.resume(with: .success(())) {
                        self?.stateUpdateHandler = nil
                    }
                case .failed(let error):
                    if gate.resume(with: .failure(VoiceControlClient.ClientError.connectionFailed(error.localizedDescription))) {
                        self?.stateUpdateHandler = nil
                    }
                case .cancelled:
                    if gate.resume(with: .failure(CancellationError())) {
                        self?.stateUpdateHandler = nil
                    }
                default:
                    break
                }
            }
            start(queue: queue)
        }
    }

    func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: VoiceControlClient.ClientError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw VoiceControlProtocolError.invalidFrameLength }
        if count == 0 { return Data() }
        var output = Data()
        output.reserveCapacity(count)
        while output.count < count {
            let remaining = count - output.count
            let chunk = try await receiveChunk(maximumLength: remaining)
            guard !chunk.isEmpty else { throw VoiceControlClient.ClientError.connectionClosed }
            output.append(chunk)
        }
        return output
    }

    func receiveChunk(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: VoiceControlClient.ClientError.receiveFailed(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: VoiceControlClient.ClientError.connectionClosed)
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }
}

/// `NWConnection` invokes state callbacks from a sendable closure. Keeping the
/// checked continuation behind a lock avoids both duplicate resumes and Swift 6
/// data-race diagnostics without weakening the rest of the actor boundary.
private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
