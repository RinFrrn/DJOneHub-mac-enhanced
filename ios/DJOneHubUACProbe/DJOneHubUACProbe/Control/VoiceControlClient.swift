import Foundation
import Network

@MainActor
final class VoiceControlModel: ObservableObject {
    @Published private(set) var stateText = "未配置 pairing key"
    @Published private(set) var detailText = ""
    @Published private(set) var isBusy = false
    @Published private(set) var moduleIdentifier: String?
    @Published private(set) var availableModuleIdentifiers: [String] = []
    @Published private(set) var access: VoiceControlAccess?
    @Published private(set) var calls: [VoiceCallSnapshot] = []
    @Published private(set) var shouldPollStatus = false
    @Published private(set) var moduleUSBAudioEnabled: Bool?
    @Published private(set) var didAttemptUSBAudioQuery = false
    @Published var dialNumber = ""
    @Published var isImportingPairing = false
    @Published var isConfirmingUnpair = false

    private var client: VoiceControlClient?
    private var keyStore: PairingKeyStore?
    private var mediaPairingKey: Data?
    private var requestTask: Task<Void, Never>?
    private var requestWatchdogTask: Task<Void, Never>?
    private var requestGeneration = 0

    var isConfigured: Bool { client != nil }
    var canControlCalls: Bool { client != nil && access == .controlSession }
    var hasActiveCall: Bool { calls.contains { $0.state == 0x03 } }
    var canChangeUSBAudio: Bool {
        canControlCalls && calls.isEmpty && moduleUSBAudioEnabled != nil && !isBusy
    }

    init(client: VoiceControlClient? = nil) {
        self.client = client
        if client != nil {
            access = .controlSession
            stateText = "已配置（内存）"
        }
    }

    deinit {
        requestTask?.cancel()
        requestWatchdogTask?.cancel()
    }

    /// Injects a key only for the lifetime of this model; it is never persisted.
    /// The production pairing ceremony will call this after authenticating the user.
    func configure(pairingKey: Data) {
        keyStore = nil
        moduleIdentifier = nil
        do {
            client = try VoiceControlClient(pairingKey: pairingKey)
            mediaPairingKey = pairingKey
            access = .controlSession
            stateText = "已配置（内存）"
            detailText = ""
        } catch {
            client = nil
            mediaPairingKey = nil
            access = nil
            stateText = "pairing key 无效"
            detailText = error.localizedDescription
        }
    }

