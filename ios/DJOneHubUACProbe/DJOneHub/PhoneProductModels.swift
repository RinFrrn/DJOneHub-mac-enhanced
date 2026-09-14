import Contacts
import Foundation

enum PhoneProductPreferences {
    static let automaticCallRecording = "automaticCallRecordingEnabled"
}

enum CallHistoryDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}

enum CallHistoryOutcome: String, Codable, Sendable {
    case completed
    case missed
    case rejected
    case canceled
    case failed
}

struct CallHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let direction: CallHistoryDirection
    let number: String?
    let startedAt: Date
    var connectedAt: Date?
    var endedAt: Date?
    var outcome: CallHistoryOutcome?
    var recordingFilename: String?

    var duration: TimeInterval {
        guard let connectedAt, let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }
}

@MainActor
final class CallHistoryStore: ObservableObject {
    @Published private(set) var entries: [CallHistoryEntry] = []

    private let storageURL: URL?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        load()
    }

    @discardableResult
    func begin(direction: CallHistoryDirection, number: String?) -> UUID {
        let entry = CallHistoryEntry(
            id: UUID(),
            direction: direction,
            number: number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            startedAt: Date(),
            connectedAt: nil,
            endedAt: nil,
            outcome: nil,
            recordingFilename: nil
        )
        entries.insert(entry, at: 0)
        persist()
        return entry.id
    }

    func markConnected(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].connectedAt == nil else { return }
        entries[index].connectedAt = Date()
        persist()
    }

    func finish(_ id: UUID, outcome: CallHistoryOutcome) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].endedAt == nil else { return }
        entries[index].endedAt = Date()
        entries[index].outcome = outcome
        persist()
    }

    func attachRecording(filename: String, to id: UUID) {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].recordingFilename = filename
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where entries.indices.contains(index) {
            entries.remove(at: index)
        }
        persist()
    }

    private func load() {
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([CallHistoryEntry].self, from: data) else {
            return
        }
        entries = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    private func persist() {
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = storageURL
            try? mutableURL.setResourceValues(values)
        } catch {
            // History is a convenience cache. A storage failure must never
            // interfere with call control or media.
        }
    }

    private static func defaultStorageURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DJOneHub", isDirectory: true)
            .appendingPathComponent("call-history.json", isDirectory: false)
    }
}

struct ContactPhone: Identifiable, Equatable, Sendable {
    let id: String
    let contactID: String
    let contactName: String
    let label: String
    let number: String
    let imageData: Data?

    var displayLabel: String {
        switch label.lowercased() {
        case "mobile": return "手机"
        case "main": return "主要"
        case "work": return "工作"
        case "home": return "住宅"
        case "other": return "其他"
        default: return label
        }
    }
}

@MainActor
final class ContactsModel: ObservableObject {
    enum AccessState: Equatable {
        case notDetermined
        case loading
        case available
        case denied
        case restricted
        case failed(String)
    }

    @Published private(set) var state: AccessState = .notDetermined
    @Published private(set) var phones: [ContactPhone] = []

    private let store = CNContactStore()
    private var contactLoadTask: Task<Void, Never>?

    init() {
        updateAuthorizationState()
    }

    deinit {
        contactLoadTask?.cancel()
    }

    func loadIfAuthorized() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || Self.isLimited(status) else {
            contactLoadTask?.cancel()
            updateAuthorizationState()
            return
        }
        loadContacts()
    }

    func requestAccess() {
        state = .loading
        store.requestAccess(for: .contacts) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                } else if granted {
                    self.loadContacts()
                } else {
                    self.state = .denied
                }
            }
        }
    }

    private func updateAuthorizationState() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined:
            phones = []
            state = .notDetermined
        case .authorized:
            loadContacts()
        case .denied:
            phones = []
            state = .denied
        case .restricted:
            phones = []
            state = .restricted
        case .limited:
            loadContacts()
        @unknown default:
            phones = []
            state = .restricted
        }
    }

    private func loadContacts() {
        state = .loading
        contactLoadTask?.cancel()
        contactLoadTask = Task { [weak self] in
            let loader = Task.detached(priority: .userInitiated) {
                try Self.fetchContacts()
            }
            do {
                let result = try await loader.value
                guard !Task.isCancelled else { return }
                self?.phones = result
                self?.state = .available
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    var people: [ContactPhone] {
        var seen = Set<String>()
        return phones.filter { seen.insert($0.contactID).inserted }
    }

    func numbers(for contact: ContactPhone) -> [ContactPhone] {
        phones.filter { $0.contactID == contact.contactID }
    }

    func matchedContact(for number: String) -> ContactPhone? {
        let normalized = Self.normalizedNumber(number)
        guard !normalized.isEmpty else { return nil }
        if let exact = phones.first(where: { Self.normalizedNumber($0.number) == normalized }) {
            return exact
        }
        let matches = phones.filter { Self.phoneNumbersMatch($0.number, number) }
        // Shared or ambiguous numbers must not resolve to an arbitrary person.
        guard Set(matches.map(\.contactID)).count == 1 else { return nil }
        return matches.first
    }

    nonisolated static func phoneNumbersMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizedNumber(a)
        let nb = normalizedNumber(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb
    }

    nonisolated private static func fetchContacts() throws -> [ContactPhone] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        request.unifyResults = true
        var result: [ContactPhone] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let formatted = CNContactFormatter.string(from: contact, style: .fullName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = formatted?.nilIfEmpty ?? "未命名联系人"
            var seenNumbers = Set<String>()
            for (index, labeledValue) in contact.phoneNumbers.enumerated() {
                let number = dialableNumber(labeledValue.value.stringValue)
                guard !number.isEmpty, seenNumbers.insert(normalizedNumber(number)).inserted else { continue }
                let label = CNLabeledValue<NSString>.localizedString(
                    forLabel: labeledValue.label ?? CNLabelPhoneNumberMain
                )
                let imageData = contact.thumbnailImageData
                result.append(ContactPhone(
                    id: "\(contact.identifier):\(index)",
                    contactID: contact.identifier,
                    contactName: name,
                    label: label,
                    number: number,
                    imageData: imageData
                ))
            }
        }
        return result
    }

    nonisolated static func normalizedNumber(_ input: String) -> String {
        var value = dialableNumber(input)
        if value.hasPrefix("00") { value = "+" + value.dropFirst(2) }
        let digits = value.hasPrefix("+") ? String(value.dropFirst()) : value
        // Explicit lengths avoid truncating local numbers that happen to start with a country code.
        for (code, localLength) in [("86", 11), ("852", 8), ("853", 8)] {
            if digits.hasPrefix(code), digits.count == code.count + localLength {
                return String(digits.dropFirst(code.count))
            }
        }
        return value
    }

    nonisolated private static func dialableNumber(_ input: String) -> String {
        var result = ""
        for character in input {
            if character.isNumber || character == "*" || character == "#" {
                result.append(character)
            } else if character == "+", result.isEmpty {
                result.append(character)
            }
        }
        return result
    }

    private static func isLimited(_ status: CNAuthorizationStatus) -> Bool {
        if #available(iOS 18.0, *) {
            return status == .limited
        }
        return false
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
