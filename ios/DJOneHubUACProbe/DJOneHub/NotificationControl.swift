import CryptoKit
import Foundation
import Network
import SwiftUI
import UniformTypeIdentifiers

private enum NotificationControlOperation: UInt8 {
    case status = 1
    case settings = 2
    case webPush = 3
    case certificate = 4
    case testBark = 5
    case testWebPush = 6
}

private enum NotificationControlStatusCode: UInt8 {
    case ok = 0
    case malformed = 1
    case authenticationFailed = 2
    case invalidConfiguration = 3
    case pushFailed = 4
    case internalError = 5
}

private struct ModuleNotificationStatus: Decodable, Sendable {
    let version: Int
    let barkConfigured: Bool
    let barkHost: String?
    let barkCallSound: Bool
    let showCallNumber: Bool
    let showSMSBody: Bool
    let webPushConfigured: Bool
    let webPushPublicKey: String
    let customCA: Bool
    let customCAHash: String?

    enum CodingKeys: String, CodingKey {
        case version
        case barkConfigured = "bark_configured"
        case barkHost = "bark_host"
        case barkCallSound = "bark_call_sound"
        case showCallNumber = "show_call_number"
        case showSMSBody = "show_sms_body"
        case webPushConfigured = "web_push_configured"
        case webPushPublicKey = "web_push_public_key"
        case customCA = "custom_ca"
        case customCAHash = "custom_ca_hash"
    }
}

private struct ModuleNotificationSettings: Encodable, Sendable {
    let barkURL: String?
    let clearBark: Bool
    let barkCallSound: Bool
    let showCallNumber: Bool
    let showSMSBody: Bool

    enum CodingKeys: String, CodingKey {
        case barkURL = "bark_url"
        case clearBark = "clear_bark"
        case barkCallSound = "bark_call_sound"
        case showCallNumber = "show_call_number"
        case showSMSBody = "show_sms_body"
    }
}

private enum NotificationControlError: Error, LocalizedError {
    case pairingRequired
    case invalidBarkURL
    case invalidFrame
    case invalidPayload
    case connectionClosed
    case timeout
    case connectionFailed(String)
    case response(NotificationControlStatusCode)

    var errorDescription: String? {
        switch self {
        case .pairingRequired: return "请先导入具备控制权限的模块配对"
        case .invalidBarkURL: return "请粘贴 Bark App 提供的完整 https:// 推送地址"
        case .invalidFrame: return "模块提醒配置响应无效"
        case .invalidPayload: return "配置文件无效或超过 64 KiB"
        case .connectionClosed: return "模块提前关闭了配置连接"
        case .timeout: return "模块提醒配置请求超时"
        case .connectionFailed(let message): return "连接模块提醒服务失败：\(message)"
        case .response(.authenticationFailed): return "模块拒绝了配对凭据"
        case .response(.invalidConfiguration): return "URL、证书或 Web Push 配置无效"
        case .response(.pushFailed): return "推送测试失败，请检查网络、URL 与证书"
        case .response(.malformed): return "模块无法识别此配置"
        case .response(.internalError): return "模块保存提醒配置失败"
        case .response(.ok): return nil
        }
    }
}

private enum NotificationControlProtocol {
    static let magic: UInt32 = 0x444A4F4E
    static let version: UInt8 = 1
    static let headerBytes = 20
    static let nonceBytes = 32
    static let tagBytes = 32
    static let helloBytes = headerBytes + nonceBytes
    static let maxPayload = 64 * 1024
    static let maxResponsePayload = 8 * 1024

    static func decodeHello(_ frame: Data) throws -> Data {
        guard frame.count == helloBytes,
              uint32(frame, 0) == magic,
              frame[4] == version,
              frame[5] == 1,
              frame[6] == 0,
              frame[7] == 0,
              uint32(frame, 8) == nonceBytes,
              uint64(frame, 12) == 0 else {
            throw NotificationControlError.invalidFrame
        }
        return frame.subdata(in: headerBytes..<helloBytes)
    }

