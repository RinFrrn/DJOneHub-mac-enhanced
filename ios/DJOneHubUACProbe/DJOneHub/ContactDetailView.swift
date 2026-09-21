import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject private var history: CallHistoryStore
    @EnvironmentObject private var contacts: ContactsModel
    @StateObject private var recordingPlayer = CallRecordingPlayer()
    @State private var recordings: [String: CallRecordingInfo] = [:]
    @State private var expandedEntryID: UUID?

    let number: String
    let onDial: (String) -> Void

    private var contact: ContactPhone? {
        contacts.matchedContact(for: number)
    }

    private var displayName: String {
        contact?.contactName ?? number
    }

    private var displayNumber: String {
        contact?.number ?? number
    }

    private var contactNumbers: [ContactPhone] {
        contact.map { contacts.numbers(for: $0) } ?? []
    }

    private var callEntries: [CallHistoryEntry] {
        return history.entries.filter {
            guard let entryNumber = $0.number else { return false }
            return ([number] + contactNumbers.map(\.number)).contains {
                ContactsModel.phoneNumbersMatch(entryNumber, $0)
            }
        }
    }

    private var groupedEntries: [(String, [CallHistoryEntry])] {
        let calendar = Calendar.current
        let now = Date()
        var today: [CallHistoryEntry] = []
        var yesterday: [CallHistoryEntry] = []
        var thisWeek: [CallHistoryEntry] = []
        var earlier: [CallHistoryEntry] = []

        for entry in callEntries {
            if calendar.isDateInToday(entry.startedAt) {
                today.append(entry)
            } else if calendar.isDateInYesterday(entry.startedAt) {
                yesterday.append(entry)
            } else if calendar.isDate(entry.startedAt, equalTo: now, toGranularity: .weekOfYear) {
                thisWeek.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var result: [(String, [CallHistoryEntry])] = []
        if !today.isEmpty { result.append(("今天", today)) }
        if !yesterday.isEmpty { result.append(("昨天", yesterday)) }
        if !thisWeek.isEmpty { result.append(("本周", thisWeek)) }
        if !earlier.isEmpty { result.append(("更早", earlier)) }
        return result
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    ContactAvatarView(
                        imageData: contact?.imageData,
                        name: displayName,
                        size: 64,
                        font: .system(size: 26, weight: .semibold)
                    )

                    VStack(spacing: 3) {
                        Text(displayName)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        if contact != nil {
                            Text("\(contactNumbers.count) 个电话号码")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("陌生号码")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    HStack(spacing: 12) {
                        DetailActionButton(
                            title: "呼叫",
                            systemImage: "phone.fill",
                            color: .green
                        ) {
                            onDial(number)
                        }

                        DetailActionButton(
                            title: "复制",
                            systemImage: "doc.on.doc",
                            color: .accentColor
                        ) {
                            UIPasteboard.general.string = displayNumber
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if !contactNumbers.isEmpty {
                Section("电话号码") {
                    ForEach(contactNumbers) { phone in
                        Button { onDial(phone.number) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(phone.displayLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(phone.number)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "phone")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                        .accessibilityLabel("呼叫\(phone.displayLabel)，\(phone.number)")
                        .contextMenu {
                            Button("复制号码", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = phone.number
                            }
                        }
                    }
                }
            }

            if callEntries.isEmpty {
                Section("通话记录") {
                    Label("暂无通话记录", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groupedEntries, id: \.0) { section in
                    Section(header: Text(section.0)) {
                        ForEach(section.1) { entry in
                            CallHistoryDetailRow(
                                entry: entry,
                                phoneLabel: contactNumbers.first {
                                    ContactsModel.phoneNumbersMatch($0.number, entry.number ?? "")
                                }?.displayLabel,
                                recording: recording(for: entry),
                                isExpanded: expandedEntryID == entry.id,
                                player: recordingPlayer,
                                expandedID: $expandedEntryID
                            )
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(10)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { reloadRecordings() }
        .onChange(of: history.entries) { reloadRecordings() }
        .onChange(of: expandedEntryID) { recordingPlayer.stop() }
        .onDisappear { recordingPlayer.stop() }
    }

    private func recording(for entry: CallHistoryEntry) -> CallRecordingInfo? {
        guard let filename = entry.recordingFilename else { return nil }
        return recordings[filename]
    }

    private func reloadRecordings() {
        let items = CallRecordingController.recordingItems()
        recordings = Dictionary(uniqueKeysWithValues: items.map { ($0.filename, $0) })
    }
}

private struct InlineRecordingPlayer: View {
    let recording: CallRecordingInfo
    @ObservedObject var player: CallRecordingPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { player.toggle(recording) } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "暂停录音" : "播放录音")

                Slider(
                    value: Binding(
                        get: { min(elapsedTime, totalDuration) },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0 ... totalDuration
                )
                .disabled(!player.canSeek(recording))
                .accessibilityLabel("录音播放进度")
                .accessibilityValue(
                    "\(phoneDurationText(elapsedTime))，共 \(phoneDurationText(totalDuration))"
                )

                ShareLink(item: recording.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .frame(width: 34, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享录音")
            }

            HStack(spacing: 6) {
                Text("\(phoneDurationText(elapsedTime)) / \(phoneDurationText(totalDuration))")
                Spacer(minLength: 8)
                Text(fileSizeText)
                Text("·")
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let error = player.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var isPlaying: Bool {
        player.isPlaying(recording)
    }

    private var isLoaded: Bool {
        player.playingURL == recording.url
    }

    private var elapsedTime: TimeInterval {
        isLoaded ? player.currentTime : 0
    }

    private var totalDuration: TimeInterval {
        max(recording.duration, isLoaded ? player.duration : 0, 0.001)
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: recording.fileSize, countStyle: .file)
    }
}

private struct DetailActionButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(color)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct CallHistoryDetailRow: View {
    let entry: CallHistoryEntry
    let phoneLabel: String?
    let recording: CallRecordingInfo?
    let isExpanded: Bool
    @ObservedObject var player: CallRecordingPlayer
    @Binding var expandedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: directionIcon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(outcomeText)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(statusColor)
                        Spacer(minLength: 4)
                        if entry.duration >= 1 {
                            Text(phoneDurationText(entry.duration))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let number = entry.number {
                            Text([phoneLabel, number].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        Spacer(minLength: 4)
                        Text(dateText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                if recording != nil {
                    Button {
                        expandedID = isExpanded ? nil : entry.id
                    } label: {
                        Image(systemName: isExpanded ? "waveform.circle.fill" : "waveform.circle")
                            .font(.title3)
                            .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
                            .frame(width: 34, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起通话录音" : "展开通话录音")
                }
            }

            if isExpanded, let recording {
                InlineRecordingPlayer(recording: recording, player: player)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 11)
    }

    private var dateText: String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: entry.startedAt) == calendar.component(.year, from: Date())
        let style = Date.FormatStyle.dateTime
        return entry.startedAt.formatted(
            sameYear ? style.month().day().hour().minute() : style.year().month().day().hour().minute()
        )
    }

    private var directionIcon: String {
        switch entry.direction {
        case .outgoing: return "phone.arrow.up.right"
        case .incoming: return "phone.arrow.down.left"
        }
    }

    private var statusColor: Color {
        switch entry.outcome {
        case .missed, .rejected, .canceled, .failed: return .red
        case .completed, nil: return .secondary
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

#Preview {
    NavigationStack {
        ContactDetailView(number: "13800138000", onDial: { _ in })
            .environmentObject(CallHistoryStore())
            .environmentObject(ContactsModel())
    }
}
