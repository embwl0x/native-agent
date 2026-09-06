// PATCH-2026-05-07: proactive-inbox-1 InboxSettingsView — trigger config + master enable
import SwiftUI
import Observation

/// A visible Inbox Policy outcome carries its own severity. Status text is
/// user-facing copy and must never be treated as an error protocol.
struct InboxPolicyStatus: Equatable {
    enum Tone: Equatable {
        case success
        case warning
        case failure
    }

    enum Event: Equatable {
        case settingsLoadFailed(String)
        case triggersLoadFailed(String)
        case masterSaved(enabled: Bool)
        case masterSaveFailed(String)
        case triggerSaved(name: String, enabled: Bool)
        case triggerSaveFailed(String)
        case testUnavailable
        case triggerFired(itemID: String?, wasStub: Bool)
        case triggerCardConfirmed(itemID: String, state: InboxTriggerTestFireReceipt.CardState, wasPlaceholder: Bool)
        case triggerFireFailed(String)
        case pathsSaved(count: Int)
        case pathsSaveFailed(String)
    }

    let text: String
    let tone: Tone

    init(_ event: Event) {
        switch event {
        case let .settingsLoadFailed(detail):
            text = "Failed to load inbox settings: \(detail)"
            tone = .failure
        case let .triggersLoadFailed(detail):
            text = "Failed to load triggers: \(detail)"
            tone = .failure
        case let .masterSaved(enabled):
            text = enabled ? "Inbox enabled." : "Inbox disabled."
            tone = .success
        case let .masterSaveFailed(detail):
            text = "Failed: \(detail)"
            tone = .failure
        case let .triggerSaved(name, enabled):
            text = "\(name) \(enabled ? "enabled" : "disabled")."
            tone = .success
        case let .triggerSaveFailed(detail):
            text = "Toggle failed: \(detail)"
            tone = .failure
        case .testUnavailable:
            text = "Test is unavailable until this trigger can produce real evidence-backed content."
            tone = .warning
        case let .triggerFired(itemID, wasStub):
            let label = wasStub ? "Fired (stub)" : "Fired"
            let head = (itemID ?? "").prefix(8)
            text = head.isEmpty ? "\(label)." : "\(label) — item: \(head)..."
            tone = .success
        case let .triggerCardConfirmed(itemID, state, wasPlaceholder):
            if wasPlaceholder {
                text = "Test failed: the trigger returned placeholder content instead of a real inbox card."
                tone = .failure
            } else {
                let label = switch state {
                case .created: "Test card created"
                case .alreadyVisible: "Test card already visible"
                }
                text = "\(label) — item: \(itemID.prefix(8))..."
                tone = .success
            }
        case let .triggerFireFailed(detail):
            text = "Fire failed: \(detail)"
            tone = .failure
        case let .pathsSaved(count):
            text = "Paths saved (\(count) entries)."
            tone = .success
        case let .pathsSaveFailed(detail):
            text = "Paths save failed: \(detail)"
            tone = .failure
        }
    }
}

/// Each Inbox Policy writer owns its own visible outcome. A successful toggle
/// must not overwrite a failed trust or trigger read merely because both used
/// to share one `status` slot.
struct InboxPolicyStatusSlot: Equatable {
    enum Source: Hashable, Comparable {
        case settingsRead
        case triggersRead
        case masterToggle
        case triggerToggle(String)
        case triggerTest(String)
        case watchedPaths

        private var order: String {
            switch self {
            case .settingsRead: return "0-settings"
            case .triggersRead: return "1-triggers"
            case .masterToggle: return "2-master"
            case .triggerToggle(let name): return "3-toggle-\(name)"
            case .triggerTest(let name): return "4-test-\(name)"
            case .watchedPaths: return "5-paths"
            }
        }

        static func < (lhs: Source, rhs: Source) -> Bool {
            lhs.order < rhs.order
        }
    }

    struct Entry: Equatable {
        let source: Source
        let status: InboxPolicyStatus
    }

    private var bySource: [Source: InboxPolicyStatus] = [:]

    var entries: [Entry] {
        bySource.map { Entry(source: $0.key, status: $0.value) }
            .sorted { $0.source < $1.source }
    }

    mutating func record(_ status: InboxPolicyStatus, from source: Source) {
        bySource[source] = status
    }

    mutating func clear(source: Source) {
        bySource.removeValue(forKey: source)
    }
}

/// Owns the policy surface's Inbox History route without becoming a second
/// inbox store. The mounted history sheet projects `AppModel.inboxItems`, so a
/// refresh made from policy updates the same cards, badges, and chat strip the
/// rest of the app already observes.
@MainActor @Observable
final class InboxHistoryRoute {
    enum RefreshResult: Equatable {
        case loaded
        case failed
        case alreadyLoading
    }