    static func request(
        key: Data,
        nonce: Data,
        operation: NotificationControlOperation,
        requestID: UInt64,
        payload: Data
    ) throws -> Data {
        guard key.count == tagBytes, nonce.count == nonceBytes,
              requestID != 0, payload.count <= maxPayload else {
            throw NotificationControlError.invalidPayload
        }
        var frame = Data()
        frame.appendBE(magic)
        frame.append(version)
        frame.append(2)
        frame.append(operation.rawValue)
        frame.append(0)
        frame.appendBE(UInt32(payload.count))
        frame.appendBE(requestID)
        frame.append(payload)
        frame.append(Data(HMAC<SHA256>.authenticationCode(
            for: nonce + frame,
            using: SymmetricKey(data: key)
        )))
        return frame
    }

    static func response(
        key: Data,
        nonce: Data,
        header: Data,
        tail: Data,
        requestID: UInt64,
        operation: NotificationControlOperation
    ) throws -> Data {
        guard header.count == headerBytes,
              uint32(header, 0) == magic,
              header[4] == version,
              header[5] == 3,
              header[7] == operation.rawValue,
              uint64(header, 12) == requestID,
              let status = NotificationControlStatusCode(rawValue: header[6]) else {
            throw NotificationControlError.invalidFrame
        }
        let length = Int(uint32(header, 8))
        guard length <= maxResponsePayload, tail.count == length + tagBytes else {
            throw NotificationControlError.invalidFrame
        }
        let payload = Data(tail.prefix(length))
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: nonce + header + payload,
            using: SymmetricKey(data: key)
        ))
        guard expected == Data(tail.suffix(tagBytes)) else {
            throw NotificationControlError.invalidFrame
        }
        guard status == .ok else { throw NotificationControlError.response(status) }
        return payload
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

private actor NotificationControlClient {
    private let key: Data
    private let host = NWEndpoint.Host("192.168.225.1")
    private let port = NWEndpoint.Port(rawValue: 45753)!

    init(pairingKey: Data) throws {
        guard pairingKey.count == NotificationControlProtocol.tagBytes else {
            throw NotificationControlError.pairingRequired
        }
        key = pairingKey
    }

    func status() async throws -> ModuleNotificationStatus {
        let payload = try await perform(.status, payload: Data())
        let result = try JSONDecoder().decode(ModuleNotificationStatus.self, from: payload)
        guard result.version == 1 else { throw NotificationControlError.invalidPayload }
        return result
    }

    func save(_ settings: ModuleNotificationSettings) async throws {
        _ = try await perform(.settings, payload: try JSONEncoder().encode(settings))
    }

    func importWebPush(_ data: Data) async throws {
        guard data.count <= NotificationControlProtocol.maxPayload else {
            throw NotificationControlError.invalidPayload
        }
        _ = try await perform(.webPush, payload: data)
    }

    func importCertificate(_ data: Data) async throws {
        guard data.count <= NotificationControlProtocol.maxPayload else {
            throw NotificationControlError.invalidPayload
        }
        _ = try await perform(.certificate, payload: data)
    }

    func removeCertificate() async throws {
        _ = try await perform(.certificate, payload: Data())
    }

    func testBark() async throws { _ = try await perform(.testBark, payload: Data()) }
    func testWebPush() async throws { _ = try await perform(.testWebPush, payload: Data()) }

    private func perform(_ operation: NotificationControlOperation, payload: Data) async throws -> Data {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wiredEthernet
        let connection = NWConnection(host: host, port: port, using: parameters)
        defer { connection.cancel() }
        try await withTimeout(.seconds(12), cancel: { connection.cancel() }) {
            try await connection.notificationStart()
        }
        let hello = try await withTimeout(.seconds(5), cancel: { connection.cancel() }) {
            try await connection.notificationReceiveExactly(NotificationControlProtocol.helloBytes)
        }
        let nonce = try NotificationControlProtocol.decodeHello(hello)
        var requestID: UInt64 = 0
        while requestID == 0 { requestID = UInt64.random(in: 1...UInt64.max) }
        let request = try NotificationControlProtocol.request(
            key: key, nonce: nonce, operation: operation, requestID: requestID, payload: payload
        )
        try await withTimeout(.seconds(8), cancel: { connection.cancel() }) {
            try await connection.notificationSend(request)
        }
        let header = try await withTimeout(.seconds(12), cancel: { connection.cancel() }) {
            try await connection.notificationReceiveExactly(NotificationControlProtocol.headerBytes)
        }
        let length = Int(NotificationControlProtocol.uint32(header, 8))
        guard length <= NotificationControlProtocol.maxResponsePayload else {
            throw NotificationControlError.invalidFrame
        }
        let tail = try await withTimeout(.seconds(5), cancel: { connection.cancel() }) {
            try await connection.notificationReceiveExactly(length + NotificationControlProtocol.tagBytes)
        }
        return try NotificationControlProtocol.response(
            key: key, nonce: nonce, header: header, tail: tail,
            requestID: requestID, operation: operation
        )
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        cancel: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: duration)
                    cancel()
                    throw NotificationControlError.timeout
                }
                guard let result = try await group.next() else { throw NotificationControlError.timeout }
                group.cancelAll()
                return result
            }
        } onCancel: { cancel() }
    }
}

