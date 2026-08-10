// PATCH-2026-05-07: proactive-inbox-1 InboxSettingsView — trigger config + master enable
import SwiftUI

struct InboxSettingsView: View {
    @Environment(AppModel.self) private var appModel

    @State private var masterEnabled: Bool = false
    @State private var suppressMasterSave = false
    @State private var triggers: [InboxTriggerConfig] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var statusText: String?
    @State private var showInboxHistory = false

    // File watcher watched paths (comma-separated editing)
    @State private var watchedPaths: String = ""

    // R22: source the client from AppModel's canonical `client` (already carries
    // nativeBaseURL + the shared runtime) instead of constructing inline.
    private var client: NativeClient { appModel.client }
    private var agentDisplayName: String {
        let profileName = appModel.personality?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chatName = appModel.chatPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profileName.isEmpty && profileName != "NativeAgent" { return profileName }
        if !chatName.isEmpty { return canonicalAgentDisplayName(chatName, fallback: "the agent") }
        return "the agent"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ── Master toggle ──────────────────────────────────────────
                NativePanel(title: "Proactive Inbox", systemImage: "tray.and.arrow.down") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Proactive Inbox", isOn: $masterEnabled)
                            .disabled(isSaving)
                            .onChange(of: masterEnabled) { _, val in
                                if suppressMasterSave {
                                    suppressMasterSave = false
                                    return
                                }
                                Task { await saveMaster(enabled: val) }
                            }

                        Text("When enabled, \(agentDisplayName) can surface observations, file changes, completed Desk tasks, and check-ins without being asked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("View Inbox History") {
                                showInboxHistory = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/inbox/self_test
                        }

                        if let status = statusText {
                            // ui-honesty 2026-06-10: the old `contains("ok")`
                            // heuristic painted every success orange (none of
                            // the success strings contain "ok"). Key off the
                            // error marker instead — all failure paths here
                            // say "fail(ed)".
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status.localizedCaseInsensitiveContains("fail") ? .orange : .green)
                        }
                    }
                }

                // ── Triggers ───────────────────────────────────────────────
                if masterEnabled {
                    NativePanel(title: "Triggers", systemImage: "bolt") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(triggers) { trigger in
                                TriggerRowView(
                                    trigger: trigger,
                                    watchedPaths: trigger.name == "file_watch" ? $watchedPaths : .constant(""),
                                    onToggle: { enabled in await setTriggerEnabled(trigger.name, enabled: enabled) },
                                    onFireNow: { Task { await fireTriggerNow(trigger) } }
                                )
                                if trigger != triggers.last { Divider() }
                            }
                        }
                    }

                    // File watcher path editor
                    if triggers.first(where: { $0.name == "file_watch" })?.enabled == true {
                        NativePanel(title: "Watched Paths", systemImage: "folder.badge.gearshape") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Enter one path per line (e.g. ~/Projects/NativeAgent/Modules/NativeAgentCore/Sources/)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $watchedPaths)
                                    .font(.caption.monospaced())
                                    .frame(minHeight: 80)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                Button("Save Paths") {
                                    Task { await saveWatchedPaths() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        // ui-taste-sweep 2026-06-07: was falling back to the bundle name.
        .navigationTitle("Inbox Policy")
        .task { await load() }
        .sheet(isPresented: $showInboxHistory) {
            NavigationStack {
                InboxView()
                    .environment(appModel)
                    .navigationTitle("Inbox History")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { showInboxHistory = false }
                        }
                    }
            }
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
            statusText = "Failed to load inbox settings: \(error.localizedDescription)"
        }
        // Load triggers
        // U5 W-A item 1 (:151): the trigger read was swallowed into [] —
        // a failed read rendered as "no triggers configured" with no
        // signal. Keep last-known rows and surface the real error in the
        // panel's status line instead.
        do {
            triggers = try await client.getInboxTriggers()
        } catch {
            statusText = "Failed to load triggers: \(error.localizedDescription)"
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
        do {
            _ = try await client.postRaw("/v1/trust", body: [
                "inboxPolicy": ["enabled": enabled]
            ])
            statusText = enabled ? "Inbox enabled." : "Inbox disabled."
        } catch {
            statusText = "Failed: \(error.localizedDescription)"
            suppressMasterSave = true
            masterEnabled = !enabled
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
            statusText = "\(name) \(enabled ? "enabled" : "disabled")."
            await load()
            return true
        } catch {
            statusText = "Toggle failed: \(error.localizedDescription)"
            return false
        }
    }

    func fireTriggerNow(_ trigger: InboxTriggerConfig) async {
        guard trigger.supportsRealManualFire else {
            statusText = "Test is unavailable until this trigger can produce real evidence-backed content."
            return
        }
        do {
            // Post-rebuild (2026-07-09): time/idle fires carry REAL content now —
            // the label follows the returned truth instead of assuming stub.
            let fired = try await client.inboxTriggerFireNow(trigger.name, stub: true)
            let head = (fired.itemId ?? "").prefix(8)
            let label = fired.wasStub ? "Fired (stub)" : "Fired"
            statusText = head.isEmpty ? "\(label)." : "\(label) — item: \(head)..."
        } catch {
            statusText = "Fire failed: \(error.localizedDescription)"
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
            statusText = "Paths saved (\(paths.count) entries)."
        } catch {
            statusText = "Paths save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - TriggerRowView

struct TriggerRowView: View {
    let trigger: InboxTriggerConfig
    @Binding var watchedPaths: String
    // ui-honesty 2026-06-10: async + Bool result so the row can revert the
    // visual toggle when the server write fails.
    let onToggle: (Bool) async -> Bool
    let onFireNow: () -> Void

    @State private var isEnabled: Bool
    @State private var suppressNextToggle = false

    init(trigger: InboxTriggerConfig, watchedPaths: Binding<String>, onToggle: @escaping (Bool) async -> Bool, onFireNow: @escaping () -> Void) {
        self.trigger = trigger
        self._watchedPaths = watchedPaths
        self.onToggle = onToggle
        self.onFireNow = onFireNow
        self._isEnabled = State(initialValue: trigger.enabled)
    }

    // PATCH-2026-05-07: polish-InboxSettingsView PulsingDot for enabled triggers
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: trigger.systemImage)
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(width: 22)
                if isEnabled {
                    PulsingDot(color: .green, size: 6)
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.displayName)
                    .font(NativeAgentFont.body.weight(.medium))
                if let desc = trigger.description {
                    Text(desc)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Test") { onFireNow() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.caption)
                .disabled(!trigger.supportsRealManualFire)
                .help(trigger.supportsRealManualFire
                    ? "Create one real trigger item now"
                    : "Unavailable until this trigger has real evidence-backed content")

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { _, val in
                    if suppressNextToggle {
                        suppressNextToggle = false
                        return
                    }
                    Task {
                        let ok = await onToggle(val)
                        if !ok {
                            // ui-honesty 2026-06-10: server write failed —
                            // revert the switch instead of leaving it in a
                            // position the server never accepted. Only arm
                            // the suppression when the assignment will
                            // actually fire onChange: if the user already
                            // toggled back while the request was in flight,
                            // a no-op assignment would leave the suppression
                            // stuck and swallow their NEXT real toggle
                            // (gpt-5.5 review).
                            if isEnabled == val {
                                suppressNextToggle = true
                                isEnabled = !val
                            }
                        }
                    }
                }
        }
        .onChange(of: trigger.enabled) { _, val in
            if isEnabled != val {
                suppressNextToggle = true
                isEnabled = val
            }
        }
    }
}
