import NativeAgentShared
import SwiftUI
import Observation
import NativeAgentCore
import NotificationInbox
import TrustCenter
import TriggerScheduler
import PersistenceCore
// Blueprint: | `InboxSettingsView.swift` | Notification preferences, trigger labels and shared history navigation over InboxFacade's ForPerson reading |

@MainActor @Observable final class InboxHistoryNavigation {
    static let shared = InboxHistoryNavigation()
    var isPresented = false
}

extension TriggerConfig: @retroactive Identifiable {
    public var id: String { name }

    var displayName: String {
        switch name {
        case "idle_checkin": return "Idle check-in"
        case "morning_brief": return "Morning brief"
        default:
            let words = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            guard let first = words.first else { return name }
            return String(first).uppercased() + words.dropFirst()
        }
    }
}

/// Severity belongs to the operation; user-facing status text is not an error protocol.
struct InboxPolicyStatus: Equatable {
    enum Tone: Equatable {
        case success
        case failure
    }

    let text: String
    let tone: Tone
}

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

/// Render cards directly from the engine revision so history cannot drift in a second collection.
enum InboxHistoryPresentation {
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

/// False is a policy value only after a successful read; unread authority must not hide triggers as though intentionally disabled.
enum InboxPolicyTrustReadState: Equatable {
    case loading
    case loaded(enabled: Bool)
    case unavailable(String)
}

struct InboxSettingsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isSaving = false
    @State private var statusSlot = InboxPolicyStatusSlot()
    @State private var history = InboxHistoryNavigation.shared
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
            displayed.record(InboxPolicyStatus(text: UserFacingError.message(error, action: "load inbox settings"), tone: .failure), from: .settingsRead)
        }
        if let error = appModel.engine.inbox.triggerError {
            displayed.record(InboxPolicyStatus(text: error, tone: .failure), from: .triggersRead)
        }
        return displayed.entries
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
            async let notes: Void = appModel.engine.inbox.observe()
            _ = await (policy, triggers, notes)
        }
        .sheet(isPresented: $history.isPresented) {
            InboxHistoryView(
                onRefresh: { await refreshInboxHistory() },
                onClose: { history.isPresented = false }
            )
            .task { await refreshInboxHistory() }
            .environment(appModel)
            .presentationDetents([.large])
        }
    }


    /// Keep the header unknown until both policy and triggers are read; settings are not pending work.
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

    private var aliveContent: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                AliveGroupCard {
                    InboxAliveSwitchRow(
                        title: "Let \(appModel.agentDisplayName) raise things unasked",
                        detail: """
                            When this is on, \(appModel.agentDisplayName) can share observations, file changes, finished Desk tasks and check-ins without \
                            being asked.
                            """,
                        isOn: masterEnabled,
                        isSaving: isSaving
                    )
                    .disabled(masterToggleDisabled)

                    switch trustReadState {
                    case .loaded(enabled: true):
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
                    case .loaded(enabled: false):
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


    private var triggersReadFailed: Bool {
        appModel.engine.inbox.triggerError != nil
    }

    func saveMaster(enabled: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appModel.engine.trust.setInboxEnabled(enabled)
            statusSlot.record(InboxPolicyStatus(text: enabled ? "Inbox enabled." : "Inbox disabled.", tone: .success), from: .masterToggle)
        } catch {
            statusSlot.record(InboxPolicyStatus(text: UserFacingError.message(error, action: "turn the inbox on or off"), tone: .failure), from: .masterToggle)
        }
    }

    func setTriggerEnabled(_ name: String, enabled: Bool) async {
        do {
            try await appModel.engine.inbox.setTrigger(name, enabled: enabled)
            statusSlot.record(InboxPolicyStatus(text: "\(name) \(enabled ? "enabled" : "disabled").", tone: .success), from: .triggerToggle(name))
        } catch {
            statusSlot.record(
                InboxPolicyStatus(text: UserFacingError.message(error, action: "change that trigger"), tone: .failure),
                from: .triggerToggle(name))
        }
    }

    private func openInboxHistory() async {
        history.isPresented = true
        await refreshInboxHistory()
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

/// Preferences history reads the shared InboxFacade revision.
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

                if appModel.engine.inbox.items.isEmpty && appModel.engine.inbox.isLoading {
                    ProgressView("Loading notification history…")
                        .font(ShellType.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.engine.inbox.items.isEmpty {
                    Text(appModel.engine.inbox.refreshErrorText == nil
                         ? "No notification history yet. Cards appear here after the agent records an observation, a file change or a finished Desk task."
                         : "Notification history is unavailable. Try refreshing.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(appModel.engine.inbox.items) { item in
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
            // Unread notes use the waiting colour; read notes stay quiet.
            Text(InboxHistoryPresentation.statusLabel(for: item))
                .font(ShellType.captionMedium)
                .foregroundStyle(item.isUnread ? NativeAgentShell.needsYou : NativeAgentShell.secondary)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - TriggerRowView

struct TriggerRowView: View {
    let trigger: TriggerConfig
    let onToggle: (Bool) async -> Void

    @State private var pendingEnabled: Bool?

    var body: some View {
        InboxAliveSwitchRow(
            title: trigger.displayName,
            detail: trigger.description,
            isOn: Binding(
                get: { pendingEnabled ?? trigger.enabled },
                set: { requestToggle($0) }
            ),
            isSaving: pendingEnabled != nil)
        .disabled(pendingEnabled != nil)
    }

    private func requestToggle(_ enabled: Bool) {
        guard pendingEnabled == nil else { return }
        pendingEnabled = enabled
        Task {
            await onToggle(enabled)
            // Publish the inbox owner's committed state, including writes made elsewhere while the request waited.
            pendingEnabled = nil
        }
    }
}

/// Give the switch its row title as an accessible label.
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
