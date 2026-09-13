import SwiftUI
import AudioToolbox

struct LegacyModuleBottomBar: ViewModifier {
    let onSettings: () -> Void

    func body(content: Content) -> some View {
        // Older systems keep a navigation bottom bar above the tab bar.
        if #available(iOS 26.0, *) {
            content
        } else {
            content.toolbar {
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Spacer(minLength: 0)
                        ModuleAccessoryButton(onOpen: onSettings)
                    }
                }
            }
        }
    }
}

struct ModuleBottomAccessory: ViewModifier {
    let onOpen: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabViewBottomAccessory {
                ModuleAccessoryButton(onOpen: onOpen)
            }
        } else {
            content
        }
    }
}

private struct ModuleAccessoryButton: View {
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            ModuleAccessoryPill()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("模块状态")
        .accessibilityHint("打开模块状态、提醒和设置")
    }
}

private struct ModuleAccessoryPill: View {
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator
    @ObservedObject private var network = ConnectionLog.shared
    private var noDevice: Bool { lifecycle.phase.showNoDevice(network.noWiredInterface) }

    var body: some View {
        HStack(spacing: 12) {
            ModuleStatusIcon()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(noDevice ? "未检测到模块" : lifecycle.phase.moduleStatusTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("模块提醒 · 录音 · 设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ModuleStatusIcon: View {
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator
    @ObservedObject private var network = ConnectionLog.shared
    private var noDevice: Bool { lifecycle.phase.showNoDevice(network.noWiredInterface) }

    var body: some View {
        Group {
            if noDevice {
                Image(systemName: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            } else if lifecycle.phase == .connecting {
                Image(systemName: "arrow.2.circlepath")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
        }
        .font(.system(size: 22, weight: .semibold))
        .imageScale(.large)
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(noDevice ? "未检测到模块" : lifecycle.phase.moduleStatusTitle)
    }

    private var iconName: String {
        switch lifecycle.phase {
        case .ready: return "checkmark.circle.fill"
        case .active: return "phone.connection.fill"
        case .incoming: return "phone.arrow.down.left.fill"
        case .needsPairing, .needsControlPairing: return "person.crop.circle.badge.plus"
        case .recovering: return "exclamationmark.triangle.fill"
        default: return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch lifecycle.phase {
        case .ready, .active: return .green
        case .incoming: return .blue
        case .needsPairing, .needsControlPairing: return .secondary
        default: return .orange
        }
    }
}

extension ProductCallPhase {
    func showNoDevice(_ noWiredInterface: Bool?) -> Bool {
        switch self {
        case .placingCall, .dialing, .incoming, .answering, .active, .ending: return false
        default: return noWiredInterface == true
        }
    }
    var moduleStatusTitle: String {
        switch self {
        case .ready: return "模块已连接"
        case .needsPairing, .needsControlPairing: return "配对模块"
        case .recovering: return "模块连接中断"
        default: return title
        }
    }
}

struct KeypadView: View {
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator
    @StateObject private var tones = DialpadTonePlayer()
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
            VStack(spacing: 14) {
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

                DialpadGlassGroup {
                    VStack(spacing: 22) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(86), spacing: 26), count: 3),
                            spacing: 20
                        ) {
                            ForEach(keys, id: \.digit) { key in
                                NativeDialpadDigit(digit: key.digit, letters: key.letters) {
                                    append(key.digit)
                                }
                                .frame(width: 86, height: 86)
                            }
                        }

                        HStack(spacing: 26) {
                            Color.clear
                                .frame(width: 86, height: 80)

                            Button(action: onCall) {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 30, weight: .semibold))
                                    .frame(width: 56, height: 56)
                            }
                            .modifier(DialpadCallButtonStyle())
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .tint(.green)
                            .disabled(!canDial)
                            .frame(width: 86, height: 80)
                            .accessibilityLabel("拨打电话")

                            FastDeleteButton {
                                guard !voiceControl.dialNumber.isEmpty else { return false }
                                voiceControl.dialNumber.removeLast()
                                return !voiceControl.dialNumber.isEmpty
                            }
                            .frame(width: 86, height: 80)
                            .disabled(displayNumber.isEmpty)
                            .opacity(displayNumber.isEmpty ? 0 : 1)
                            .accessibilityHidden(displayNumber.isEmpty)
                            .accessibilityHint("轻点删除一位，按住连续删除")
                        }
                    }
                }

                Toggle(isOn: $automaticCallRecordingEnabled) {
                    Label(
                        "自动录音",
                        systemImage: automaticCallRecordingEnabled
                            ? "record.circle.fill"
                            : "record.circle"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 38)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(.primary.opacity(0.06), lineWidth: 0.5)
                }
                .accessibilityHint("开启后，每次电话接通时自动开始本地录音")
                Spacer(minLength: 4)
            }
            .navigationBarTitleDisplayMode(.inline)
            .modifier(LegacyModuleBottomBar(onSettings: onSettings))
            .task { await tones.prepare() }
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
        tones.play(digit)
    }
}