@MainActor
private final class NotificationControlModel: ObservableObject {
    @Published var barkURL = ""
    @Published var barkCallSound = true
    @Published var showCallNumber = false
    @Published var showSMSBody = false
    @Published private(set) var status: ModuleNotificationStatus?
    @Published private(set) var stateText = "尚未读取模块提醒配置"
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false

    func refresh(pairingKey: Data?) { run(pairingKey: pairingKey, progress: "正在读取模块提醒配置…") { client in
        let status = try await client.status()
        await MainActor.run {
            self.status = status
            self.barkCallSound = status.barkCallSound
            self.showCallNumber = status.showCallNumber
            self.showSMSBody = status.showSMSBody
            self.stateText = "已连接模块提醒服务"
            self.lastError = nil
        }
    } }

    func connectAndTestBark(pairingKey: Data?) {
        let replacement = barkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: replacement),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            lastError = NotificationControlError.invalidBarkURL.localizedDescription
            stateText = lastError ?? "Bark 地址无效"
            return
        }
        let settings = ModuleNotificationSettings(
            barkURL: replacement,
            clearBark: false,
            barkCallSound: barkCallSound,
            showCallNumber: showCallNumber,
            showSMSBody: showSMSBody
        )
        run(pairingKey: pairingKey, progress: "正在连接 Bark 并发送测试…") { client in
            try await client.save(settings)
            await MainActor.run { self.barkURL = "" }
            do {
                try await client.testBark()
                await self.finishAndRefresh(client: client, message: "测试提醒已发送，请查看 iPhone 通知")
            } catch {
                let message = error.localizedDescription
                await self.finishAndRefresh(client: client, message: "Bark 已保存，但测试提醒发送失败")
                await MainActor.run { self.lastError = message }
            }
        }
    }

    func setBarkCallSound(_ enabled: Bool, pairingKey: Data?) {
        let previous = barkCallSound
        barkCallSound = enabled
        savePreferences(pairingKey: pairingKey) { self.barkCallSound = previous }
    }

    func setShowCallNumber(_ enabled: Bool, pairingKey: Data?) {
        let previous = showCallNumber
        showCallNumber = enabled
        savePreferences(pairingKey: pairingKey) { self.showCallNumber = previous }
    }

    func setShowSMSBody(_ enabled: Bool, pairingKey: Data?) {
        let previous = showSMSBody
        showSMSBody = enabled
        savePreferences(pairingKey: pairingKey) { self.showSMSBody = previous }
    }

    func disableBark(pairingKey: Data?) {
        let settings = ModuleNotificationSettings(
            barkURL: nil, clearBark: true, barkCallSound: barkCallSound,
            showCallNumber: showCallNumber, showSMSBody: showSMSBody
        )
        run(pairingKey: pairingKey, progress: "正在停用 Bark…") { client in
            try await client.save(settings)
            await MainActor.run { self.barkURL = "" }
            await self.finishAndRefresh(client: client, message: "Bark 已停用")
        }
    }

    func testBark(pairingKey: Data?) { run(pairingKey: pairingKey, progress: "正在从模块发送 Bark 测试…") { client in
        try await client.testBark()
        await MainActor.run { self.stateText = "Bark 已接受测试，请查看通知" }
    } }

    func testWebPush(pairingKey: Data?) { run(pairingKey: pairingKey, progress: "正在从模块发送 Web Push 测试…") { client in
        try await client.testWebPush()
        await MainActor.run {
            self.stateText = "网页提醒测试已发送，请查看通知"
            self.lastError = nil
        }
    } }

    func testPreferredService(pairingKey: Data?) {
        if status?.barkConfigured == true {
            testBark(pairingKey: pairingKey)
        } else if status?.webPushConfigured == true {
            testWebPush(pairingKey: pairingKey)
        }
    }

    func importWebPush(_ result: Result<[URL], Error>, pairingKey: Data?) {
        importFile(result, pairingKey: pairingKey, progress: "正在导入 Web Push 订阅…") { client, data in
            try await client.importWebPush(data)
            await self.finishAndRefresh(client: client, message: "Web Push 订阅已保存到模块")
        }
    }

    func importCertificate(_ result: Result<[URL], Error>, pairingKey: Data?) {
        importFile(result, pairingKey: pairingKey, progress: "正在导入证书…") { client, data in
            try await client.importCertificate(data)
            await self.finishAndRefresh(client: client, message: "证书已保存并立即生效")
        }
    }

    func removeCertificate(pairingKey: Data?) { run(pairingKey: pairingKey, progress: "正在移除自定义证书…") { client in
        try await client.removeCertificate()
        await self.finishAndRefresh(client: client, message: "已恢复系统 CA")
    } }

    private func finishAndRefresh(client: NotificationControlClient, message: String) async {
        do {
            let latest = try await client.status()
            status = latest
            stateText = message
            lastError = nil
        } catch {
            stateText = message
        }
    }

    private func savePreferences(pairingKey: Data?, onFailure: @escaping () -> Void) {
        let settings = ModuleNotificationSettings(
            barkURL: nil,
            clearBark: false,
            barkCallSound: barkCallSound,
            showCallNumber: showCallNumber,
            showSMSBody: showSMSBody
        )
        run(pairingKey: pairingKey, progress: "正在保存更改…", onFailure: onFailure) { client in
            try await client.save(settings)
            await self.finishAndRefresh(client: client, message: "更改已保存到模块")
        }
    }

    private func run(
        pairingKey: Data?,
        progress: String,
        onFailure: @escaping () -> Void = {},
        operation: @escaping @Sendable (NotificationControlClient) async throws -> Void
    ) {
        guard !isBusy else { return }
        guard let pairingKey else {
            onFailure()
            lastError = NotificationControlError.pairingRequired.localizedDescription
            stateText = lastError ?? "需要模块配对"
            return
        }
        isBusy = true
        lastError = nil
        stateText = progress
        Task {
            defer { isBusy = false }
            do {
                let client = try NotificationControlClient(pairingKey: pairingKey)
                try await operation(client)
            } catch is CancellationError {
                return
            } catch {
                onFailure()
                lastError = error.localizedDescription
                stateText = error.localizedDescription
            }
        }
    }

    private func importFile(
        _ result: Result<[URL], Error>,
        pairingKey: Data?,
        progress: String,
        operation: @escaping @Sendable (NotificationControlClient, Data) async throws -> Void
    ) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= NotificationControlProtocol.maxPayload else {
                throw NotificationControlError.invalidPayload
            }
            run(pairingKey: pairingKey, progress: progress) { client in try await operation(client, data) }
        } catch {
            lastError = error.localizedDescription
            stateText = error.localizedDescription
        }
    }
}

