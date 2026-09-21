import SwiftUI

struct RecentsView: View {
    @EnvironmentObject private var history: CallHistoryStore
    @EnvironmentObject private var contacts: ContactsModel
    @State private var recordingIndex: [String: CallRecordingInfo] = [:]
    let onDial: (String) -> Void
    let onSettings: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    ContentUnavailableView(
                        "暂无通话记录",
                        systemImage: "clock",
                        description: Text("通过 DJOneHub 拨打或接听的电话会显示在这里。")
                    )
                } else {
                    List {
                        ForEach(history.entries) { entry in
                            NavigationLink {
                                if let number = entry.number {
                                    ContactDetailView(number: number, onDial: onDial)
                                }
                            } label: {
                                CallHistoryRow(
                                    entry: entry,
                                    contact: matchedContact(for: entry),
                                    hasRecording: recording(for: entry) != nil
                                )
                            }
                            .disabled(entry.number == nil)
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            .swipeActions {
                                Button("删除", role: .destructive) { history.remove(entry.id) }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("最近通话")
            .modifier(LegacyModuleBottomBar(onSettings: onSettings))
            .task { reloadRecordings() }
            .onChange(of: history.entries) { reloadRecordings() }
        }
    }

    private func matchedContact(for entry: CallHistoryEntry) -> ContactPhone? {
        guard let number = entry.number else { return nil }
        return contacts.matchedContact(for: number)
    }

    private func recording(for entry: CallHistoryEntry) -> CallRecordingInfo? {
        guard let filename = entry.recordingFilename else { return nil }
        return recordingIndex[filename]
    }

    private func reloadRecordings() {
        let items = CallRecordingController.recordingItems()
        recordingIndex = Dictionary(uniqueKeysWithValues: items.map { ($0.filename, $0) })
    }
}

private struct CallHistoryRow: View {
    let entry: CallHistoryEntry
    let contact: ContactPhone?
    let hasRecording: Bool

    private var displayName: String {
        contact?.contactName ?? entry.number ?? "未知号码"
    }

    private var displayNumber: String? {
        guard contact != nil else { return nil }
        return entry.number
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 12) {
                ContactAvatarView(
                    imageData: contact?.imageData,
                    name: displayName,
                    size: 38
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(isUnsuccessful ? .red : .primary)
                    if let displayNumber {
                        Text(displayNumber)
                            .font(.subheadline)
                            .foregroundStyle(isUnsuccessful ? .red.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    } else {
                        Text(outcomeText)
                            .font(.subheadline)
                            .foregroundStyle(isUnsuccessful ? .red : .secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    if hasRecording {
                        Image(systemName: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                            .accessibilityLabel("有通话录音")
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(callRelativeTime(entry.startedAt, relativeTo: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if entry.duration >= 1 {
                            Text(phoneDurationText(entry.duration))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
    }

    private var isUnsuccessful: Bool {
        switch entry.outcome {
        case .missed, .rejected, .canceled, .failed: return true
        case .completed, nil: return false
        }
    }

    private var outcomeText: String {
        switch entry.outcome {
        case .completed: return entry.direction == .outgoing ? "已拨电话" : "已接电话"
        case .missed: return "未接来电"
        case .rejected: return "已拒接"
        case .canceled: return "已取消"
        case .failed: return "呼叫失败"
        case nil: return "进行中"
        }
    }
}

private func callRelativeTime(_ date: Date, relativeTo now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    if elapsed < 60 { return "刚刚" }
    if Calendar.current.isDateInToday(date) {
        if elapsed < 3_600 { return "\(max(1, Int(elapsed / 60)))分钟前" }
        return "\(max(1, Int(elapsed / 3_600)))小时前"
    }
    if Calendar.current.isDateInYesterday(date) { return "昨天" }
    if Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now) {
        return date.formatted(.dateTime.month().day())
    }
    return date.formatted(.dateTime.year().month().day())
}

struct ContactsView: View {
    @EnvironmentObject private var contacts: ContactsModel
    @State private var searchText = ""

    let onDial: (String) -> Void
    let onSettings: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch contacts.state {
                case .notDetermined:
                    ContentUnavailableView {
                        Label("使用通讯录", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("选择号码后会填入 DJOneHub 拨号键盘，通讯录不会上传。")
                    } actions: {
                        Button("允许访问通讯录") { contacts.requestAccess() }
                            .buttonStyle(.borderedProminent)
                    }
                case .loading:
                    ProgressView("正在读取通讯录…")
                case .denied, .restricted:
                    ContentUnavailableView(
                        "无法访问通讯录",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("请在系统设置中允许 DJOneHub 访问通讯录。")
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "通讯录读取失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .available:
                    contactList
                }
            }
            .navigationTitle("通讯录")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(LegacyModuleBottomBar(onSettings: onSettings))
        }
    }

    private var contactList: some View {
        List(filteredPhones) { phone in
            NavigationLink {
                ContactDetailView(number: phone.number, onDial: onDial)
            } label: {
                HStack(spacing: 12) {
                    ContactAvatarView(
                        imageData: phone.imageData,
                        name: phone.contactName,
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phone.contactName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text("\(phone.number)" + (contacts.numbers(for: phone).count > 1 ? " · \(contacts.numbers(for: phone).count) 个号码" : ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 10)
            }
            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "姓名或号码")
    }

    private var filteredPhones: [ContactPhone] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts.people }
        return contacts.people.filter { person in
            person.contactName.localizedCaseInsensitiveContains(query) ||
            contacts.numbers(for: person).contains {
                $0.number.contains(ContactsModel.normalizedNumber(query)) &&
                !ContactsModel.normalizedNumber(query).isEmpty
            }
        }
    }
}

struct MessagesView: View {
    @ObservedObject var sms: SMSControlModel
    let onRefresh: () -> Void
    let onSettings: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if sms.messages.isEmpty {
                    ContentUnavailableView {
                        Label(
                            sms.isInitialLoading ? "正在读取短信" : "暂无短信",
                            systemImage: sms.isInitialLoading ? "arrow.triangle.2.circlepath" : "message"
                        )
                    } description: {
                        Text(sms.stateText)
                    }
                } else {
                    List(sms.messages) { message in
                        NavigationLink {
                            ModuleSMSDetailView(message: message)
                                .onAppear { sms.markRead(message) }
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                    .opacity(sms.isUnread(message) ? 1 : 0)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(message.title)
                                            .font(.body.weight(sms.isUnread(message) ? .semibold : .regular))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(message.storageTitle)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(message.preview)
                                        .font(.subheadline)
                                        .foregroundStyle(sms.isUnread(message) ? .primary : .secondary)
                                        .lineLimit(2)
                                    if let incomplete = message.incompleteText {
                                        Text(incomplete).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                            .accessibilityValue(sms.isUnread(message) ? "未读" : "已读")
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { onRefresh() }
                }
            }
            .navigationTitle("信息")
            .modifier(LegacyModuleBottomBar(onSettings: onSettings))
            .safeAreaInset(edge: .bottom) {
                if !sms.messages.isEmpty {
                    Text(sms.stateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct ModuleSMSDetailView: View {
    let message: ModuleSMSDisplayMessage

    var body: some View {
        List {
            Section("内容") {
                LabeledContent("发件人", value: message.title)
                if let incomplete = message.incompleteText {
                    Text(incomplete).font(.footnote).foregroundStyle(.secondary)
                }
                Text(message.preview)
                    .textSelection(.enabled)
            }
            ForEach(message.parts) { part in
                Section("模块存储 · \(part.storage.title) #\(part.index)") {
                    LabeledContent("标签", value: tagText(part.tag))
                    LabeledContent("格式", value: String(format: "0x%02X", part.format))
                    DisclosureGroup("原始 PDU") {
                        Text(part.rawHex)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("短信")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tagText(_ tag: UInt8) -> String {
        switch tag {
        case 0: return "已读"
        case 1: return "未读"
        case 2: return "已发送"
        case 3: return "未发送"
        default: return "未知"
        }
    }
}

func phoneDurationText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%02d:%02d", minutes, remainder)
}
