import Foundation
import Testing
import StandingBots
import ProviderRouting
@testable import NativeAgentApp

@Suite("Bots shelf preview")
struct BotsShelfTests {
    @Test func textOnlyCaptionFollowsSelectedAccount() throws {
        #expect(ProviderToolCapability.caption(providerID: "codex") == "text only, no tools")
        #expect(ProviderToolCapability.caption(providerID: "openai_oauth_direct") == nil)
        for file in ["BotsEditorSheet.swift", "ProviderSettingsView.swift"] {
            let source = try String(contentsOf: AppSourceScraping.appSourcesRoot().appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("ProviderToolCapability.caption(providerID:"))
            #expect(source.contains("Text(caption).font(.caption).foregroundStyle(.secondary)"))
        }
    }
    @MainActor @Test("Continue on a waiting entry targets the existing Approvals surface")
    func waitingEntryContinueTargetsApprovals() throws {
        let bot = BotDefinition(name: "Notes", brief: "Read the folder", cadence: .manual,
            budget: BotBudget(tokens: 1000, seconds: 30))
        let date = Date()
        var entry = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: date, coverageStart: date,
            coverageEnd: date, headline: "", findings: "", changedSinceLastGood: "", runHealth: .ok,
            spend: ShelfSpend(tokens: 0, seconds: 0))
        entry.status = .waitingForApproval
        entry.sessionID = bot.sessionID
        var record = BotsShelfRecord(definition: bot, entries: [entry], unreadIDs: [])
        #expect(BotsShelfView.continueDestination(for: record) == .activity(.approvals))
        record.entries[0].status = .completed
        #expect(BotsShelfView.continueDestination(for: record) == .sidebar(.chat))
        // The actual button callback must use ContentView's existing destination
        // handler, which selects the Approvals section of Activity.
        let source = try String(contentsOf: AppSourceScraping.appSourcesRoot()
            .appendingPathComponent("ContentView.swift"), encoding: .utf8)
        #expect(source.contains("BotsShelfPreviewPage(onContinue: applyNavigationDestination)"))
    }
    @MainActor @Test("Production shelf keeps forty verbatim replies and approval status")
    func productionReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = BotDefinitionStore(dataRoot: root)
        let bot = try definitions.create(BotDefinition(name: "Notes", brief: "Keep notes", cadence: .manual,
            budget: BotBudget(tokens: 1000, seconds: 30)))
        let shelf = ShelfStore(dataRoot: root)
        let emptySession = try await BotsShelfView.chatSession(for: bot, root: root)
        let sameSession = try await BotsShelfView.chatSession(for: bot, root: root)
        #expect(emptySession.id == bot.sessionID && sameSession.id == emptySession.id)
        #expect(try await NativeClient.getChatSessions(dataRoot: root).count == 1)
        for i in 0..<40 {
            let date = Date(timeIntervalSince1970: Double(i))
            var entry = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: date, coverageStart: date,
                coverageEnd: date, headline: "", findings: "", changedSinceLastGood: "", runHealth: .ok,
                spend: ShelfSpend(tokens: 0, seconds: 0))
            entry.reply = "**Reply \(i)**\n[Link](https://example.org)"
            entry.status = i == 39 ? .waitingForApproval : .completed
            entry.artifacts = [BotArtifact(name: "Notes", path: "/tmp/notes.md")]
            try shelf.append(entry)
        }
        let record = try #require(BotsShelfView.readRecords(root: root).first)
        #expect(record.entries.count == 40)
        #expect(record.sortedEntries.first?.actualReply == "**Reply 39**\n[Link](https://example.org)")
        #expect(record.sortedEntries.first?.artifacts?.first?.path == "/tmp/notes.md")
        #expect(record.metadata().contains("Waiting for approval"))
        #expect(record.metadata(state: "Running").hasSuffix("Running"))
        _ = try definitions.pause(bot.id)
        _ = try BotRunQueue(dataRoot: root).enqueueRequest(bot: bot.id)
        #expect(try BotRunQueue(dataRoot: root).activeOrQueuedIDs().contains(bot.id))
        #expect(try definitions.get(bot.id).paused)
    }
    @Test("Default keyboard model order matches visual groups; divider cannot select or focus", arguments: [false, true])
    func railKeyboardModelOrderMatchesVisualOrder(botsEnabled: Bool) throws {
        let items = SidebarItem.shellPrimaryItems
        let top = Array(items.dropLast())
        let visual = BotsShelfRailProposal.everyday(top)
            + (botsEnabled ? [.bots] : [])
            + BotsShelfRailProposal.configuration(top) + Array(items.suffix(1))
        let expected = ["Chat", "Today", "Memories", "Desk", "Notifications"]
            + (botsEnabled ? ["Bots"] : [])
            + ["Personality", "Providers", "Trust", "Connectors", "Capabilities", "Diagnostics", "Settings"]
        #expect(visual.map(\.shellRailTitle) == expected)
        #expect(visual.map(\.rawValue) == BotsShelfRailProposal.destinations(items, enabled: botsEnabled))
        #expect(Set(visual.map(\.normalized)).count == expected.count)

        // Native Button focus follows view order; no custom arrow-key traversal.
        // Pin the production wiring as well as the model, without driving the Mac.
        let source = try String(contentsOf: AppSourceScraping.appSourcesRoot()
            .appendingPathComponent("ShellSidebarRail.swift"), encoding: .utf8)
        let everyday = try #require(source.range(of: "ForEach(BotsShelfRailProposal.everyday"))
        let bots = try #require(source.range(of: "if botsPreviewOverride ?? botsPreviewEnabled { proposalItem(.bots) }"))
        let dividerStart = try #require(source.range(of: "Rectangle()", range: bots.upperBound..<source.endIndex))
        let configuration = try #require(source.range(of: "ForEach(BotsShelfRailProposal.configuration"))
        let settings = try #require(source.range(of: "if let last = items.last"))
        #expect(everyday.lowerBound < bots.lowerBound)
        #expect(bots.lowerBound < dividerStart.lowerBound)
        #expect(dividerStart.lowerBound < configuration.lowerBound)
        #expect(configuration.lowerBound < settings.lowerBound)
        let divider = source[dividerStart.lowerBound..<configuration.lowerBound]
        #expect(divider.contains(".allowsHitTesting(false)"))
        #expect(divider.contains(".accessibilityHidden(true)"))
        // The divider may only ever opt OUT of focus (".focusable(false)"); it is
        // never a button, never focusable, never a selectable tag.
        #expect(!divider.contains("Button") && !divider.contains(".focusable(true)") && !divider.contains(".tag("))
        #expect(!divider.contains(".focusable") || divider.contains(".focusable(false)"))
        // No custom arrow-key traversal: focus order is the view order, shaped only
        // by focus sections the shell declares.
        for handler in [".onMoveCommand", ".onKeyPress"] {
            #expect(!source.contains(handler))
        }
        #expect(source.contains("Button(action: onSelect)"))
        #expect(source.contains("onSelect: { selection = item }"))
        #expect(source.contains("onSelect: { selection = last }"))
        #expect(source.contains("selection.normalized == item.normalized"))
        #expect(source.contains("selection.normalized == last.normalized"))
    }

    @Test("Flag off preserves the shipped rail destination snapshot")
    func flagOffDestinationSnapshot() {
        let expected = ["Chat", "Activity", "Memories", "Desk", "Inbox Policy",
                        "Personality", "Providers", "Trust", "Connectors", "Capabilities", "Diagnostics", "Settings"]
        #expect(BotsShelfRailProposal.destinations(SidebarItem.shellPrimaryItems, enabled: false) == expected)
        let subset: [SidebarItem] = [.chat, .desk, .settings]
        #expect(BotsShelfRailProposal.destinations(subset, enabled: false) == subset.map(\.rawValue))
        let defaults = UserDefaults(suiteName: "BotsShelfTests.\(UUID().uuidString)")!
        #expect(!BotsShelfPreference.isEnabled(defaults))
    }

    @MainActor @Test("Render the review shelf offscreen when explicitly requested")
    func headlessSnapshots() throws {
        #if DEBUG
        guard let output = ProcessInfo.processInfo.environment["BOTS_SHELF_SNAPSHOT_DIR"] else { return }
        try BotsShelfSnapshots.render(to: URL(fileURLWithPath: output, isDirectory: true))
        #endif
    }

    @MainActor @Test("Snapshot entry points are enclosed in DEBUG only")
    func debugOnlySnapshotEntryPoints() async throws {
        let sources = try AppSourceScraping.appSourcesRoot()
        for file in ["BotsShelfSnapshots.swift", "SimplicitySnapshots.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.first == "#if DEBUG")
            #expect(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
            // No early #endif/#else can leave an entry point in release code.
            #expect(lines.filter { $0.hasPrefix("#if") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("#endif") }.count == 1)
            #expect(!lines.contains { $0.hasPrefix("#else") })
            #expect(source.contains("static func render(to directory: URL) throws"))
        }
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["SIMPLICITY_FINISH_DIR"] {
            try await SimplicitySnapshots.renderFinish(to: URL(fileURLWithPath: output, isDirectory: true))
            return
        }
        let entryPoints: [@MainActor (URL) throws -> Void] = [
            BotsShelfSnapshots.render(to:), SimplicitySnapshots.render(to:),
        ]
        #expect(entryPoints.count == 2)
        #expect(SimplicitySnapshots.Screen.allCases.count == 7)
        if let output = ProcessInfo.processInfo.environment["SIMPLICITY_SNAPSHOT_DIR"] {
            if ProcessInfo.processInfo.environment["PROVIDERS_SNAPSHOT_ONLY"] != "1" {
                try entryPoints[1](URL(fileURLWithPath: output, isDirectory: true))
            }
            if ProcessInfo.processInfo.environment["SIMPLICITY_RAIL_PRODUCTION"] != "1" {
                try await SimplicitySnapshots.renderProviders(to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent("pass2"))
            }
        }
        #endif
    }
}