    /// Loads a key only when the caller explicitly opts into the production
    /// pairing store. The app does not call this during probe startup.
    func configure(from keyStore: PairingKeyStore) {
        do {
            guard let credential = try keyStore.load() else {
                client = nil
                self.keyStore = nil
                moduleIdentifier = nil
                stateText = "未找到 pairing key"
                detailText = "请先完成生产配对"
                return
            }
            try selectPairing(moduleIdentifier: keyStore.moduleIdentifier, credential: credential)
            self.keyStore = keyStore
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
            try selectPairing(moduleIdentifier: pairing.moduleIdentifier, credential: pairing.credential)
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
            guard let credential = try keyStore.load() else {
                throw PairingKeyStoreError.unexpectedData
            }
            try selectPairing(moduleIdentifier: moduleIdentifier, credential: credential)
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
            try keyStore.save(StoredPairingCredential(key: pairing.pairingKey, access: pairing.access))
            try PairingKeyStore.deleteAll(exceptModuleIdentifier: pairing.moduleIdentifier)
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
        requestWatchdogTask?.cancel()
        requestTask = nil
        requestWatchdogTask = nil
        client = nil
        mediaPairingKey = nil
        keyStore = nil
        moduleIdentifier = nil
        access = nil
        calls = []
        moduleUSBAudioEnabled = nil
        didAttemptUSBAudioQuery = false
        shouldPollStatus = false
        if !preservingModuleList {
            availableModuleIdentifiers = []
        }
        isBusy = false
        stateText = "未配置 pairing key"
        detailText = ""
    }

    private func selectPairing(moduleIdentifier: String, credential: StoredPairingCredential) throws {
        let keyStore = try PairingKeyStore(moduleIdentifier: moduleIdentifier)
        client = try VoiceControlClient(pairingKey: credential.key)
        mediaPairingKey = credential.key
        self.keyStore = keyStore
        self.moduleIdentifier = moduleIdentifier
        access = credential.access
        moduleUSBAudioEnabled = nil
        didAttemptUSBAudioQuery = false
        stateText = credential.access == .controlSession
            ? "控制会话 · \(Self.shortIdentifier(moduleIdentifier))"
            : "STATUS 配对 · \(Self.shortIdentifier(moduleIdentifier))"
        detailText = ""
    }

    func pairingKeyForUplinkProbe() -> Data? {
        guard access == .controlSession else { return nil }
        return mediaPairingKey
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
        shouldPollStatus = false
        perform(
            state: "读取中…",
            success: "模块已响应 STATUS",
            operation: {
                try await client.status()
            },
            enablePollingOnSuccess: true,
            disablePollingOnFailure: true
        )
    }

    func pollStatus() {
        guard let client, canControlCalls, shouldPollStatus else { return }
        perform(
            state: nil,
            success: nil,
            reportFailure: false,
            updateSnapshotDescriptionOnSuccess: true,
            operation: {
                try await client.status()
            },
            enablePollingOnSuccess: false,
            disablePollingOnFailure: true
        )
    }

    func refreshUSBAudioState(reportFailure: Bool = true) {
        guard let client, canControlCalls else { return }
        didAttemptUSBAudioQuery = true
        perform(
            state: reportFailure ? "读取音频模式…" : nil,
            success: reportFailure ? "已读取模块音频模式" : nil,
            reportFailure: reportFailure,
            operation: {
                try await client.usbAudio(enabled: nil)
            },
            onSuccess: { [weak self] result in
                self?.moduleUSBAudioEnabled = result.actionCallID != 0
            }
        )
    }

    func setKeepsSystemAudioOnPhone(_ enabled: Bool) {
        guard let client, requireCallControl(), calls.isEmpty else {
            stateText = "通话期间不能切换 USB Audio"
            detailText = "请结束当前呼叫后再切换"
            return
        }
        let moduleAudioEnabled = !enabled
        perform(
            state: "切换音频输出…",
            success: enabled ? "系统声音留在 iPhone" : "系统声音可输出到模块",
            operation: {
                try await client.usbAudio(enabled: moduleAudioEnabled)
            },
            onSuccess: { [weak self] result in
                self?.moduleUSBAudioEnabled = result.actionCallID != 0
            }
        )
    }

    func dial() {
        guard let client, requireCallControl() else { return }
        let number = dialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(state: "拨号中…", success: "拨号命令已确认") {
            try await client.dial(number)
        }
    }

    func answer(callID: UInt8) {
        guard let client, requireCallControl() else { return }
        perform(state: "接听中…", success: "接听命令已确认") {
            try await client.answer(callID: callID)
        }
    }

    func end(callID: UInt8) {
        guard let client, requireCallControl() else { return }
        perform(state: "挂断中…", success: "挂断命令已确认") {
            try await client.end(callID: callID)
        }
    }

    private func requireCallControl() -> Bool {
        guard canControlCalls else {
            stateText = "当前凭据仅允许 STATUS"
            detailText = "请导入控制会话配对包"
            return false
        }
        return true
    }

    private func perform(
        state: String?,
        success: String?,
        reportFailure: Bool = true,
        updateSnapshotDescriptionOnSuccess: Bool = false,
        operation: @escaping @Sendable () async throws -> VoiceControlResult,
        enablePollingOnSuccess: Bool = false,
        disablePollingOnFailure: Bool = false,
        onSuccess: (@MainActor @Sendable (VoiceControlResult) -> Void)? = nil
    ) {
        guard !isBusy else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        isBusy = true
        if let state {
            stateText = state
            detailText = ""
        }
        requestWatchdogTask?.cancel()
        requestWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(24))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.requestGeneration == generation,
                      self.isBusy else { return }
                self.requestTask?.cancel()
                self.requestTask = nil
                self.isBusy = false
                self.stateText = "控制请求超时"
                self.detailText = "模块控制端口未在 24 秒内响应；请检查 iPhone USB 网卡和模块供电"
            }
        }
        requestTask = Task { [weak self] in
            do {
                let result = try await operation()
                let cancelled = Task.isCancelled
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.requestWatchdogTask?.cancel()
                    self.isBusy = false
                    self.calls = result.calls.filter { $0.state != 0x09 }
                    if enablePollingOnSuccess {
                        self.shouldPollStatus = true
                    }
                    if !cancelled {
                        if let success {
                            self.stateText = success
                            self.detailText = Self.describe(result)
                        } else if updateSnapshotDescriptionOnSuccess {
                            self.stateText = "模块已响应 STATUS"
                            self.detailText = Self.describe(result)
                        }
                    }
                    self.requestTask = nil
                    if !cancelled {
                        onSuccess?(result)
                    }
                }
            } catch {
                let cancelled = Task.isCancelled
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.requestWatchdogTask?.cancel()
                    self.isBusy = false
                    if disablePollingOnFailure {
                        self.shouldPollStatus = false
                    }
                    if !cancelled, reportFailure {
                        self.stateText = "控制请求失败"
                        self.detailText = error.localizedDescription
                    }
                    self.requestTask = nil
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
        case 0x06: return "保持"
        case 0x07: return "等待"
        case 0x08: return "正在结束"
        case 0x09: return "结束"
        case 0x0A: return "呼叫建立"
        default: return "状态 0x\(String(state, radix: 16))"
        }
    }
}

