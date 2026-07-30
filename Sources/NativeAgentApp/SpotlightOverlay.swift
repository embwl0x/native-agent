// PATCH-2026-05-07: spotlight-overlay Global ⌘⇧J pops a Raycast-style chat
// overlay anywhere on macOS. Talks to the same in-process Swift runtime as the
// main window with a stable sessionId="spotlight" so memory carries across pops.
//
// Design notes:
//   - NSPanel (not NSWindow) with .nonactivatingPanel so it floats above the
//     active app without yanking focus from whatever the user was doing
//   - .borderless + .floating level so it sits over fullscreen apps
//   - Esc dismisses; ⌘⇧J toggles; submit calls Swift chat orchestration
//   - Last reply renders inline (single-shot), with a "Open full chat"
//     escape hatch that brings the main window forward
//   - Recent prompts persisted in UserDefaults for ↑/↓ recall

import SwiftUI
import AppKit
import NativeAgentCore

// PATCH-2026-05-07: spotlight-overlay-keywindow Subclass NSPanel so we can
// override canBecomeKey/Main. .nonactivatingPanel style normally refuses key
// status, which means TextField can't accept keystrokes. We DO want the panel
// to be the key window so typing works — we just don't want the app to fully
// activate behind it.
final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

/// PATCH-2026-05-07: spotlight-frame Bridge-callable probe for the overlay
/// panel's current frame. Lives outside the @MainActor class so the
/// non-MainActor MacControlBridge can read it without actor-isolation
/// errors. Hops to the main thread internally.
enum SpotlightOverlayProbe {
    /// Returns (x, y, width, height) of the panel's current frame, or nil
    /// when the panel hasn't been instantiated.
    static func currentFrame() -> (Int, Int, Int, Int)? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var captured: (Int, Int, Int, Int)? = nil
        DispatchQueue.main.async {
            if let p = SpotlightOverlay.shared.panel {
                let f = p.frame
                captured = (Int(f.origin.x), Int(f.origin.y), Int(f.size.width), Int(f.size.height))
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(500))
        return captured
    }
}

@MainActor
final class SpotlightOverlay {
    static let shared = SpotlightOverlay()

    fileprivate var panel: SpotlightPanel?
    private var hostingController: NSHostingController<SpotlightView>?
    private let viewModel = SpotlightViewModel()

    private init() {}

    func toggle() {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        ensurePanel()
        guard let panel = panel else { return }
        positionOnActiveScreen()
        panel.alphaValue = 0
        // Make the panel key WITHOUT activating the app. SpotlightPanel
        // overrides canBecomeKey = true even though .nonactivatingPanel
        // normally refuses, so the TextField receives keystrokes — but the
        // app itself stays in the background. Other windows do not
        // come forward when ⌘⇧J fires.
        panel.makeKeyAndOrderFront(nil)
        viewModel.focusInput.toggle()  // re-trigger SwiftUI focus
        Task { await viewModel.refreshCommandPalette() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1.0
        }
    }

