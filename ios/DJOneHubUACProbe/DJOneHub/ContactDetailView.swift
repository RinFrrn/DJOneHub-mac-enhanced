import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject private var history: CallHistoryStore
    @EnvironmentObject private var contacts: ContactsModel

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
                VStack(spacing: 14) {
                    ContactAvatarView(
                        imageData: contact?.imageData,
                        name: displayName,
                        size: 72,
                        font: .system(size: 28, weight: .semibold)
                    )

                    VStack(spacing: 4) {
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
                .padding(.bottom, 8)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if !contactNumbers.isEmpty {
                Section("电话号码") {
                    ForEach(contactNumbers) { phone in
                        Button { onDial(phone.number) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
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
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                        .padding(.vertical, 12)
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
                                }?.displayLabel
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(20)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(color)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct CallHistoryDetailRow: View {
    let entry: CallHistoryEntry
    let phoneLabel: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: directionIcon)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
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
                if let number = entry.number {
                    Text([phoneLabel, number].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(entry.startedAt.formatted(
                    .dateTime.year().month().day().hour().minute()
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
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
