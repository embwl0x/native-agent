import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Behavior checks for the value and action owners used by the Mac's
/// high-risk surfaces. They intentionally avoid SwiftUI source scraping.
@MainActor
@Suite("Mac high-risk visible-surface behavior")
struct MacHighRiskSurfaceBehaviorEvalTests {
    @Test("context receipt preserves cache-state precedence")
    func contextReceiptCacheStateDoesNotQuietlyBecomeUnknownOrSuccess() {
        #expect(ContextReceiptPresentation.cacheDisplayText(status: "warm", hit: false, budgetStatus: "cold") == "warm")
        #expect(ContextReceiptPresentation.cacheDisplayText(status: nil, hit: false, budgetStatus: "warm") == "cache miss")
        #expect(ContextReceiptPresentation.cacheDisplayText(status: "", hit: nil, budgetStatus: "warm") == "warm")
        #expect(ContextReceiptPresentation.cacheDisplayText(status: nil, hit: nil, budgetStatus: nil) == nil)
    }

    @Test("tool pills distinguish pending, failed, succeeded, and duration truthfully")
    func toolPillNeverTreatsMissingMetadataAsSuccess() {
        #expect(ToolPillPresentation.outcome(ok: nil) == .pending)
        #expect(ToolPillPresentation.outcome(ok: false) == .unknown)
        #expect(ToolPillPresentation.outcome(ok: true) == .unknown)
        #expect(ToolPillPresentation.Outcome.pending.icon == "clock")
        #expect(ToolPillPresentation.Outcome.failed.icon == "xmark.circle.fill")
        // 2026-09-06: 3ccfb925 (ui-simplify lane A) dropped the "unknown duration"
        // confession — an absent duration now renders nothing and the outcome glyph
        // carries pending-vs-done (ChatMessageListView.swift:176-184). Still the real
        // pin: a missing duration must never be dressed up as a measured one.
        #expect(ToolPillPresentation.durationText(nil) == "")
        #expect(ToolPillPresentation.durationText(0) == "0ms")
    }

    @Test("write diff caps visible work and accounts for hidden lines")
    func toolDiffMakesTruncationExplicit() {
        let before = (0..<65).map { "before-\($0)" }.joined(separator: "\n")
        let after = (0..<65).map { "after-\($0)" }.joined(separator: "\n")
        let lines = ToolDiffPresentation.lines(before: before, after: after, limit: 60)
        #expect(lines.count == 61)
        #expect(lines.last == "... (70 more lines)")
        #expect(lines.prefix(60).allSatisfy { $0.hasPrefix("-") || $0.hasPrefix("+") })
    }

    @Test("slash planning keeps direct arguments, missing arguments, and forms distinct")
    func toolInputPlanningKeepsItsExactActionPlan() {
        let store = CapabilitiesStore(manifestLoader: { .object([:]) })
        store.tools = [
            tool(name: "note", required: ["text"], properties: ["text": "string"]),
            tool(name: "compose", required: ["subject", "body"], properties: ["subject": "string", "body": "string"]),
        ]
        let direct = store.planDispatch(toolName: "note", freeText: "keep this")
        #expect(direct?.mode == .singleStringArg(field: "text"))
        #expect(direct?.prefilled["text"] as? String == "keep this")
        #expect(store.planDispatch(toolName: "note", freeText: "  ")?.mode == .singleStringArg(field: "text"))
        #expect(store.planDispatch(toolName: "compose", freeText: "anything")?.mode == .formNeeded)
    }

    @Test("inbox failures preserve known items and expose adverse state")
    func inboxFailureKeepsLastKnownItemsAndStopsTheSuccessPath() throws {
        let item = try inboxItem(id: "pending")
        let failed = InboxStripPresentation.failed(previousItems: [item], errorDescription: "fixture read failed")
        #expect(failed.items == [item])
        #expect(failed.loadError == "fixture read failed")
        #expect(InboxStripPresentation.loaded([item]).loadError == nil)
    }

    @Test("Desk palette resolves the selected target, never an arbitrary first row")
    func deskPaletteNeverMutatesAnArbitraryFirstRow() {
        let first = DeskPaletteRow(handle: "first", alias: "1", title: "First", project: "P", status: "open")
        let selected = DeskPaletteRow(handle: "selected", alias: "2", title: "Selected", project: "P", status: "open")
        let target = DeskPalettePresentation.target(rows: [first, selected], matches: [first, selected], selectedHandle: "selected", parsed: .parse("close"), highlighted: 0)
        #expect(target?.handle == "selected")
        #expect(DeskPalettePresentation.bannerText(for: .close, target: target, query: "") == "Enter closes “Selected”.")
    }

    @Test("Desk nag icon has exactly muted, armed, and disabled meanings")
    func deskNagBellCannotInventAQuietFourthState() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DeskItemPresentation.nagBellSymbol(config: .init(enabled: false), now: now) == "bell")
        #expect(DeskItemPresentation.nagBellSymbol(config: .init(enabled: true), now: now) == "bell.fill")
        #expect(DeskItemPresentation.nagBellSymbol(config: .init(enabled: true, mutedUntil: "9999-12-31"), now: now) == "bell.slash")
    }

    @Test("context receipt lists disclose every hidden row")
    func contextReceiptStringListMakesItsCapVisible() {
        #expect(ContextReceiptPresentation.remainingCount(total: 6, displayed: 6) == nil)
        #expect(ContextReceiptPresentation.remainingCount(total: 7, displayed: 6) == 1)
        #expect(ContextReceiptPresentation.remainingCount(total: 19, displayed: 6) == 13)
    }

    @Test("malformed Desk freshness is unknown, never blank or fresh")
    func deskFreshnessDoesNotTurnAnInvalidTimestampIntoCalmWhitespace() {
        let freshness = DeskItemPresentation.freshness(for: deskItem(updatedAt: "not-a-timestamp"), now: Date())
        #expect(freshness == .init(text: "unknown", isStale: false, isKnown: false))
    }

    @Test("Telegram state retains explicit unavailable and configured distinctions")
    func telegramDisconnectCannotBeAnImmediateOrMisleadingAction() {
        #expect(TelegramSettingsPresentation.tokenStatusLabel(tokenConfigured: true) == "Bot token configured")
        #expect(TelegramSettingsPresentation.tokenStatusLabel(tokenConfigured: false) == "Bot token missing")
        #expect(TelegramPanelPresentation.readState(status: nil, refreshError: "read failed") == .unavailable(detail: "read failed"))
    }

    private func tool(name: String, required: [String], properties: [String: String]) -> ToolCapability {
        ToolCapability(name: name, description: "fixture", autonomy: "observe", effectiveAutonomy: "observe", autonomySource: "fixture", sideEffects: false, providerConstraints: nil, availableNow: true, inputSchema: ToolInputSchema(properties: Dictionary(uniqueKeysWithValues: properties.map { ($0.key, ToolInputProp(type: $0.value, description: nil)) }), required: required))
    }

    private func inboxItem(id: String) throws -> InboxItemRecord {
        try JSONDecoder().decode(InboxItemRecord.self, from: Data("""
        {"id":"\(id)","title":"Fixture","body":"Body","created_at":"2026-01-01T00:00:00Z","read":false}
        """.utf8))
    }

    private func deskItem(updatedAt: String) -> DeskItem {
        DeskItem(
            handle: "fixture",
            alias: "1",
            kind: .watch,
            project: "Eval",
            title: "Fixture",
            openedAt: "2026-01-01T00:00:00Z",
            updatedAt: updatedAt
        )
    }
}
