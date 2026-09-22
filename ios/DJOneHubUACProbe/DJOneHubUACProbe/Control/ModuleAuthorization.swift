import Foundation
import CryptoKit
import Security

enum ModuleAuthorizationError: Error, LocalizedError {
    case invalidData, expiredInvitation, identityMismatch, noPendingEnrollment
    case backupRequired, unauthorized, pendingChange, deviceLimit, storageUnavailable
    case connectionFailed, timeout

    var errorDescription: String? {
        switch self {
        case .invalidData: "模块授权资料格式无效"
        case .expiredInvitation: "绑定码已过期，请使用恢复码或重新生成首次绑定资料"
        case .identityMismatch: "连接的模块与保存的身份不一致"
        case .noPendingEnrollment: "没有待完成的手机绑定"
        case .backupRequired: "请先保存恢复码，再确认启用新手机"
        case .unauthorized: "模块未授权此手机或此恢复码已失效"
        case .pendingChange: "模块正在处理另一项绑定，请稍后重试"
        case .deviceLimit: "模块已达到授权手机数量上限"
        case .storageUnavailable: "无法安全保存授权资料，请保留当前手机和恢复码后重试"
        case .connectionFailed: "无法连接模块授权服务，请检查模块连接及固件版本"
        case .timeout: "模块响应超时，已保存的绑定进度可继续重试"
        }
    }
}

struct ModuleIdentity: Codable, Equatable, Sendable {
    static let host = "192.168.225.1"
    static let port: UInt16 = 45754
    let moduleID: String
    let certificateSHA256: String

    func validate() throws {
        guard Self.isHex(moduleID, count: 32), Self.isHex(certificateSHA256, count: 64) else {
            throw ModuleAuthorizationError.invalidData
        }
    }

    func verifies(certificate: Data) -> Bool {
        let digest = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        return digest == certificateSHA256
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct ModuleInvitation: Codable, Sendable {
    let version: Int
    let purpose: String
    let moduleID: String
    let host: String
    let port: UInt16
    let certificateSHA256: String
    let secret: String
    let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case version, purpose, host, port, secret
        case moduleID = "module_id", certificateSHA256 = "certificate_sha256", expiresAt = "expires_at"
    }

    var identity: ModuleIdentity { ModuleIdentity(moduleID: moduleID, certificateSHA256: certificateSHA256) }

    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 4096 else { throw ModuleAuthorizationError.invalidData }
        let invitation: Self
        do { invitation = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ModuleAuthorizationError.invalidData }
        try invitation.validate(now: now)
        return invitation
    }

    func validate(now: Date = Date()) throws {
        try identity.validate()
        guard version == 1, host == ModuleIdentity.host, port == ModuleIdentity.port,
              AuthorizationSecret.isValid(secret) else { throw ModuleAuthorizationError.invalidData }
        switch purpose {
        case "module-bootstrap":
            guard let expiresAt, Double(expiresAt) > now.timeIntervalSince1970 else {
                throw ModuleAuthorizationError.expiredInvitation
            }
            guard Double(expiresAt) <= now.timeIntervalSince1970 + 20 * 60 else {
                throw ModuleAuthorizationError.invalidData
            }
        case "module-recovery":
            guard expiresAt == nil || expiresAt == 0 else { throw ModuleAuthorizationError.invalidData }
        default: throw ModuleAuthorizationError.invalidData
        }
    }

    func replacingRecoverySecret(_ secret: String) -> Self {
        Self(version: 1, purpose: "module-recovery", moduleID: moduleID, host: host, port: port,
             certificateSHA256: certificateSHA256, secret: secret, expiresAt: nil)
    }
}

