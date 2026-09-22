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
    @Published private(set) var internetUpdatedAt: Date?
    @Published private(set) var moduleInternetEnabled: Bool?
    @Published private(set) var internetChangeError: String?
    @Published private(set) var radio: ModuleRadioStatus?
    @Published private(set) var radioUpdatedAt: Date?
    @Published private(set) var calls: [VoiceCallSnapshot] = []
    @Published private(set) var shouldPollStatus = false
    @Published private(set) var statusSuccessGeneration: UInt64 = 0
    @Published private(set) var moduleUSBAudioEnabled: Bool?
    @Published private(set) var authorizationStateText = "旧密钥回退"
    @Published private(set) var authorizationSessionExpiresAt: Date?
    @Published private(set) var testPairingExpiresAt: Date?
    @Published private(set) var didAttemptUSBAudioQuery = false
    @Published var dialNumber = ""
    @Published var isImportingPairing = false
    @Published var isConfirmingUnpair = false

    private var client: VoiceControlClient?
    private var legacyClient: VoiceControlClient?
    private var keyStore: PairingKeyStore?
    private var mediaPairingKey: Data?
    private var legacyMediaPairingKey: Data?
    private var legacyAccess: VoiceControlAccess?
    private var authorizationTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var requestWatchdogTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var requestArbitration = VoiceControlRequestArbitration()

    var isConfigured: Bool { client != nil }
    var hasTestPairing: Bool { legacyClient != nil }
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
        authorizationTask?.cancel()
    }

    /// Injects a key only for the lifetime of this model; it is never persisted.
    /// A future production pairing ceremony may call this after authenticating the user.
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

    func configureAuthorizationSession(pairingKey: Data, expiresAt: Date) async throws {
        guard expiresAt > Date() else { throw ModuleAuthorizationError.invalidData }
        let candidate = try VoiceControlClient(pairingKey: pairingKey)
        // Do not replace a working legacy client until the module proves that
        // it accepts this newly issued session key.
        _ = try await candidate.status(connectTimeout: .seconds(5))
        client = candidate
        mediaPairingKey = pairingKey
        access = .controlSession
        authorizationSessionExpiresAt = expiresAt
        authorizationStateText = "长期授权 · 短期会话"
        stateText = "长期授权会话"
        detailText = "会话将在 \(expiresAt.formatted(date: .omitted, time: .shortened)) 前自动续签"
    }

    func refreshLongTermAuthorization(force: Bool = false) {
        if authorizationTask != nil, !force { return }
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            let model = ModuleAuthorizationModel()
            while !Task.isCancelled {
                var activated = false
                do {
                    for moduleID in try model.savedModuleIDs() {
                        _ = try await model.status(moduleID: moduleID)
                        let session = try await model.voiceSession(moduleID: moduleID)
                        guard let key = AuthorizationSecret.decode(session.credential) else {
                            throw ModuleAuthorizationError.invalidData
                        }
                        let expiry = session.localExpirationDate()
                        try await self.configureAuthorizationSession(pairingKey: key, expiresAt: expiry)
                        activated = true
                        let delay = max(30, expiry.timeIntervalSinceNow - 5 * 60)
                        try await Task.sleep(for: .seconds(delay))
                        break
                    }
                    if !activated {
                        self.restoreLegacyAuthorization(reason: "此 iPhone 尚未绑定长期授权")
                        self.authorizationTask = nil
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.restoreLegacyAuthorization(reason: "短期会话不可用，正在自动重试")
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }

    private func restoreLegacyAuthorization(reason: String) {
        guard let legacyClient else {
            authorizationSessionExpiresAt = nil
            authorizationStateText = "未配置电话授权"
            return
        }
        client = legacyClient
        mediaPairingKey = legacyMediaPairingKey
        access = legacyAccess
        authorizationSessionExpiresAt = nil
        authorizationStateText = "旧密钥回退"
        detailText = reason
    }

    /// Loads a key only when the caller explicitly opts into the pairing store.
    func configure(from keyStore: PairingKeyStore) {
        do {
            guard let credential = try keyStore.load() else {
                client = nil
                self.keyStore = nil
                moduleIdentifier = nil
                stateText = "未找到 pairing key"
                detailText = "请先导入受信任的模块配对"
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
                refreshLongTermAuthorization()
                return
            }
            try selectPairing(moduleIdentifier: pairing.moduleIdentifier, credential: pairing.credential)
            refreshLongTermAuthorization()
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
            try keyStore.save(StoredPairingCredential(
                key: pairing.pairingKey,
                access: pairing.access,
                createdAt: pairing.createdAt,
                expiresAt: pairing.expiresAt
            ))
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
            detailText = "已删除此 iPhone 上的测试配对，长期配对不受影响"
        } catch {
            stateText = "删除本机配对失败"
            detailText = error.localizedDescription
        }
    }

    func clearConfiguration() {
        clearConfiguration(preservingModuleList: false)
    }

    private func clearConfiguration(preservingModuleList: Bool) {
        testPairingExpiresAt = nil
        requestTask?.cancel()
        requestWatchdogTask?.cancel()
        requestGeneration &+= 1
        requestTask = nil
        requestWatchdogTask = nil
        requestArbitration.reset()
        client = nil
        legacyClient = nil
        mediaPairingKey = nil
        legacyMediaPairingKey = nil
        legacyAccess = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        authorizationSessionExpiresAt = nil
        authorizationStateText = "未配置电话授权"
        keyStore = nil
        moduleIdentifier = nil
        access = nil
        internetUpdatedAt = nil
        moduleInternetEnabled = nil
        internetChangeError = nil
        radio = nil
        radioUpdatedAt = nil
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
        internetUpdatedAt = nil
        moduleInternetEnabled = nil
        internetChangeError = nil
        radio = nil
        radioUpdatedAt = nil
        let selectedClient = try VoiceControlClient(pairingKey: credential.key)
        client = selectedClient
        legacyClient = selectedClient
        mediaPairingKey = credential.key
        legacyMediaPairingKey = credential.key
        self.keyStore = keyStore
        self.moduleIdentifier = moduleIdentifier
        access = credential.access
        legacyAccess = credential.access
        testPairingExpiresAt = credential.expiresAt
        authorizationSessionExpiresAt = nil
        authorizationStateText = "旧密钥回退"
        moduleUSBAudioEnabled = nil
        didAttemptUSBAudioQuery = false
        stateText = credential.access == .controlSession
            ? "控制会话 · \(Self.shortIdentifier(moduleIdentifier))"
            : "STATUS 配对 · \(Self.shortIdentifier(moduleIdentifier))"
        detailText = ""
    }

    func sessionKeyForModuleServices() -> Data? {
        guard access == .controlSession else { return nil }
        return mediaPairingKey
    }

    private static func shortIdentifier(_ identifier: String) -> String {
        String(identifier.prefix(8))
    }

    func refreshStatus() {
        guard let client else {
            stateText = "未配置 pairing key"
            detailText = "控制请求被阻止：请先导入模块配对"
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
            priority: .backgroundStatus,
            operation: {
                try await client.status(connectTimeout: .seconds(3))
            },
            enablePollingOnSuccess: false,
            disablePollingOnFailure: true
        )
    }

    func setModuleInternetEnabled(_ enabled: Bool) {
        guard let client, canControlCalls, !isBusy, calls.isEmpty,
              moduleInternetEnabled != nil else { return }
        internetChangeError = nil
        perform(
            state: "正在切换模块上网…",
            success: enabled ? "模块上网已开启" : "模块上网已关闭",
            operation: { [weak self] in
                do {
                    return try await client.internet(enabled: enabled)
                } catch {
                    await MainActor.run {
                        self?.internetChangeError = "未能确认切换结果，请刷新后重试。"
                    }
                    throw error
                }
            }
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

    func setModuleUSBAudioEnabled(_ enabled: Bool) {
        guard let client, requireCallControl(), calls.isEmpty else {
            stateText = "通话期间不能切换 USB Audio"
            detailText = "请结束当前呼叫后再切换"
            return
        }
        perform(
            state: "切换 USB Audio 数据通道…",
            success: enabled ? "模块 USB Audio 数据通道已开启" : "模块 USB Audio 数据通道已关闭",
            operation: {
                try await client.usbAudio(enabled: enabled)
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
        priority: VoiceControlRequestPriority = .foreground,
        operation: @escaping @Sendable () async throws -> VoiceControlResult,
        enablePollingOnSuccess: Bool = false,
        disablePollingOnFailure: Bool = false,
        onSuccess: (@MainActor @Sendable (VoiceControlResult) -> Void)? = nil
    ) {
        let decision = requestArbitration.begin(priority)
        guard decision != .reject else { return }
        if decision == .preemptBackground {
            requestTask?.cancel()
            requestWatchdogTask?.cancel()
            requestTask = nil
            requestWatchdogTask = nil
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        isBusy = requestArbitration.isForegroundBusy
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
                      self.requestArbitration.activePriority == priority else { return }
                self.requestTask?.cancel()
                self.requestTask = nil
                self.requestArbitration.finish(priority)
                self.isBusy = self.requestArbitration.isForegroundBusy
                if disablePollingOnFailure {
                    self.shouldPollStatus = false
                }
                if reportFailure {
                    self.stateText = "控制请求超时"
                    self.detailText = "模块控制端口未在 24 秒内响应；请检查 iPhone USB 网卡和模块供电"
                }
            }
        }
        requestTask = Task { [weak self] in
            do {
                let result = try await operation()
                let cancelled = Task.isCancelled
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.requestWatchdogTask?.cancel()
                    self.requestArbitration.finish(priority)
                    self.isBusy = self.requestArbitration.isForegroundBusy
                    if result.operation == .status {
                        self.statusSuccessGeneration &+= 1
                    }
                    if result.operation == .status || result.operation == .internet {
                        self.moduleInternetEnabled = result.internetEnabled
                        self.internetUpdatedAt = result.internetEnabled == nil ? nil : Date()
                        if result.internetEnabled != nil { self.internetChangeError = nil }
                    }
                    self.radio = result.radio
                    self.radioUpdatedAt = result.radio == nil ? nil : Date()
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
                    self.requestArbitration.finish(priority)
                    self.isBusy = self.requestArbitration.isForegroundBusy
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
    private var loggedInitialAuthentication = false
    private let configuration: Configuration

    init(pairingKey: Data, configuration: Configuration = .init()) throws {
        guard pairingKey.count == VoiceControlProtocol.tagBytes else {
            throw VoiceControlProtocolError.invalidPairingKeyLength
        }
        self.pairingKey = pairingKey
        self.configuration = configuration
    }

    func status(connectTimeout: Duration? = nil) async throws -> VoiceControlResult {
        try await perform(.status, payload: Data(), connectTimeout: connectTimeout)
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

    func internet(enabled: Bool?) async throws -> VoiceControlResult {
        let payload = try VoiceControlProtocol.payload(for: .internet, internetEnabled: enabled)
        return try await perform(.internet, payload: payload)
    }

    func usbAudio(enabled: Bool?) async throws -> VoiceControlResult {
        let payload = try VoiceControlProtocol.payload(
            for: .usbAudio,
            usbAudioEnabled: enabled
        )
        return try await perform(.usbAudio, payload: payload)
    }

    private func perform(
        _ operation: VoiceControlOperation,
        payload: Data,
        connectTimeout: Duration? = nil
    ) async throws -> VoiceControlResult {
        try Task.checkCancellation()
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ClientError.invalidPort
        }

        let connection = try await connectWhenReady(
            port: port,
            timeout: connectTimeout ?? configuration.connectTimeout
        )
        defer { connection.cancel() }
        if !loggedInitialAuthentication {
            await ConnectionLog.shared.append("控制 TCP 已连接，等待模块握手")
        }

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
            if !loggedInitialAuthentication {
                loggedInitialAuthentication = true
                await ConnectionLog.shared.append("控制响应认证通过，模块已就绪")
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
    private func connectWhenReady(
        port: NWEndpoint.Port,
        timeout: Duration
    ) async throws -> NWConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error = ClientError.timeout
        var attempt = 0

        while clock.now < deadline {
            try Task.checkCancellation()
            attempt += 1
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wiredEthernet
            let connection = NWConnection(
                host: NWEndpoint.Host(configuration.host),
                port: port,
                using: parameters
            )
            let attemptStarted = clock.now
            let diagnostic = TCPAttemptDiagnostic()
            do {
                try await waitForTCP(connection, diagnostic: diagnostic, deadline: deadline)
                if attempt > 1 || !loggedInitialAuthentication {
                    await ConnectionLog.shared.append("控制 TCP 第 \(attempt) 次连接成功，耗时 \(TCPAttemptDiagnostic.elapsed(since: attemptStarted))；\(diagnostic.summary)")
                }
                return connection
            } catch {
                connection.cancel()
                try Task.checkCancellation()
                await ConnectionLog.shared.append("控制 TCP 第 \(attempt) 次未连通，耗时 \(TCPAttemptDiagnostic.elapsed(since: attemptStarted))；\(diagnostic.summary)")
                lastError = error
            }
            guard clock.now < deadline else { break }
            // Probe quickly during USB insertion, then back off while the
            // module boots. Only TCP establishment is retried, never commands.
            let delay = attempt <= 4
                ? min(configuration.connectRetryDelay, .milliseconds(150))
                : configuration.connectRetryDelay
            try await Task.sleep(for: min(delay, clock.now.duration(to: deadline)))
        }
        await ConnectionLog.shared.append("本轮控制 TCP 连接结束，共尝试 \(attempt) 次，等待额度已用完")
        throw lastError
    }

    private func waitForTCP(
        _ connection: NWConnection,
        diagnostic: TCPAttemptDiagnostic,
        deadline: ContinuousClock.Instant
    ) async throws {
        let attemptTimeout = configuration.connectAttemptTimeout
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try Task.checkCancellation()
                    try await connection.startAndWaitUntilReady(diagnostic: diagnostic)
                }
                group.addTask {
                    let clock = ContinuousClock()
                    try await Task.sleep(for: max(.zero, min(attemptTimeout, clock.now.duration(to: deadline))))
                    // Preserve the same connection when iOS is waiting for its
                    // USB path or local-network permission. A refused port still
                    // uses the short retry interval. Never exceed the round budget.
                    if diagnostic.shouldWaitForNetwork {
                        try await Task.sleep(for: max(.zero, clock.now.duration(to: deadline)))
                    }
                    try Task.checkCancellation()
                    diagnostic.markTimedOut()
                    connection.cancel()
                    throw ClientError.timeout
                }
                _ = try await group.next()
            }
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

/// Network callbacks and the timeout task use different queues. Keep only
/// sanitized state/code information, never endpoint names or error userInfo.
private final class TCPAttemptDiagnostic: @unchecked Sendable {
    private let lock = NSLock()
    private var state = "尚未收到网络状态"
    private var path = "网络路径尚未提供"
    private var timedOut = false
    private var waitingForNetwork = false
    private var lastReportedState: String?

    var shouldWaitForNetwork: Bool { lock.withLock { waitingForNetwork } }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    func update(_ value: NWConnection.State, path currentPath: NWPath?) {
        let event: String? = lock.withLock {
            switch value {
            case .setup: state = "等待开始"
            case .preparing: state = "正在准备连接"
            case .waiting(let error):
                state = "网络正在等待：\(Self.describe(error))"
                if case .posix(let code) = error,
                   [.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EACCES, .EPERM].contains(code) {
                    waitingForNetwork = true
                }
                if currentPath?.unsatisfiedReason == .localNetworkDenied {
                    waitingForNetwork = true
                }
            case .failed(let error): state = "连接失败：\(Self.describe(error))"
            case .ready: state = "TCP 已就绪"
            case .cancelled: break // Preserve the cause preceding timeout cancellation.
            @unknown default: state = "未知连接状态"
            }
            if let currentPath {
                let status: String
                switch currentPath.status {
                case .satisfied: status = "网络路径可用"
                case .requiresConnection: status = "网络路径等待建立"
                case .unsatisfied:
                    switch currentPath.unsatisfiedReason {
                    case .localNetworkDenied: status = "本地网络权限被拒绝"
                    case .notAvailable: status = "所需网络路径不可用"
                    default: status = "网络路径不可用"
                    }
                @unknown default: status = "网络路径状态未知"
                }
                path = "\(status)，\(currentPath.usesInterfaceType(.wiredEthernet) ? "使用有线网络" : "未使用有线网络")"
            }
            if case .cancelled = value { return nil }
            let report = "\(state)；\(path)"
            guard waitingForNetwork, report != lastReportedState else { return nil }
            lastReportedState = report
            return "控制 TCP 路径变化（保留连接，最多等待至本轮超时）：\(report)"
        }
        if let event {
            Task { @MainActor in ConnectionLog.shared.append(event) }
        }
    }

    var summary: String {
        lock.withLock { "\(timedOut ? "单次连接超时；" : "")\(state)；\(path)" }
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let value = start.duration(to: .now).components
        return String(format: "%.3f 秒", Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            let reason: String
            switch code {
            case .ECONNREFUSED: reason = "连接被拒绝（控制端口可能尚未监听）"
            case .ETIMEDOUT: reason = "连接超时"
            case .ENETDOWN: reason = "网络接口未就绪"
            case .ENETUNREACH: reason = "网络不可达"
            case .EHOSTUNREACH: reason = "模块地址不可达"
            case .EACCES, .EPERM: reason = "连接受到权限限制"
            default: reason = "网络系统错误"
            }
            return "\(reason)，POSIX \(code.rawValue)"
        case .dns(let code): return "地址解析错误，DNS \(code)"
        case .tls(let code): return "安全连接错误，TLS \(code)"
        default: return "其他网络错误"
        }
    }
}

private extension NWConnection {
    func startAndWaitUntilReady(diagnostic: TCPAttemptDiagnostic) async throws {
        let queue = DispatchQueue(label: "DJOneHub.VoiceControlClient")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate(continuation)

            pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                diagnostic.update(self.state, path: path)
            }
            stateUpdateHandler = { [weak self] state in
                diagnostic.update(state, path: self?.currentPath)
                switch state {
                case .ready:
                    if gate.resume(with: .success(())) {
                        self?.stateUpdateHandler = nil
                        self?.pathUpdateHandler = nil
                    }
                case .failed(let error):
                    if gate.resume(with: .failure(VoiceControlClient.ClientError.connectionFailed(error.localizedDescription))) {
                        self?.stateUpdateHandler = nil
                        self?.pathUpdateHandler = nil
                    }
                case .cancelled:
                    if gate.resume(with: .failure(CancellationError())) {
                        self?.stateUpdateHandler = nil
                        self?.pathUpdateHandler = nil
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
