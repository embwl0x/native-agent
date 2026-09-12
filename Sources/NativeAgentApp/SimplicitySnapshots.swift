#if DEBUG
import Foundation
import AppKit
import SwiftUI
import ProviderRouting
import StandingBots

/// Synthetic design material only. Never loaded by a production page or store.
private struct HelperReviewFixture: View {
    let page: String
    private var secondary: Color { NativeAgentShell.secondary }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ShellPageFrame(title: "Bots", showsBack: false) {
            ZStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(page == "detail" ? "Release watch" : "Standing helpers")
                        .font(ShellType.display)
                    Spacer()
                    if page == "list" { Button("New bot", systemImage: "plus") {} }
                }
                if page == "detail" { detail }
                else { list }
                Spacer(minLength: 0)
                Text("Synthetic design fixture · September 9, 2026")
                    .font(.caption).foregroundStyle(secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(page == "create" ? 0.2 : 1)
                if page == "create" {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("New bot").font(ShellType.title)
                        creation
                    }
                    .padding(24).frame(width: 540)
                    .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.99),
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(secondary.opacity(0.18)))
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
                }
            }
        }
    }
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Release watch", "Check the project releases and tell me what changed.",
                "GPT-5.5 / Low · Twice daily · Last today, 09:00 · Next 21:00 · Ready")
            Divider().padding(.vertical, 18)
            row("Draft companion", "Help me work through the draft when I ask.",
                "Sonnet / Medium · Manual only · Last yesterday, 14:20 · Paused")
            Divider().padding(.vertical, 18)
            row("Folder notes", "Read the folder I chose and keep notes in my requested form.",
                "GPT-5.5 / High · Daily, 08:00 · Last today, 08:00 · Waiting for approval")
        }
    }
    private func row(_ name: String, _ brief: String, _ metadata: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(name).font(.headline); Spacer(); Image(systemName: "chevron.right").foregroundStyle(secondary) }
            Text(brief).font(ShellType.body)
            Text(metadata).font(.caption).foregroundStyle(secondary)
        }
    }
    private var detail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Check the project releases and tell me what changed. Keep the reply short, in plain words.")
                .font(ShellType.body)
            Text("GPT-5.5 / Low · Twice daily · Last today, 09:00 · Next 21:00 · Ready")
                .font(.caption).foregroundStyle(secondary)
            HStack(spacing: 14) {
                Button("Run once") {}; Button("Pause") {}; Button("Edit") {}
                Spacer()
                Text("Limits: 8,000 tokens/run · 24,000/day").font(.caption).foregroundStyle(secondary)
            }
            Divider()
            reply("Today, 09:00", "Completed", "The sample project published a small update this morning. It fixes the export issue mentioned yesterday and adds a way to rename saved drafts. The release notes do not mention any other changes.")
            Divider()
            reply("Yesterday, 21:00", "Completed", "There has been no new release since the morning check. The export fix is still listed as planned.")
            Divider()
            reply("Yesterday, 09:00", "Interrupted · Token limit reached", "I found the new release notes and read the first section. It describes a fix for exports. I have not finished the remaining notes.")
            Divider()
            HStack {
                Label("Session", systemImage: "chevron.right").font(.headline)
                Text("Messages and tool activity").font(.caption).foregroundStyle(secondary)
                Spacer()
                Button("Continue in Chat", systemImage: "arrow.up.right") {}
            }
        }
    }
    private func reply(_ date: String, _ status: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(date).font(.subheadline.weight(.medium)); Spacer(); Text(status).font(.caption).foregroundStyle(secondary) }
            Text(text).font(ShellType.body).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var creation: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("Name", height: 32)
            field("What to do", height: 72)
            field("Desired output", height: 52)
            HStack(spacing: 16) {
                field("Model", height: 32)
                field("Think", height: 32)
                field("When", height: 32)
            }
            DisclosureGroup("Optional controls") {
                Text("Fast · Notify · Per-run token cap · Daily ceiling")
            }.foregroundStyle(secondary)
            HStack { Spacer(); Button("Cancel") {}; Button("Create") {}.disabled(true) }
        }
    }
    private func field(_ label: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline)
            RoundedRectangle(cornerRadius: 6).fill(secondary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(secondary.opacity(0.22)))
                .frame(height: height)
        }
    }
}

