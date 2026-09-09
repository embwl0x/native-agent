import Foundation
import Testing
@testable import NativeAgentApp

// Upgrade sweep 2026-08, TRACK D items D1–D4. One suite per item.
//
// Where a behaviour is a pure decision (empty-state branch, slash routing,
// popover copy) it is tested directly. Where it is SwiftUI wiring that no test
// process can render (which view owns an `onChange`, which modifier a body
// carries), it is pinned by source conformance — stated as such rather than
// dressed up as a behavioural test.

// MARK: - D1: the blank chat branches on provider readiness

@Suite("D1 chat empty state branches on provider readiness")
struct ChatEmptyStateProviderBranchTests {
    @Test("no usable provider gets the connect prompt, not an invitation to type")
    func noProviderShowsConnectPrompt() {
        #expect(ChatEmptyStateMode.mode(hasUsableProvider: false) == .connectProvider)
    }

    @Test("a connected provider keeps the D6 capability chips")
    func connectedProviderKeepsSuggestions() {
        #expect(ChatEmptyStateMode.mode(hasUsableProvider: true) == .suggestions)
        // D6 landed the day before this item; the branch must build on it, not
        // replace it.
        #expect(ChatEmptyStatePresentation.suggestions.count == 4)
    }

    @Test("the connect copy names where to go and never invites a first message")
    func connectCopyIsActionableAndDoesNotInviteAMessage() {
        let copy = [
            ChatProviderConnectEmptyState.title,
            ChatProviderConnectEmptyState.detail,
            ChatProviderConnectEmptyState.actionTitle,
        ].joined(separator: " ")

        #expect(ChatProviderConnectEmptyState.actionTitle == "Open Providers")
        #expect(ChatProviderConnectEmptyState.detail.contains("Open Providers"))
        #expect(ChatProviderConnectEmptyState.detail.contains(
            "Sign in with an account you already use, or add an API key."
        ))
        #expect(!copy.lowercased().contains("token"))
        #expect(!copy.contains("console.anthropic.com"))
        // The dead end this item removes: "Say something to <persona>" on a
        // machine that cannot answer.
        #expect(!copy.contains("Say something"))
        #expect(!copy.lowercased().contains("start with a goal"))
    }

    @Test("ChatView reads the cached readiness flag, never the disk probe, from body")
    func bodyDoesNotStatCredentialFilesAtTokenRate() throws {
        let source = try AppSourceScraping.appSource("ChatView.swift")
        // The branch is fed by @State, refreshed at appear / session switch /
        // provider change / window-key regain. Calling hasAnyUsableProvider()
        // inline would stat credential files on every body pass.
        #expect(source.contains("hasUsableProvider: hasUsableProvider"))
        #expect(source.contains("@State var hasUsableProvider = true"))
        #expect(
            AppSourceScraping.occurrences(
                of: "hasUsableProvider = appModel.hasAnyUsableProvider()", in: source
            ) == 4
        )
        #expect(source.contains("ChatProviderConnectEmptyState"))
    }
}

// MARK: - D2: one prefix check for both chat surfaces

