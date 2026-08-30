import Foundation
import Security

enum PairingKeyStoreError: Error, LocalizedError {
    case invalidKeyLength
    case invalidModuleIdentifier
    case unexpectedData
    case securityStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength:
            return "pairing key 必须恰好为 32 字节"
        case .invalidModuleIdentifier:
            return "模块标识不能为空、包含控制字符或超过 128 字节"
        case .unexpectedData:
            return "Keychain 返回了无法识别的 pairing key"
        case .securityStatus(let status):
            return "Keychain 操作失败（OSStatus \(status)）"
        }
    }
}

/// Stores the module pairing key only after an authenticated production pairing ceremony.
/// This type never generates, logs, exports, or displays the key.
struct PairingKeyStore: Sendable {
    static let keyLength = VoiceControlProtocol.tagBytes

    private let service: String
    private let account: String

    init(
        moduleIdentifier: String,
        service: String = "io.github.rogerbush007.DJOneHubUACProbe.voice"
    ) throws {
        guard !moduleIdentifier.isEmpty,
              moduleIdentifier.utf8.count <= 128,
              moduleIdentifier.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PairingKeyStoreError.invalidModuleIdentifier
        }
        self.service = service
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

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
