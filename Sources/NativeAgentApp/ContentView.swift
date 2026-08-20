import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// PATCH-2026-05-06: ui-consolidation — default selection chat, 5 visible + Advanced disclosure sidebar
// PATCH-2026-05-10: startup-tour-gate — tour is manual only; startup must not block chat.
struct ContentView: View {
    // Liquid Feel W4: page-switch transition respects Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selection") private var selectionRaw = SidebarItem.chat.rawValue
    @SceneStorage("skillsToolsSection") private var skillsToolsSectionRaw = SkillsToolsSection.skills.rawValue
    @AppStorage("sidebarShowAdvanced") private var showAdvanced = false
    // B2.2: developer/internal surfaces (Turn Inspector, MCP, Cognition, …)
    // render only when this UI-visibility preference is on. Fresh installs
    // default OFF so a stranger cannot reach raw internals in one click.
    // Surfaced as one toggle in Settings; NOT coupled to Trust's developerMode.
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false
    @AppStorage("nativeagent.showTour") private var showTour = false
    @State private var didCheckFirstRunOnboarding = false
    @State private var showFirstRunOnboarding = false
    @State private var showingDoctor = false
    // PATCH-2026-06-06: command-palette — Cmd+K modal sheet flag.
    @State private var showCommandPalette = false
    // B2.3 follow-up: Desk's New Task sheet is presented HERE, not in
    // DeskHubView — a sheet attached to NavigationSplitView detail content
    // presents only once per app run on macOS (the bridge never releases the
    // presentation seat after dismiss). ContentView-level sheets re-present
    // reliably (the command palette proves it), so the toolbar button posts
    // .newWorkshopTaskRequest and the sheet lives on this attachment point.
    @State private var showNewWorkshopTask = false
    @State private var navigationMountID: UUID?

    private var selection: Binding<SidebarItem> {
        Binding {
            // Normalize on read AND write: a saved selection or command route
            // naming a retired/alias tab ("Panels", "Self-Improvement") must
            // land on its canonical home — otherwise no sidebar row shows
            // selected and refreshForSidebarItem hits a stale branch
            // (gpt-5.5 review MED, 2026-07-03 dead-weight sweep).
            (SidebarItem(rawValue: selectionRaw) ?? .chat).normalized
        } set: {
            selectionRaw = $0.normalized.rawValue
        }
    }

    private var skillsToolsSection: Binding<SkillsToolsSection> {
        Binding {
            SkillsToolsSection(rawValue: skillsToolsSectionRaw) ?? .skills
        } set: {
            skillsToolsSectionRaw = $0.rawValue
        }
    }

    private var activeContentItem: SidebarItem {
        let selected = selection.wrappedValue.normalized
        if selected == .skills, skillsToolsSection.wrappedValue == .tools {
            return .tools
        }
        return selected
    }

    // PATCH-2026-05-10: sidebar-flatten — pulled directly from SidebarItem
    // so order/membership is defined in one place (Models.swift).
    private var primaryItems: [SidebarItem] { SidebarItem.primaryItems }
    // B2.2: the Advanced disclosure shows consumer-only rows by default and the
    // full set (incl. developer surfaces) once showDeveloperSurfaces is on.
    private var advancedItems: [SidebarItem] {
        SidebarItem.visibleAdvancedItems(developerSurfacesEnabled: showDeveloperSurfaces)
    }

