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

import Foundation
import SwiftUI
import AppKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

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
enum SpotlightOverlayProbeResult: Equatable {
    case frame(Int, Int, Int, Int)
    case absent
    case timedOut
}

enum SpotlightOverlayProbe {
    /// Returns (x, y, width, height) of the panel's current frame, or nil
    /// when the panel hasn't been instantiated.
    static func currentFrame() -> SpotlightOverlayProbeResult {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var captured: (Int, Int, Int, Int)? = nil
        DispatchQueue.main.async {
            if let p = SpotlightOverlay.shared.panel {
                let f = p.frame
                captured = (Int(f.origin.x), Int(f.origin.y), Int(f.size.width), Int(f.size.height))
            }
            semaphore.signal()
        }
        let completed = semaphore.wait(timeout: .now() + .milliseconds(500)) == .success
        return resolve(completed: completed, frame: captured)
    }

    /// Keep a visible overlay distinct from a main-thread probe that could not
    /// complete. The bridge must never describe a timeout as "not open".
    static func resolve(
        completed: Bool,
        frame: (Int, Int, Int, Int)?
    ) -> SpotlightOverlayProbeResult {
        guard completed else { return .timedOut }
        guard let frame else { return .absent }
        return .frame(frame.0, frame.1, frame.2, frame.3)
    }
}

enum SpotlightRecentPrompts {
    static let defaultsKey = "spotlight.recentPrompts"
    static let maximumCount = 30

    static func load(from defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    @discardableResult
    static func record(_ prompt: String, in defaults: UserDefaults) -> [String] {
        let updated = recording(prompt, into: load(from: defaults))
        defaults.set(updated, forKey: defaultsKey)
        return updated
    }

    static func recording(_ prompt: String, into existing: [String]) -> [String] {
        var prompts = existing.filter { $0 != prompt }
        prompts.insert(prompt, at: 0)
        return Array(prompts.prefix(maximumCount))
    }
}

enum SpotlightCommandPalettePresentation {
    static let maximumEntries = 6

    enum State: Equatable {
        case loading
        case unavailable(String)
        case entries([CoordinationCommandEntry])
        case noMatches
        case idle
    }

    static func visibleEntries(_ entries: [CoordinationCommandEntry]) -> [CoordinationCommandEntry] {
        Array(entries.prefix(maximumEntries))
    }

    static func resolved(
        _ result: Result<[CoordinationCommandEntry], Error>
    ) -> (entries: [CoordinationCommandEntry], error: String?) {
        switch result {
        case .success(let entries):
            return (visibleEntries(entries), nil)
        case .failure(let error):
            return ([], "Command shortcuts unavailable: \(error.localizedDescription)")
        }
    }

    /// The exact precedence the overlay renders below its input: an in-flight
    /// search and a failed reader must never be disguised as an empty result.
    static func state(
        input: String,
        isPending: Bool,
        entries: [CoordinationCommandEntry],
        error: String?
    ) -> State {
        if isPending { return .loading }
        if let error { return .unavailable(error) }
        let visible = visibleEntries(entries)
        if !visible.isEmpty { return .entries(visible) }
        return input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .idle
            : .noMatches
    }
}

/// The palette command click has one atomic observable effect: resolve a
/// command into a canonical app destination, deliver that destination, then
/// dismiss the temporary overlay. Unknown command entries remain inert and do
/// not dismiss the overlay.
enum SpotlightCommandPaletteAction {
    @discardableResult
    static func select(
        _ entry: CoordinationCommandEntry,
        route: (NativeAgentNavigationDestination) -> Void,
        dismiss: () -> Void
    ) -> Bool {
        guard let destination = NativeAgentNavigationDestination.commandEntry(entry) else {
            return false
        }
        route(destination)
        dismiss()
        return true
    }
}

/// A previous chat reply must not hide shortcut search. The overlay keeps its
/// last answer across pops, but entering a new query is an explicit request to
/// search commands and should take precedence over that retained answer.
enum SpotlightOverlayPresentation {
    static func showsCommandPalette(input: String, hasReply: Bool) -> Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasReply
    }
}

/// The overlay is a focused entrance to the main conversation, not a separate
/// model surface. Keep its stable transcript identity together with the exact
/// route ingredients that are admitted for the main chat surface, so a stale
/// UI cache cannot silently send this conversation to a different model.
struct SpotlightTurnIngredient: Sendable, Equatable {
    static let spotlightSessionId = "spotlight"

    let sessionId: String
    let model: String
    let reasoningEffort: String
    let fileAccess: String

    static func resolved(
        routing: SurfacePreference,
        fileAccess: String
    ) -> SpotlightTurnIngredient {
        SpotlightTurnIngredient(
            sessionId: spotlightSessionId,
            model: routing.model,
            reasoningEffort: routing.reasoningEffort,
            fileAccess: AppModel.normalizedAgentAccessMode(fileAccess)
        )
    }