@Suite("D2 slash-command routing is shared by main and detached chat")
struct ChatSlashCommandRoutingTests {
    @Test("plain text is never intercepted")
    func plainTextSends() {
        #expect(
            ChatSlashCommandRouting.decide(text: "what's on my calendar?", supportsDispatch: true)
                == .sendAsMessage
        )
        #expect(
            ChatSlashCommandRouting.decide(text: "", supportsDispatch: false) == .sendAsMessage
        )
    }

    @Test("non-command slash text still reaches the agent, on both surfaces")
    func unknownSlashTextIsNotACommand() {
        for supportsDispatch in [true, false] {
            #expect(
                ChatSlashCommandRouting.decide(text: "/tmp/foo", supportsDispatch: supportsDispatch)
                    == .sendAsMessage,
                "a file path must not be swallowed as a command (supportsDispatch: \(supportsDispatch))"
            )
            #expect(
                ChatSlashCommandRouting.decide(
                    text: "/notacommand please", supportsDispatch: supportsDispatch
                ) == .sendAsMessage
            )
        }
    }

    @Test("a known command dispatches on the main window, with the slash dropped")
    func knownCommandDispatchesWhereSupported() {
        #expect(
            ChatSlashCommandRouting.decide(text: "/model gpt-5.5", supportsDispatch: true)
                == .dispatch("model gpt-5.5")
        )
        #expect(
            ChatSlashCommandRouting.decide(text: "  /clear  ", supportsDispatch: true)
                == .dispatch("clear")
        )
        // Command matching is case-insensitive; the payload keeps what was typed.
        #expect(
            ChatSlashCommandRouting.decide(text: "/MODEL gpt-5.5", supportsDispatch: true)
                == .dispatch("MODEL gpt-5.5")
        )
    }

    @Test("the same command in a detached window is refused, not shipped to the LLM")
    func knownCommandIsRefusedWhereUnsupported() {
        #expect(
            ChatSlashCommandRouting.decide(text: "/model gpt-5.5", supportsDispatch: false)
                == .unsupportedHere("model")
        )
        // This is the bug: without the check, `/model gpt-5.5` was sent as chat
        // text and echoed back by the agent.
        #expect(
            ChatSlashCommandRouting.unsupportedMessage(command: "model")
                == "/model only works in the main chat window."
        )
    }

    @Test("dynamically registered capability tools route like built-ins")
    func dynamicToolNamesAreRecognized() {
        #expect(
            ChatSlashCommandRouting.decide(
                text: "/recall_search cats",
                dynamicToolNames: ["recall_search"],
                supportsDispatch: true
            ) == .dispatch("recall_search cats")
        )
        // A surface with no capabilities store (the detached panel) does not
        // know the tool, so it falls through to a normal send rather than
        // refusing something it cannot classify.
        #expect(
            ChatSlashCommandRouting.decide(text: "/recall_search cats", supportsDispatch: false)
                == .sendAsMessage
        )
    }

    @Test("every registry command is routable through the shared decision")
    func allRegisteredCommandsRoute() {
        for descriptor in ChatSlashCommandRegistry.all {
            #expect(
                ChatSlashCommandRouting.decide(
                    text: "/" + descriptor.command, supportsDispatch: true
                ) == .dispatch(descriptor.command),
                "/\(descriptor.command) is registered but did not route"
            )
        }
    }

    @Test("both send paths call the shared decision")
    func bothSurfacesAreWiredToTheRouter() throws {
        let main = try AppSourceScraping.appSource("ChatView+SlashCommands.swift")
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")

        #expect(main.contains("ChatSlashCommandRouting.decide("))
        #expect(main.contains("supportsDispatch: true"))
        #expect(detached.contains("ChatSlashCommandRouting.decide("))
        #expect(detached.contains("supportsDispatch: false"))
        #expect(detached.contains("ChatSlashCommandRouting.unsupportedMessage"))

        // The seam is the routing DECISION only — the detached panel must not
        // have grown a dispatcher of its own.
        #expect(!detached.contains("handleSlashCommand"))
    }
}

// MARK: - D3: the health pill explains itself in consumer words

@Suite("D3 health pill popover copy and honest label")
struct HealthPillPopoverPresentationTests {
    /// Words a person using this app has never been taught. The pill is the
    /// one always-visible health control, so its copy carries the bar.
    private static let developerVocabulary = [
        "doctor", "diagnostic", "diagnostics", "check failed", "repair",
        "report", "daemon", "endpoint", "subsystem", "log",
    ]