    var body: some View {
        // Render-cost audit: make the root's invalidation rate a NUMBER, not an
        // argument. Gated behind the existing `NATIVE_AGENT_RENDER_AUDIT=1`
        // env check inside `RenderAudit` — when it is off, `bump` reads one
        // already-computed `Bool` and returns, so this costs nothing in a
        // normal run. This is the counter that proves F13 (the sidebar badge
        // scalar) actually cut root re-evaluations.
        RenderAudit.bump("contentview.body")
        return ZStack {
            NavigationSplitView {
                // S.5: when onboarding overlay is shown, hide the nav content from accessibility
                // (OnboardingTourOverlay already carries .isModal; this prevents VoiceOver reaching behind it)
                // 2026-06-06 sidebar-fix v6: restored to the standard
                // List(selection:)+sidebar pattern that renders correctly.
                // .scrollDisabled broke rendering; manual ScrollView+VStack
                // broke rendering. The executions-click scroll-shift is a
                // known issue tracked separately — at least the sidebar
                // works again. isSelected is still passed for the orange
                // highlight (since List's own selection styling differs).
                List(selection: selection) {
                    Section {
                        ForEach(primaryItems) { item in
                            SidebarItemLabel(
                                item: item,
                                badgeCount: sidebarBadgeCount(for: item),
                                badgeIsStale: item == .activity && appModel.sidebarActivityRefreshStatus?.isStale == true
                            )
                            .tag(item)
                        }
                    }

                    Section {
                        DisclosureGroup(isExpanded: $showAdvanced) {
                            ForEach(advancedItems) { item in
                                SidebarItemLabel(
                                    item: item,
                                    badgeCount: sidebarBadgeCount(for: item),
                                    badgeIsStale: item == .activity && appModel.sidebarActivityRefreshStatus?.isStale == true
                                )
                                .tag(item)
                            }
                        } label: {
                            Label("Advanced", systemImage: "chevron.right.2")
                                .foregroundStyle(.secondary)
                                .togglesDisclosure($showAdvanced)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .naInteractive(radius: NativeAgentRadius.control)
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("NativeAgent")
                // Keep the Activity badge honest without pulling the full
                // Activity surface while another tab is open. The full
                // ActivityView owns detailed proposal/improvement refreshes.
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    let root = PersistenceCore.defaultDataRoot()
                    let memoryDatabase = root
                        .appendingPathComponent("memory", isDirectory: true)
                        .appendingPathComponent("memory.sqlite")
                    await ViewFileRefreshTask.run(paths: [
                        root.appendingPathComponent("workflows/approvals/requests.json"),
                        root.appendingPathComponent("notifications/inbox.jsonl"),
                        memoryDatabase,
                        URL(fileURLWithPath: memoryDatabase.path + "-wal"),
                    ]) {
                        await appModel.refreshSidebarActivityBadge()
                    }
                }
            } detail: {
                VStack(spacing: 0) {
                // M12 (gpt-5.5 review, 2026-07-09): the stale annotation renders
                // for EVERY panel, in one place. `refreshForSidebarItem` records
                // per-endpoint failures for whichever panel it refreshed; a panel
                // whose data is carried over from an earlier refresh says so at
                // the top instead of impersonating live state. Chat renders its
                // own copy inside its layout, so it is skipped here.
                if activeContentItem != .chat,
                   let notice = appModel.panelStaleNotice(for: activeContentItem) {
                    StalePanelNotice(text: notice)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                Group {
                    // PATCH-2026-05-19: ui-pull-together — primary sidebar
                    // stays compact. Advanced/routed child surfaces remain
                    // reachable without competing as always-visible tabs.
                    switch selection.wrappedValue.normalized {
                    // ── Primary ───────────────────────────────────────────────
                    case .chat: ChatView()
                    case .activity: ActivityView()
                    case .memories: MemoryView()
                    case .skills: SkillsToolsView(selection: skillsToolsSection)
                    case .desk: DeskHubView()
                    case .personality: PersonalityView()
                    case .connectors: ConnectorsView()
                    case .trust: TrustCenterView()
                    case .providers: ProviderSettingsView()
                    case .macIntegration: MacIntegrationView()
                    case .settings: SlimSettingsView()
                    // ── Advanced / routed child surfaces ──────────────────────
                    case .capabilities: CapabilitiesView()
                    case .knowledge: KnowledgeGraphView()
                    case .dreams: DreamsView()
                    // B2.4/B2.6 (fence-B handoff): the Observatory's surviving
                    // observational core and the Inspector now LIVE as
                    // Diagnostics segments; these routes render the segment
                    // directly so deep links keep landing on the same content.
                    // Reviewer note (accepted): a deep link here shows content
                    // with no sidebar row highlighted — deliberately the SAME
                    // behavior as any developer-gated tab reached by deep link
                    // with the gate off (pinned in b2-A's render states). One
                    // contract for all route-only surfaces.
                    case .cognition: DiagnosticsView(initialMode: .cognition)
                    case .inspector: DiagnosticsView(initialMode: .inspector)
                    case .diagnostics: DiagnosticsView()
                    case .telegram: TelegramView()
                    case .inboxPolicy: InboxSettingsView()
                    case .mcp: MCPHubView()
                    // ── Legacy aliases (unreachable post-normalize, kept exhaustive) ───
                    // .autoImprovement → .activity and .panels → .diagnostics
                    // joined this list in the 2026-07-03 dead-weight sweep.
                    // .command/.workshop → .desk keep retired routes and saved state working.
                    case .memory, .settingsHub, .approvals, .workshop, .legacyWorkshop, .work, .skillLifecycle, .tools,
                         .autoImprovement, .panels, .command:
                        EmptyView()  // unreachable: .normalized routes these above
                    }
                }
                // Liquid Feel W4: pages settle in instead of hard-cutting.
                // id() gives each page distinct identity so the transition
                // fires on switch; state within a page is untouched while
                // its selection is stable.
                .id(selection.wrappedValue.normalized)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        )
                )
                .animation(
                    NativeAgentMotion.respecting(NativeAgentMotion.gentle, reduceMotion: reduceMotion),
                    value: selection.wrappedValue.normalized
                )
                .task(id: "\(selectionRaw)|\(skillsToolsSectionRaw)") {
                    let item = activeContentItem
                    if item.normalized == .activity {
                        await appModel.refreshSidebarActivityBadge()
                    } else {
                        await appModel.refreshForSidebarItem(item)
                    }
                }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HealthPill(showingDoctor: $showingDoctor)
                }
            }
            // S.5: hide NavigationSplitView from VoiceOver while onboarding overlay is active
            .accessibilityHidden(showTour || showFirstRunOnboarding)

            // PATCH-2026-05-10: startup-tour-gate — only show when explicitly replayed from About.
            if showTour {
                OnboardingTourOverlay(
                    onComplete: {
                        showTour = false
                    },
                    onSelectTab: { item in
                        if item.isAdvanced {
                            showAdvanced = true
                        }
                        selectionRaw = item.rawValue
                    }
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            SystemToastBar(center: appModel.systemToasts)
        }
        .animation(.easeInOut(duration: 0.35), value: showTour)
        .onAppear {
            if selectionRaw == SidebarItem.tools.rawValue {
                skillsToolsSectionRaw = SkillsToolsSection.tools.rawValue
                selectionRaw = SidebarItem.skills.rawValue
            }
            guard navigationMountID == nil else { return }
            navigationMountID = NativeAgentAppCoordinator.shared.mountMainScene { destination in
                applyNavigationDestination(destination)
            }
        }
        .onDisappear {
            guard let navigationMountID else { return }
            NativeAgentAppCoordinator.shared.unmountMainScene(id: navigationMountID)
            self.navigationMountID = nil
        }
        .task {
            await checkFirstRunOnboardingIfNeeded()
        }
        // All Mac projections of chat sessions share AppModel's one canonical
        // list: Chat, detached-window titles, Status, command search, and the
        // optional project/session lineage page. Keep it current from the
        // canonical index while the app scene is active. This watcher is
        // vnode-driven, burst-coalesced, and performs no idle polling; the
        // lightweight refresh also suppresses equal observed writes.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let sessionIndexPath = PersistenceCore.defaultDataRoot()
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("sessions.json")
            await ViewFileRefreshTask.run(
                paths: [sessionIndexPath],
                debounceDelay: .milliseconds(150)
            ) {
                await appModel.refreshChatSessionIndex()
            }
        }
        .sheet(isPresented: $showFirstRunOnboarding) {
            OnboardingWizard {
                showFirstRunOnboarding = false
                selectionRaw = SidebarItem.chat.rawValue
                Task {
                    await appModel.refreshForSidebarItem(.chat)
                    // Fire the first-run welcome right when onboarding finishes and
                    // chat is loaded — the most reliable trigger (ChatView's .task
                    // is timing-fragile after a sheet dismiss).
                    await appModel.maybeSendFirstRunGreeting()
                }
            }
            .interactiveDismissDisabled(true)
        }
        // PATCH-2026-06-06: command-palette — Cmd+K modal.
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(isPresented: $showCommandPalette)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
            showCommandPalette = true
        }
        .sheet(isPresented: $showNewWorkshopTask) {
            NewWorkshopTaskSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkshopTaskRequest)) { _ in
            showNewWorkshopTask = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .iCloudInboxDidProcess)) { _ in
            Task {
                if selectionRaw == SidebarItem.activity.rawValue {
                    await appModel.refreshForSidebarItem(.activity)
                } else {
                    await appModel.refreshSidebarActivityBadge()
                }
            }
        }
        .onChange(of: showingDoctor) { _, new in
            if new {
                showAdvanced = true
                selectionRaw = SidebarItem.diagnostics.rawValue
                showingDoctor = false
            }
        }
        // S.6: wire "Build a Skill" button — switch to Chat tab and prefill draft
        .onReceive(NotificationCenter.default.publisher(for: .skillBuildRequest)) { note in
            selectionRaw = SidebarItem.chat.rawValue
            let starter = (note.object as? String) ?? "Create a skill from this conversation:"
            if appModel.activeChatSessionId.isEmpty { return }
            // Only prefill if the draft is currently empty. H5: go through
            // injectChatDraft so ChatView's view-local composer state picks the
            // starter up — a bare `chatDrafts` write is invisible to it now.
            if appModel.chatDrafts[appModel.activeChatSessionId]?.isEmpty != false {
                appModel.injectChatDraft(starter, sessionId: appModel.activeChatSessionId)
            }
        }
        // Inbox "Act" on a chat-shaped item — same shape as skillBuildRequest
        // above: switch to Chat, prefill only when the composer is empty so a
        // half-typed message is never clobbered.
        .onReceive(NotificationCenter.default.publisher(for: .openChatDraftRequest)) { note in
            selectionRaw = SidebarItem.chat.rawValue
            guard let draft = note.object as? String, !draft.isEmpty else { return }
            if appModel.activeChatSessionId.isEmpty { return }
            if appModel.chatDrafts[appModel.activeChatSessionId]?.isEmpty != false {
                appModel.injectChatDraft(draft, sessionId: appModel.activeChatSessionId)
            }
        }
        // L5 G6 — the inversion. Her message is already persisted (the act
        // handler posted it through the proactive-speech seam before posting
        // this). All that's left is to land User in the session and pull the new
        // row in. NOTHING is written to the composer: an empty composer with
        // her message above it is the whole point of the change.
        .onReceive(NotificationCenter.default.publisher(for: .openSpokenChatRequest)) { _ in
            selectionRaw = SidebarItem.chat.rawValue
            let sessionId = appModel.activeChatSessionId
            guard !sessionId.isEmpty else { return }
            Task { await appModel.refreshChatMessagesAfterTurn(sessionId: sessionId) }
        }
    }

    @MainActor
    private func checkFirstRunOnboardingIfNeeded() async {
        guard !didCheckFirstRunOnboarding else { return }
        didCheckFirstRunOnboarding = true
        // WAVE 15 (2026-06-01): runtime must be plumbed — /v1/onboarding/start is retired,
        // and startOnboarding() now throws DaemonError.swiftOnlyRoute when the gate sees no runtime.
        // R22: AppModel's canonical `client` already carries the shared runtime.
        // ONBOARDING-2026-05-26: extended retry budget for cold first launch.
        // The previous budget (8 × 500ms = 4s) was below the bundled-Python
        // first-cold-launch daemon ready time (5–10s + indexing), so the
        // wizard never fired on a fresh DMG install — the user landed in the
        // main UI with an uninitialized persona. 60 × 500ms = 30s is enough
        // for first-cold-launch on slower Macs while still timing out fast
        // enough that a stuck daemon doesn't block the UI forever.
        for attempt in 0..<60 {
            if Task.isCancelled { return }
            do {
                let start = try await appModel.startOnboarding()
                if start.pendingRecovery == true || start.resetRequired == true {
                    selectionRaw = SidebarItem.chat.rawValue
                    showTour = false
                    showFirstRunOnboarding = true
                    return
                }
                guard !start.hasExisting else { return }
                selectionRaw = SidebarItem.chat.rawValue
                showTour = false
                showFirstRunOnboarding = true
                return
            } catch {
                if attempt == 0 {
                    await appModel.loadHealthCard(includeApprovals: false)
                }
                if attempt == 59 {
                    // A malformed or root-mismatched pending transaction is a
                    // fail-closed onboarding state, not permission to hide the
                    // wizard forever. The wizard exposes the exact error and an
                    // explicit backup-preserving reset; it never auto-deletes.
                    selectionRaw = SidebarItem.chat.rawValue
                    showTour = false
                    showFirstRunOnboarding = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // PATCH-2026-06-06: command-palette — sidebar badge counts for the
    // "needs your eyes" tabs. .activity stays the combined inbox/approvals
    // queue; .executions surfaces currently-running executions. Skills/MCP
    // have no pending count yet, so they return 0.
    private func sidebarBadgeCount(for item: SidebarItem) -> Int {
        switch item {
        case .activity:
            return appModel.pendingActivityCount
        case .desk:
            return 0
        default:
            return 0
        }
    }

    private func applyNavigationDestination(_ destination: NativeAgentNavigationDestination) {
        switch destination {
        case .activity(let section):
            applyActivitySection(section)
        case .skillsTools(let section):
            applySkillsToolsSection(section)
        case .sidebar(.approvals):
            applyActivitySection(.approvals)
        case .sidebar(.autoImprovement):
            applyActivitySection(.selfImprovement)
        case .sidebar(let item):
            if item == .tools {
                applySkillsToolsSection(.tools)
                return
            }
            let target = item.normalized
            if target == .skills {
                applySkillsToolsSection(.skills)
                return
            }
            if target == .activity {
                applyActivityRoot()
                return
            }
            if target.isAdvanced {
                showAdvanced = true
            }
            selectionRaw = target.rawValue
        }
    }

    private func openActivitySection(_ section: ActivitySection) {
        NativeAgentAppCoordinator.shared.request(.activity(section))
    }

    private func openActivityRoot() {
        NativeAgentAppCoordinator.shared.request(.sidebar(.activity))
    }

    private func applyActivitySection(_ section: ActivitySection) {
        appModel.pendingActivitySectionRaw = section.rawValue
        selectionRaw = SidebarItem.activity.rawValue
        NotificationCenter.default.post(
            name: .openActivitySectionRequest,
            object: section.rawValue
        )
    }

    private func applyActivityRoot() {
        appModel.pendingActivitySectionRaw = nil
        selectionRaw = SidebarItem.activity.rawValue
        NotificationCenter.default.post(name: .openActivityRootRequest, object: nil)
    }

    private func applySkillsToolsSection(_ section: SkillsToolsSection) {
        skillsToolsSectionRaw = section.rawValue
        selectionRaw = SidebarItem.skills.rawValue
    }
}

private struct SidebarItemLabel: View {
    var item: SidebarItem
    var badgeCount: Int = 0
    var badgeIsStale: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Label(item.displayName, systemImage: item.systemImage)
            Spacer(minLength: 8)
            if badgeCount > 0 {
                Text(badgeIsStale ? "\(badgeCount)?" : "\(badgeCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .help(badgeIsStale ? "Partial or last-known count; one or more Activity sources were unavailable." : "")
            } else if badgeIsStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Activity count is unavailable because the last refresh failed.")
            }
        }
        // Liquid Feel (User 2026-08-17, "the tabs... no love?"): macOS sidebars
        // paint SELECTION natively but never hover — the roll-over feel is
        // ours to add. Rides the label so the native selection tint stays.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .naInteractive(radius: NativeAgentRadius.control)
    }
}


struct NativeRuntimeTile: View {
    var title: String
    var value: String
    var detail: String
    var status: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(NativeAgentTheme.statusColor(status))
                Spacer()
                InlineStatusDot(status: status)
            }
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NativeAgentFont.label)
                Text(detail)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}


struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(title)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 48)
        .padding(NativeAgentSpacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}


struct ActivityRow: View {
    var event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(NativeAgentFont.section)
                    .lineLimit(1)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(UserDisplayFormatters.humanizeISOTimestamp(event.createdAt))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .textSelection(.enabled)
    }

    private var icon: String {
        switch event.kind {
        case "mission": "target"
        case "trust": "lock.shield"
        case "backup": "externaldrive.badge.timemachine"
        case "eval": "checklist"
        case "connector": "point.3.connected.trianglepath.dotted"
        case "chat": "bubble.left.and.bubble.right"
        default: "circle"
        }
    }

    private var color: Color {
        switch event.status {
        case "ok": .green
        case "warn": .orange
        case "fail": .red
        default: .secondary
        }
    }
}

enum NativeScreenCapture {
    enum CaptureError: LocalizedError {
        case permissionRequired
        case noDisplay
        case encodingFailed
        case tooLarge
        // ScreenVision v1 (2026-06-06): preserves the underlying
        // ScreenCaptureKit reason when SwiftNativeScreenVision throws
        // .captureFailed(_). Previously these were collapsed to
        // .encodingFailed, which lost the real cause in the user-facing toast.
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Screen Recording permission is required for NativeAgent. Enable it in System Settings, then restart NativeAgent if macOS asks."
            case .noDisplay:
                return "NativeAgent could not find a display to capture."
            case .encodingFailed:
                return "NativeAgent captured the screen but could not encode it as an image."
            case .tooLarge:
                return "NativeAgent captured the screen, but the image was too large to send."
            case .captureFailed(let reason):
                return "Screen capture failed: \(reason)"
            }
        }
    }

    private static let maxCaptureDimension = 1600
    private static let maxCaptureBytes = 6 * 1024 * 1024

    static func requestAccessIfNeeded() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func captureImageBase64(preferredDisplayID: CGDirectDisplayID? = nil) async throws -> (base64: String, mime: String, name: String, byteSize: Int) {
        // v1 vision pipeline (2026-06-06): the capture itself is delegated to
        // the Swift-native ScreenVision module. The size-cap / re-encode path
        // below stays here because ScreenVision returns raw PNG bytes; the
        // chat surface still wants a JPEG-with-quality-ladder fallback for
        // anything that would exceed `maxCaptureBytes`.
        //
        // NOTE: ScreenVision v1 captures ONLY the primary display, so
        // `preferredDisplayID` is silently ignored in this pass. Multi-display
        // selection is deferred to v2. The parameter is retained with a nil
        // default for source-compatibility with any future caller that hasn't
        // been updated yet; today the composer's `captureScreen()` handler
        // calls this with no argument.
        _ = preferredDisplayID

        let png: Data
        do {
            png = try await SwiftNativeScreenVision().captureScreen()
        } catch let e as ScreenVisionError {
            // Map the ScreenVision error surface back onto the existing
            // CaptureError cases. Preserve the underlying ScreenCaptureKit
            // reason in .captureFailed so the user-facing toast shows the
            // real cause (e.g. "Screen capture failed: SCStream
            // configuration is invalid") instead of a generic encode error.
            switch e {
            case .permissionDenied:
                throw CaptureError.permissionRequired
            case .noDisplay:
                throw CaptureError.noDisplay
            case .captureFailed(let reason):
                throw CaptureError.captureFailed(reason)
            }
        }

        // Decode the PNG back into a CGImage so the existing encodeForChat
        // ladder (JPEG quality fallbacks, then PNG, then tooLarge) can run
        // unchanged.
        guard let provider = CGDataProvider(data: png as CFData),
              let cg = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw CaptureError.encodingFailed
        }
        let encoded = try encodeForChat(cg)
        return (
            encoded.data.base64EncodedString(),
            encoded.mime,
            encoded.name,
            encoded.data.count
        )
    }

    @MainActor
    static func preferredCaptureDisplayID() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return nil
    }

    private static func encodeForChat(_ source: CGImage) throws -> (data: Data, mime: String, name: String) {
        let image = resizedForChat(source)
        let bitmap = NSBitmapImageRep(cgImage: image)
        for quality in [0.78, 0.65, 0.52, 0.40] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= maxCaptureBytes {
                return (jpeg, "image/jpeg", "screen.jpg")
            }
        }
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= maxCaptureBytes {
            return (png, "image/png", "screen.png")
        }
        throw CaptureError.tooLarge
    }

    private static func resizedForChat(_ source: CGImage) -> CGImage {
        let width = source.width
        let height = source.height
        let largest = max(width, height)
        guard largest > maxCaptureDimension else { return source }
        let scale = CGFloat(maxCaptureDimension) / CGFloat(largest)
        let targetWidth = max(1, Int(CGFloat(width) * scale))
        let targetHeight = max(1, Int(CGFloat(height) * scale))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return source
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? source
    }

}