struct ModuleNotificationSettingsView: View {
    let pairingKey: Data?
    var dismiss: (() -> Void)? = nil
    var openModuleSettings: (() -> Void)? = nil
    @StateObject private var model = NotificationControlModel()
    @State private var isShowingBarkSetup = false
    @State private var isImportingWebPush = false
    @State private var isImportingCertificate = false

    var body: some View {
        Group {
            if pairingKey == nil {
                ContentUnavailableView {
                    Label("先连接模块", systemImage: "cable.connector")
                } description: {
                    Text("连接模块并导入配对后，iPhone 才能把提醒设置直接保存到模块。")
                } actions: {
                    if let openModuleSettings {
                        Button("打开模块设置", action: openModuleSettings)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                notificationList
            }
        }
        .navigationTitle("模块提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let dismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: dismiss)
                }
            }
        }
        .task {
            if pairingKey != nil { model.refresh(pairingKey: pairingKey) }
        }
        .sheet(isPresented: $isShowingBarkSetup) {
            NavigationStack {
                BarkSetupView(model: model, pairingKey: pairingKey)
            }
        }
        .fileImporter(
            isPresented: $isImportingWebPush,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { model.importWebPush($0, pairingKey: pairingKey) }
        .fileImporter(
            isPresented: $isImportingCertificate,
            allowedContentTypes: certificateTypes,
            allowsMultipleSelection: false
        ) { model.importCertificate($0, pairingKey: pairingKey) }
    }

    private var notificationList: some View {
        List {
            Section {
                NotificationSummaryView(model: model)

                if hasReceivingService {
                    Button {
                        model.testPreferredService(pairingKey: pairingKey)
                    } label: {
                        Label("发送测试提醒", systemImage: "paperplane")
                    }
                    .disabled(model.isBusy)
                }

                if model.lastError != nil {
                    Button {
                        model.refresh(pairingKey: pairingKey)
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
            } footer: {
                HStack(spacing: 7) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.stateText)
                        .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                }
            }

            Section("接收提醒") {
                Button { isShowingBarkSetup = true } label: {
                    NotificationDestinationRow(
                        icon: "app.badge.fill",
                        color: .green,
                        title: "Bark",
                        detail: barkDetail,
                        state: model.status?.barkConfigured == true ? "已连接" : "设置"
                    )
                }
                .buttonStyle(.plain)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.showCallNumber },
                    set: { model.setShowCallNumber($0, pairingKey: pairingKey) }
                )) {
                    NotificationToggleLabel(
                        title: "显示来电号码",
                        detail: "关闭时只显示“有电话呼入”"
                    )
                }
                Toggle(isOn: Binding(
                    get: { model.showSMSBody },
                    set: { model.setShowSMSBody($0, pairingKey: pairingKey) }
                )) {
                    NotificationToggleLabel(
                        title: "显示短信内容",
                        detail: "关闭时只显示“收到新短信”"
                    )
                }
            } header: {
                Text("提醒里显示什么")
            } footer: {
                Text("更改会立即保存到模块。开启后，相应内容会交给你选择的提醒服务。")
            }
            .disabled(model.isBusy || model.status == nil)

