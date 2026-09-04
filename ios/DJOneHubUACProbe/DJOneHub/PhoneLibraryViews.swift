import SwiftUI

struct RecentsView: View {
    @EnvironmentObject private var history: CallHistoryStore
    @State private var selectedRecording: CallRecordingInfo?
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
                            HStack(spacing: 8) {
                                Button {
                                    if let number = entry.number { onDial(number) }
                                } label: {
                                    CallHistoryRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                                .disabled(entry.number == nil)

                                if let recording = recording(for: entry) {
                                    Button {
                                        selectedRecording = recording
                                    } label: {
                                        Image(systemName: "waveform.circle.fill")
                                            .font(.title2)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("打开通话录音")
                                }
                            }
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
            .sheet(item: $selectedRecording) { recording in
                RecordingPlaybackView(recording: recording)
            }
        }
    }

    private func recording(for entry: CallHistoryEntry) -> CallRecordingInfo? {
        guard let filename = entry.recordingFilename else { return nil }
        return CallRecordingController.recording(named: filename)
    }
}

private struct RecordingPlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = CallRecordingPlayer()
    let recording: CallRecordingInfo

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(.tint)
                Text(recording.createdAt.formatted(date: .long, time: .shortened))
                    .font(.title3.weight(.semibold))
                Text("\(phoneDurationText(recording.duration)) · \(fileSizeText)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)

                VStack(spacing: 5) {
                    Slider(
                        value: Binding(
                            get: { min(player.currentTime, progressDuration) },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0 ... progressDuration
                    )
                    .disabled(!player.canSeek(recording))
                    .accessibilityLabel("录音播放进度")
                    .accessibilityValue(
                        "\(phoneDurationText(player.currentTime))，共 \(phoneDurationText(progressDuration))"
                    )

                    HStack {
                        Text(phoneDurationText(player.currentTime))
                        Spacer()
                        Text(phoneDurationText(progressDuration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)

                Button {
                    player.toggle(recording)
                } label: {
                    Label(
                        player.isPlaying(recording) ? "暂停" : "播放",
                        systemImage: player.isPlaying(recording) ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if let error = player.errorText {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                ShareLink(item: recording.url) {
                    Label("分享录音", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            .padding()
            .navigationTitle("通话录音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onDisappear { player.stop() }
        }
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: recording.fileSize, countStyle: .file)
    }

    private var progressDuration: TimeInterval {
        max(recording.duration, max(player.duration, 0.001))
    }
}

private struct CallHistoryRow: View {
    let entry: CallHistoryEntry

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 12) {
                Image(systemName: entry.direction == .outgoing
                      ? "phone.arrow.up.right" : "phone.arrow.down.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isUnsuccessful ? .red : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.number ?? "未知号码")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isUnsuccessful ? .red : .primary)
                    Text(outcomeText)
                        .font(.subheadline)
                        .foregroundStyle(isUnsuccessful ? .red : .secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(callRelativeTime(entry.startedAt, relativeTo: context.date))
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