// PATCH-2026-05-06: multimodal-ui Sprint 3 — ChatView extended with voice, image, file, screen capture
// B.2: recognised slash commands; anything else falls through to regular send
// PATCH-2026-05-08: review-fix-r2 Removed "skill" — handleSlashCommand has
// no case for it, so /skill ... was being intercepted as "Unknown command"
// instead of falling through to chat (where _chat_intent_skill_build can
// detect natural-language skill requests).
extension Notification.Name {
    /// Fired by AppModel.sendChat after a turn lands so any ContextFillBar
    /// instance can re-poll the session context.
    static let chatTurnCompleted = Notification.Name("chatTurnCompleted")
    /// Fired by /nextgen slash command to navigate to the NextGen panel in Capabilities.
    static let openNextGenRequest = Notification.Name("NativeAgent.openNextGenRequest")
    static let openApprovalsRequest = Notification.Name("NativeAgent.openApprovalsRequest")
    static let openTelegramRequest = Notification.Name("NativeAgent.openTelegramRequest")
    static let openCommandRouteRequest = Notification.Name("NativeAgent.openCommandRouteRequest")
    static let openCommandPaletteRequest = Notification.Name("NativeAgent.openCommandPaletteRequest")
    /// B2.3 follow-up: posted by Desk's New Task toolbar button; ContentView
    /// owns the sheet (detail-attached sheets present only once on macOS).
    static let newWorkshopTaskRequest = Notification.Name("NativeAgent.newWorkshopTaskRequest")
    static let iCloudInboxDidProcess = Notification.Name("NativeAgent.iCloudInboxDidProcess")
    /// PATCH-2026-06-06: activity-flatten — posted by Cmd+Shift+A / Cmd+Shift+I
    /// (and any future direct-route into Activity's sub-queues). Object is an
    /// `ActivitySection.rawValue` string; ActivityView resets its
    /// NavigationPath and pushes the matching destination.
    static let openActivitySectionRequest = Notification.Name("NativeAgent.openActivitySectionRequest")
    static let openActivityRootRequest = Notification.Name("NativeAgent.openActivityRootRequest")
    /// Inbox "Act" on a chat-shaped item (morning brief, idle check-in, …):
    /// switch to Chat and prefill the composer with the object string via
    /// AppModel.injectChatDraft — same idiom as skillBuildRequest.
    static let openChatDraftRequest = Notification.Name("NativeAgent.openChatDraftRequest")
    /// L5 G6: Act on a card SHE authored — her message is ALREADY in the
    /// transcript by the time this posts. Switch to Chat and reload; the
    /// composer is deliberately left untouched, because User is answering her,
    /// not writing to himself.
    static let openSpokenChatRequest = Notification.Name("NativeAgent.openSpokenChatRequest")
}


