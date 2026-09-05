import Foundation

enum IncomingCallPushEventError: Error, Equatable {
    case invalidPayload
    case expired
}

struct IncomingCallPushEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case incoming
        case ended
    }

    static let version = 1
    static let maximumLifetime: TimeInterval = 5 * 60

    let kind: Kind
    let callUUID: UUID
    let moduleIdentifier: String
    let moduleCallID: UInt8
    let callerNumber: String?
    let expiresAt: Date

    init(dictionary: [AnyHashable: Any], now: Date = Date()) throws {
        guard Self.integer(dictionary["v"]) == Self.version,
              let rawKind = dictionary["event"] as? String,
              let kind = Kind(rawValue: rawKind),
              let rawUUID = dictionary["call_uuid"] as? String,
              let callUUID = UUID(uuidString: rawUUID),
              let rawModuleIdentifier = dictionary["module_id"] as? String,
              Self.isModuleIdentifier(rawModuleIdentifier),
              let rawCallID = Self.integer(dictionary["call_id"]),
              (1 ... 255).contains(rawCallID),
              let expiration = Self.number(dictionary["expires_at"]) else {
            throw IncomingCallPushEventError.invalidPayload
        }

        let expiresAt = Date(timeIntervalSince1970: expiration)
        guard expiresAt > now,
              expiresAt.timeIntervalSince(now) <= Self.maximumLifetime else {
            throw IncomingCallPushEventError.expired
        }

        let caller = (dictionary["caller"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard caller == nil || Self.isSafeCaller(caller!) else {
            throw IncomingCallPushEventError.invalidPayload
        }

        self.kind = kind
        self.callUUID = callUUID
        moduleIdentifier = rawModuleIdentifier.lowercased()
        moduleCallID = UInt8(rawCallID)
        callerNumber = caller?.isEmpty == false ? caller : nil
        self.expiresAt = expiresAt
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func isModuleIdentifier(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit }
    }

    private static func isSafeCaller(_ value: String) -> Bool {
        guard value.utf8.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy {
            !($0.value < 0x20 || (0x7F ... 0x9F).contains($0.value))
        }
    }
}