    private(set) var isPresented = false
    private(set) var isLoading = false
    private(set) var errorText: String?

    func open(
        read: @escaping @MainActor () async throws -> [InboxItemRecord],
        retainedItemCount: @escaping @MainActor () -> Int,
        adopt: @escaping @MainActor ([InboxItemRecord]) -> Void
    ) async {
        isPresented = true
        _ = await refresh(read: read, retainedItemCount: retainedItemCount, adopt: adopt)
    }

    @discardableResult
    func refresh(
        read: @escaping @MainActor () async throws -> [InboxItemRecord],
        retainedItemCount: @escaping @MainActor () -> Int,
        adopt: @escaping @MainActor ([InboxItemRecord]) -> Void
    ) async -> RefreshResult {
        guard !isLoading else { return .alreadyLoading }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            adopt(try await read())
            return .loaded
        } catch {
            errorText = InboxLoadFailurePresentation.banner(
                error: error,
                retainedItemCount: retainedItemCount()
            )
            return .failed
        }
    }

    func close() {
        isPresented = false
    }
}

/// Rendered truth for the policy's history sheet. This deliberately has no
/// collection state: cards come directly from the app-wide inbox mirror.
enum InboxHistoryPresentation {
    enum Content: Equatable {
        case empty
        case rows([InboxItemRecord])
    }

    static func content(items: [InboxItemRecord]) -> Content {
        items.isEmpty ? .empty : .rows(items)
    }

    static func statusLabel(for item: InboxItemRecord) -> String {
        switch item.normalizedStatus {
        case "unread": return "Unread"
        case "read": return "Read"
        case "archived": return "Archived"
        case "dismissed": return "Dismissed"
        case "": return "Status unavailable"
        default: return "Unrecognized status"
        }
    }
}

/// Trust reads are a three-state fact. `false` is meaningful only after a
/// successful read; using it as the initial value made an unreadable policy
/// look intentionally disabled and hid the trigger inventory behind it.
enum InboxPolicyTrustReadState: Equatable {
    case loading
    case loaded(enabled: Bool)
    case unavailable(String)
}

enum InboxPolicyTriggersPanelGate: Equatable {
    case loading
    case enabled
    case disabled
    case unavailable(String)

    static func resolve(trustRead: InboxPolicyTrustReadState) -> Self {
        switch trustRead {
        case .loading: return .loading
        case .loaded(enabled: true): return .enabled
        case .loaded(enabled: false): return .disabled
        case .unavailable(let detail): return .unavailable(detail)
        }
    }
}

