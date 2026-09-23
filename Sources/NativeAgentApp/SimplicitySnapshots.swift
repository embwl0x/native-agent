#if DEBUG
import Foundation
import AppKit
import SwiftUI
import ProviderRouting
import StandingBots
import ChatOrchestration
import PersistenceCore

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
        // 0.4.12 mockup round, 2026-09-13: two judged-before-built items.
        if ProcessInfo.processInfo.environment["SIMPLICITY_CARDS"] == "1" {
            try InlineCardMockups.render(to: directory.appendingPathComponent("cards"))
            return
        }
        // Mood-in-the-tint mockup round, 2026-09-14. MOCKUPS ONLY.
        if ProcessInfo.processInfo.environment["SIMPLICITY_MOCKUPS_MOOD"] == "1" {
            try MoodTintMockups.render(to: directory.appendingPathComponent("mood-tint"))
            return
        }
        // Composer round, 2026-09-15. MOCKUPS ONLY, mounted nowhere.
        if ProcessInfo.processInfo.environment["SIMPLICITY_MOCKUPS_COMPOSER"] == "1" {
            try ComposerMockups.render(to: directory.appendingPathComponent("composer"))
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_MOCKUPS_TRUST"] == "1" {
            try MockupsSept13.renderTrust(to: directory.appendingPathComponent("trust-presets"))
            return
        }
        if ProcessInfo.processInfo.environment["SIMPLICITY_MOCKUPS_PROVIDERS"] == "1" {
            try MockupsSept13.renderProvidersDensity(to: directory.appendingPathComponent("providers-density"))
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
        if ProcessInfo.processInfo.environment["SIMPLICITY_COMPUTER_PANE"] == "1" {
            try renderComputerPane(to: directory)
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

    /// The working card with and without the live computer pane, in the chat
    /// frame it floats over. Four frames: pane on and pane off, dark and light.
    ///
    /// The thumbnail is NOT a screen capture. A synthetic desktop is drawn here
    /// and then pushed through the production
    /// ``MacScreenPreviewFrame.previewImage`` with one secure-field mark, so the
    /// PNG shows exactly what the masking path produces — the painted-out field
    /// in the frame is the real redaction, not a drawing of one.
    private static func renderComputerPane(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-pane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})
        let sent = ChatMessage(role: "user", content: "Open the sharing settings in Safari and turn the download prompt back on.")
        let card = MacChatTurnCardModel(
            identity: MacChatTurnIdentity(sessionId: "snapshot", turnId: "snapshot"),
            phase: .tool, title: "\(app.agentDisplayName) is using a tool",
            detail: "Using tool: screen",
            delegateName: nil, tone: .working, symbolName: "wrench.and.screwdriver",
            isTerminal: false, showsLiveIndicator: true, elapsed: 12,
            secondsSinceMovement: 0, cancellationPending: false, approval: nil)
        try renderSecureFieldProof(to: directory)
        // A REAL captured window when one is supplied, so legibility at the
        // thumbnail's true size is judged on real pixels, not on a drawing.
        let realFrame = ProcessInfo.processInfo.environment["COMPUTER_PANE_SAFARI_PNG"]
            .flatMap { loadImage(URL(fileURLWithPath: $0)) }
            .flatMap { image in
                MacScreenPreviewFrame.previewImage(
                    from: image, marks: [], origin: (x: 0, y: 0),
                    logicalSize: (w: Double(image.width), h: Double(image.height)))
            }
        let preview = MacChatScreenPreview(
            image: realFrame ?? syntheticPreviewFrame(),
            caption: "Looking at Safari",
            updatedAt: Date())
        // The two captions a verb actually shows, over the two frames it
        // actually captures: prospective mid-verb, past tense only afterwards.
        let actingPreview = MacChatScreenPreview(
            image: realFrame ?? syntheticPreviewFrame(),
            caption: "About to click Make Safari Default",
            updatedAt: Date())
        for scheme in [ColorScheme.light, .dark] {
            try BotsShelfSnapshots.write(
                chatFrame(app: app, card: card, sent: sent, preview: actingPreview, scheme: scheme),
                name: "computer-pane-about-to-\(scheme == .dark ? "dark" : "light")",
                size: CGSize(width: 1280, height: 800), scheme: scheme, directory: directory, scale: 1)
            for showsPane in [true, false] {
                let view = chatFrame(app: app, card: card, sent: sent,
                                     preview: showsPane ? preview : nil, scheme: scheme)
                try BotsShelfSnapshots.write(view,
                    name: "computer-pane-\(showsPane ? "on" : "off")-\(scheme == .dark ? "dark" : "light")",
                    size: CGSize(width: 1280, height: 800), scheme: scheme, directory: directory, scale: 1)
            }
        }
    }

    /// The chat frame the working card floats over. One builder for every
    /// computer-pane frame, so pane-on and pane-off differ ONLY by the pane.
    @ViewBuilder
    private static func chatFrame(
        app: AppModel,
        card: MacChatTurnCardModel,
        sent: ChatMessage,
        preview: MacChatScreenPreview?,
        scheme: ColorScheme
    ) -> some View {
        VStack(spacing: 0) {
            Text(app.agentDisplayName).font(ShellType.title).padding(24)
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MessageBubble(message: sent)
                    }
                    .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                    .padding(.vertical, 16)
                    .frame(maxWidth: NativeAgentShellLayout.roomColumn)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: viewport.size.height, alignment: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MacChatTurnCard(model: card, onStop: {}, onDecideApproval: nil,
                                snapshotWithoutLiveGlass: true,
                                preview: preview)
                    .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                    .frame(maxWidth: NativeAgentShellLayout.roomColumn)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, minHeight: ChatViewportPresentation.turnCardClearance(showingTurnCard: true, measuredHeight: 0), alignment: .bottom)
            }
        }
        .padding(.bottom, 24)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97))
        .environment(app)
    }

    /// Proof, by driving rather than by fixture (Agent, 2026-09-13).
    ///
    /// `COMPUTER_PANE_SECURE_PNG` is a REAL window captured off a real display
    /// with `screencapture`, containing a real `NSSecureTextField`.
    /// `COMPUTER_PANE_SECURE_RECT` and `..._ORIGIN` are that field's and that
    /// window's rects in global screen points, exactly as a four-verb mark
    /// carries them. The capture goes through the production
    /// ``MacScreenPreviewFrame.previewImage`` with one `AXSecureTextField` mark,
    /// and the masked result is then read back BYTE BY BYTE: every pixel inside
    /// the field's mapped rect must be the single fill colour, and the same
    /// rect in the untouched capture must NOT be uniform — otherwise the test
    /// would pass just as happily against a blank image.
    private static func renderSecureFieldProof(to directory: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["COMPUTER_PANE_SECURE_PNG"],
              let rect = numbers(environment["COMPUTER_PANE_SECURE_RECT"]), rect.count == 4,
              let origin = numbers(environment["COMPUTER_PANE_SECURE_ORIGIN"]), origin.count == 4,
              let raw = loadImage(URL(fileURLWithPath: input)) else {
            print("COMPUTER_PANE_PROOF skipped: no real capture supplied")
            return
        }
        // The shapes a password box actually arrives in. AppKit publishes the
        // secure ROLE; WebKit publishes an ordinary text field with the secure
        // SUBROLE; a bare `<input type=password>` with no label and no subrole
        // is the hard case, and reaches us only as obscured value glyphs. Every
        // one of them must be painted out, and the ordinary email field beside
        // them must not be.
        let shapes: [(String, [String: JSONValue])] = [
            ("AppKit secure role", ["role": .string("AXSecureTextField"), "label": .string("Password")]),
            ("WebKit secure subrole", ["role": .string("AXTextField"), "subrole": .string("AXSecureTextField"), "label": .string("Password")]),
            ("web field, label only", ["role": .string("AXTextField"), "label": .string("Password")]),
            ("web field, no label, obscured value", ["role": .string("AXTextField"), "value": .string("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")]),
            ("compiler verdict only", ["role": .string("AXTextField"), "secret_field": .bool(true)]),
        ]
        let frameJSON: JSONValue = .object([
            "x": .double(rect[0]), "y": .double(rect[1]),
            "w": .double(rect[2]), "h": .double(rect[3]),
        ])
        for (name, attributes) in shapes {
            var mark = attributes
            mark["frame"] = frameJSON
            let caught = MacScreenPreviewFrame.secretRects(
                marks: [.object(mark)],
                imagePixelSize: (w: raw.width, h: raw.height),
                origin: (x: origin[0], y: origin[1]),
                logicalSize: (w: origin[2], h: origin[3])).isEmpty == false
            print("COMPUTER_PANE_PROOF shape \"\(name)\": \(caught ? "MASKED" : "NOT MASKED <- LEAK")")
        }
        // The plain field beside it, which must stay readable.
        if let plain = numbers(environment["COMPUTER_PANE_PLAIN_RECT"]), plain.count == 4 {
            let plainMark: JSONValue = .object([
                "role": .string("AXTextField"),
                "label": .string("Email"),
                "value": .string("user@example.com"),
                "frame": .object([
                    "x": .double(plain[0]), "y": .double(plain[1]),
                    "w": .double(plain[2]), "h": .double(plain[3]),
                ]),
            ])
            let masked = MacScreenPreviewFrame.secretRects(
                marks: [plainMark],
                imagePixelSize: (w: raw.width, h: raw.height),
                origin: (x: origin[0], y: origin[1]),
                logicalSize: (w: origin[2], h: origin[3])).isEmpty == false
            print("COMPUTER_PANE_PROOF plain email field: \(masked ? "MASKED <- WRONG, only secure fields may be masked" : "left visible")")
        }

        let marks: [JSONValue] = [
            .object([
                "role": .string("AXSecureTextField"),
                "label": .string("Password"),
                "frame": frameJSON,
            ])
        ]
        guard let masked = MacScreenPreviewFrame.previewImage(
            from: raw, marks: marks,
            origin: (x: origin[0], y: origin[1]),
            logicalSize: (w: origin[2], h: origin[3])
        ) else {
            print("COMPUTER_PANE_PROOF failed: masking produced no image")
            return
        }
        try writePNG(masked, to: directory.appendingPathComponent("secure-field-masked.png"))
        try writePNG(raw, to: directory.appendingPathComponent("secure-field-captured.png"))

        // The field's rect in the MASKED image's pixel space, by the same
        // mapping the masking used.
        let rawWidth = Double(raw.width)
        let rawHeight = Double(raw.height)
        let scale: Double = Double(masked.width) / rawWidth
        let rawScaleX: Double = rawWidth / origin[2]
        let rawScaleY: Double = rawHeight / origin[3]
        let offsetX: Double = rect[0] - origin[0]
        let offsetY: Double = rect[1] - origin[1]

        let probeX: Double = offsetX * rawScaleX * scale
        let probeY: Double = offsetY * rawScaleY * scale
        let probeW: Double = rect[2] * rawScaleX * scale
        let probeH: Double = rect[3] * rawScaleY * scale
        let probe = CGRect(x: probeX, y: probeY, width: probeW, height: probeH)
        let after = uniformity(of: masked, in: probe)

        let beforeX: Double = offsetX * rawScaleX
        let beforeY: Double = offsetY * rawScaleY
        let beforeW: Double = rect[2] * rawScaleX
        let beforeH: Double = rect[3] * rawScaleY
        let beforeRect = CGRect(x: beforeX, y: beforeY, width: beforeW, height: beforeH)
        let before = uniformity(of: raw, in: beforeRect)
        print("COMPUTER_PANE_PROOF field rect in preview pixels: \(Int(probe.minX)),\(Int(probe.minY)),\(Int(probe.width)),\(Int(probe.height))")
        print("COMPUTER_PANE_PROOF captured (before masking): \(before.described) <- must NOT be uniform")
        print("COMPUTER_PANE_PROOF masked   (after  masking): \(after.described) <- must be one solid colour")
        print("COMPUTER_PANE_PROOF verdict: \(after.distinctColours == 1 && before.distinctColours > 1 ? "PASS" : "FAIL")")
    }

    private struct Uniformity {
        let distinctColours: Int
        let sample: (UInt8, UInt8, UInt8)
        let pixels: Int
        var described: String {
            "\(pixels) px, \(distinctColours) distinct colour\(distinctColours == 1 ? "" : "s"), first rgb(\(sample.0),\(sample.1),\(sample.2))"
        }
    }

    /// Reads the actual bytes. No sampling, no tolerance: every pixel in the
    /// rect is counted.
    private static func uniformity(of image: CGImage, in rect: CGRect) -> Uniformity {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(image.width, Int(rect.maxX.rounded(.up)))
        let y1 = min(image.height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return Uniformity(distinctColours: 0, sample: (0, 0, 0), pixels: 0) }
        let width = x1 - x0
        let height = y1 - y0
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return Uniformity(distinctColours: 0, sample: (0, 0, 0), pixels: 0) }
        // Draw only the crop: shift the image so the rect's corner sits at the
        // context's origin, remembering the context is bottom-left.
        context.draw(image, in: CGRect(
            x: -Double(x0), y: -Double(image.height - y1),
            width: Double(image.width), height: Double(image.height)))
        var seen = Set<UInt32>()
        for index in stride(from: 0, to: bytes.count, by: 4) {
            seen.insert(UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]))
        }
        return Uniformity(
            distinctColours: seen.count,
            sample: (bytes[0], bytes[1], bytes[2]),
            pixels: width * height)
    }

    private static func numbers(_ raw: String?) -> [Double]? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.isEmpty ? nil : parts
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    /// A drawn stand-in for a captured desktop: a window with a titlebar, a
    /// toolbar, body text, and one password field. Never a real capture.
    private static func syntheticPreviewFrame() -> CGImage? {
        let width = 1600
        let height = 1000
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // Desktop.
        context.setFillColor(red: 0.14, green: 0.22, blue: 0.33, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Window body, in a bottom-left-origin context.
        let window = CGRect(x: 140, y: 120, width: 1320, height: 760)
        context.setFillColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1)
        context.fill(window)
        // Titlebar and toolbar.
        context.setFillColor(red: 0.88, green: 0.88, blue: 0.87, alpha: 1)
        context.fill(CGRect(x: window.minX, y: window.maxY - 64, width: window.width, height: 64))
        context.setFillColor(red: 0.93, green: 0.93, blue: 0.92, alpha: 1)
        context.fill(CGRect(x: window.minX, y: window.maxY - 124, width: window.width, height: 60))
        // Traffic lights.
        for (index, colour) in [(0.98, 0.42, 0.38), (0.99, 0.76, 0.26), (0.34, 0.80, 0.38)].enumerated() {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fillEllipse(in: CGRect(x: window.minX + 22 + Double(index) * 28, y: window.maxY - 44, width: 18, height: 18))
        }
        // Body text lines.
        context.setFillColor(red: 0.72, green: 0.72, blue: 0.71, alpha: 1)
        for row in 0..<12 {
            let y = window.maxY - 190 - Double(row) * 44
            guard y > window.minY + 120 else { break }
            context.fill(CGRect(x: window.minX + 60, y: y, width: Double(420 + (row % 4) * 180), height: 16))
        }
        // The password field, in the same place the mark below describes.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: window.minX + 60, y: window.minY + 60, width: 420, height: 40))
        context.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        for dot in 0..<9 {
            context.fillEllipse(in: CGRect(x: window.minX + 76 + Double(dot) * 18, y: window.minY + 74, width: 10, height: 10))
        }
        guard let raw = context.makeImage() else { return nil }

        // One secure field, in global screen points with a top-left origin —
        // the space the real marks arrive in. y is measured from the top, so the
        // field drawn near the window's bottom sits low in this frame.
        let fieldTop = Double(height) - (window.minY + 100)
        let marks: [JSONValue] = [
            .object([
                "role": .string("AXSecureTextField"),
                "label": .string("Password"),
                "frame": .object([
                    "x": .double(window.minX + 60),
                    "y": .double(fieldTop),
                    "w": .double(420),
                    "h": .double(40),
                ]),
            ])
        ]
        return MacScreenPreviewFrame.previewImage(
            from: raw,
            marks: marks,
            origin: (x: 0, y: 0),
            logicalSize: (w: Double(width), h: Double(height))
        )
    }

    /// Seed only a temporary root, resolve the production routing stores, then
    /// mount ProviderSettingsView itself. No resident runtime or auth task runs.
    static func renderProviders(to directory: URL) async throws {
        if ProcessInfo.processInfo.environment["SIMPLICITY_HELPERS_ONLY"] == "1" { return }
        // The Trust mockup needs no Providers page; the Providers mockup DOES
        // run this one — the shipped page is its ground truth.
        if ProcessInfo.processInfo.environment["SIMPLICITY_MOCKUPS_TRUST"] == "1" { return }
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
        // One membership table, here too: a snapshot that hardcoded the Work
        // members would drift the moment the real table changed.
        let work = ProviderSurfaceGroups.work.surfaces
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
            Text("Connect an AI account.").font(NativeAgentFont.display)
            Text("Connect an account you already use, or add an API key.")
                .font(NativeAgentFont.body).foregroundStyle(.secondary)
            NativePanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in with your account").font(NativeAgentFont.section)
                    Button("Sign in with ChatGPT") {}
                    Button("Sign in with Claude") {}
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
            Text("You can connect later in Providers. Chat needs a connected account.")
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