private struct DialpadGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else { content() }
    }
}

/// UIKit owns touch tracking and the glass highlight. SwiftUI only lays out
/// the control; it does not insert a gesture recognizer around each digit.
private struct NativeDialpadDigit: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let digit: String
    let letters: String
    let action: () -> Void

    func makeUIView(context: Context) -> NativeDialpadDigitControl {
        let button = NativeDialpadDigitControl(frame: .zero)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        configuration.titleAlignment = .center
        configuration.titlePadding = 0
        configuration.baseForegroundColor = .label
        let font = UIFont.systemFont(ofSize: 36)
        let descriptor = font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor
        configuration.attributedTitle = AttributedString(digit, attributes: AttributeContainer([
            .font: UIFont(descriptor: descriptor, size: 36)
        ]))
        if digit != "*", digit != "#" {
            configuration.attributedSubtitle = AttributedString(letters.isEmpty ? " " : letters, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold), .kern: 1.5
            ]))
        }
        button.configuration = configuration
        button.accessibilityLabel = digit
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .vertical)
        return button
    }

    func updateUIView(_ button: NativeDialpadDigitControl, context: Context) {
        button.action = action
        button.isEnabled = isEnabled
    }
}

private final class NativeDialpadDigitControl: UIButton {
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Keep commit-on-release and drag-out cancellation. UIButton handles
        // highlight on touch-down without a SwiftUI long-press recognizer.
        addTarget(self, action: #selector(activate), for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func activate() {
        guard isEnabled else { return }
        action?()
    }
}

private struct DialpadCallButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
private final class DialpadTonePlayer: ObservableObject {
    private var sounds: [String: SystemSoundID] = [:]
    private var isPreparing = false

    func prepare() async {
        guard sounds.isEmpty, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        // Register the bundled effects off the UI thread. No AVAudioSession
        // activation or route changes: these are UI sounds, not call audio.
        sounds = await Task.detached(priority: .userInitiated) {
            var registered: [String: SystemSoundID] = [:]
            for (digit, name) in [("0", "0"), ("1", "1"), ("2", "2"), ("3", "3"),
                                  ("4", "4"), ("5", "5"), ("6", "6"), ("7", "7"),
                                  ("8", "8"), ("9", "9"), ("*", "star"), ("#", "hash")] {
                guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "DialpadSounds") else { continue }
                var sound: SystemSoundID = 0
                guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { continue }
                var isUISound: UInt32 = 1
                AudioServicesSetProperty(kAudioServicesPropertyIsUISound,
                                         UInt32(MemoryLayout<SystemSoundID>.size), &sound,
                                         UInt32(MemoryLayout<UInt32>.size), &isUISound)
                registered[digit] = sound
            }
            return registered
        }.value
    }

    func play(_ digit: String) {
        guard let sound = sounds[digit] else { return }
        AudioServicesPlaySystemSound(sound)
    }

    deinit {
        for sound in sounds.values { AudioServicesDisposeSystemSoundID(sound) }
    }
}

private struct FastDeleteButton: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    let deleteCharacter: () -> Bool

    func makeUIView(context: Context) -> RepeatingDeleteControl {
        RepeatingDeleteControl(frame: .zero)
    }

    func updateUIView(_ button: RepeatingDeleteControl, context: Context) {
        button.deleteCharacter = deleteCharacter
        button.isEnabled = isEnabled && scenePhase == .active
    }

    static func dismantleUIView(_ button: RepeatingDeleteControl, coordinator: ()) {
        button.stopRepeating()
    }
}

private final class RepeatingDeleteControl: UIButton {
    var deleteCharacter: (() -> Bool)?
    private var repeatTask: Task<Void, Never>?

    override var isEnabled: Bool {
        didSet { if !isEnabled { stopRepeating() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setImage(UIImage(systemName: "delete.left.fill",
                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
        tintColor = .secondaryLabel
        accessibilityLabel = "删除"
        accessibilityHint = "轻点删除一位，按住连续删除"
        addTarget(self, action: #selector(beginRepeating), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(stopRepeating), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginRepeating() {
        stopRepeating()
        guard isEnabled, deleteCharacter?() == true else { return }
        repeatTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                while !Task.isCancelled {
                    guard self?.isEnabled == true, self?.deleteCharacter?() == true else { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch { /* Releasing the key cancels the delay immediately. */ }
        }
    }

    @objc func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeating() }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        _ = deleteCharacter?()
        return true
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
