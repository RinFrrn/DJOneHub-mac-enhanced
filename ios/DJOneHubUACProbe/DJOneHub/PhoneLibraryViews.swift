import SwiftUI

struct RecentsView: View {
    @EnvironmentObject private var history: CallHistoryStore
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
                            Button {
                                if let number = entry.number { onDial(number) }
                            } label: {
                                CallHistoryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.number == nil)
                            .swipeActions {
                                Button("删除", role: .destructive) { history.remove(entry.id) }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("最近通话")
            .toolbar { ProductToolbar(onSettings: onSettings) }
        }
    }
}

private struct CallHistoryRow: View {
    let entry: CallHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.direction == .outgoing
                  ? "phone.arrow.up.right" : "phone.arrow.down.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(entry.outcome == .missed ? .red : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.number ?? "未知号码")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(entry.outcome == .missed ? .red : .primary)
                Text(outcomeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.startedAt, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if entry.duration >= 1 {
                    Text(phoneDurationText(entry.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
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
            .toolbar { ProductToolbar(onSettings: onSettings) }
        }
    }

    private var contactList: some View {
        List(filteredPhones) { phone in
            Button { onDial(phone.number) } label: {
                HStack(spacing: 12) {
                    Text(initials(phone.contactName))
                        .font(.headline)
                        .frame(width: 42, height: 42)
                        .foregroundStyle(.white)
                        .background(Color.accentColor.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(phone.contactName).font(.body.weight(.semibold))
                        Text("\(phone.label)  \(phone.number)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "phone.fill").foregroundStyle(.green)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "姓名或号码")
    }

    private var filteredPhones: [ContactPhone] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts.phones }
        return contacts.phones.filter {
            $0.contactName.localizedCaseInsensitiveContains(query) || $0.number.contains(query)
        }
    }

    private func initials(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }
}

struct MessagesView: View {
    let onSettings: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("模块短信尚未启用", systemImage: "message.badge")
            } description: {
                Text("当前认证网关只支持电话控制和 PCM。短信需要先在 QDC507 上增加受限的收取、发送和状态协议。")
            }
            .navigationTitle("信息")
            .toolbar { ProductToolbar(onSettings: onSettings) }
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