struct InboxSettingsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var masterEnabled: Bool = false
    @State private var suppressMasterSave = false
    @State private var triggers: [InboxTriggerConfig] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var statusSlot = InboxPolicyStatusSlot()
    @State private var trustReadState: InboxPolicyTrustReadState = .loading
    @State private var inboxHistoryRoute = InboxHistoryRoute()

    // File watcher watched paths (comma-separated editing)
    @State private var watchedPaths: String = ""

    // R22: source the client from AppModel's canonical `client` (already carries
    // nativeBaseURL + the shared runtime) instead of constructing inline.
    private var client: NativeClient { appModel.client }
    private var triggersPanelGate: InboxPolicyTriggersPanelGate {
        InboxPolicyTriggersPanelGate.resolve(trustRead: trustReadState)
    }
    private var masterToggleDisabled: Bool {
        if isSaving { return true }
        switch trustReadState {
        case .loaded: return false
        case .loading, .unavailable: return true
        }
    }
    private var agentDisplayName: String {
        let profileName = appModel.personality?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chatName = appModel.chatPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profileName.isEmpty && profileName != "NativeAgent" { return profileName }
        if !chatName.isEmpty { return canonicalAgentDisplayName(chatName, fallback: "the agent") }
        return "the agent"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // ── Master toggle ──────────────────────────────────────────
                InboxSection(title: "Proactive inbox") {
                    Toggle("Let the agent raise things unasked", isOn: $masterEnabled)
                        .disabled(masterToggleDisabled)
                        .onChange(of: masterEnabled) { _, val in
                            if suppressMasterSave {
                                suppressMasterSave = false
                                return
                            }
                            Task { await saveMaster(enabled: val) }
                        }

                    Text("When this is on, \(agentDisplayName) can surface observations, file changes, finished Desk tasks and check-ins without being asked.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("View inbox history") {
                        Task { await openInboxHistory() }
                    }
                    .disabled(inboxHistoryRoute.isLoading)

                    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/inbox/self_test

                    if !statusSlot.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(statusSlot.entries, id: \.source) { entry in
                                Text(entry.status.text)
                                    .font(ShellType.label)
                                    .foregroundStyle(statusColor(entry.status.tone))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                // ── Triggers ───────────────────────────────────────────────
                switch triggersPanelGate {
                case .enabled:
                    InboxSection(title: "Triggers") {
                        ForEach(triggers) { trigger in
                            TriggerRowView(
                                trigger: trigger,
                                watchedPaths: trigger.name == "file_watch" ? $watchedPaths : .constant(""),
                                onToggle: { enabled in await setTriggerEnabled(trigger.name, enabled: enabled) },
                                onFireNow: { Task { await fireTriggerNow(trigger) } }
                            )
                        }
                    }

                    // File watcher path editor
                    if triggers.first(where: { $0.name == "file_watch" })?.enabled == true {
                        InboxSection(title: "Watched folders") {
                            Text("One path per line.")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                            TextEditor(text: $watchedPaths)
                                .font(ShellType.code)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(NativeAgentShell.quietFill)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                                )
                            Button("Save paths") {
                                Task { await saveWatchedPaths() }
                            }
                        }
                    }
                case .disabled:
                    EmptyView()
                case .loading:
                    InboxSection(title: "Triggers") {
                        Text("Checking whether the proactive inbox is on…")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                case .unavailable(let detail):
                    InboxSection(title: "Triggers unavailable") {
                        Text("The proactive inbox setting could not be read, so the trigger settings are unavailable rather than off.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.trouble)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // ui-taste-sweep 2026-06-07: was falling back to the bundle name.
        .navigationTitle("Notifications")
        .task { await load() }
        .sheet(isPresented: Binding(
            get: { inboxHistoryRoute.isPresented },
            set: { presented in
                if !presented { inboxHistoryRoute.close() }
            }
        )) {
            InboxHistoryView(
                route: inboxHistoryRoute,
                onRefresh: { await refreshInboxHistory() },
                onClose: { inboxHistoryRoute.close() }
            )
            .environment(appModel)
            .presentationDetents([.large])
        }
    }

    // ── Data loading ──────────────────────────────────────────────────────

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // Load trust policy via raw dictionary to pick up inboxPolicy (not yet in Swift TrustPolicy struct)
        // PATCH-2026-05-29: surface-load-errors Do not swallow the /v1/trust fetch
        // with try?; a failed fetch left masterEnabled stale/false with no status.
        do {
            let obj = try await client.getTrustRaw()
            let ip = obj["inboxPolicy"] as? [String: Any]
            let loaded = ip?["enabled"] as? Bool ?? false
            trustReadState = .loaded(enabled: loaded)
            statusSlot.clear(source: .settingsRead)
            // Suppress the master toggle's onChange save only when the value
            // actually changes: this is a programmatic load, not a user toggle,
            // so it must not trigger a write-back. Guarding on the delta avoids
            // arming the flag when onChange won't fire (which would otherwise
            // swallow the next genuine user toggle).
            if masterEnabled != loaded {
                suppressMasterSave = true
                masterEnabled = loaded
            }
        } catch {
            trustReadState = .unavailable(error.localizedDescription)
            statusSlot.record(InboxPolicyStatus(.settingsLoadFailed(error.localizedDescription)), from: .settingsRead)
        }
        // Load triggers
        // U5 W-A item 1 (:151): the trigger read was swallowed into [] —
        // a failed read rendered as "no triggers configured" with no
        // signal. Keep last-known rows and surface the real error in the
        // panel's status line instead.
        do {
            triggers = try await client.getInboxTriggers()
            statusSlot.clear(source: .triggersRead)
        } catch {
            statusSlot.record(InboxPolicyStatus(.triggersLoadFailed(error.localizedDescription)), from: .triggersRead)
        }
        // Load watched paths for file_watch trigger
        if let fw = triggers.first(where: { $0.name == "file_watch" }),
           let paths = fw.config?["paths"] {
            watchedPaths = paths
        }
    }

    func saveMaster(enabled: Bool) async {
        isSaving = true
        defer { isSaving = false }
        let previousEnabled: Bool = {
            if case .loaded(let enabled) = trustReadState { return enabled }
            return !enabled
        }()
        do {
            _ = try await client.postRaw("/v1/trust", body: [
                "inboxPolicy": ["enabled": enabled]
            ])
            trustReadState = .loaded(enabled: enabled)
            statusSlot.record(InboxPolicyStatus(.masterSaved(enabled: enabled)), from: .masterToggle)
        } catch {
            statusSlot.record(InboxPolicyStatus(.masterSaveFailed(error.localizedDescription)), from: .masterToggle)
            suppressMasterSave = true
            masterEnabled = previousEnabled
            trustReadState = .loaded(enabled: previousEnabled)
        }
    }

    // PATCH-2026-05-07: surface-load-errors Stop swallowing failures with
    // try?. Toggling a trigger or firing-now silently failed before; user
    // had no idea their click did nothing.
    // ui-honesty 2026-06-10: returns success so the row can revert its local
    // toggle when the server write fails — the switch used to stay flipped
    // in a position the server never accepted.
    func setTriggerEnabled(_ name: String, enabled: Bool) async -> Bool {
        do {
            try await client.inboxTriggerEnable(name, enabled: enabled)
            statusSlot.record(InboxPolicyStatus(.triggerSaved(name: name, enabled: enabled)), from: .triggerToggle(name))
            await load()
            return true
        } catch {
            statusSlot.record(InboxPolicyStatus(.triggerSaveFailed(error.localizedDescription)), from: .triggerToggle(name))
            return false
        }
    }

    func fireTriggerNow(_ trigger: InboxTriggerConfig) async {
        guard trigger.supportsRealManualFire else {
            statusSlot.record(InboxPolicyStatus(.testUnavailable), from: .triggerTest(trigger.name))
            return
        }
        do {
            // The client returns only after the exact card receipt is readable
            // from the live notifications inbox. A scheduler "fired" response
            // alone is not enough to present a successful Desk test.
            let fired = try await client.inboxTriggerFireNow(trigger.name, stub: true)
            statusSlot.record(InboxPolicyStatus(.triggerCardConfirmed(
                itemID: fired.itemID,
                state: fired.cardState,
                wasPlaceholder: fired.wasPlaceholder
            )), from: .triggerTest(trigger.name))
        } catch {
            statusSlot.record(InboxPolicyStatus(.triggerFireFailed(error.localizedDescription)), from: .triggerTest(trigger.name))
        }
    }

    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/inbox/self_test

    func saveWatchedPaths() async {
        let paths = watchedPaths
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            // Keep configuration on the typed NativeClient path so validation
            // and persistence remain owned by TriggerScheduler.
            try await client.inboxTriggerConfigure("file_watch", body: ["paths": paths])
            statusSlot.record(InboxPolicyStatus(.pathsSaved(count: paths.count)), from: .watchedPaths)
        } catch {
            statusSlot.record(InboxPolicyStatus(.pathsSaveFailed(error.localizedDescription)), from: .watchedPaths)
        }
    }

    private func openInboxHistory() async {
        await inboxHistoryRoute.open(
            read: { try await appModel.getInboxItems(unreadOnly: false) },
            retainedItemCount: { appModel.inboxItems.count },
            adopt: { appModel.inboxItems = $0 }
        )
    }

    private func refreshInboxHistory() async {
        _ = await inboxHistoryRoute.refresh(
            read: { try await appModel.getInboxItems(unreadOnly: false) },
            retainedItemCount: { appModel.inboxItems.count },
            adopt: { appModel.inboxItems = $0 }
        )
    }

    private func statusColor(_ tone: InboxPolicyStatus.Tone) -> Color {
        switch tone {
        case .success: return NativeAgentShell.calm
        case .warning: return NativeAgentShell.trouble
        case .failure: return NativeAgentShell.trouble
        }
    }
}

// MARK: - Inbox history

/// Read-only history projection used only by Inbox Policy. It intentionally
/// does not mount `InboxView`: there is one source of inbox rows, the shared
/// AppModel mirror, and this sheet merely renders it.
struct InboxHistoryView: View {
    @Environment(AppModel.self) private var appModel

    let route: InboxHistoryRoute
    let onRefresh: @MainActor () async -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let errorText = route.errorText {
                    Text(errorText)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }

                switch InboxHistoryPresentation.content(items: appModel.inboxItems) {
                case .empty where route.isLoading:
                    ProgressView("Loading inbox history…")
                        .font(ShellType.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    Text("No inbox history yet. Cards appear here after the agent records an observation, a file change or a finished Desk task.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .rows(let items):
                    List(items) { item in
                        InboxHistoryRow(item: item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Inbox history")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(route.isLoading)
                    .accessibilityLabel("Refresh inbox history")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }
}

private struct InboxHistoryRow: View {
    let item: InboxItemRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.sourceIcon)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled inbox item" : item.title)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(2)
                }
                Text(item.created_at.isEmpty
                     ? "Time unavailable"
                     : UserDisplayFormatters.humanizeISOTimestamp(item.created_at))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
            Spacer(minLength: 8)
            // The teal is the room's one "waiting on you" colour, and an
            // unread inbox card is exactly that; a read one goes quiet.
            Text(InboxHistoryPresentation.statusLabel(for: item))
                .font(ShellType.captionMedium)
                .foregroundStyle(item.isUnread ? NativeAgentShell.needsYou : NativeAgentShell.secondary)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - TriggerRowView

/// Keeps a trigger switch honest while its durable write is in flight. The
/// visible value is optimistic, but a failed latest request always returns to
/// the last server snapshot. Later user intent gets its own request instead of
/// being swallowed by a programmatic-revert suppression latch.
struct InboxTriggerToggleStateMachine: Equatable {
    struct Request: Equatable, Sendable {
        let id: Int
        let requestedEnabled: Bool
    }

    private(set) var visualEnabled: Bool
    private(set) var serverEnabled: Bool
    private var latestRequestID: Int?
    private var nextRequestID = 0

    init(serverEnabled: Bool) {
        visualEnabled = serverEnabled
        self.serverEnabled = serverEnabled
    }

    mutating func userToggled(to requestedEnabled: Bool) -> Request {
        nextRequestID &+= 1
        let request = Request(id: nextRequestID, requestedEnabled: requestedEnabled)
        latestRequestID = request.id
        visualEnabled = requestedEnabled
        return request
    }

    mutating func completed(_ request: Request, accepted: Bool) {
        // A prior request is no longer allowed to repaint a more recent user
        // choice. Its server reload, when available, still enters through
        // `synchronizeServer(enabled:)` below.
        guard latestRequestID == request.id else { return }
        latestRequestID = nil
        if accepted {
            serverEnabled = request.requestedEnabled
            visualEnabled = request.requestedEnabled
        } else {
            visualEnabled = serverEnabled
        }
    }

    mutating func synchronizeServer(enabled: Bool) {
        serverEnabled = enabled
        // Do not clobber a newer local request while the parent's refresh is
        // delivering an older server snapshot.
        if latestRequestID == nil {
            visualEnabled = enabled
        }
    }
}

struct TriggerRowView: View {
    let trigger: InboxTriggerConfig
    @Binding var watchedPaths: String
    // ui-honesty 2026-06-10: async + Bool result so the row can revert the
    // visual toggle when the server write fails.
    let onToggle: (Bool) async -> Bool
    let onFireNow: () -> Void

    @State private var toggleState: InboxTriggerToggleStateMachine

    init(trigger: InboxTriggerConfig, watchedPaths: Binding<String>, onToggle: @escaping (Bool) async -> Bool, onFireNow: @escaping () -> Void) {
        self.trigger = trigger
        self._watchedPaths = watchedPaths
        self.onToggle = onToggle
        self.onFireNow = onFireNow
        self._toggleState = State(initialValue: InboxTriggerToggleStateMachine(serverEnabled: trigger.enabled))
    }

    // PATCH-2026-05-07: polish-InboxSettingsView PulsingDot for enabled triggers
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: trigger.systemImage)
                    .font(ShellType.body)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .frame(width: 22)
                if toggleState.visualEnabled {
                    PulsingDot(color: NativeAgentShell.calm, size: 6)
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.displayName)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                if let desc = trigger.description {
                    Text(desc)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button("Test") { onFireNow() }
                .controlSize(.small)
                .disabled(!trigger.supportsRealManualFire)
                .help(trigger.supportsRealManualFire
                    ? "Create one real trigger item now"
                    : "Unavailable until this trigger has real evidence-backed content")

            Toggle("", isOn: Binding(
                get: { toggleState.visualEnabled },
                set: { requestToggle($0) }
            ))
                .labelsHidden()
        }
        .frame(minHeight: 48)
        .onChange(of: trigger.enabled) { _, val in
            toggleState.synchronizeServer(enabled: val)
        }
    }

    private func requestToggle(_ enabled: Bool) {
        let request = toggleState.userToggled(to: enabled)
        Task {
            let accepted = await onToggle(request.requestedEnabled)
            toggleState.completed(request, accepted: accepted)
        }
    }
}

// MARK: - Page kit (2026-09-03 Advanced refinement)

/// One section of the page: the eyebrow the Advanced list uses, and the rows
/// under it on one card. Replaces the stack of `NativePanel` material slabs
/// this page carried; on the shell's one sheet those read as plates.
private struct InboxSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                        .fill(TodayPalette.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                        .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
                )
        }
    }
}