    private func allCopy() -> [String] {
        var copy: [String] = []
        for summary: SystemHealthSummary in [
            .unknown, .ok, .warn(count: 1), .warn(count: 3), .error(count: 1), .error(count: 2),
        ] {
            for isChecking in [true, false] {
                copy.append(HealthPillPopoverPresentation.headline(
                    summary: summary, isChecking: isChecking
                ))
                copy.append(HealthPillPopoverPresentation.detail(
                    summary: summary, isChecking: isChecking
                ))
            }
        }
        copy.append(HealthPillPopoverPresentation.actionTitle(.check))
        copy.append(HealthPillPopoverPresentation.actionTitle(.checking))
        return copy
    }

    @Test("no user-visible popover string uses developer vocabulary")
    func copyPassesTheNoDeveloperVocabularyBar() {
        for line in allCopy() {
            let lowered = line.lowercased()
            for word in Self.developerVocabulary {
                #expect(
                    !lowered.contains(word),
                    "popover copy '\(line)' uses developer vocabulary '\(word)'"
                )
            }
        }
    }

    @Test("each state says something different and true")
    func headlinesDistinguishTheStates() {
        #expect(
            HealthPillPopoverPresentation.headline(summary: .unknown, isChecking: false)
                == "Nothing has been looked at yet"
        )
        #expect(
            HealthPillPopoverPresentation.headline(summary: .ok, isChecking: false)
                == "Everything looks fine"
        )
        #expect(
            HealthPillPopoverPresentation.headline(summary: .warn(count: 1), isChecking: false)
                == "1 thing could use attention"
        )
        #expect(
            HealthPillPopoverPresentation.headline(summary: .warn(count: 4), isChecking: false)
                == "4 things could use attention"
        )
        #expect(
            HealthPillPopoverPresentation.headline(summary: .error(count: 1), isChecking: false)
                == "1 thing isn't working"
        )
        #expect(
            HealthPillPopoverPresentation.headline(summary: .error(count: 2), isChecking: false)
                == "2 things aren't working"
        )
        // A live run outranks every bucket — the pill must not claim a verdict
        // while it is still forming one.
        for summary: SystemHealthSummary in [.unknown, .ok, .warn(count: 2), .error(count: 2)] {
            #expect(
                HealthPillPopoverPresentation.headline(summary: summary, isChecking: true)
                    == "Looking things over…"
            )
        }
    }

    @Test("the action reflects whether a look is already in flight")
    func actionTracksTheRunningFlag() {
        #expect(HealthPillPopoverPresentation.action(isChecking: false) == .check)
        #expect(HealthPillPopoverPresentation.action(isChecking: true) == .checking)
        #expect(HealthPillPopoverPresentation.actionTitle(.check) == "Take a look")
    }

    @Test("the pill opens a popover; the sticky receipt tooltip is gone")
    func pillNoLongerJumpsOrCarriesAStickyTooltip() throws {
        let source = try AppSourceScraping.appSource("HealthPill.swift")

        // Sticky tooltip: `.help(...)` was derived from the LAST navigation
        // receipt, so one click left "…queued until the main window is ready."
        // in the tooltip permanently.
        #expect(!source.contains(".help(HealthPillDoctorJump.help(for: doctorJumpReceipt))"))
        #expect(!source.contains("@State private var doctorJumpReceipt"))
        #expect(source.contains(".help(\"How the app is doing\")"))

        // Primary click opens the popover instead of navigating.
        #expect(source.contains("Button(action: { showPopover = true })"))
        #expect(source.contains(".popover(isPresented: $showPopover"))

        // The developer-gated jump survives only behind the developer gate.
        #expect(source.contains("if showDeveloperSurfaces {"))
        // 2026-09-06: ab1e2ace put Diagnostics on the rail and df974e5f emptied
        // the gate outside the classic shell (SidebarModels.swift:182), so the
        // jump's destination is only a developer surface in classic. Either way
        // the pill's jump lands on a Diagnostics destination that exists.
        if NativeAgentShellPreference.isClassic() {
            #expect(SidebarItem.diagnostics.isDeveloperSurface)
        } else {
            #expect(SidebarItem.shellPrimaryItems.contains(.diagnostics))
            #expect(!SidebarItem.diagnostics.isDeveloperSurface)
        }
    }

    @Test("'Checking' now requires a run in flight; a cold pill says it has no answer")
    func perpetualCheckingLabelIsFixed() throws {
        let source = try AppSourceScraping.appSource("HealthPill.swift")
        let labelBody = try #require(AppSourceScraping.looseFunctionBody(named: "label", in: source))
        #expect(labelBody.contains("appModel.doctorRunning ? \"Checking\" : \"Not checked\""))
        // "OK" still belongs to the .ok arm alone.
        #expect(AppSourceScraping.occurrences(of: "\"OK\"", in: labelBody) == 1)
    }

    @Test("the always-visible health pill reuses shared evidence instead of duplicating startup Doctor")
    func healthPillDoesNotRunDuplicateInitialCheck() throws {
        let source = try AppSourceScraping.appSource("HealthPill.swift")
        #expect(source.contains("healthCard?.subsystems"))
        #expect(!source.contains("guard appModel.doctorReport == nil, !appModel.doctorRunning else { return }"))
        #expect(AppSourceScraping.occurrences(
            of: "appModel.runDoctor(repair: false)", in: source
        ) == 1)
    }

    @MainActor
    @Test("a cold-launch model really is the state that used to read Checking forever")
    func coldLaunchIsUnknownAndNotRunning() {
        let model = AppModel()
        #expect(model.doctorReport == nil)
        #expect(model.systemHealthSummary == .unknown)
        // Nothing is running, so the label arm resolves to "Not checked".
        #expect(model.doctorRunning == false)
    }
}

