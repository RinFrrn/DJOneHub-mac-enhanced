import Foundation
import CryptoKit
import Security

enum PairingKeyStoreError: Error, LocalizedError {
    case invalidKeyLength
    case invalidModuleIdentifier
    case unexpectedData
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
        case .multiplePairings:
            return "已保存多个模块，请先选择要连接的模块"
        case .securityStatus(let status):
            return "Keychain 操作失败（OSStatus \(status)）"
        }
    }
}

/// Stores the module pairing key only after an authenticated production pairing ceremony.
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

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw PairingKeyStoreError.unexpectedData }
            guard data.count == Self.keyLength else { throw PairingKeyStoreError.invalidKeyLength }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw PairingKeyStoreError.securityStatus(status)
        }
    }

    func save(_ key: Data) throws {
        guard key.count == Self.keyLength else { throw PairingKeyStoreError.invalidKeyLength }

        var item = baseQuery
        item[kSecValueData as String] = key
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
            kSecValueData as String: key
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

    static func loadAll(service: String = defaultService) throws -> [(moduleIdentifier: String, key: Data)] {
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
            guard let key = item[kSecValueData as String] as? Data,
                  key.count == keyLength else {
                throw PairingKeyStoreError.unexpectedData
            }
            return (String(account.dropFirst("module:".count)), key)
        }.sorted { $0.moduleIdentifier < $1.moduleIdentifier }
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
        case .wrongPurpose: return "该文件不是 STATUS 测试配对包"
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
    static let purpose = "development-status-only"
    static let host = "192.168.225.1"
    static let port: UInt16 = 45_750
    static let maximumValidity: TimeInterval = 60 * 60
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
    }

    static func decodeAndValidate(_ data: Data, now: Date = Date()) throws -> Validated {
        let bundle: DevelopmentPairingBundle
        do {
            bundle = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw DevelopmentPairingBundleError.malformed
        }
        guard bundle.version == 1 else { throw DevelopmentPairingBundleError.unsupportedVersion }
        guard bundle.purpose == purpose else { throw DevelopmentPairingBundleError.wrongPurpose }
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
        return Validated(moduleIdentifier: expectedIdentifier, pairingKey: key)
    }

    static func moduleIdentifier(for key: Data) -> String {
        SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
