import SwiftUI
import PersistenceCore

// Simple view, User 2026-09-23 (approved from a mockup): one floating glass
// sidebar — the agent, the agents it talks to, its helpers — beside the
// agent's ordinary chat. No settings pages; everything else is asked of the
// agent. Advanced is the full app, unchanged. The whole feature lives in the
// Simple*.swift files; the shared views carry one hook each.

/// "simple", "advanced" or "agent", in `nativeagent.viewMode` (the agent can
/// switch it: `settings.view_mode` in QuietSelfAdminSettings). Agent is User's
/// window into hers (AgentScreenView.swift) and never the unset default.
enum SimpleViewMode {
    static let key = "nativeagent.viewMode"
    static let simple = "simple"
    static let advanced = "advanced"
    static let agent = "agent"
    static let choices = [simple, advanced, agent]

    /// With the key unset: Simple on a fresh install, Advanced where chats
    /// already exist, so nobody who knows the full app loses it on update.
    /// Read once per launch.
    static let unsetDefault: String = hasExistingChats(PersistenceCore.defaultDataRoot()) ? advanced : simple

    static func resolved(_ raw: String) -> String { choices.contains(raw) ? raw : unsetDefault }

    /// What the window shows now: Simple has no pages to send anyone to.
    static var isShowing: Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: NativeAgentShellPreference.classicShellKey)
            && resolved(defaults.string(forKey: key) ?? "") == simple
    }
    static let noPagesNote = "No pages in Simple view; raise request_interaction for setup."

    /// Write the first-launch answer down, so the chats a new install goes on
    /// to make never flip it to Advanced later.
    static func settle(_ defaults: UserDefaults = .standard) {
        if defaults.string(forKey: key) == nil { defaults.set(unsetDefault, forKey: key) }
    }

    private static func hasExistingChats(_ root: URL) -> Bool {
        let messages = root.appendingPathComponent("chat/messages", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: messages.path)) ?? []
        return names.contains { $0.hasSuffix(".jsonl") }
    }
}

/// Simple | Advanced | Agent: a small glass segmented control in the title strip,
/// clear of the traffic lights. A pill is right here — it IS a segmented
/// control (house rule 2).
struct ViewModeSwitch: View {
    @AppStorage(SimpleViewMode.key) private var raw = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let current = SimpleViewMode.resolved(raw)
        HStack(spacing: 2) {
            ForEach(SimpleViewMode.choices, id: \.self) { mode in
                let selected = current == mode
                Button { raw = mode } label: {
                    Text(mode.capitalized)
                        .font(ShellType.captionMedium)
                        .foregroundStyle(selected ? NativeAgentShell.text : NativeAgentShell.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background { if selected { Capsule().fill(NativeAgentShell.softFill) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .glassEffect(reduceTransparency ? .identity : .regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }
}

extension View {
    /// The switch at the window's top right, and the first-launch default.
    func viewModeSwitch(hidden: Bool) -> some View {
        overlay {
            if !hidden {
                VStack {
                    HStack { Spacer(); ViewModeSwitch() }
                    Spacer()
                }
                .padding(.top, 3)
                .padding(.trailing, 10)
                .ignoresSafeArea(edges: .top)
            }
        }
        .onAppear { SimpleViewMode.settle() }
    }
}

private let simpleTopFade: CGFloat = 24

extension View {
    /// A scroll view's pinned top chrome, in its top inset. Simple view's
    /// header has no backing (a sheet read as a band) and cannot be a
    /// `safeAreaBar` (it pinned the main thread), so the scrolled words are
    /// alpha-masked instead. The mask sits inside the inset: its frame is the
    /// scroll view's safe area, below the header and the title strip, so a
    /// line fades out over the last `simpleTopFade` points before the header
    /// and is gone under it. The header is outside the mask and keeps its
    /// hits. The mask reaches through the bottom inset so lines still pass
    /// under the composer. Static geometry. Advanced keeps the plain inset.
    @ViewBuilder
    func roomTopChrome<Chrome: View>(masked: Bool, @ViewBuilder _ chrome: () -> Chrome) -> some View {
        if masked {
            mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: simpleTopFade)
                    Color.black
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .safeAreaInset(edge: .top, spacing: 0, content: chrome)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: chrome)
        }
    }
}

/// Simple view reuses the Chat page whole, minus its conversation list.
private struct ChatHidesConversationListKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatHidesConversationList: Bool {
        get { self[ChatHidesConversationListKey.self] }
        set { self[ChatHidesConversationListKey.self] = newValue }
    }
}
