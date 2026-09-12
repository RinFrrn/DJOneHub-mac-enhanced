import Foundation
import CryptoKit
import Security

enum VoiceControlAccess: UInt8, Sendable {
    case statusOnly = 1
    case controlSession = 2
}

struct StoredPairingCredential: Sendable {
    let key: Data
    let access: VoiceControlAccess
    let createdAt: Date?
    let expiresAt: Date?

    init(
        key: Data,
        access: VoiceControlAccess,
        createdAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.key = key
        self.access = access
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

enum PairingKeyStoreError: Error, LocalizedError {
    case invalidKeyLength
    case invalidModuleIdentifier
    case unexpectedData
    case expired
    case invalidLifecycle
    case multiplePairings
    case securityStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength:
            return "pairing key 必须恰好为 32 字节"
        case .invalidModuleIdentifier:
            return "模块标识不能为空、包含控制字符或超过 128 字节"
        case .unexpectedData:
            return "Keychain 返回了无法识别的 pairing key"
        case .expired:
            return "本机保存的开发配对已经过期，请在 Mac 重新武装模块"
        case .invalidLifecycle:
            return "本机保存的开发配对生命周期无效"
        case .multiplePairings:
            return "已保存多个模块，请先选择要连接的模块"
        case .securityStatus(let status):
            return "Keychain 操作失败（OSStatus \(status)）"
        }
    }
}

/// Stores a module pairing key only after an authenticated pairing or validated development import.
/// This type never generates, logs, exports, or displays the key.
struct PairingKeyStore: Sendable {
    static let keyLength = VoiceControlProtocol.tagBytes
    static let defaultService = "io.github.rogerbush007.DJOneHubUACProbe.voice"

    private let service: String
    private let account: String
    let moduleIdentifier: String

