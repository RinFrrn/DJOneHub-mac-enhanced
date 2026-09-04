import SwiftUI

struct ProductToolbar: ToolbarContent {
    let onSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("设置", systemImage: "gearshape", action: onSettings)
        }
    }
}

struct ConnectionPill: View {
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(lifecycle.phase.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch lifecycle.phase {
        case .ready, .active: return .green
        case .incoming: return .blue
        case .needsPairing, .needsControlPairing: return .secondary
        default: return .orange
        }
    }
}

struct KeypadView: View {
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator
    @AppStorage(PhoneProductPreferences.automaticCallRecording)
    private var automaticCallRecordingEnabled = false

    let onCall: () -> Void
    let onSettings: () -> Void

    private let keys: [(digit: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", "")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                Text(displayNumber.isEmpty ? "输入号码" : displayNumber)
                    .font(.system(
                        size: displayNumber.count > 18 ? 28 : 36,
                        weight: .regular,
                        design: .rounded
                    ))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(displayNumber.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.horizontal, 34)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(78), spacing: 22), count: 3),
                    spacing: 14
                ) {
                    ForEach(keys, id: \.digit) { key in
                        Button { append(key.digit) } label: {
                            Group {
                                if key.digit == "*" || key.digit == "#" {
                                    Text(key.digit)
                                        .font(.system(size: 32, weight: .regular, design: .rounded))
                                } else {
                                    VStack(spacing: 0) {
                                        Text(key.digit)
                                            .font(.system(size: 32, weight: .regular, design: .rounded))
                                        Text(key.letters)
                                            .font(.system(size: 10, weight: .semibold))
                                            .tracking(1.5)
                                            .frame(height: 12)
                                    }
                                }
                            }
                            .frame(width: 76, height: 76)
                            .foregroundStyle(.primary)
                            .background(Color.secondary.opacity(0.14), in: Circle())
                            .contentShape(Circle())
                        }
                        .buttonStyle(PhoneCircleButtonStyle())
                        .accessibilityLabel(key.digit)
                    }
                }

                HStack(spacing: 22) {
                    Color.clear
                        .frame(width: 78, height: 72)

                    Button(action: onCall) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .frame(width: 72, height: 72)
                            .foregroundStyle(.white)
                            .background(.green, in: Circle())
                    }
                    .buttonStyle(PhoneCircleButtonStyle())
                    .disabled(!canDial)
                    .opacity(canDial ? 1 : 0.35)
                    .frame(width: 78, height: 72)
                    .accessibilityLabel("拨打电话")

                    Button("删除", systemImage: "delete.left.fill") {
                        voiceControl.dialNumber.removeLast()
                    }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(width: 78, height: 72)
                    .disabled(displayNumber.isEmpty)
                    .opacity(displayNumber.isEmpty ? 0 : 1)
                    .accessibilityHidden(displayNumber.isEmpty)
                }

                Toggle("自动录音", isOn: $automaticCallRecordingEnabled)
                    .font(.subheadline.weight(.medium))
                    .fixedSize()
                    .accessibilityHint("开启后，每次电话接通时自动开始本地录音")
                Spacer(minLength: 4)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionPill()
                }
                ProductToolbar(onSettings: onSettings)
            }
        }
    }

    private var displayNumber: String {
        voiceControl.dialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canDial: Bool {
        !displayNumber.isEmpty && !voiceControl.isBusy && lifecycle.phase == .ready
    }

    private func append(_ digit: String) {
        guard voiceControl.dialNumber.utf8.count < VoiceControlProtocol.maxDialBytes else { return }
        voiceControl.dialNumber.append(digit)
    }
}

struct PhoneCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 1), value: configuration.isPressed)
    }
}
