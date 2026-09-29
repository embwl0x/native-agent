import AppToolRuntime
import SwiftUI
import PersistenceCore

// Simple view, User 2026-09-23 (approved from a mockup): one floating glass
// sidebar — the agent, the agents it talks to, its helpers — beside the
// agent's ordinary chat. No settings pages; everything else is asked of the
// agent. Advanced is the full app, unchanged. The whole feature lives in the
// Simple*.swift files; the shared views carry one hook each.

/// Simple | Advanced | Agent: a small glass segmented control in the title strip,
/// clear of the traffic lights. A pill is right here — it IS a segmented
/// control (house rule 2).
struct ViewModeSwitch: View {
    @AppStorage(SimpleViewMode.key) private var raw = ""

    var body: some View {
        // The Mac's own segmented control (User 09-27: all controls native).
        Picker("View", selection: Binding(
            get: { SimpleViewMode.resolved(raw) },
            set: { raw = $0 }
        )) {
            ForEach(SimpleViewMode.choices, id: \.self) { mode in
                Text(mode.capitalized).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

extension View {
    /// The switch at the window's top right, and the first-launch default.
    func viewModeSwitch() -> some View {
        overlay {
            VStack {
                HStack { Spacer(); ViewModeSwitch() }
                Spacer()
            }
            .padding(.top, 3)
            .padding(.trailing, 10)
            .ignoresSafeArea(edges: .top)
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