    func hide() {
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            Task { @MainActor in panel?.orderOut(nil) }
        })
    }

    private func ensurePanel() {
        if panel != nil { return }

        // PATCH-2026-05-07: spotlight-default-size Default size locked from
        // The settled preference (600×360 — measured live via the
        // /macctl/spotlight_frame probe). Autosave still persists per-user
        // tweaks, this is just the first-run frame for new installs.
        let initialFrame = NSRect(x: 0, y: 0, width: 600, height: 360)
        let p = SpotlightPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.animationBehavior = .none
        // We want the panel to take key status (so TextField works); only
        // taking key when something inside requests it would block our
        // .onAppear focus path on first show.
        p.becomesKeyOnlyIfNeeded = false
        p.worksWhenModal = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        // PATCH-2026-05-07: spotlight-min-size Floor on resize so accidental
        // drags cannot trap the user at a 162-wide strip again. Set just below
        // the default (600×360) so he can shrink a little if he wants but
        // can't accidentally collapse it to a sliver.
        p.contentMinSize = NSSize(width: 480, height: 280)
        // PATCH-2026-05-07: spotlight-autosize Persist the resized frame
        // across launches. setFrameAutosaveName turns ON the save side;
        // setFrameUsingName turns ON the load side. Without the second call,
        // every launch resets to the default frame.
        p.setFrameAutosaveName("SpotlightOverlayPanel")
        p.setFrameUsingName("SpotlightOverlayPanel")

        let view = SpotlightView(viewModel: viewModel) { [weak self] in
            self?.hide()
        }
        let hosting = NSHostingController(rootView: view)
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = 14
        hosting.view.layer?.masksToBounds = true
        p.contentViewController = hosting

        self.panel = p
        self.hostingController = hosting
    }

    private func positionOnActiveScreen() {
        guard let panel = panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        // Position 25% from the top
        let y = screenFrame.maxY - panelSize.height - (screenFrame.height * 0.25)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - View model

@MainActor
final class SpotlightViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var lastReply: String = ""
    @Published var lastPrompt: String = ""
    @Published var isThinking: Bool = false
    @Published var error: String? = nil
    @Published var focusInput: Bool = false   // toggling this re-focuses the field
    @Published var commandEntries: [CoordinationCommandEntry] = []
    private var commandPaletteGate = LatestAsyncRequestGate()

    // Stable session id so memory persists across pops
    private let sessionId: String = "spotlight"
    private var nativeBase: String {
        NativeBaseURLDefaults.read()
    }

    // Up-arrow recall
    private let recentKey = "spotlight.recentPrompts"
    var recentPrompts: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }
    private func saveRecent(_ prompt: String) {
        var list = recentPrompts
        list.removeAll(where: { $0 == prompt })
        list.insert(prompt, at: 0)
        if list.count > 30 { list = Array(list.prefix(30)) }
        UserDefaults.standard.set(list, forKey: recentKey)
    }

    func refreshCommandPalette(query: String = "") async {
        let requestToken = commandPaletteGate.begin()
        let api = NativeClient(baseURL: nativeBase)
        do {
            let entries = try await api.searchCommandPalette(query: query, limit: 8)
            guard !Task.isCancelled, commandPaletteGate.accepts(requestToken) else { return }
            self.commandEntries = entries
        } catch {
            // The command palette is opportunistic; Spotlight chat remains usable if it is unavailable.
        }
    }

    func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        lastPrompt = trimmed
        input = ""
        isThinking = true
        error = nil
        saveRecent(trimmed)

        Task { [weak self] in
            await self?.send(trimmed)
        }
    }

    private func send(_ text: String) async {
        defer { Task { @MainActor in self.isThinking = false } }
        let api = NativeClient(baseURL: nativeBase)
        let model = UserDefaults.standard.string(forKey: "chatModel") ?? nativeAgentPrimaryModel
        let effort = UserDefaults.standard.string(forKey: "chatReasoningEffort") ?? "high"
        let fileAccess = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"
        do {
            let response = try await api.chat(
                message: text,
                sessionId: sessionId,
                model: model,
                reasoningEffort: effort,
                fileAccess: fileAccess
            )
            let reply = response.output
            await MainActor.run {
                self.lastReply = reply.isEmpty ? "(no reply)" : reply
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }
}

// MARK: - View

struct SpotlightView: View {
    @ObservedObject var viewModel: SpotlightViewModel
    var onDismiss: () -> Void
    @FocusState private var isInputFocused: Bool
    @State private var commandSearchTask: Task<Void, Never>?
    // Computed per render on purpose: the panel's SpotlightView is built
    // ONCE (ensurePanel early-returns while panel != nil), so anything
    // cached at construction would stay stale across persona renames for
    // the app's lifetime. The profile read is a small local file and this
    // view only renders while the overlay is open.
    private var placeholder: String {
        "Ask \(NativeAgentNotificationDefaults.agentDisplayName())..."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Input row — always at top, always visible
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(viewModel.isThinking
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color.secondary))
                    .symbolEffect(.pulse, options: .repeating, isActive: viewModel.isThinking)
                TextField(placeholder, text: $viewModel.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .focused($isInputFocused)
                    .onSubmit { viewModel.submit() }
                    .onAppear { isInputFocused = true }
                    .onChange(of: viewModel.input) { _, newValue in
                        commandSearchTask?.cancel()
                        commandSearchTask = Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            guard !Task.isCancelled else { return }
                            await viewModel.refreshCommandPalette(query: newValue)
                        }
                    }
                    .onChange(of: viewModel.focusInput) { _, _ in
                        DispatchQueue.main.async { isInputFocused = true }
                    }
                if viewModel.isThinking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Divider()

            // Reply / hint area — always fills the remaining height so the
            // panel feels solid even when there's no reply yet.
            ZStack(alignment: .topLeading) {
                if let err = viewModel.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Error")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.85))
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    .padding(20)
                } else if !viewModel.lastReply.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !viewModel.lastPrompt.isEmpty {
                                Text(viewModel.lastPrompt)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 2)
                            }
                            Text(viewModel.lastReply)
                                .font(.system(size: 15))
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(20)
                    }
                } else {
                    // Empty state — Raycast-style hint copy + recent prompts.
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 12, weight: .medium))
                            Text("Ask anything. Memory and context carry across pops.")
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(.secondary)

                        if !viewModel.commandEntries.isEmpty {
                            Text("FIND")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                            ForEach(viewModel.commandEntries.prefix(6)) { entry in
                                Button {
                                    NativeAgentAppCoordinator.shared.request(commandEntry: entry)
                                    onDismiss()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: entry.systemImage ?? "magnifyingglass")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.title ?? entry.id)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1)
                                                .foregroundStyle(.secondary)
                                            if let subtitle = entry.subtitle, !subtitle.isEmpty {
                                                Text(subtitle)
                                                    .font(.system(size: 11))
                                                    .lineLimit(1)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !viewModel.recentPrompts.isEmpty {
                            Text("RECENT")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                            ForEach(viewModel.recentPrompts.prefix(5), id: \.self) { rp in
                                Button {
                                    viewModel.input = rp
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.uturn.up")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                        Text(rp)
                                            .font(.system(size: 13))
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Spacer()

                        HStack(spacing: 14) {
                            Label("↩ submit", systemImage: "return")
                            Label("Esc dismiss", systemImage: "escape")
                            Label("⌘⇧J toggle", systemImage: "keyboard")
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear {
            commandSearchTask?.cancel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        // Esc to dismiss
        .background(KeyEventCatcher(onEsc: onDismiss))
    }
}

// AppKit hook to swallow Esc inside the panel and trigger dismissal.
private struct KeyEventCatcher: NSViewRepresentable {
    var onEsc: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyCatcherView()
        v.onEsc = onEsc
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyCatcherView)?.onEsc = onEsc
    }
    final class KeyCatcherView: NSView {
        var onEsc: (() -> Void)?
        // nonisolated(unsafe) so deinit can safely call NSEvent.removeMonitor
        nonisolated(unsafe) private var monitor: Any?
        override var acceptsFirstResponder: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Drop any existing monitor before installing a new one so
            // toggling the panel doesn't stack handlers.
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
            // B.8: if we've been removed from a window, clean up and stop
            guard self.window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // B.8: only intercept Esc when the event belongs to our window
                // and that window is currently visible. Otherwise pass it on
                // so Esc works correctly in other windows (e.g., sheets, popovers).
                guard event.window === self?.window,
                      self?.window?.isVisible == true else { return event }
                if event.keyCode == 53 /* Esc */ {
                    self?.onEsc?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let m = monitor {
                NSEvent.removeMonitor(m)
            }
        }
    }
}
