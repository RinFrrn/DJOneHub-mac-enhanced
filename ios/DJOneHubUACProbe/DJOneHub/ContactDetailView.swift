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

    private var callEntries: [CallHistoryEntry] {
        return history.entries.filter {
            guard let entryNumber = $0.number else { return false }
            return ContactsModel.phoneNumbersMatch(entryNumber, number)
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
                VStack(spacing: 16) {
                    ContactAvatarView(
                        imageData: contact?.imageData,
                        name: displayName,
                        size: 88,
                        font: .system(size: 34, weight: .semibold)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)

                    VStack(spacing: 4) {
                        Text(displayName)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        if contact != nil {
                            Text(displayNumber)
                                .font(.body)
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

                    HStack(spacing: 24) {
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
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            if callEntries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "暂无通话记录",
                        systemImage: "clock",
                        description: Text("与该号码的通话会显示在这里。")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groupedEntries, id: \.0) { section in
                    Section(header: Text(section.0)) {
                        ForEach(section.1) { entry in
                            CallHistoryDetailRow(entry: entry)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(contact == nil ? "陌生号码" : displayName)
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct DetailActionButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.white)
                    .background(color.gradient, in: Circle())
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CallHistoryDetailRow: View {
    let entry: CallHistoryEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: directionIcon)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(outcomeText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(statusColor)
                Text(entry.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if entry.duration >= 1 {
                Text(phoneDurationText(entry.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