    /// Read the same persisted `chat` picker that the main chat turn admits.
    /// Missing configuration has a provider-routing default; malformed routing
    /// state remains an error instead of falling back to unrelated defaults.
    @MainActor
    static func current(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        defaults: UserDefaults = .standard
    ) async throws -> SpotlightTurnIngredient {
        let routing = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let preference = try await routing.modelForSurface("chat")
        return resolved(
            routing: preference,
            fileAccess: defaults.string(forKey: "chatFileAccess") ?? "auto"
        )
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
    @Published var commandPaletteError: String?
    @Published var commandSearchPending = false
    private var commandPaletteGate = LatestAsyncRequestGate()
    private let ingredientResolver: @MainActor () async throws -> SpotlightTurnIngredient
    private let turnSender: @MainActor (String, SpotlightTurnIngredient) async throws -> String

    init() {
        ingredientResolver = { try await SpotlightTurnIngredient.current() }
        turnSender = { text, ingredient in
            let response = try await NativeClient(baseURL: NativeBaseURLDefaults.read()).chat(
                message: text,
                sessionId: ingredient.sessionId,
                model: ingredient.model,
                reasoningEffort: ingredient.reasoningEffort,
                fileAccess: ingredient.fileAccess,
                surface: "chat"
            )
            return response.output
        }
    }

    init(
        ingredientResolver: @escaping @MainActor () async throws -> SpotlightTurnIngredient,
        turnSender: @escaping @MainActor (String, SpotlightTurnIngredient) async throws -> String
    ) {
        self.ingredientResolver = ingredientResolver
        self.turnSender = turnSender
    }

    // Up-arrow recall
    var recentPrompts: [String] {
        SpotlightRecentPrompts.load(from: .standard)
    }
    private func saveRecent(_ prompt: String) {
        SpotlightRecentPrompts.record(prompt, in: .standard)
    }

    func prepareCommandPaletteSearch() {
        commandSearchPending = true
        commandEntries = []
        commandPaletteError = nil
    }

    func refreshCommandPalette(query: String = "") async {
        let requestToken = commandPaletteGate.begin()
        prepareCommandPaletteSearch()
        let api = NativeClient(baseURL: NativeBaseURLDefaults.read())
        do {
            // The rendered panel intentionally has room for six entries. Keep
            // the request aligned so a returned entry is never silently
            // fetched and then made unreachable.
            let entries = try await api.searchCommandPalette(
                query: query,
                limit: SpotlightCommandPalettePresentation.maximumEntries
            )
            guard !Task.isCancelled, commandPaletteGate.accepts(requestToken) else { return }
            let presentation = SpotlightCommandPalettePresentation.resolved(.success(entries))
            self.commandEntries = presentation.entries
            self.commandPaletteError = presentation.error
            self.commandSearchPending = false
        } catch {
            guard !Task.isCancelled, commandPaletteGate.accepts(requestToken) else { return }
            let presentation = SpotlightCommandPalettePresentation.resolved(.failure(error))
            self.commandEntries = presentation.entries
            self.commandPaletteError = presentation.error
            self.commandSearchPending = false
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
        defer { isThinking = false }
        do {
            let ingredient = try await ingredientResolver()
            let reply = try await turnSender(text, ingredient)
            lastReply = reply.isEmpty ? "(no reply)" : reply
        } catch {
            self.error = error.localizedDescription
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
                        viewModel.prepareCommandPaletteSearch()
                        commandSearchTask = Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            guard !Task.isCancelled else { return }
                            await viewModel.refreshCommandPalette(query: newValue)
                        }
                    }
                    .onChange(of: viewModel.focusInput) { _, _ in
                        DispatchQueue.main.async { isInputFocused = true }
                    }
                    .accessibilityIdentifier("spotlight.input")
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
                } else if !viewModel.lastReply.isEmpty,
                          !SpotlightOverlayPresentation.showsCommandPalette(
                            input: viewModel.input,
                            hasReply: true
                          ) {
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

                        switch SpotlightCommandPalettePresentation.state(
                            input: viewModel.input,
                            isPending: viewModel.commandSearchPending,
                            entries: viewModel.commandEntries,
                            error: viewModel.commandPaletteError
                        ) {
                        case .loading:
                            Label("Searching shortcuts…", systemImage: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .accessibilityIdentifier("spotlight.commandPalette.loading")
                        case .unavailable(let error):
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .padding(.top, 4)
                                .accessibilityIdentifier("spotlight.commandPalette.error")
                        case .entries(let entries):
                            Text("FIND")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                            ForEach(entries) { entry in
                                Button {
                                    _ = SpotlightCommandPaletteAction.select(
                                        entry,
                                        route: { NativeAgentAppCoordinator.shared.request($0) },
                                        dismiss: onDismiss
                                    )
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
                                .accessibilityIdentifier("spotlight.commandPalette.\(entry.id)")
                            }
                        case .noMatches:
                            Label("No shortcuts match this search. Press Return to ask the assistant instead.", systemImage: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .accessibilityIdentifier("spotlight.commandPalette.empty")
                        case .idle:
                            EmptyView()
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
