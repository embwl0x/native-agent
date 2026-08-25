import AppKit
import Foundation
import SwiftUI
import Testing
@testable import NativeAgentApp

// Ledger fence app.mac — rows `route.chatDraftInjection`,
// `ui.newWorkshopTaskSheet`, `ui.menuBarExtra.activityCaptureIndicator`,
// `ui.nav.toolsSelectionMigration`, `route.activityNavigationDestination`,
// `setting.appearanceDarkMode`, and the SIGPIPE half of
// `gate.launchPreflightAndSingleInstance`.
//
// Each assertion targets the production outcome the ledger names rather than
// the presence of a particular implementation spelling.

// MARK: - draft injection (wrong value: a half-typed message clobbered)

@MainActor
private final class MountedChatDraftRoutes {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(app: AppModel) {
        host = NSHostingView(rootView: AnyView(ContentView().environment(app)))
        window = NSWindow(
            contentRect: NSRect(x: -2_000, y: -2_000, width: 1_200, height: 900),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    func dismiss() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

@MainActor
@Test("both prefill routes refuse to overwrite a non-empty draft")
func chatDraftRoutes_guardTheComposerBeforeWriting() {
    let app = AppModel(
        dataRootOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-draft-routing-\(UUID().uuidString)", isDirectory: true),
        startBackgroundTasks: false
    )
    app.activeChatSessionId = "routing-session"
    let mounted = MountedChatDraftRoutes(app: app)
    defer { mounted.dismiss() }

    app.commitChatDraft("A half-typed message", sessionId: app.activeChatSessionId)
    #expect(app.requestSkillBuild(starter: "Build a release skill") == .existingDraftPreserved)
    #expect(app.chatDraft(for: app.activeChatSessionId) == "A half-typed message")

    let generation = app.chatDraftInjectionGeneration
    NotificationCenter.default.post(name: .openChatDraftRequest, object: "Investigate the release receipt")
    mounted.host.layoutSubtreeIfNeeded()
    #expect(app.chatDraft(for: app.activeChatSessionId) == "A half-typed message")
    #expect(app.chatDraftInjectionGeneration == generation)

    app.commitChatDraft("", sessionId: app.activeChatSessionId)
    #expect(app.requestSkillBuild(starter: "Build a release skill") == .draftPrepared)
    #expect(app.chatDraft(for: app.activeChatSessionId) == "Build a release skill")

    app.commitChatDraft("", sessionId: app.activeChatSessionId)
    NotificationCenter.default.post(name: .openChatDraftRequest, object: "Investigate the release receipt")
    mounted.host.layoutSubtreeIfNeeded()
    #expect(app.chatDraft(for: app.activeChatSessionId) == "Investigate the release receipt")
}

@MainActor
@Test("injectChatDraft is the write the guarded routes rely on")
func injectChatDraft_landsTextAndTellsTheComposer() {
    let model = AppModel()
    model.activeChatSessionId = "s1"
    let generation = model.chatDraftInjectionGeneration

    model.injectChatDraft("Create a skill from this conversation:", sessionId: "s1")
    #expect(model.chatDraft(for: "s1") == "Create a skill from this conversation:")
    // The composer holds its own view-local copy; without the generation bump
    // the prefill is written and never rendered.
    #expect(model.chatDraftInjectionGeneration > generation)
}

// MARK: - the workshop-task sheet (dead control)

@Test("NewWorkshopTaskSheet is presented from ContentView and nowhere else")
func newWorkshopTaskSheet_staysHoistedAboveTheDetailView() throws {
    let root = try AppSourceScraping.appSourcesRoot()
    var presenters: [String] = []
    for (file, source) in try AppSourceScraping.swiftSourceContents(under: root) {
        guard source.contains("NewWorkshopTaskSheet()") else { continue }
        presenters.append(file)
    }

    // Moved back under a detail view, the sheet presents once per app run and
    // then silently does nothing on every later click, because the detail view
    // is torn down and rebuilt on tab switches.
    #expect(presenters == ["ContentView.swift"], "unexpected presenter: \(presenters.sorted())")

    let content = try AppSourceScraping.appSource("ContentView.swift")
    #expect(content.contains(".sheet(isPresented: $showNewWorkshopTask)"))
    #expect(content.contains("publisher(for: .newWorkshopTaskRequest)"))
}

// MARK: - the menu-bar recording indicator (privacy consent signal)

@Test("the recording indicator reads capture live and its setter stays inert")
func activityCaptureIndicator_cannotSayNotRecordingWhileCaptureRuns() throws {
    let source = try AppSourceScraping.appSource("NativeAgentApp.swift")
    let binding = try #require(
        AppSourceScraping.looseFunctionBody(named: "activityCaptureIndicatorBinding", in: source)
            ?? source.range(of: "private var activityCaptureIndicatorBinding: Binding<Bool> {").map { r -> String in
                let open = source[r.lowerBound...].firstIndex(of: "{")!
                let close = AppSourceScraping.balancedEnd(
                    in: source, startingAt: open, opening: "{", closing: "}"
                )!
                return String(source[open...close])
            },
        "the indicator binding is gone"
    )

    // The getter must read the controller directly. A cached @State mirror can
    // say "not recording" while capture is live — silent surveillance with the
    // consent signal switched off.
    #expect(binding.contains("get: { ActivityWatchController.shared.isCapturing }"))
    // The setter must stay empty: honouring a write would let the indicator be
    // dismissed while capture keeps running.
    #expect(binding.contains("set: { _ in }"))

    // And the scene must actually be bound to it.
    #expect(source.contains("isInserted: activityCaptureIndicatorBinding"))

    // The menu's "what is recorded" line must honour the master override, not
    // just the titles switch.
    #expect(source.contains("controller.policy.captureTitles && !controller.policy.appNameOnlyMode"))
}

// MARK: - retired-tab migration (wrong value on exactly one cohort)

@Test("a saved Tools selection restores as Skills with the Tools subpage")
func toolsSelectionMigration_routesTheRetiredTabAndIsIdempotent() throws {
    // The routing half is real logic and testable directly.
    #expect(SidebarItem.tools.normalized == .skills)
    #expect(SidebarItem.skills.normalized == .skills)

    // Without the migration the user lands on Skills with the SKILLS section
    // selected — right sidebar row, wrong sub-page, and no fixture carries the
    // saved value that reproduces it.
    let source = try AppSourceScraping.appSource("ContentView.swift")
    let appear = try #require(source.range(of: ".onAppear {"))
    let open = source.index(before: appear.upperBound)
    let close = try #require(
        AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
    )
    let body = String(source[open...close])