// MARK: - D4: streaming render cost

@Suite("D4 streaming render cost")
struct ChatStreamingRenderCostTests {
    @Test("the sidebar projection is cached across unrelated body passes")
    func sidebarProjectionIsCached() throws {
        let source = try AppSourceScraping.appSource("ChatView.swift")

        // One exact-input owner serves both the rail and pinned strip. A token
        // delta can re-evaluate ChatView without decoding pins or rebuilding
        // session dictionaries and sets.
        #expect(!source.contains("var filteredPinnedSidebarSessions"))
        #expect(!source.contains("var filteredUnpinnedSidebarSessions"))
        #expect(source.contains("var sidebarProjection: ChatSidebarProjection"))
        #expect(source.contains("sidebarProjectionCache.project("))
        #expect(AppSourceScraping.occurrences(of: "ChatSidebarSections.split(", in: source) == 1)
        // 2026-09-06: 3ccfb925 ("the tab strip is gone from the new shell — the
        // sessions ARE the tabs") wrapped the binding in the classic-shell
        // check at ChatView.swift:988. The D4 invariant is unchanged: the strip
        // reads the projection ONCE and both the emptiness test and the rows
        // use that binding.
        #expect(source.contains("let pinnedTabs = classicShell ? sidebarProjection.pinnedTabs : []"))
        #expect(AppSourceScraping.occurrences(of: "sidebarProjection.pinnedTabs", in: source) == 1)
        #expect(AppSourceScraping.occurrences(of: "sessions: pinnedTabs", in: source) == 1)
    }

    @MainActor
    @Test("unchanged sessions, pins, and search reuse the exact projection")
    func unchangedSidebarInputsDoNotRebuild() throws {
        let a = try session("a")
        let b = try session("b")
        let c = try session("c")
        let pins = try MacPinnedChatSessionStore.save(["c", "a"])
        let cache = ChatSidebarProjectionCache()

        let first = cache.project(sessions: [a, b, c], pinnedRaw: pins, anchorSessionId: nil, search: "")
        let second = cache.project(sessions: [a, b, c], pinnedRaw: pins, anchorSessionId: nil, search: "")
        #expect(cache.rebuildCount == 1)
        #expect(first.pinnedTabs.map(\.id) == ["c", "a"])
        #expect(second.sections.unpinned.map(\.id) == ["b"])

        let searched = cache.project(sessions: [a, b, c], pinnedRaw: pins, anchorSessionId: nil, search: "B")
        #expect(cache.rebuildCount == 2)
        #expect(searched.sections.pinned.isEmpty)
        #expect(searched.sections.unpinned.map(\.id) == ["b"])
    }