enum AuthorizationSecret {
    static func generate() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ModuleAuthorizationError.storageUnavailable }
        return encode(bytes)
    }

    static func isValid(_ value: String) -> Bool {
        guard let bytes = decode(value) else { return false }
        return encode(bytes) == value
    }

    static func decode(_ value: String) -> Data? {
        guard value.utf8.count == 43,
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32 else { return nil }
        return bytes
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct ModuleVoiceSession: Codable, Sendable {
    let version: Int
    let scope: String
    let credential: String
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey { case version, scope, credential; case expiresAt = "expires_at" }

    // The QDC507 has no reliable battery-backed wall clock. The module still
    // enforces expiresAt against its own clock; iOS schedules renewal from the
    // authenticated receipt time instead of comparing unrelated Unix epochs.
    func localExpirationDate(receivedAt: Date = Date()) -> Date {
        receivedAt.addingTimeInterval(60 * 60)
    }
}

struct AuthorizedModuleDevice: Codable, Sendable {
    let id: String
    let name: String
    let createdAt: Int64
    enum CodingKeys: String, CodingKey { case id, name; case createdAt = "created_at" }
}

struct ModuleAuthorizationStatus: Codable, Sendable {
    let version: Int
    let moduleID: String
    let generation: UInt64
    let currentDeviceID: String
    let devices: [AuthorizedModuleDevice]
    enum CodingKeys: String, CodingKey {
        case version, generation, devices
        case moduleID = "module_id", currentDeviceID = "current_device_id"
    }
}

struct PreparedModuleAuthorization: Codable, Sendable {
    let moduleID: String
    let deviceID: String
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey { case moduleID = "module_id", deviceID = "device_id", expiresAt = "expires_at" }
}

struct PrepareModuleAuthorization: Encodable, Sendable {
    let kind: String
    let credential: String
    let name: String
    let newRecoverySecret: String?
    enum CodingKeys: String, CodingKey { case kind, credential, name; case newRecoverySecret = "new_recovery_secret" }
}

// A separate Keychain service prevents either format from being interpreted as
// a legacy voice key. A production enrollment never upgrades a STATUS import.
struct ModuleAuthorizationRecord: Codable, Sendable {
    struct Active: Codable, Sendable {
        let credential: String
        let deviceID: String
    }
    struct Pending: Codable, Sendable {
        let invitation: ModuleInvitation
        let credential: String
        let name: String
        let newRecoverySecret: String?
        var prepared: PreparedModuleAuthorization?
        var backupConfirmed: Bool
    }
    let version: Int
    let identity: ModuleIdentity
    var active: Active?
    var pending: Pending?

    func validate() throws {
        try identity.validate()
        guard version == 1, active != nil || pending != nil else { throw ModuleAuthorizationError.invalidData }
        if let active {
            guard AuthorizationSecret.isValid(active.credential), AuthorizationSecret.isValid(active.deviceID) else {
                throw ModuleAuthorizationError.invalidData
            }
        }
        if let pending {
            // Expired pending transactions remain recoverable locally; only the
            // module decides whether prepare/commit may still succeed.
            guard pending.invitation.identity == identity,
                  pending.invitation.version == 1,
                  pending.invitation.host == ModuleIdentity.host,
                  pending.invitation.port == ModuleIdentity.port,
                  ["module-bootstrap", "module-recovery"].contains(pending.invitation.purpose),
                  AuthorizationSecret.isValid(pending.invitation.secret),
                  AuthorizationSecret.isValid(pending.credential),
                  pending.credential != pending.invitation.secret,
                  !pending.name.isEmpty, pending.name.utf8.count <= 80,
                  pending.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw ModuleAuthorizationError.invalidData
            }
            if pending.invitation.purpose == "module-recovery" {
                guard let secret = pending.newRecoverySecret, AuthorizationSecret.isValid(secret),
                      secret != pending.credential, secret != pending.invitation.secret else { throw ModuleAuthorizationError.invalidData }
            } else if pending.newRecoverySecret != nil { throw ModuleAuthorizationError.invalidData }
            if let prepared = pending.prepared {
                guard prepared.moduleID == identity.moduleID, AuthorizationSecret.isValid(prepared.deviceID),
                      prepared.expiresAt > 0 else { throw ModuleAuthorizationError.invalidData }
            }
        }
    }
}

struct ModuleAuthorizationStore: Sendable {
    private let service = "io.github.rogerbush007.DJOneHub.module-authorization.v1"

    func load(moduleID: String) throws -> ModuleAuthorizationRecord? {
        var query = query(moduleID: moduleID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 16_384 else {
            throw ModuleAuthorizationError.storageUnavailable
        }
        let record = try JSONDecoder().decode(ModuleAuthorizationRecord.self, from: data)
        try record.validate()
        guard record.identity.moduleID == moduleID else { throw ModuleAuthorizationError.identityMismatch }
        return record
    }

    func moduleIDs() throws -> [String] {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ModuleAuthorizationError.storageUnavailable }
        let items = result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
        let identifiers = items.compactMap { $0[kSecAttrAccount as String] as? String }
        guard identifiers.count == Set(identifiers).count else { throw ModuleAuthorizationError.storageUnavailable }
        return identifiers.sorted()
    }

    func save(_ record: ModuleAuthorizationRecord) throws {
        try record.validate()
        let data = try JSONEncoder().encode(record)
        var item = query(moduleID: record.identity.moduleID)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem,
              SecItemUpdate(query(moduleID: record.identity.moduleID) as CFDictionary,
                            [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
            throw ModuleAuthorizationError.storageUnavailable
        }
    }

    // Local forgetting is intentionally distinct from remote revocation.
    func forgetLocal(moduleID: String) throws {
        let status = SecItemDelete(query(moduleID: moduleID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ModuleAuthorizationError.storageUnavailable }
    }

    private func query(moduleID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: moduleID, kSecAttrSynchronizable as String: false]
    }
}