/// Review fixtures, not alternate runtime screens. The private, AppModel-backed
/// Chat guidance and composer, page frame, rail, cards and typography are shipped
/// components. Onboarding setup hosts the production wizard with an inert DEBUG state.
/// Providers hosts its production view with a temporary fixture root and an AppModel
/// with background tasks disabled; no authentication is started. Trust hosts the
/// production view with an isolated AppModel that disables background work and
/// security loading; no resident runtime, auth flow or user policy store is started.
@MainActor
enum SimplicitySnapshots {
    enum Screen: String, CaseIterable {
        case onboardingSetup = "onboarding-setup"
        case onboardingAccountFailure = "onboarding-account-failure"
        case trustClosed = "trust-closed"
        case trustOpen = "trust-open"
        case providersClosed = "providers-closed"
        case providersOpen = "providers-open"
        case firstChat = "first-chat-no-provider"

        var selection: SidebarItem {
            switch self {
            case .trustClosed, .trustOpen: .trust
            case .providersClosed, .providersOpen: .providers
            case .firstChat: .chat
            default: .settings
            }
        }
    }

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["SIMPLICITY_HELPERS_ONLY"] == "1" {
            let output = directory.appendingPathComponent("helpers")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for scheme in [ColorScheme.light, .dark] {
                for compact in [false, true] {
                    for page in ["list", "detail", "create"] {
                        try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                            ShellSidebarRail(selection: .constant(.bots), botsPreviewOverride: true)
                        } detail: {
                            HelperReviewFixture(page: page)
                        }, name: "\(page)-\(compact ? "1024x700" : "1280x800")-\(scheme == .dark ? "dark" : "light")",
                        size: CGSize(width: compact ? 1024 : 1280, height: compact ? 700 : 800),
                        scheme: scheme, directory: output, scale: 1)
                    }
                }
            }
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_TRUST_FOUR_CARDS"] == "1" {
            try renderTrustFourCards(to: directory.appendingPathComponent("trust-four-cards"))
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_RAIL_PRODUCTION"] == "1" {
            try renderRail(to: directory.appendingPathComponent("rail/production"), production: true)
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_RAIL_ONLY"] == "1" {
            try renderRail(to: directory.appendingPathComponent("rail"))
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_RECEIPTS_ONLY"] == "1" {
            try ReceiptDesignSnapshots.render(to: directory.appendingPathComponent("receipts"))
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_CHAT_ONLY"] == "1" {
            try renderChat(to: directory.appendingPathComponent("chat"))
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_TODAY_ONLY"] == "1" {
            try renderToday(to: directory.appendingPathComponent("today"))
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_ONBOARDING_PASS2"] == "1" {
            try renderOnboarding(to: directory.appendingPathComponent("pass2"))
            return
        }
        for scheme in [ColorScheme.light, .dark] {
            for screen in Screen.allCases where screen != .providersClosed && screen != .providersOpen {
                if screen == .trustClosed || screen == .trustOpen {
                    let pass2 = directory.appendingPathComponent("pass2", isDirectory: true)
                    try FileManager.default.createDirectory(at: pass2, withIntermediateDirectories: true)
                    for compact in [false, true] {
                        try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                            ShellSidebarRail(selection: .constant(.trust), botsPreviewOverride: false)
                        } detail: {
                            SimplicityFixture(screen: screen)
                        }
                        .environment(\.dynamicTypeSize, compact ? .accessibility5 : .large),
                        name: "\(screen.rawValue)-\(compact ? "1024-largest" : "1280")-\(scheme == .dark ? "dark" : "light")",
                        size: CGSize(width: compact ? 1024 : 1280, height: compact ? 700 : 800),
                        scheme: scheme, directory: pass2, scale: 1)
                    }
                    if screen == .trustOpen {
                        try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                            ShellSidebarRail(selection: .constant(.trust), botsPreviewOverride: false)
                        } detail: {
                            SimplicityFixture(screen: screen)
                        }, name: "trust-open-full-\(scheme == .dark ? "dark" : "light")",
                        size: CGSize(width: 1280, height: 1500), scheme: scheme, directory: pass2, scale: 1)
                    }
                    continue
                }
                if ProcessInfo.processInfo.environment["SIMPLICITY_TRUST_ONLY"] == "1" { continue }
                for compact in [false, true] {
                    try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                        ShellSidebarRail(selection: .constant(screen.selection), botsPreviewOverride: false)
                    } detail: {
                        SimplicityFixture(screen: screen)
                    }.environment(\.dynamicTypeSize, compact ? .accessibility5 : .large),
                       name: "\(screen.rawValue)-\(scheme == .dark ? "dark" : "light")\(compact ? "-1024-accessibility5" : "")",
                       size: compact ? CGSize(width: 1024, height: 700) : CGSize(width: 1280, height: 800), scheme: scheme,
                       directory: directory, scale: 1)
                }
            }
        }
    }

    private static func renderTrustFourCards(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for preset in TrustPolicyPreset.allCases.map(Optional.some) + [nil] {
            let plan = (preset ?? .work).plan
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("trust-four-cards-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
            let body: [String: Any] = [
                "permissionLevel": plan.permissionLevel,
                "autonomyDefault": preset == nil ? "app_data_autonomous" : plan.autonomyDefault,
                "developerMode": plan.developerMode,
                "filePolicy": [
                    "requireBackupBeforeWrite": plan.requireBackups,
                    "outsideWorkspaceDefault": plan.outsideDefault,
                    "allowDestructiveActions": plan.developerMode
                ],
                "macControlPolicy": NativeClient.macControlPolicyForAccessMode(
                    plan.agentAccessMode, remoteFromIosAllowed: preset == .fullMac,
                    developerMode: plan.developerMode
                )
            ]
            let policy = try JSONDecoder().decode(TrustPolicy.self, from: JSONSerialization.data(withJSONObject: body))
            app.trustPolicy = policy
            app.chatFileAccess = plan.agentAccessMode
            for scheme in [ColorScheme.light, .dark] {
                for compact in [false, true] {
                    try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                        ShellSidebarRail(selection: .constant(.trust), botsPreviewOverride: false)
                    } detail: {
                        ShellPageFrame(title: "Trust", showsBack: false) {
                            TrustCenterView(snapshotPolicy: policy, expanded: false).environment(app)
                        }
                    }.environment(\.dynamicTypeSize, compact ? .accessibility5 : .large),
                        // 1024x700 at the largest Dynamic Type; the page's ShellType fonts are fixed-size,
                        // so the frame proves fit at the small size, not text scaling. Named honestly.
                        name: "\(preset.map { String(describing: $0) } ?? "custom")-\(compact ? "1024" : "1280")-\(scheme == .dark ? "dark" : "light")",
                        size: CGSize(width: compact ? 1024 : 1280, height: compact ? 700 : 800),
                        scheme: scheme, directory: directory, scale: 1)
                }
            }
        }
    }

    private static func renderRail(to directory: URL, production: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for option in production ? [.optionB] : RailGroupingFixture.Option.allCases {
            for pass in 0..<(production ? 8 : 3) {
                let defaultText = production && pass >= 4
                let botsEnabled = !defaultText || pass >= 6
                let compact = pass >= 2 && !defaultText
                let scheme: ColorScheme = pass % 2 == 1 ? .dark : .light
                try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                    if production {
                        ShellSidebarRail(selection: .constant(.chat), botsPreviewOverride: botsEnabled)
                    } else {
                        RailGroupingFixture(option: option, botsPreviewEnabled: true)
                    }
                } detail: {
                    ShellPageFrame(title: "Chat", showsBack: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("New conversation").font(ShellType.display)
                            Text("Message the agent to get started.")
                                .font(ShellType.body).foregroundStyle(NativeAgentShell.secondary)
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }.environment(\.dynamicTypeSize, defaultText ? .large : (production || compact ? .accessibility5 : .large)),
                    name: production
                        ? (defaultText
                            ? "rail-bots-\(botsEnabled ? "on" : "off")-1280x800-\(scheme == .dark ? "dark" : "light")"
                            : "rail-\(compact ? "1024x700" : "1280x800")-largest-\(scheme == .dark ? "dark" : "light")")
                        : "\(option.rawValue)-\(compact ? "1024x700-largest-light" : "1280x800-\(scheme == .dark ? "dark" : "light")")",
                    size: CGSize(width: compact ? 1024 : 1280, height: compact ? 700 : 800),
                    scheme: scheme, directory: directory, scale: 1)
            }
        }
    }

    /// Static pre-stream and completed-reply evidence using production bubbles
    /// and the production card. Mirrors ChatView's intrinsic bottom inset; no
    /// live ChatView tasks, NSWindow, screen readback, or resident stores.
    /// Today on the shell's own ground: the page the ground change is judged
    /// on. The rows and the waiting line are fixture copy; the card surfaces,
    /// the sections and the frame are the shipped components.
    private static func renderToday(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let at = Date(timeIntervalSince1970: 1_788_780_600)
        let did = [
            TodayRow(id: "talked", title: "Talked with you", line: "One conversation, on Mac.", at: at),
            TodayRow(id: "worked", title: "I worked with another builder",
                     line: "One loaded conversation with builder participation.", at: at),
            TodayRow(id: "dream", title: "I dreamed",
                     line: "A garden after rain. Quiet, with something new taking root beyond the familiar paths.",
                     at: at, dreamDate: "2026-09-07"),
        ]
        let ahead = [
            TodayRow(id: "facing", title: "What I'm facing", line: "The shell ground, with User, later today.", at: at),
        ]
        for scheme in [ColorScheme.light, .dark] {
            try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                ShellSidebarRail(selection: .constant(.activity), botsPreviewOverride: false)
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: TodayMetrics.sectionSpacing) {
                        Text("Today").font(ShellType.display)
                        TodayWaitingCard(momentsLine: "One moment from today", onReadMoments: {}, approvals: [])
                        TodaySection(title: "What I did today", rows: did)
                        TodaySection(title: "What's ahead", rows: ahead)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, TodayMetrics.topPadding)
                    .padding(.bottom, 32)
                    .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }, name: "today-\(scheme == .dark ? "dark" : "light")",
            size: CGSize(width: 1280, height: 800), scheme: scheme, directory: directory, scale: 1)
        }
    }

    private static func renderChat(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})
        let sent = ChatMessage(role: "user", content: "Please review the conversation layout carefully, including this longer message that wraps across several lines. The final line should remain fully visible while the agent prepares a reply, with enough space above the working card to read every word. Check both appearances and preserve the existing conversation width and controls.")
        let reply = ChatMessage(content: """
        Here is the review:

        - **Readable spacing.** Keep the entire sent message visible while the agent prepares a reply, including this deliberately long explanation that wraps onto several lines within the existing transcript width.
        - **Consistent bullets.** Each continuation should begin directly beneath the first word of the item, keeping the marker in a separate column even when the explanation needs more room.

        1. **Review the first state.** Send a long message and inspect the space above the working card before any reply text arrives, making sure the final line remains easy to read.
        2. **Review the completed reply.** Check the numbered markers and bold opening phrases in both appearances, with wrapped text aligned beneath the first word rather than beneath the number.
        """)
        let card = MacChatTurnCardModel(
            identity: MacChatTurnIdentity(sessionId: "snapshot", turnId: "snapshot"),
            phase: .working, title: "\(app.agentDisplayName) is working…", detail: nil,
            delegateName: nil, tone: .working, symbolName: "sparkles", isTerminal: false,
            showsLiveIndicator: true, elapsed: 8, secondsSinceMovement: 0,
            cancellationPending: false, approval: nil)
        for scheme in [ColorScheme.light, .dark] {
            for preStream in [true, false] {
                let view = VStack(spacing: 0) {
                    Text(app.agentDisplayName).font(ShellType.title).padding(24)
                    GeometryReader { viewport in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                MessageBubble(message: preStream ? sent : reply)
                            }
                            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                            .padding(.vertical, 16)
                            .frame(maxWidth: NativeAgentShellLayout.roomColumn)
                            .frame(maxWidth: .infinity)
                            // A windowless scroll view does not apply its
                            // initial scroll anchor. Seat this static fixture
                            // at the available viewport's bottom explicitly.
                            .frame(minHeight: preStream ? viewport.size.height : 0,
                                   alignment: preStream ? .bottom : .top)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if preStream {
                            MacChatTurnCard(model: card, onStop: {}, onDecideApproval: nil,
                                            snapshotWithoutLiveGlass: true)
                                .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                                .frame(maxWidth: NativeAgentShellLayout.roomColumn)
                                .padding(.bottom, 6)
                                .frame(maxWidth: .infinity, minHeight: ChatViewportPresentation.turnCardClearance(showingTurnCard: true, measuredHeight: 0), alignment: .bottom)
                        }
                    }
                }
                .padding(.bottom, 24)
                .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97))
                .environment(app)
                try BotsShelfSnapshots.write(view,
                    name: "\(preStream ? "pre-stream" : "wrapped-lists")-\(scheme == .dark ? "dark" : "light")",
                    size: CGSize(width: 1280, height: 800), scheme: scheme, directory: directory, scale: 1)
            }
        }
    }

    /// Seed only a temporary root, resolve the production routing stores, then
    /// mount ProviderSettingsView itself. No resident runtime or auth task runs.
    static func renderProviders(to directory: URL) async throws {
        if ProcessInfo.processInfo.environment["SIMPLICITY_HELPERS_ONLY"] == "1" { return }
        if ProcessInfo.processInfo.environment["SIMPLICITY_RAIL_PRODUCTION"] == "1" { return }
        if ProcessInfo.processInfo.environment["SIMPLICITY_RAIL_ONLY"] == "1" { return }
        if ProcessInfo.processInfo.environment["SIMPLICITY_RECEIPTS_ONLY"] == "1" { return }
        if ProcessInfo.processInfo.environment["SIMPLICITY_CHAT_ONLY"] == "1" { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("providers-pass2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let providerDirectory = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        // Three group rows, three states: Chat is Mixed (iPhone and Telegram
        // were pinned to Fast by an older build), Work carries one explicit
        // choice across all of its surfaces, Memory and mind inherits Chat.
        let work = ["desk", "workshop", "autonomy", "swarms", "training", "heartbeat", "diagnostics"]
        var preferences: [String: [String: String]] = [
            "chat": ["model": "gpt-6-astra", "reasoningEffort": "medium", "serviceTier": "default"],
            "ios": ["model": "gpt-6-astra", "reasoningEffort": "medium", "serviceTier": "priority"],
            "telegram": ["model": "gpt-6-astra", "reasoningEffort": "medium", "serviceTier": "priority"],
        ]
        var active = ["chat": "openai_oauth_direct", "ios": "openai_oauth_direct", "telegram": "openai_oauth_direct"]
        for surface in work {
            preferences[surface] = ["model": "gpt-6-astra", "reasoningEffort": "high", "serviceTier": "default"]
            active[surface] = "openai_oauth_direct"
        }
        try JSONSerialization.data(withJSONObject: preferences).write(to: providerDirectory.appendingPathComponent("surfaces.json"))
        try JSONSerialization.data(withJSONObject: active)
            .write(to: providerDirectory.appendingPathComponent("active.json"))
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})
        // Catalog and provider methods come from the production client. Only
        // the account-readiness receipt is a fixture; no credentials are made.
        var providers = try await app.client.listProviders(dataRoot: root, authEnvironment: [:])
        if let index = providers.firstIndex(where: { $0.provider_id == "openai_oauth_direct" }) {
            providers[index].auth_status.state = "ready"
            providers[index].auth_status.detail = "DEBUG connected-account fixture"
        }
        let fixtureRegistry = providerDirectory.appendingPathComponent("fixture-registry.json")
        try JSONEncoder().encode(providers).write(to: fixtureRegistry)
        providers = try JSONDecoder().decode([ProviderInfo].self, from: Data(contentsOf: fixtureRegistry))
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        let resolved = try await routing.checkedRoutingSnapshot()
        let snapshot = ProviderSettingsRefreshAction.Snapshot(
            providers: providers, catalog: nil,
            rowSet: try await routing.providerSurfaceRowSet(),
            activeProviders: resolved.activeProviders,
            preferences: resolved.preferences
        )
        for scheme in [ColorScheme.light, .dark] {
            for size in (ProcessInfo.processInfo.environment["SIMPLICITY_FINISH_ONLY"] == "1"
                ? [CGSize(width: 1024, height: 700)]
                : [CGSize(width: 1280, height: 800), CGSize(width: 1024, height: 700)]) {
                for expanded in [true] {
                    try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                        ShellSidebarRail(selection: .constant(.providers), botsPreviewOverride: false)
                    } detail: {
                        ShellPageFrame(title: "Providers", showsBack: false, wide: true) {
                            ProviderSettingsView(snapshot: snapshot,
                                explicitSurfaces: Set(resolved.pinnedModels.keys).union(resolved.activeProviders.keys),
                                savedReceipt: "Chat → gpt-6-astra / Medium / Fast saved")
                                .environment(app)
                        }
                    }.environment(\.dynamicTypeSize, .large),
                    name: "providers-\(expanded ? "open" : "closed")-\(Int(size.width))x\(Int(size.height))-\(scheme == .dark ? "dark" : "light")",
                    size: size, scheme: scheme, directory: directory, scale: 1)
                }
                if ProcessInfo.processInfo.environment["SIMPLICITY_FINISH_ONLY"] == "1" { continue }
                try BotsShelfSnapshots.write(
                    BotsEditorSheet(definition: nil, save: { _ in }).environment(app)
                        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.98)),
                    name: "bots-new-\(Int(size.width))x\(Int(size.height))-\(scheme == .dark ? "dark" : "light")",
                    size: size, scheme: scheme, directory: directory, scale: 1)
            }
        }
    }

    static func renderFinish(to directory: URL) async throws {
        try await renderProviders(to: directory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bots-finish-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})
        let accounts = try await app.client.listProviders(dataRoot: root, authEnvironment: [:])
        let account = accounts.first { $0.provider_id == "openai_oauth_direct" }!
        let model = account.models.first { $0.id == "gpt-6-astra" && $0.supports_fast == true }!
        let choices = [ProviderThenModelPicker.Provider(id: account.provider_id, name: account.display_name,
            ready: true, models: [ProviderThenModelPicker.Model(id: model.id, name: model.name,
                supportedEfforts: model.supported_reasoning_efforts, supportsFast: model.supports_fast)])]
        var bot = BotDefinition(name: "Release watch", brief: "Check the project releases and tell me what changed.",
            cadence: .interval(seconds: 43200), budget: BotBudget(tokens: 8000, seconds: 120))
        bot.provider = account.provider_id; bot.model = model.id; bot.reasoningEffort = "medium"
        let anchor = Date(timeIntervalSince1970: 1788962400)
        let entries = (0..<8).map { index in
            let date = anchor.addingTimeInterval(-Double(index) * 43200)
            var entry = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: date, coverageStart: date,
                coverageEnd: date, headline: "", findings: "", changedSinceLastGood: "", runHealth: .ok,
                spend: ShelfSpend(tokens: 500, seconds: 12))
            entry.sessionID = bot.sessionID; entry.status = .completed
            entry.reply = index == 0
                ? "The project published a small update this morning.\n\nThe export fix preserves the formatting of saved drafts."
                : "There has been no new release since the previous check. The export fix remains the latest change."
            return entry
        }
        for page in ["bots-detail", "bots-waiting", "bots-new-blank", "bots-new-fast"] {
            var replies = entries
            if page == "bots-waiting" {
                replies = [entries[0]]
                replies[0].status = .waitingForApproval
                replies[0].reply = "The folder needs approval before the files can be read. The earlier notes remain available in this session."
            }
            let record = BotsShelfRecord(definition: bot, entries: replies, unreadIDs: [])
            let creating = page.hasPrefix("bots-new")
            try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                ShellSidebarRail(selection: .constant(.bots), botsPreviewOverride: true)
            } detail: {
                ZStack {
                    BotsShelfView(records: [record], selectedID: creating ? nil : bot.id)
                        .opacity(creating ? 0.2 : 1)
                    if creating {
                        BotsEditorSheet(snapshotProviders: choices,
                            provider: page == "bots-new-fast" ? account.provider_id : "",
                            model: page == "bots-new-fast" ? model.id : "")
                            .background(Color(white: 0.99), in: RoundedRectangle(cornerRadius: 12))
                            .compositingGroup().shadow(radius: 16)
                    }
                }
            }.environment(app), name: "\(page)-1280x800-light", size: CGSize(width: 1280, height: 800),
                scheme: .light, directory: directory, scale: 1)
        }
    }

    private static func renderOnboarding(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for size in [CGSize(width: 1280, height: 800), CGSize(width: 1024, height: 700)] {
                for variant in ["names", "overview"] {
                    let state = OnboardingWizardState()
                    state.userName = "Sam"
                    state.agentName = "Ada"
                    state.showsAbilityOverview = variant != "names"
                    try writeOnboarding(
                        OnboardingWizard(snapshotState: state)
                            .environment(\.dynamicTypeSize, size.width == 1024 ? .accessibility5 : .large),
                        name: "onboarding-\(variant)-\(Int(size.width))-\(scheme == .dark ? "dark" : "light")",
                        size: size, scheme: scheme, directory: directory)
                }
            }
        }
    }

    /// The same offscreen NSHostingView path as BotsShelfSnapshots.write, with
    /// actual native scrolling so every production row has visual evidence.
    private static func writeOnboarding<V: View>(
        _ view: V, name: String, size: CGSize, scheme: ColorScheme, directory: URL
    ) throws {
        let previous = NSAppearance.current
        let previousApp = NSApplication.shared.appearance
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        NSAppearance.current = appearance
        NSApplication.shared.appearance = appearance
        defer {
            NSAppearance.current = previous
            NSApplication.shared.appearance = previousApp
        }
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .key)
            .transaction { $0.animation = nil })
        // Never ordered onscreen: attachment lets AppKit settle the native
        // scroll document, which remains zero-sized in an unattached host.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // SwiftUI commits native scroll geometry during its first display pass.
        guard let firstPass = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw OnboardingSnapshotError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: firstPass)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        guard let scroll = scrollView(in: host), let document = scroll.documentView else {
            throw OnboardingSnapshotError.missingScrollView
        }
        let viewport = scroll.contentView.bounds.height
        guard viewport > 0, document.bounds.height > 0 else {
            throw OnboardingSnapshotError.unlaidOutDocument
        }
        let maximum = max(0, document.bounds.height - viewport)
        var offsets: [CGFloat] = [0]
        while let last = offsets.last, last < maximum {
            offsets.append(min(maximum, last + viewport * 0.8))
        }
        for (page, offset) in offsets.enumerated() {
            let y = document.isFlipped ? offset : maximum - offset
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw OnboardingSnapshotError.noBitmap
            }
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw OnboardingSnapshotError.noBitmap
            }
            try png.write(to: directory.appendingPathComponent("\(name)-\(page).png"))
        }
        let geometry = "viewport=\(viewport), content=\(document.bounds.height), offsets=\(offsets)\n"
        try geometry.write(to: directory.appendingPathComponent("\(name)-scroll.txt"), atomically: true, encoding: .utf8)
    }

    private enum OnboardingSnapshotError: Error { case missingScrollView, noBitmap, unlaidOutDocument }
}