            Section("更多方式") {
                NavigationLink {
                    WebPushSettingsView(
                        model: model,
                        pairingKey: pairingKey,
                        onImport: { isImportingWebPush = true }
                    )
                } label: {
                    NotificationDestinationRow(
                        icon: "safari.fill",
                        color: .blue,
                        title: "主屏幕网页提醒",
                        detail: "不安装 Bark App 也能接收",
                        state: model.status?.webPushConfigured == true ? "已连接" : nil,
                        showsChevron: false
                    )
                }

                NavigationLink {
                    CustomCertificateSettingsView(
                        model: model,
                        pairingKey: pairingKey,
                        onImport: { isImportingCertificate = true }
                    )
                } label: {
                    NotificationDestinationRow(
                        icon: "lock.shield.fill",
                        color: .orange,
                        title: "自建服务证书",
                        detail: "使用自己的推送服务器时设置",
                        state: model.status?.customCA == true ? "已安装" : nil,
                        showsChevron: false
                    )
                }
            }
        }
        .refreshable { model.refresh(pairingKey: pairingKey) }
    }

    private var hasReceivingService: Bool {
        model.status?.barkConfigured == true || model.status?.webPushConfigured == true
    }

    private var barkDetail: String {
        if let host = model.status?.barkHost, !host.isEmpty { return host }
        return "推荐，设置最简单"
    }

    private var certificateTypes: [UTType] {
        [UTType(filenameExtension: "pem"), UTType(filenameExtension: "cer"), UTType(filenameExtension: "crt")]
            .compactMap { $0 }
    }
}

