import NativeAgentShared

// Blueprint: | `InboxSettingsView.swift` | `InboxSettingsView`: master/trigger controls, independent writer outcomes and history navigation over canonical inbox policy |
// PATCH-2026-05-07: proactive-inbox-1 InboxSettingsView — trigger config + master enable
import SwiftUI
import NativeAgentCore
import NotificationInbox
import Observation
import TrustCenter
import TriggerScheduler
import PersistenceCore

/// A visible Inbox Policy outcome carries its own severity. Status text is
/// user-facing copy and must never be treated as an error protocol.
struct InboxPolicyStatus: Equatable {
    enum Tone: Equatable {
        case success
        case failure
    }

    enum Event: Equatable {
        case settingsLoadFailed(String)
        case triggersLoadFailed(String)
        case masterSaved(enabled: Bool)
        case masterSaveFailed(String)
        case triggerSaved(name: String, enabled: Bool)
        case triggerSaveFailed(String)
    }

    let text: String
    let tone: Tone

    init(_ event: Event) {
        switch event {
        case let .settingsLoadFailed(detail):
            text = detail
            tone = .failure
        case let .triggersLoadFailed(detail):
            text = detail
            tone = .failure
        case let .masterSaved(enabled):
            text = enabled ? "Inbox enabled." : "Inbox disabled."
            tone = .success
        case let .masterSaveFailed(detail):
            text = detail
            tone = .failure
        case let .triggerSaved(name, enabled):
            text = "\(name) \(enabled ? "enabled" : "disabled")."
            tone = .success
        case let .triggerSaveFailed(detail):
            text = detail
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

        private var order: String {
            switch self {
            case .settingsRead: return "0-settings"
            case .triggersRead: return "1-triggers"
            case .masterToggle: return "2-master"
            case .triggerToggle(let name): return "3-toggle-\(name)"
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

}

/// Owns the policy surface's Inbox History route without becoming a second
/// inbox store. The mounted history sheet projects `engine.inbox.items`, so a
/// refresh made from policy updates the same cards, badges, and chat strip the
/// rest of the app already observes.
@MainActor @Observable
final class InboxHistoryRoute {
    private(set) var isPresented = false

    func open(inbox: InboxFacade) async {
        isPresented = true
        await inbox.refresh()
    }

    func close() {
        isPresented = false
    }
}

/// Rendered truth for the policy's history sheet. This deliberately has no
/// collection state: cards come directly from the engine's inbox revision.
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

    @State private var isSaving = false
    @State private var statusSlot = InboxPolicyStatusSlot()
    @State private var inboxHistoryRoute = InboxHistoryRoute()
    private var triggers: [TriggerConfig] { appModel.engine.inbox.triggerRows }
    private var triggersRead: Bool { appModel.engine.inbox.triggersRead }
    private var isLoading: Bool { appModel.engine.inbox.isLoadingTriggers }
    private var trustReadState: InboxPolicyTrustReadState {
        let trust = appModel.engine.trust
        if let error = trust.inboxPolicyError {
            return .unavailable(UserFacingError.cause(error, action: "read the notification setting"))
        }
        return trust.hasReadInboxPolicy ? .loaded(enabled: trust.inboxPolicyEnabled) : .loading
    }
    private var masterEnabled: Binding<Bool> {
        Binding(
            get: { appModel.engine.trust.inboxPolicyEnabled },
            set: { enabled in Task { await saveMaster(enabled: enabled) } })
    }
    private var statuses: [InboxPolicyStatusSlot.Entry] {
        var displayed = statusSlot
        if let error = appModel.engine.trust.inboxPolicyError {
            displayed.record(InboxPolicyStatus(.settingsLoadFailed(UserFacingError.message(error, action: "load inbox settings"))), from: .settingsRead)
        }
        if let error = appModel.engine.inbox.triggerError {
            displayed.record(InboxPolicyStatus(.triggersLoadFailed(error)), from: .triggersRead)
        }
        return displayed.entries
    }

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
    var body: some View {
        ScrollView {
            aliveContent
        }
        .alivePageLine(headerLine)
        // ui-taste-sweep 2026-06-07: was falling back to the bundle name.
        .navigationTitle("Notifications")
        .quietReadTask(live: false) {
            do { _ = try await appModel.engine.trust.inboxEnabled() }
            catch { ModuleLog.app("%@", "[inbox settings] \(error.localizedDescription)") }
            do { _ = try await appModel.engine.inbox.triggers() }
            catch { ModuleLog.app("%@", "[inbox triggers] \(error.localizedDescription)") }
        }
        .liveTask {
            async let policy: Void = appModel.engine.trust.observeInboxPolicy()
            async let triggers: Void = appModel.engine.inbox.observeTriggers()
            _ = await (policy, triggers)
        }
        .sheet(isPresented: Binding(
            get: { inboxHistoryRoute.isPresented },
            set: { presented in
                if !presented { inboxHistoryRoute.close() }
            }
        )) {
            InboxHistoryView(
                onRefresh: { await refreshInboxHistory() },
                onClose: { inboxHistoryRoute.close() }
            )
            .environment(appModel)
            .presentationDetents([.large])
        }
    }

    // ── Alive glass (Advanced shell, 2026-09-23) ──────────────────────────

    /// The header's one sentence, in the agent's own voice. No "waiting"
    /// count: this page holds settings, not things waiting on him. Nil until
    /// both the setting and the triggers have been read.
    private var headerLine: String? {
        guard triggersRead else { return nil }
        switch trustReadState {
        case .loading: return nil
        case .unavailable: return "I couldn't read these settings just now."
        case .loaded(enabled: false): return "I keep quiet until you ask."
        case .loaded(enabled: true):
            guard !triggers.isEmpty else { return "I bring you things without being asked." }
            let on = triggers.filter(\.enabled).count
            return "I bring you things without being asked; \(on) of \(triggers.count) kinds are on."
        }
    }

    /// Same controls, same writes: the master switch and every trigger in ONE
    /// group card, each row a title, a detail and the haze switch; the history
    /// is a quiet line under it.
    private var aliveContent: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                AliveGroupCard {
                    InboxAliveSwitchRow(
                        title: "Let \(appModel.agentDisplayName) raise things unasked",
                        detail: "When this is on, \(appModel.agentDisplayName) can share observations, file changes, finished Desk tasks and check-ins without being asked.",
                        isOn: masterEnabled,
                        isSaving: isSaving
                    )
                    .disabled(masterToggleDisabled)

                    switch triggersPanelGate {
                    case .enabled:
                        VStack(alignment: .leading, spacing: 0) {
                            PageReadStatus(
                                isReading: !triggersRead || isLoading,
                                text: !triggersRead ? "Reading notification options…"
                                    : isLoading ? "Refreshing notification options…"
                                    : triggersReadFailed ? "I couldn't read notification options. Try again."
                                    : triggers.isEmpty ? "No notification options configured yet." : nil
                            )
                            ForEach(triggers) { trigger in
                                Rectangle()
                                    .fill(AlivePalette.divider)
                                    .frame(height: 1)
                                    .padding(.vertical, AliveMetrics.rowInsetV)
                                TriggerRowView(
                                    trigger: trigger,
                                    onToggle: { enabled in await setTriggerEnabled(trigger.name, enabled: enabled) }
                                )
                            }
                        }
                        .id("notification-options")
                        .transition(NativeAgentMotion.arrivalFade)
                    case .disabled:
                        EmptyView()
                    case .loading:
                        Text("Checking whether notifications from \(appModel.agentDisplayName) are on…")
                            .font(.system(size: 13))
                            .foregroundStyle(NativeAgentShell.secondary)
                    case .unavailable(let detail):
                        VStack(alignment: .leading, spacing: 3) {
                            Text("The notification setting could not be read. Notification options are unavailable until it can be loaded.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(NativeAgentShell.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(detail)
                                .font(.system(size: 13))
                                .foregroundStyle(NativeAgentShell.secondary)
                                .lineLimit(3)
                        }
                    }
                }

                if !statuses.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(statuses, id: \.source) { entry in
                            Text(entry.status.text)
                                .font(ShellType.label)
                                .foregroundStyle(statusColor(entry.status.tone))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Button {
                    Task { await openInboxHistory() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Notification history")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(ShellType.captionSemibold)
                    }
                    .foregroundStyle(NativeAgentShell.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appModel.engine.inbox.isLoading)
            }
        }
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Data loading ──────────────────────────────────────────────────────

    private var triggersReadFailed: Bool {
        appModel.engine.inbox.triggerError != nil
    }

    func saveMaster(enabled: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appModel.engine.trust.setInboxEnabled(enabled)
            statusSlot.record(InboxPolicyStatus(.masterSaved(enabled: enabled)), from: .masterToggle)
        } catch {
            statusSlot.record(InboxPolicyStatus(.masterSaveFailed(UserFacingError.message(error, action: "turn the inbox on or off"))), from: .masterToggle)
        }
    }

    // PATCH-2026-05-07: surface-load-errors Stop swallowing failures with
    // try?. Toggling a trigger silently failed before; user
    // had no idea their click did nothing.
    // ui-honesty 2026-06-10: returns success so the row can revert its local
    // toggle when the server write fails — the switch used to stay flipped
    // in a position the server never accepted.
    func setTriggerEnabled(_ name: String, enabled: Bool) async -> Bool {
        do {
            try await appModel.engine.inbox.setTrigger(name, enabled: enabled)
            statusSlot.record(InboxPolicyStatus(.triggerSaved(name: name, enabled: enabled)), from: .triggerToggle(name))
            return true
        } catch {
            statusSlot.record(InboxPolicyStatus(.triggerSaveFailed(UserFacingError.message(error, action: "change that trigger"))), from: .triggerToggle(name))
            return false
        }
    }

    private func openInboxHistory() async {
        await inboxHistoryRoute.open(inbox: appModel.engine.inbox)
    }

    private func refreshInboxHistory() async {
        await appModel.engine.inbox.refresh()
    }

    private func statusColor(_ tone: InboxPolicyStatus.Tone) -> Color {
        switch tone {
        case .success: return NativeAgentShell.calm
        case .failure: return NativeAgentShell.trouble
        }
    }
}

// MARK: - Inbox history

/// Read-only history projection used only by Inbox Policy. It intentionally
/// does not mount `InboxView`: there is one source of inbox rows, the shared
/// InboxFacade revision, and this sheet merely renders it.
struct InboxHistoryView: View {
    @Environment(AppModel.self) private var appModel

    let onRefresh: @MainActor () async -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let errorText = appModel.engine.inbox.refreshErrorText {
                    Text(errorText)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }

                switch InboxHistoryPresentation.content(items: appModel.engine.inbox.items) {
                case .empty where appModel.engine.inbox.isLoading:
                    ProgressView("Loading notification history…")
                        .font(ShellType.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    Text(appModel.engine.inbox.refreshErrorText == nil
                         ? "No notification history yet. Cards appear here after the agent records an observation, a file change or a finished Desk task."
                         : "Notification history is unavailable. Try refreshing.")
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
            .navigationTitle("Notification history")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(appModel.engine.inbox.isLoading)
                    .accessibilityLabel("Refresh notification history")
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

    var isSaving: Bool { latestRequestID != nil }

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
    let trigger: TriggerConfig
    // ui-honesty 2026-06-10: async + Bool result so the row can revert the
    // visual toggle when the server write fails.
    let onToggle: (Bool) async -> Bool

    @State private var toggleState: InboxTriggerToggleStateMachine

    init(trigger: TriggerConfig, onToggle: @escaping (Bool) async -> Bool) {
        self.trigger = trigger
        self.onToggle = onToggle
        self._toggleState = State(initialValue: InboxTriggerToggleStateMachine(serverEnabled: trigger.enabled))
    }

    /// Title, detail, haze switch. No glyph, and no pulsing dot: the switch
    /// already says on, and nothing here animates per frame.
    var body: some View {
        InboxAliveSwitchRow(
            title: trigger.displayName,
            detail: trigger.description,
            isOn: Binding(
                get: { toggleState.visualEnabled },
                set: { requestToggle($0) }
            ),
            isSaving: toggleState.isSaving)
        .disabled(toggleState.isSaving)
        .onChange(of: trigger.enabled) { _, val in
            toggleState.synchronizeServer(enabled: val)
        }
    }

    private func requestToggle(_ enabled: Bool) {
        guard !toggleState.isSaving else { return }
        let request = toggleState.userToggled(to: enabled)
        Task {
            let accepted = await onToggle(request.requestedEnabled)
            toggleState.completed(request, accepted: accepted)
        }
    }
}

/// One row of the alive settings card: a title, a detail under it, and the
/// haze switch on the right. The switch carries the title as its label, so
/// it names itself the way the labelled toggle it replaces did.
private struct InboxAliveSwitchRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    var isSaving = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if isSaving { ProgressView().controlSize(.small) }
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
        }
    }
}