enum MemoryViewTab: String, CaseIterable, Identifiable {
    case active = "Active"
    case pending = "Pending"
    case tombstones = "Tombstones"
    var id: String { rawValue }
    // Consumer-facing label; rawValue stays stable for ids/deep links.
    var title: String {
        self == .tombstones ? "Deleted" : rawValue
    }
    var systemImage: String {
        switch self {
        case .active: return "brain"
        case .pending: return "tray"
        case .tombstones: return "xmark.bin"
        }
    }
}


struct PrivacyCategoryRow: View {
    var category: PrivacyCategory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: category.exportable ? "square.and.arrow.up" : "lock.fill")
                .foregroundStyle(category.exportable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(category.title)
                        .font(.subheadline.weight(.semibold))
                    StatusBadge(text: category.exportable ? "Exportable" : "Protected", status: category.exportable ? "ok" : "warn")
                }
                Text(category.contains)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(category.path)
                    .font(NativeAgentFont.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .textSelection(.enabled)
    }
}


extension String {
    var withoutStaleNextGenPhaseCopy: String {
        var value = self
        value = value.replacingOccurrences(
            of: #"(?i)next-gen runtime phases?\s+52\s*[-–]\s*92"#,
            with: "Next-Gen Runtime",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)phases?\s+52\s*[-–]\s*92"#,
            with: "next-gen phases",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"phase-52[-–]92"#,
            with: "nextgen-phase",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"phase-73[-–]92"#,
            with: "nextgen-key-phase",
            options: .regularExpression
        )
        return value
    }
}


enum CapabilityWorkspaceMode: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case build = "Build"
    case operate = "Operate"
    case hardening = "Hardening"

    var id: String { rawValue }
}