/// Pictures only. Rows are production ShellRailItem; stack metrics mirror
/// ShellSidebarRail without consulting or changing the persisted preview flag.
private struct RailGroupingFixture: View {
    enum Option: String, CaseIterable {
        case baseline, optionA = "option-a", optionB = "option-b"
    }

    let option: Option
    let botsPreviewEnabled: Bool
    @Namespace private var selectionBar

    private var everyday: [SidebarItem] {
        [.chat, .activity, .memories, .desk, .inboxPolicy] + (botsPreviewEnabled ? [.bots] : [])
    }
    private let configuration: [SidebarItem] = [
        .personality, .providers, .trust, .connectors, .capabilities, .diagnostics,
    ]

    var body: some View {
        VStack(spacing: 4) {
            if option == .baseline {
                ForEach(SidebarItem.shellPrimaryItems.dropLast()) { item in row(item) }
                if botsPreviewEnabled { row(.bots) }
            } else {
                if option == .optionA { header("EVERYDAY") }
                ForEach(everyday) { item in row(item) }
                if option == .optionA {
                    header("CONFIGURE")
                } else {
                    Rectangle().fill(NativeAgentShell.hairline).frame(height: 1)
                        .padding(.horizontal, NativeAgentShellLayout.railWordInset)
                        .padding(.vertical, 6)
                }
                ForEach(configuration) { item in row(item) }
            }
            Spacer(minLength: 8)
            row(.settings)
        }
        .padding(.vertical, 14)
        .frame(width: NativeAgentShellLayout.railWidth)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NativeAgentShell.hairline).frame(width: 1).ignoresSafeArea()
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        ShellRailItem(item: item, isSelected: item == .chat, onSelect: {}, barNamespace: selectionBar)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium))
            .foregroundStyle(NativeAgentShell.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, NativeAgentShellLayout.railWordInset)
            .padding(.vertical, 2)
    }
}