private struct NotificationSummaryView: View {
    @ObservedObject var model: NotificationControlModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var hasService: Bool {
        model.status?.barkConfigured == true || model.status?.webPushConfigured == true
    }

    private var title: String {
        if model.status == nil { return model.lastError == nil ? "正在连接模块" : "暂时无法连接" }
        return hasService ? "模块提醒已开启" : "还没有接收方式"
    }

    private var detail: String {
        if model.status == nil { return model.lastError == nil ? "正在读取当前设置…" : "请检查模块连接后重试" }
        if model.status?.barkConfigured == true && model.status?.webPushConfigured == true {
            return "Bark 和网页提醒均已连接"
        }
        if model.status?.barkConfigured == true { return "通过 Bark 接收来电和短信" }
        if model.status?.webPushConfigured == true { return "通过主屏幕网页接收提醒" }
        return "建议先连接 Bark"
    }

    private var icon: String {
        if model.status == nil && model.lastError != nil { return "exclamationmark.triangle.fill" }
        return hasService ? "bell.badge.fill" : "bell.slash.fill"
    }

    private var color: Color {
        if model.status == nil && model.lastError != nil { return .orange }
        return hasService ? .green : .secondary
    }
}

private struct NotificationDestinationRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String
    let state: String?
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let state {
                Text(state).font(.subheadline).foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct NotificationToggleLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BarkSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NotificationControlModel
    let pairingKey: Data?
    @State private var showsAddress = false
    @State private var isConfirmingDisable = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "app.badge.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.status?.barkConfigured == true ? "Bark 已连接" : "连接 Bark")
                            .font(.headline)
                        Text(model.status?.barkHost ?? "适合大多数用户")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                LabeledContent("1", value: "在 Bark App 中复制推送地址")
                LabeledContent("2", value: "粘贴到下方并连接")
                LabeledContent("3", value: "收到测试通知即设置成功")
            } header: {
                Text("设置方法")
            }

            Section {
                HStack {
                    Group {
                        if showsAddress {
                            TextField("https://api.day.app/…", text: $model.barkURL)
                        } else {
                            SecureField("https://api.day.app/…", text: $model.barkURL)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                    Button(showsAddress ? "隐藏地址" : "显示地址", systemImage: showsAddress ? "eye.slash" : "eye") {
                        showsAddress.toggle()
                    }
                    .labelStyle(.iconOnly)
                }

                Button {
                    model.connectAndTestBark(pairingKey: pairingKey)
                } label: {
                    Label(
                        model.status?.barkConfigured == true ? "更换并测试" : "连接并测试",
                        systemImage: "paperplane.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.barkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Bark 推送地址")
            } footer: {
                Text("地址包含你的设备密钥。保存后 App 不会再次显示完整地址。")
            }

            if model.status?.barkConfigured == true {
                Section {
                    Toggle(isOn: Binding(
                        get: { model.barkCallSound },
                        set: { model.setBarkCallSound($0, pairingKey: pairingKey) }
                    )) {
                        NotificationToggleLabel(
                            title: "来电提醒持续响铃",
                            detail: "像电话一样持续响约 30 秒"
                        )
                    }
                    .disabled(model.isBusy)

                    Button("发送测试提醒") { model.testBark(pairingKey: pairingKey) }
                        .disabled(model.isBusy)
                }

                Section {
                    Button("停用 Bark", role: .destructive) { isConfirmingDisable = true }
                        .disabled(model.isBusy)
                }
            }

            Section {
                HStack(spacing: 7) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.stateText)
                        .font(.footnote)
                        .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle("Bark")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        .confirmationDialog("停用 Bark 后，模块将不再通过 Bark 发送提醒。", isPresented: $isConfirmingDisable) {
            Button("停用 Bark", role: .destructive) { model.disableBark(pairingKey: pairingKey) }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct WebPushSettingsView: View {
    @ObservedObject var model: NotificationControlModel
    let pairingKey: Data?
    let onImport: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("当前状态", value: model.status?.webPushConfigured == true ? "已连接" : "未连接")
                Text("把配对文件保存到“文件”App，再在这里导入。模块会直接向浏览器推送服务发送提醒。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("选择配对文件", systemImage: "doc.badge.plus", action: onImport)
                    .disabled(model.isBusy)
                if model.status?.webPushConfigured == true {
                    Button("发送测试提醒") { model.testWebPush(pairingKey: pairingKey) }
                        .disabled(model.isBusy)
                }
            }

            if let key = model.status?.webPushPublicKey, !key.isEmpty {
                Section {
                    DisclosureGroup("查看模块公钥") {
                        Text(key).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Text("公钥用于生成与此模块匹配的网页提醒配对文件。")
                }
            }

            Section {
                HStack(spacing: 7) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.stateText)
                        .font(.footnote)
                        .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle("主屏幕网页提醒")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CustomCertificateSettingsView: View {
    @ObservedObject var model: NotificationControlModel
    let pairingKey: Data?
    let onImport: () -> Void
    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            Section {
                LabeledContent("当前状态", value: model.status?.customCA == true ? "已安装" : "使用系统证书")
                Text("只有使用自签名证书的自建 Bark 或 Web Push 服务时才需要设置。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("选择证书文件", systemImage: "doc.badge.plus", action: onImport)
                    .disabled(model.isBusy)
                if model.status?.customCA == true {
                    Button("移除自建服务证书", role: .destructive) { isConfirmingRemoval = true }
                        .disabled(model.isBusy)
                }
            } footer: {
                Text("支持 PEM、CER 和 CRT 公共证书文件。")
            }

            if let hash = model.status?.customCAHash, !hash.isEmpty {
                Section {
                    DisclosureGroup("查看证书指纹") {
                        Text(hash).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }

            Section {
                HStack(spacing: 7) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.stateText)
                        .font(.footnote)
                        .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle("自建服务证书")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("移除后，自签名的推送服务可能无法连接。", isPresented: $isConfirmingRemoval) {
            Button("移除证书", role: .destructive) { model.removeCertificate(pairingKey: pairingKey) }
            Button("取消", role: .cancel) {}
        }
    }
}

private extension NWConnection {
    func notificationStart() async throws {
        let queue = DispatchQueue(label: "DJOneHub.NotificationControl")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = NotificationContinuationGate(continuation)
            stateUpdateHandler = { state in
                switch state {
                case .ready: _ = gate.resume(.success(()))
                case .failed(let error): _ = gate.resume(.failure(NotificationControlError.connectionFailed(error.localizedDescription)))
                case .cancelled: _ = gate.resume(.failure(CancellationError()))
                default: break
                }
            }
            start(queue: queue)
        }
    }

    func notificationSend(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func notificationReceiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: NotificationControlError.connectionClosed) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            guard !chunk.isEmpty else { throw NotificationControlError.connectionClosed }
            result.append(chunk)
        }
        return result
    }
}

private final class NotificationContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func resume(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard let continuation else { lock.unlock(); return false }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