    init(
        moduleIdentifier: String,
        service: String = Self.defaultService
    ) throws {
        guard !moduleIdentifier.isEmpty,
              moduleIdentifier.utf8.count <= 128,
              moduleIdentifier.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PairingKeyStoreError.invalidModuleIdentifier
        }
        self.service = service
        self.moduleIdentifier = moduleIdentifier
        self.account = "module:\(moduleIdentifier)"
    }

    private static let legacyEnvelopePrefix = Data([0x44, 0x4A, 0x50, 0x01])
    private static let lifecycleEnvelopePrefix = Data([0x44, 0x4A, 0x50, 0x02])
    private static let timestampBytes = 8

    func load(now: Date = Date()) throws -> StoredPairingCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw PairingKeyStoreError.unexpectedData }
            let credential = try Self.decodeCredential(data, now: now)
            if credential.createdAt == nil || credential.expiresAt == nil {
                let migrated = Self.credentialByAddingLifecycle(credential, now: now)
                try save(migrated)
                return migrated
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw PairingKeyStoreError.securityStatus(status)
        }
    }

    func save(_ credential: StoredPairingCredential) throws {
        guard credential.key.count == Self.keyLength else { throw PairingKeyStoreError.invalidKeyLength }
        let encoded = try Self.encodeCredential(credential)

        var item = baseQuery
        item[kSecValueData as String] = encoded
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else {
            if addStatus != errSecSuccess { throw PairingKeyStoreError.securityStatus(addStatus) }
            return
        }

        // Keep the existing accessibility policy on replacement. Some iOS releases
        // reject changing kSecAttrAccessible during an update even when the value
        // itself is otherwise valid.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [
            kSecValueData as String: encoded
        ] as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw PairingKeyStoreError.securityStatus(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingKeyStoreError.securityStatus(status)
        }
    }

    static func loadAll(
        service: String = defaultService,
        now: Date = Date()
    ) throws -> [(moduleIdentifier: String, credential: StoredPairingCredential)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw PairingKeyStoreError.securityStatus(status)
        }
        guard let items = result as? [[String: Any]] else {
            throw PairingKeyStoreError.unexpectedData
        }
        return try items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("module:") else {
                return nil
            }
            guard let data = item[kSecValueData as String] as? Data else {
                throw PairingKeyStoreError.unexpectedData
            }
            let identifier = String(account.dropFirst("module:".count))
            let credential = try decodeCredential(data, now: now)
            if credential.createdAt == nil || credential.expiresAt == nil {
                let migrated = credentialByAddingLifecycle(credential, now: now)
                try PairingKeyStore(moduleIdentifier: identifier, service: service).save(migrated)
                return (identifier, migrated)
            }
            return (identifier, credential)
        }.sorted { $0.moduleIdentifier < $1.moduleIdentifier }
    }

    static func deleteAll(exceptModuleIdentifier retainedIdentifier: String? = nil) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: defaultService,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            throw status == errSecSuccess
                ? PairingKeyStoreError.unexpectedData
                : PairingKeyStoreError.securityStatus(status)
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("module:") else { continue }
            let identifier = String(account.dropFirst("module:".count))
            if identifier != retainedIdentifier {
                try PairingKeyStore(moduleIdentifier: identifier).delete()
            }
        }
    }

    static func encodeCredential(_ credential: StoredPairingCredential) throws -> Data {
        guard credential.key.count == keyLength else { throw PairingKeyStoreError.invalidKeyLength }
        guard let createdAt = credential.createdAt,
              let expiresAt = credential.expiresAt,
              createdAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970 >= 0,
              expiresAt > createdAt else {
            throw PairingKeyStoreError.invalidLifecycle
        }
        var encoded = lifecycleEnvelopePrefix
        encoded.append(credential.access.rawValue)
        appendTimestamp(createdAt, to: &encoded)
        appendTimestamp(expiresAt, to: &encoded)
        encoded.append(credential.key)
        return encoded
    }

    static func decodeCredential(_ data: Data, now: Date = Date()) throws -> StoredPairingCredential {
        // Migrate the original STATUS-only Keychain value without granting it
        // the newly introduced mutating control capability.
        if data.count == keyLength {
            return StoredPairingCredential(key: data, access: .statusOnly)
        }
        if data.count == legacyEnvelopePrefix.count + 1 + keyLength,
           data.prefix(legacyEnvelopePrefix.count) == legacyEnvelopePrefix,
           let access = VoiceControlAccess(rawValue: data[legacyEnvelopePrefix.count]) {
            // Version 1 did not retain the bundle timestamps. Keep it usable so an
            // app update never forces the currently deployed module to be re-paired.
            return StoredPairingCredential(key: data.suffix(keyLength), access: access)
        }
        let accessOffset = lifecycleEnvelopePrefix.count
        let createdOffset = accessOffset + 1
        let expiresOffset = createdOffset + timestampBytes
        let keyOffset = expiresOffset + timestampBytes
        guard data.count == keyOffset + keyLength,
              data.prefix(lifecycleEnvelopePrefix.count) == lifecycleEnvelopePrefix,
              let access = VoiceControlAccess(rawValue: data[accessOffset]),
              let createdSeconds = decodeTimestamp(data, offset: createdOffset),
              let expiresSeconds = decodeTimestamp(data, offset: expiresOffset) else {
            throw PairingKeyStoreError.unexpectedData
        }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdSeconds))
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresSeconds))
        guard createdAt <= now.addingTimeInterval(DevelopmentPairingBundle.maximumClockSkew),
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= DevelopmentPairingBundle.maximumValidity else {
            throw PairingKeyStoreError.invalidLifecycle
        }
        guard expiresAt > now else { throw PairingKeyStoreError.expired }
        return StoredPairingCredential(key: data.suffix(keyLength), access: access,
                                       createdAt: createdAt, expiresAt: expiresAt)
    }

    private static func appendTimestamp(_ date: Date, to data: inout Data) {
        var value = UInt64(Int64(date.timeIntervalSince1970.rounded(.towardZero))).bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func decodeTimestamp(_ data: Data, offset: Int) -> Int64? {
        guard offset >= 0, data.count >= offset + timestampBytes else { return nil }
        let value = data[offset..<(offset + timestampBytes)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        let timestamp = Int64(bitPattern: value)
        return timestamp >= 0 ? timestamp : nil
    }

    private static func credentialByAddingLifecycle(
        _ credential: StoredPairingCredential,
        now: Date
    ) -> StoredPairingCredential {
        let createdAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return StoredPairingCredential(
            key: credential.key,
            access: credential.access,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(DevelopmentPairingBundle.maximumValidity)
        )
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

enum DevelopmentPairingBundleError: Error, LocalizedError, Equatable {
    case malformed
    case unsupportedVersion
    case wrongPurpose
    case invalidEndpoint
    case invalidKey
    case identifierMismatch
    case expired
    case createdInFuture
    case validityTooLong

    var errorDescription: String? {
        switch self {
        case .malformed: return "测试配对包格式无效"
        case .unsupportedVersion: return "测试配对包版本不受支持"
        case .wrongPurpose: return "该文件不是受支持的 DJOneHub 测试配对包"
        case .invalidEndpoint: return "测试配对包指向了非预期模块地址"
        case .invalidKey: return "测试配对包中的 key 无效"
        case .identifierMismatch: return "模块标识与 pairing key 指纹不匹配"
        case .expired: return "测试配对包已经过期，请重新武装模块"
        case .createdInFuture: return "测试配对包创建时间晚于本机时间"
        case .validityTooLong: return "测试配对包有效期异常"
        }
    }
}

struct DevelopmentPairingBundle: Decodable, Sendable {
    static let statusPurpose = "development-status-only"
    static let controlSessionPurpose = "development-control-session"
    static let host = "192.168.225.1"
    static let port: UInt16 = 45_750
    static let maximumValidity: TimeInterval = 30 * 24 * 60 * 60
    static let maximumClockSkew: TimeInterval = 5 * 60

    let version: Int
    let purpose: String
    let moduleIdentifier: String
    let pairingKeyBase64: String
    let host: String
    let port: UInt16
    let createdAt: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case version, purpose, host, port
        case moduleIdentifier = "module_identifier"
        case pairingKeyBase64 = "pairing_key_base64"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    struct Validated: Sendable {
        let moduleIdentifier: String
        let pairingKey: Data
        let access: VoiceControlAccess
        let createdAt: Date
        let expiresAt: Date
    }

    static func decodeAndValidate(_ data: Data, now: Date = Date()) throws -> Validated {
        let bundle: DevelopmentPairingBundle
        do {
            bundle = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw DevelopmentPairingBundleError.malformed
        }
        guard bundle.version == 1 else { throw DevelopmentPairingBundleError.unsupportedVersion }
        let access: VoiceControlAccess
        switch bundle.purpose {
        case statusPurpose:
            access = .statusOnly
        case controlSessionPurpose:
            access = .controlSession
        default:
            throw DevelopmentPairingBundleError.wrongPurpose
        }
        guard bundle.host == host, bundle.port == port else {
            throw DevelopmentPairingBundleError.invalidEndpoint
        }
        guard let key = Data(base64Encoded: bundle.pairingKeyBase64),
              key.count == PairingKeyStore.keyLength else {
            throw DevelopmentPairingBundleError.invalidKey
        }
        let expectedIdentifier = moduleIdentifier(for: key)
        guard bundle.moduleIdentifier == expectedIdentifier else {
            throw DevelopmentPairingBundleError.identifierMismatch
        }
        let formatter = ISO8601DateFormatter()
        guard let createdAt = formatter.date(from: bundle.createdAt),
              let expiresAt = formatter.date(from: bundle.expiresAt) else {
            throw DevelopmentPairingBundleError.malformed
        }
        guard expiresAt > now else { throw DevelopmentPairingBundleError.expired }
        guard createdAt <= now.addingTimeInterval(maximumClockSkew) else {
            throw DevelopmentPairingBundleError.createdInFuture
        }
        guard expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= maximumValidity else {
            throw DevelopmentPairingBundleError.validityTooLong
        }
        return Validated(moduleIdentifier: expectedIdentifier, pairingKey: key, access: access,
                         createdAt: createdAt, expiresAt: expiresAt)
    }

    static func moduleIdentifier(for key: Data) -> String {
        SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