private struct SimplicityFixture: View {
    let screen: SimplicitySnapshots.Screen

    var body: some View {
        switch screen {
        case .onboardingSetup, .onboardingAccountFailure:
            onboarding(failed: screen == .onboardingAccountFailure)
        case .trustClosed, .trustOpen:
            ShellPageFrame(title: "Trust", showsBack: false) {
                trust(expanded: screen == .trustOpen)
            }
        case .providersClosed, .providersOpen:
            // The production Providers view is hosted by renderProviders(to:).
            EmptyView()
        case .firstChat:
            VStack(alignment: .leading, spacing: 16) {
                Text("New conversation").font(ShellType.display)
                ChatProviderConnectEmptyState(onConnect: {})
                MacChatComposerControlStrip(
                    shell: true, isListening: false, screenCaptureAllowed: false,
                    screenCaptureDisabled: true, pendingAttachmentCount: 0,
                    isRunning: false, canSend: false, onToggleVoice: {},
                    onCaptureScreen: {}, onAttach: {}, onStop: {}, onSend: {}
                ) {
                    TextField("Message the agent", text: .constant(""))
                        .textFieldStyle(.plain)
                }
            }
            .padding(28)
            .background { ShellRoomBackdrop() }
        }
    }

    @ViewBuilder
    private func onboarding(failed: Bool) -> some View {
        if failed {
            // This older provider-error projection is outside the identity review.
            VStack(spacing: 20) {
                HStack(spacing: 8) {
                    ForEach(0..<3) { index in
                        Circle().fill(index <= 1 ? Color.blue : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                ScrollView {
                    accountFailure.frame(maxWidth: 520).padding(.vertical, 4)
                }
                HStack {
                    Button("Back") {}
                    Spacer()
                    Button("Skip for now") {}.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: 520)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(colors: [NativeAgentBrand.accent.opacity(0.08),
                                        NativeAgentBrand.accentCool.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            OnboardingWizard(snapshotState: OnboardingWizardState())
        }
    }

    private var accountFailure: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect a provider.").font(NativeAgentFont.display)
            Text("The agent needs a model to think with. Connect whichever service(s) you already use — sign in with OAuth, or paste an API key. No provider is required to be a particular one.")
                .font(NativeAgentFont.body).foregroundStyle(.secondary)
            NativePanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in with your account").font(NativeAgentFont.section)
                    Button("Sign in with ChatGPT") {}
                    Button("Sign in with Anthropic") {}
                    Button("Sign in with xAI") {}
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            NativePanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("All providers").font(NativeAgentFont.section)
                    Text("Paste an API key for any provider — OpenAI, OpenRouter, Anthropic, xAI — or reconfigure one above.")
                        .foregroundStyle(.secondary)
                    Text("Couldn't check your connected accounts").foregroundStyle(NativeAgentShell.trouble)
                    Button("Retry") {}
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("You can skip this and connect later in the Providers tab in the sidebar — but chat won't work until a provider is connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func trust(expanded: Bool) -> some View {
        // The production view receives an inert, temporary-root AppModel.
        // Stores never point at the resident agent's data.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-snapshot-\(UUID().uuidString)", isDirectory: true)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let policy = TrustPolicy(
            permissionLevel: "strict", autonomyDefault: "supervised",
            filePolicy: TrustFilePolicy(requireBackupBeforeWrite: true, outsideWorkspaceDefault: "deny")
        )
        app.trustPolicy = policy
        app.chatFileAccess = "read_only"
        return TrustCenterView(snapshotPolicy: policy, expanded: expanded).environment(app)
    }

    private func choice(_ title: String, _ value: String) -> some View {
        Picker(title, selection: .constant(value)) { Text(value).tag(value) }
            .pickerStyle(.menu).font(ShellType.label)
    }
}
#endif
