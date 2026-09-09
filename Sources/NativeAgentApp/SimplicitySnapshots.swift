#if DEBUG
import Foundation
import AppKit
import SwiftUI
import ProviderRouting

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
        if ProcessInfo.processInfo.environment["SIMPLICITY_CHAT_ONLY"] == "1" {
            try renderChat(to: directory.appendingPathComponent("chat"))
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

    /// Static pre-stream and completed-reply evidence using production bubbles
    /// and the production card. Mirrors ChatView's intrinsic bottom inset; no
    /// live ChatView tasks, NSWindow, screen readback, or resident stores.
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
        if ProcessInfo.processInfo.environment["SIMPLICITY_CHAT_ONLY"] == "1" { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("providers-pass2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let providerDirectory = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        let preferences: [String: [String: String]] = [
            "chat": ["model": "gpt-6-astra", "reasoningEffort": "medium", "serviceTier": "default"],
            "ios": ["model": "gpt-6-astra", "reasoningEffort": "medium", "serviceTier": "priority"],
            "telegram": ["model": "gpt-6-astra", "reasoningEffort": "medium", "serviceTier": "priority"],
        ]
        try JSONSerialization.data(withJSONObject: preferences).write(to: providerDirectory.appendingPathComponent("surfaces.json"))
        try JSONSerialization.data(withJSONObject: ["chat": "openai_oauth_direct", "ios": "openai_oauth_direct", "telegram": "openai_oauth_direct"])
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
            for size in [CGSize(width: 1280, height: 800), CGSize(width: 1024, height: 700)] {
                for expanded in [false, true] {
                    try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                        ShellSidebarRail(selection: .constant(.providers), botsPreviewOverride: false)
                    } detail: {
                        ShellPageFrame(title: "Providers", showsBack: false, wide: true) {
                            ProviderSettingsView(snapshot: snapshot,
                                explicitSurfaces: Set(resolved.pinnedModels.keys).union(resolved.activeProviders.keys),
                                expanded: expanded)
                                .environment(app)
                        }
                    }.environment(\.dynamicTypeSize, size.width == 1024 ? .accessibility5 : .large),
                    name: "providers-\(expanded ? "open" : "closed")-\(Int(size.width))x\(Int(size.height))-\(scheme == .dark ? "dark" : "light")\(size.width == 1024 ? "-accessibility5" : "")",
                    size: size, scheme: scheme, directory: directory, scale: 1)
                }
            }
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