    @Test("splitting once yields exactly what the two properties used to yield")
    func splitStillPartitionsPinnedAndRecent() throws {
        let a = try session("a")
        let b = try session("b")
        let c = try session("c")
        let sections = ChatSidebarSections.split(visible: [a, b, c], orderedPinned: [c, a])

        #expect(sections.pinned.map(\.id) == ["c", "a"])
        #expect(sections.unpinned.map(\.id) == ["b"])
    }

    private func session(_ id: String) throws -> ChatSession {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "title": id.uppercased(),
            "messageCount": 0,
            "createdAt": "2026-08-28T00:00:00Z",
        ])
        return try JSONDecoder().decode(ChatSession.self, from: data)
    }

    @Test("the token-rate read-aloud triggers moved off the root body — and still fire")
    func readAloudObserverOwnsTheTokenRateTriggers() throws {
        let source = try AppSourceScraping.appSource("ChatView.swift")

        // The observer exists, is mounted, and watches the SAME three signals
        // the root body used to watch. This is the auto-read verification the
        // item asks for: the move must not drop a trigger.
        #expect(source.contains("struct ChatReadAloudObserver: View"))
        #expect(source.contains("ChatReadAloudObserver(onChanged: speakLatestAssistantIfReady)"))

        let observer = try #require(observerBody(in: source))
        #expect(observer.contains(".onChange(of: appModel.chatMessages.count)"))
        #expect(observer.contains(".onChange(of: appModel.chatMessages.last?.content)"))
        #expect(observer.contains(".onChange(of: appModel.isBusy)"))
        #expect(AppSourceScraping.occurrences(of: "onChanged()", in: observer) == 3)

        // And ChatView's own body no longer carries them.
        let body = try #require(chatViewBody(in: source))
        #expect(!body.contains("speakLatestAssistantIfReady()"))
    }

    @MainActor
    @Test("auto-read still speaks a fresh assistant reply once, and only once")
    func autoReadGateStillFiresAfterTheMove() {
        let reply = ChatMessage(
            id: "m2", sessionId: "s1", role: "assistant", content: "here you go"
        )
        // What the observer's handlers call into is unchanged, so the decision
        // this pins is the one a streamed reply produces.
        #expect(
            ChatVoiceAutoReadGate.decide(
                enabled: true,
                sessionID: "s1",
                isSessionPrimed: true,
                lastMessage: reply,
                lastReadMessageID: "m1"
            ) == .speak(messageID: "m2", text: "here you go")
        )
        // The three handlers all fire for one reply; the cursor makes the
        // repeats no-ops.
        #expect(
            ChatVoiceAutoReadGate.decide(
                enabled: true,
                sessionID: "s1",
                isSessionPrimed: true,
                lastMessage: reply,
                lastReadMessageID: "m2"
            ) == .alreadyRead
        )
    }

    private func observerBody(in source: String) -> String? {
        guard let start = source.range(of: "struct ChatReadAloudObserver: View"),
              let end = source.range(
                  of: "\nstruct ChatView: View",
                  range: start.upperBound..<source.endIndex
              )
        else { return nil }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private func chatViewBody(in source: String) -> String? {
        guard let start = source.range(of: "    var body: some View {"),
              let end = source.range(
                  of: "\n    @ViewBuilder\n    var sessionSidebar",
                  range: start.upperBound..<source.endIndex
              )
        else { return nil }
        return String(source[start.upperBound..<end.lowerBound])
    }
}