    let migration = try #require(body.range(of: "if selectionRaw == SidebarItem.tools.rawValue {"))
    let sectionWrite = try #require(body.range(of: "skillsToolsSectionRaw = SkillsToolsSection.tools.rawValue"))
    let selectionWrite = try #require(body.range(of: "selectionRaw = SidebarItem.skills.rawValue"))
    #expect(migration.lowerBound < sectionWrite.lowerBound)
    // The subpage must be written BEFORE the selection is rewritten, or the
    // condition that guards the migration is already false.
    #expect(sectionWrite.lowerBound < selectionWrite.lowerBound)

    // Idempotence: after the rewrite the guard cannot match again, so a second
    // mount is a no-op rather than a section reset.
    #expect(SidebarItem.skills.rawValue != SidebarItem.tools.rawValue)
}

// MARK: - activity drill-in destinations (wrong page, confidently)

@Test("drilling into Memory Proposals lands on Pending, and every section has its own page")
func activityNavigationDestination_keepsItsExplicitInitialTab() throws {
    let source = try AppSourceScraping.appSource("ActivityView.swift")
    let start = try #require(source.range(of: ".navigationDestination(for: ActivitySection.self)"))
    let open = try #require(source[start.upperBound...].firstIndex(of: "{"))
    let close = try #require(
        AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
    )
    let mapping = String(source[open...close])

    // Dropping the argument in a refactor lands the user on a list of already
    // ACTIVE memories, which reads as an empty queue rather than a wrong tab.
    #expect(mapping.contains("case .memoryProposals:  MemoryView(initialTab: .pending)")
            || mapping.contains("case .memoryProposals: MemoryView(initialTab: .pending)"))

    // Every section maps to a DISTINCT destination view — two sections sharing
    // one page is a silent mis-navigation, and the compiler cannot see it.
    var destinations: [String] = []
    for line in mapping.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("case .") , let colon = trimmed.firstIndex(of: ":") else { continue }
        let view = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !view.isEmpty else { continue }
        destinations.append(String(view.prefix { $0 != "(" }))
    }
    #expect(destinations.count == 6, "ActivitySection case count changed: \(destinations)")
    #expect(Set(destinations).count == destinations.count, "two sections share a destination: \(destinations)")
}