actor VoiceControlClient {
    struct Configuration: Sendable {
        var host = "192.168.225.1"
        var port: UInt16 = 45750
        var connectTimeout: Duration = .seconds(20)
        var connectAttemptTimeout: Duration = .seconds(1)
        var connectRetryDelay: Duration = .milliseconds(500)
        var ioTimeout: Duration = .seconds(5)
    }

    enum ClientError: Error, LocalizedError {
        case invalidPort
        case connectionFailed(String)
        case connectionClosed
        case timeout
        case sendFailed(String)
        case receiveFailed(String)
        case responseStatus(VoiceControlStatus)

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                return "模块控制端口无效"
            case .connectionFailed(let detail):
                return "连接模块失败：\(detail)"
            case .connectionClosed:
                return "模块提前关闭了连接"
            case .timeout:
                return "模块控制请求超时"
            case .sendFailed(let detail):
                return "发送控制请求失败：\(detail)"
            case .receiveFailed(let detail):
                return "读取模块响应失败：\(detail)"
            case .responseStatus(.forbidden):
                return "当前模块会话不允许该操作"
            case .responseStatus(.precondition):
                return "当前通话状态不允许该操作"
            case .responseStatus(.confirmationTimeout):
                return "模块未能确认通话状态变化"
            case .responseStatus(.authenticationFailed):
                return "模块拒绝了配对凭据"
            case .responseStatus(let status):
                return "模块返回控制错误（\(status.rawValue)）"
            }
        }
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

    func usbAudio(enabled: Bool?) async throws -> VoiceControlResult {
        let payload = try VoiceControlProtocol.payload(
            for: .usbAudio,
            usbAudioEnabled: enabled
        )
        return try await perform(.usbAudio, payload: payload)
    }

    private func perform(_ operation: VoiceControlOperation, payload: Data) async throws -> VoiceControlResult {
        try Task.checkCancellation()
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ClientError.invalidPort
        }

        let connection = try await connectWhenReady(port: port)
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
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

    /// The module's ECM interface appears before its cold-boot voice runtime
    /// has loaded the QDC507 drivers and started the authenticated listener.
    /// Retry only TCP establishment; once a HELLO is received, operations such
    /// as DIAL are never replayed automatically.
    private func connectWhenReady(port: NWEndpoint.Port) async throws -> NWConnection {
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
                try await withTimeout(
                    configuration.connectAttemptTimeout,
                    onTimeout: { connection.cancel() }
                ) {
                    try await connection.startAndWaitUntilReady()
                }
                return connection
            } catch {
                connection.cancel()
                lastError = error
            }
            guard clock.now < deadline else { break }
            try await Task.sleep(for: configuration.connectRetryDelay)
        }
        throw lastError
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