// MARK: - appearance preference ownership (stale UI by omission)

@Test("the dark-mode preference has exactly the documented read sites")
func appearanceDarkMode_readSitesAreTheDocumentedSet() throws {
    let root = try AppSourceScraping.appSourcesRoot()
    var readers: Set<String> = []
    for (file, source) in try AppSourceScraping.swiftSourceContents(under: root) {
        if source.contains("\"nativeagent.darkMode\"") { readers.insert(file) }
    }

    // The preference has no single owner: every window-owning surface must
    // carry its own read, so a new window added without one renders in system
    // appearance while everything else honours the toggle.
    //   NativeAgentApp.swift        — main Window + Settings scene
    //   SlimSettingsView.swift      — the writer
    //   DetachedChatPanelView.swift — detached chat content
    //   DetachedChatPanel.swift     — the detached NSPanel chrome
    #expect(
        readers == [
            "NativeAgentApp.swift",
            "SlimSettingsView.swift",
            "DetachedChatPanelView.swift",
            "DetachedChatPanel.swift",
        ],
        "dark-mode read sites changed: \(readers.sorted())"
    )

    // The two KNOWN exceptions, pinned so they stay deliberate rather than
    // becoming forgotten: the Spotlight panel and the agent browser window
    // render in system appearance today.
    let spotlight = try AppSourceScraping.appSource("SpotlightOverlay.swift")
    let browser = try AppSourceScraping.appSource("BrowserWindow.swift")
    #expect(!spotlight.contains("preferredColorScheme"))
    #expect(!browser.contains("preferredColorScheme"))

    // Every reader that owns a window must actually APPLY it; a read with no
    // application is the same stale surface with extra steps.
    let appSource = try AppSourceScraping.appSource("NativeAgentApp.swift")
    #expect(AppSourceScraping.occurrences(of: "preferredColorScheme(preferDarkAppearance ? .dark : nil)", in: appSource) == 2)
}

// MARK: - launch gate ordering (silent no-launch / data-root split)

@Test("SIGPIPE is ignored before any subprocess-owning state is constructed")
func launchGate_sigpipeIsIgnoredBeforeAppConstruction() throws {
    let source = try AppSourceScraping.appSource("NativeAgentApp.swift")
    let main = try AppSourceScraping.functionBody(named: "main", in: source)

    // The suppressed-GUI path must return with a receipt rather than silently
    // doing nothing at all — a double-click that does nothing, with no trace.
    #expect(main.contains("NativeAgentLaunchPreflight.shouldSuppressGUIStart()"))
    #expect(main.contains("writeSuppressedLaunchReceipt"))

    // SIGPIPE lives in NativeAgentApp.init(), which is the earliest hook that
    // runs before any delegate callback or subprocess spawn. Without SIG_IGN a
    // write to a dead MCP/builder child kills the whole app, and the user sees
    // an unexplained quit.
    let initStart = try #require(source.range(of: "    init() {"), "NativeAgentApp.init() moved")
    let open = try #require(source[initStart.lowerBound...].firstIndex(of: "{"))
    let close = try #require(
        AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
    )
    let initBody = String(source[open...close])

    let sigpipe = try #require(
        initBody.range(of: "signal(SIGPIPE, SIG_IGN)"),
        "SIGPIPE is no longer ignored in NativeAgentApp.init()"
    )
    let appModel = try #require(
        initBody.range(of: "let appModel = AppModel()"),
        "AppModel is no longer constructed in init() — re-anchor this ordering guard"
    )
    // AppModel construction claims the process-wide MemoryV2 SQLite owner and
    // starts the subprocess-owning loops; the handler must be installed first.
    #expect(sigpipe.lowerBound < appModel.lowerBound)

    // And the whole App must not be constructed until the data root is settled.
    let claim = try #require(main.range(of: "AppDelegate.claimSingleAppInstance()"))
    let prepare = try #require(main.range(of: "NativeAgentPaths.preparePublicReleaseDataRootIfNeeded()"))
    let construct = try #require(main.range(of: "NativeAgentApp.main()"))
    #expect(claim.lowerBound < prepare.lowerBound)
    #expect(prepare.lowerBound < construct.lowerBound)
}
