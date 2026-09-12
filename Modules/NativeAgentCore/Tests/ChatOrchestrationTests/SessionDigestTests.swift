import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle

// MARK: - The /new carry-over ANCHOR
//
// Covers: the surface-scoped, probe-excluding prior-session resolver (bridge
// sessions are full sessions as of 2026-09-12, 086055a4e); the
// two-line pointer payload (no telemetry, no quoted reply); first-turn-only
// injection at the head of the DYNAMIC segment; per-session BYTE-STABILITY
// across rebuilds (the prompt-cache invariant); absence when there is nothing
// to point at; and the adapter invariant systemPrompt == stable + "\n\n" +
// dynamic with the anchor present.

// MARK: helpers

/// Real surface sessions always carry UUID ids; bridge/probe runs supply
/// their own slug. The resolver keys on that, so fixtures must too.
private let currentTelegram = "11111111-1111-4111-8111-111111111111"
private let priorTelegram = "22222222-2222-4222-8222-222222222222"
private let otherTelegram = "33333333-3333-4333-8333-333333333333"
private let priorMac = "44444444-4444-4444-8444-444444444444"
private let bridgeTelegram = "55555555-5555-4555-8555-555555555555"

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sessiondigest-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func sessionRow(
    id: String,
    title: String,
    created: String,
    updated: String,
    source: String = "telegram",
    sourceKey: String? = "telegram:1394548068",
    messageCount: Int = 12,
    preview: String = "Morning, handsome. The board is quiet on my end.",
    archived: Bool = false
) -> String {
    var fields = [
        "\"id\": \"\(id)\"",
        "\"title\": \"\(title)\"",
        "\"createdAt\": \"\(created)\"",
        "\"updatedAt\": \"\(updated)\"",
        "\"source\": \"\(source)\"",
        "\"messageCount\": \(messageCount)",
        "\"lastMessagePreview\": \"\(preview)\"",
        "\"archived\": \(archived)",
    ]
    if let sourceKey { fields.append("\"sourceKey\": \"\(sourceKey)\"") }
    return "{" + fields.joined(separator: ", ") + "}"
}

private func writeSessions(root: URL, _ rows: [String]) throws {
    try write(
        "[\n" + rows.joined(separator: ",\n") + "\n]",
        to: root.appendingPathComponent("chat/sessions.json")
    )
}

/// The canonical fixture: a Telegram /new whose only honest carry-over is one
/// genuinely-prior Telegram session, surrounded by every row the old
/// surface-blind resolver used to pick instead.
private func writeSurfaceFixture(root: URL) throws {
    try writeSessions(root: root, [
        sessionRow(id: priorTelegram, title: "Genuine prior",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        sessionRow(id: currentTelegram, title: "Telegram 1394548068",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z",
                   messageCount: 0),
        // Newer, but a DIFFERENT surface.
        sessionRow(id: priorMac, title: "Mac window",
                   created: "2026-06-10T07:00:00Z", updated: "2026-06-10T08:00:00Z",
                   source: "app", sourceKey: "app"),
        // Newer, same surface kind, but a different chat/device.
        sessionRow(id: otherTelegram, title: "Someone else",
                   created: "2026-06-10T07:00:00Z", updated: "2026-06-10T08:50:00Z",
                   sourceKey: "telegram:999999"),
        // Newer, right surface, opened over the bridge — and since 2026-09-12
        // (086055a4e) that is a FULL session: a UUID-keyed row qualifies no
        // matter who its first message came from. This is the row that wins.
        sessionRow(id: bridgeTelegram, title: "[from: codex, via bridge] One read-only check",
                   created: "2026-06-10T08:00:00Z", updated: "2026-06-10T08:30:00Z"),
        // Newer, right surface — but a probe run with its own slug id.
        sessionRow(id: "generalist-outcome-proof-20260610", title: "Reply with exactly: ok",
                   created: "2026-06-10T08:40:00Z", updated: "2026-06-10T08:45:00Z"),
    ])
}

/// Words the old five-source digest put in front of her on every session
/// start. None of them may ever reappear in the anchor.
private let telemetryWords = [
    "worklog", "Workshop", "Standup", "Dream diary", "Traces:",
    "Activity since", "No recorded background activity", "Last reply:",
]

// MARK: engine harness (mirrors SessionHistoryTests)

private final class StubRoutingD: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": SurfacePreference(surface: "chat", model: "gpt-5.5", reasoningEffort: "high")]
    }
}

private struct FixedRecallStubD: MemoryRecalling {
    let hits: [MemoryRecallHit]
    func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] { hits }
}

private func makeDigestEngine(
    personaRoot: URL,
    remPinsDataRoot: URL? = nil,
    recallHits: [MemoryRecallHit] = []
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: hermeticPersona(root: personaRoot),
        memory: recallHits.isEmpty ? nil : FixedRecallStubD(hits: recallHits),
        router: StubRoutingD(),
        trust: hermeticTrust(),
        llm: MockLLMClient(scriptedResponses: ["ok"]),
        tools: MockToolDispatchClient(),
        remPinsDataRoot: remPinsDataRoot,
        memoryPromoter: nil
    )
}

// MARK: - resolver: surface-scoped and human-scoped

// 2026-09-12 (086055a4e): bridge turns are full turns, so the exclusions this
// test pins are the SURFACE ones (other source, other chat/device) plus the
// slug-id probe runs. A bridge-opened UUID session is no longer excluded.
@Test
func priorSession_resolver_skips_other_surfaces_and_probe_slugs() async throws {
    let root = try makeTempRoot("resolver-scope")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSurfaceFixture(root: root)

    let prior = try #require(
        PriorChatSession.latest(excluding: currentTelegram, dataRoot: root)
    )
    // The newest row on THIS chat, which is the bridge-opened one. The Mac
    // window (08:00) and the other Telegram chat (08:50) are both more recent
    // in the index and are both skipped, as is the probe slug (08:45).
    #expect(prior.id == bridgeTelegram)
    #expect(prior.source == "telegram")

    // The markings, stated directly: a bridge TITLE proves nothing now; a
    // free-form slug id is still a probe run.
    #expect(!PriorChatSession.isMachineOrigin(
        id: bridgeTelegram, title: "[from: codex, via bridge] One read-only check"))
    #expect(!PriorChatSession.isMachineOrigin(
        id: bridgeTelegram, title: "[from: claude, via bridge] resume 658.14"))
    #expect(PriorChatSession.isMachineOrigin(
        id: "generalist-outcome-proof-20260610", title: "Reply with exactly: ok"))
    #expect(!PriorChatSession.isMachineOrigin(id: priorTelegram, title: "Genuine prior"))

    // Symmetric: a bridge session is HANDED a carry-over too — it gets the
    // previous session on its own surface, which is the genuine prior.
    let handed = try #require(
        PriorChatSession.latest(excluding: bridgeTelegram, dataRoot: root)
    )
    #expect(handed.id == priorTelegram)
    // A probe slug is still handed nothing.
    #expect(PriorChatSession.latest(
        excluding: "generalist-outcome-proof-20260610", dataRoot: root) == nil)

    // A Mac /new in the same index gets the MAC session, never the Telegram one.
    try writeSessions(root: root, [
        sessionRow(id: priorTelegram, title: "Genuine prior",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        sessionRow(id: priorMac, title: "Mac window",
                   created: "2026-06-10T07:00:00Z", updated: "2026-06-10T08:00:00Z",
                   source: "app", sourceKey: "app"),
        sessionRow(id: currentTelegram, title: "New Chat",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z",
                   source: "app", sourceKey: "app", messageCount: 0),
    ])
    let macPrior = try #require(
        PriorChatSession.latest(excluding: currentTelegram, dataRoot: root)
    )
    #expect(macPrior.id == priorMac)
}

@Test
func priorSession_resolver_skips_interleaved_and_unknown_current_sessions() async throws {
    let root = try makeTempRoot("resolver-interleave")
    defer { try? FileManager.default.removeItem(at: root) }
    // The interleaved row is a second window still running NOW: created
    // before the current session, last active after it started.
    try writeSessions(root: root, [
        sessionRow(id: priorTelegram, title: "Genuine prior",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        sessionRow(id: currentTelegram, title: "Current",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z"),
        sessionRow(id: otherTelegram, title: "Interleaved other window",
                   created: "2026-06-10T08:00:00Z", updated: "2026-06-10T10:00:00Z"),
    ])
    let prior = try #require(
        PriorChatSession.latest(excluding: currentTelegram, dataRoot: root)
    )
    #expect(prior.id == priorTelegram)

    // A session with NO row in the index cannot be surface-scoped, so the
    // resolver says nothing rather than guessing across surfaces.
    #expect(PriorChatSession.latest(excluding: "never-written", dataRoot: root) == nil)
}

/// REGRESSION (reviewer finding, 2026-09-01). The id half of the machine test
/// was a blanket "not a UUID ⇒ machine", and Telegram's own store still mints
/// `telegram:<chatId>` for legacy human threads
/// (`TelegramSessionStore.legacySessionId`). Those threads were being dropped
/// from BOTH halves of the carry-over: never offered as the prior session, and
/// never handed one. The carve-out is corroborated by the row's own `source`,
/// because the live index also holds `telegram:codex-probe` rows that carry
/// `source: "app"` — id shape alone cannot tell them apart.
@Test
func priorSession_resolver_keeps_legacy_telegram_human_ids() async throws {
    let root = try makeTempRoot("resolver-legacy-telegram")
    defer { try? FileManager.default.removeItem(at: root) }

    let legacyPrior = "telegram:1394548068"
    let legacyCurrent = "telegram:-1001234567890" // group chats are negative
    try writeSessions(root: root, [
        sessionRow(id: legacyPrior, title: "Legacy human thread",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        sessionRow(id: legacyCurrent, title: "Telegram 1394548068",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z",
                   messageCount: 0),
        // Same id SHAPE, but a codex probe: the live index carries these with
        // source "app", and they must stay machine.
        sessionRow(id: "telegram:codex-probe", title: "Reply with exactly: tg probe 1 ok",
                   created: "2026-06-10T08:00:00Z", updated: "2026-06-10T08:50:00Z",
                   source: "app", sourceKey: "app"),
    ])

    let prior = try #require(
        PriorChatSession.latest(excluding: legacyCurrent, dataRoot: root)
    )
    #expect(prior.id == legacyPrior)

    // Stated directly, both directions of the carve-out.
    #expect(!PriorChatSession.isMachineOrigin(
        id: legacyPrior, title: "Legacy human thread", source: "telegram"))
    #expect(!PriorChatSession.isMachineOrigin(
        id: legacyCurrent, title: "Telegram group", source: "telegram"))
    #expect(PriorChatSession.isMachineOrigin(
        id: "telegram:codex-probe", title: "Reply with exactly: tg probe 1 ok", source: "app"))
    #expect(PriorChatSession.isMachineOrigin(
        id: "telegram:codex-tool-catalog-probe", title: "Use your tool catalog", source: "app"))
    // Fail closed: a telegram-SHAPED id we cannot corroborate against a
    // telegram row stays machine.
    #expect(PriorChatSession.isMachineOrigin(id: legacyPrior, title: "no source", source: nil))
    // 2026-09-12 (086055a4e): a bridge title no longer overrides the carve-out.
    // The ID and the row's source decide origin; who wrote the first message
    // does not. A bridge turn on a legacy human thread is still that thread.
    #expect(!PriorChatSession.isMachineOrigin(
        id: legacyPrior, title: "[from: codex, via bridge] check", source: "telegram"))
    // Slug probe ids are unchanged by the carve-out.
    #expect(PriorChatSession.isMachineOrigin(
        id: "generalist-outcome-proof-20260830", title: "Reply with exactly: ok", source: "app"))
}

/// REGRESSION (reviewer finding, 2026-09-01). Archived rows were invisible to
/// the resolver on both sides: a thread User has put away could be offered as
/// "your previous session", and an archived current row could still be handed
/// a carry-over it has no use for.
@Test
func priorSession_resolver_skips_archived_rows_on_both_sides() async throws {
    let root = try makeTempRoot("resolver-archived")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSessions(root: root, [
        sessionRow(id: priorTelegram, title: "Genuine prior",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        // Newer than the genuine prior, right surface, human — but ARCHIVED.
        sessionRow(id: otherTelegram, title: "Put away by hand",
                   created: "2026-06-10T07:00:00Z", updated: "2026-06-10T08:50:00Z",
                   archived: true),
        sessionRow(id: currentTelegram, title: "Current",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z",
                   messageCount: 0),
    ])
    let prior = try #require(
        PriorChatSession.latest(excluding: currentTelegram, dataRoot: root)
    )
    #expect(prior.id == priorTelegram, "an archived row was offered as the prior session")

    // And the symmetric half: an archived CURRENT row gets nothing.
    try writeSessions(root: root, [
        sessionRow(id: priorTelegram, title: "Genuine prior",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        sessionRow(id: currentTelegram, title: "Current, archived",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z",
                   messageCount: 0, archived: true),
    ])
    #expect(PriorChatSession.latest(excluding: currentTelegram, dataRoot: root) == nil)
}

// MARK: - payload: two lines, one of them a pointer

@Test
func sessionDigest_is_two_lines_and_carries_no_telemetry_or_quoted_reply() async throws {
    let root = try makeTempRoot("payload")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSurfaceFixture(root: root)
    let provider = SessionDigestProvider(dataRoot: root)

    let digest = try #require(await provider.digest(forSessionId: currentTelegram))
    let lines = digest.split(separator: "\n", omittingEmptySubsequences: false)

    #expect(lines.count == 2)
    #expect(lines[0] == SessionDigestProvider.headerLine[...])
    #expect(digest.contains("Your last Telegram session"))
    // 2026-09-12 (086055a4e): the newest same-surface row is the bridge-opened
    // one, and it gets a digest like any session — its title is what she sees.
    #expect(digest.contains("[from: codex, via bridge]"))
    #expect(digest.contains("12 messages"))
    #expect(digest.contains("ago."))
    #expect(digest.hasSuffix(SessionDigestProvider.pointerSentence))
    #expect(digest.count <= SessionDigestProvider.digestCharCap)

    // The clutter half of clause 6: none of the five background feeds, and
    // no verbatim quote of her own last words.
    for word in telemetryWords {
        #expect(!digest.lowercased().contains(word.lowercased()), "leaked \(word)")
    }
    #expect(!digest.contains("Morning, handsome"))
    #expect(!digest.contains("The board is quiet"))

    // Surface label is a closed vocabulary — an unknown `source` never lands
    // in her prompt as its own raw text.
    #expect(SessionDigestProvider.surfaceLabel("telegram") == "Telegram")
    #expect(SessionDigestProvider.surfaceLabel("app") == "Mac")
    #expect(SessionDigestProvider.surfaceLabel("ios") == "iOS")
    #expect(SessionDigestProvider.surfaceLabel("\u{202E}evil-surface") == "chat")
    #expect(SessionDigestProvider.surfaceLabel(nil) == "chat")
}

@Test
func sessionDigest_hard_cap_holds_for_an_absurd_title() async throws {
    let root = try makeTempRoot("cap")
    defer { try? FileManager.default.removeItem(at: root) }
    let longTitle = String(repeating: "Long title segment ", count: 40)
    try writeSessions(root: root, [
        sessionRow(id: priorTelegram, title: longTitle,
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z",
                   messageCount: 987_654),
        sessionRow(id: currentTelegram, title: "Current",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z"),
    ])
    let provider = SessionDigestProvider(dataRoot: root)
    let digest = try #require(await provider.digest(forSessionId: currentTelegram))
    #expect(digest.count <= SessionDigestProvider.digestCharCap)
    #expect(digest.split(separator: "\n").count == 2)
    // The pointer — the whole point of the anchor — survives the clip.
    #expect(digest.hasSuffix(SessionDigestProvider.pointerSentence))
}

@Test
func sessionDigest_relative_age_is_compact() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(SessionDigestProvider.relativeAge(now.addingTimeInterval(-30), from: now) == "just now")
    #expect(SessionDigestProvider.relativeAge(now.addingTimeInterval(-42 * 60), from: now) == "42m ago")
    #expect(SessionDigestProvider.relativeAge(now.addingTimeInterval(-6 * 3600), from: now) == "6h ago")
    #expect(SessionDigestProvider.relativeAge(now.addingTimeInterval(-3 * 86400), from: now) == "3d ago")
}

// MARK: - absence

@Test
func sessionDigest_no_qualifying_prior_returns_nil() async throws {
    // First session ever on this surface.
    let root = try makeTempRoot("fresh")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSessions(root: root, [
        sessionRow(id: currentTelegram, title: "First ever",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:05:00Z"),
    ])
    #expect(await SessionDigestProvider(dataRoot: root)
        .digest(forSessionId: currentTelegram) == nil)

    // 2026-09-12 (086055a4e): a bridge-only root is no longer "nothing to point
    // at" — the bridge session qualifies, so she gets her two lines. What still
    // returns nil is a row that is genuinely not hers: a probe slug.
    let bridgeOnly = try makeTempRoot("bridge-only")
    defer { try? FileManager.default.removeItem(at: bridgeOnly) }
    try writeSessions(root: bridgeOnly, [
        sessionRow(id: bridgeTelegram, title: "[from: codex, via bridge] check",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        sessionRow(id: currentTelegram, title: "Current",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z"),
    ])
    let bridgeDigest = try #require(await SessionDigestProvider(dataRoot: bridgeOnly)
        .digest(forSessionId: currentTelegram))
    #expect(bridgeDigest.contains("Your last Telegram session"))

    let probeOnly = try makeTempRoot("probe-only")
    defer { try? FileManager.default.removeItem(at: probeOnly) }
    try writeSessions(root: probeOnly, [
        sessionRow(id: "generalist-outcome-proof-20260609", title: "Reply with exactly: ok",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z"),
        sessionRow(id: currentTelegram, title: "Current",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z"),
    ])
    #expect(await SessionDigestProvider(dataRoot: probeOnly)
        .digest(forSessionId: currentTelegram) == nil)

    // Missing index, corrupt index, blank session id: nil, never a throw.
    let empty = try makeTempRoot("empty")
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(await SessionDigestProvider(dataRoot: empty).digest(forSessionId: "any") == nil)
    let corrupt = try makeTempRoot("corrupt")
    defer { try? FileManager.default.removeItem(at: corrupt) }
    try write("{{{{ not json at all", to: corrupt.appendingPathComponent("chat/sessions.json"))
    #expect(await SessionDigestProvider(dataRoot: corrupt).digest(forSessionId: "s") == nil)
    #expect(await SessionDigestProvider(dataRoot: root).digest(forSessionId: "   ") == nil)
}

// MARK: - byte stability

@Test
func sessionDigest_frozen_bytes_survive_rebuilds_and_moving_sources() async throws {
    let root = try makeTempRoot("frozen")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSurfaceFixture(root: root)
    let provider = SessionDigestProvider(dataRoot: root)

    let first = try #require(await provider.digest(forSessionId: currentTelegram))
    let diskPath = root.appendingPathComponent(
        "chat/session_state/\(currentTelegram)/digest.txt")
    #expect(try String(contentsOf: diskPath, encoding: .utf8) == first)

    // The index MOVES underneath us (the prior session gets renamed and grows,
    // a newer session appears) and the in-memory cache is evicted.
    try writeSessions(root: root, [
        sessionRow(id: priorTelegram, title: "RENAMED AFTER FREEZE",
                   created: "2026-06-09T18:00:00Z", updated: "2026-06-09T20:00:00Z",
                   messageCount: 9_999),
        sessionRow(id: currentTelegram, title: "Current",
                   created: "2026-06-10T09:00:00Z", updated: "2026-06-10T09:00:00Z"),
        sessionRow(id: otherTelegram, title: "Appeared later",
                   created: "2026-06-10T08:00:00Z", updated: "2026-06-10T08:59:00Z"),
    ])
    await SessionDigestCache.shared.removeAll()

    let second = try #require(await provider.digest(forSessionId: currentTelegram))
    #expect(second == first)
    #expect(!second.contains("RENAMED AFTER FREEZE"))
    #expect(!second.contains("Appeared later"))
}

/// Thread-safe build counter for the single-flight assertion.
private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Test
func sessionDigest_concurrent_first_turns_yield_identical_bytes_from_one_build() async throws {
    let root = try makeTempRoot("concurrent")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSurfaceFixture(root: root)
    let provider = SessionDigestProvider(dataRoot: root)
    let results = await withTaskGroup(of: String?.self) { group in
        for _ in 0..<8 {
            group.addTask { await provider.digest(forSessionId: currentTelegram) }
        }
        var out: [String?] = []
        for await r in group { out.append(r) }
        return out
    }
    let first = try #require(results.first ?? nil)
    #expect(results.count == 8)
    #expect(results.allSatisfy { $0 == first })

    // The single-flight mechanism itself: concurrent misses on ONE key run
    // the build closure exactly once.
    let counter = BuildCounter()
    let key = "single-flight-\(UUID().uuidString)"
    let values = await withTaskGroup(of: String.self) { group in
        for _ in 0..<8 {
            group.addTask {
                await SessionDigestCache.shared.value(forKey: key) {
                    counter.increment()
                    Thread.sleep(forTimeInterval: 0.05)
                    return "BUILT-ONCE"
                }
            }
        }
        var out: [String] = []
        for await v in group { out.append(v) }
        return out
    }
    #expect(values.allSatisfy { $0 == "BUILT-ONCE" })
    #expect(counter.count == 1)
}

// MARK: - engine integration: first turn only, head of DYNAMIC

@Test
func buildTurnContextWithHistory_injects_anchor_at_head_of_dynamic_on_turn_one_only() async throws {
    let root = try makeTempRoot("inject")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSurfaceFixture(root: root)
    let provider = SessionDigestProvider(dataRoot: root)
    try write(
        """
        {"SOUL.md": [{"id": "pin-1", "text": "PIN-MARKER-BEFORE-ANCHOR", "createdAt": "2026-06-01T00:00:00Z"}]}
        """,
        to: root.appendingPathComponent("rem_pins.json")
    )
    let personaDir = try makeTempRoot("persona-inject")
    defer { try? FileManager.default.removeItem(at: personaDir) }
    try write("PERSONA-MARKER-STABLE", to: personaDir.appendingPathComponent("SOUL.md"))
    let engine = makeDigestEngine(
        personaRoot: personaDir,
        remPinsDataRoot: root,
        recallHits: [MemoryRecallHit(score: 0.9, preview: "RECALL-MARKER-DYNAMIC")]
    )
    let reader = SessionHistoryReader(dataRoot: root)

    // TURN 1 — no on-disk history yet.
    let turn1 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: currentTelegram,
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let seg1 = try #require(turn1.systemSegments)
    let anchor = try #require(await provider.digest(forSessionId: currentTelegram))

    // Head of the DYNAMIC segment — per-session bytes on the churning side of
    // the stable-end cache breakpoint — and never inside stable.
    #expect(seg1.dynamic.hasPrefix(anchor))
    #expect(!seg1.stable.contains(SessionDigestProvider.headerLine))
    let persona = try #require(seg1.stable.range(of: "PERSONA-MARKER-STABLE"))
    let pin = try #require(seg1.stable.range(of: "PIN-MARKER-BEFORE-ANCHOR"))
    #expect(persona.lowerBound < pin.lowerBound)
    // Model-visible order: persona + pins, then anchor, then recall.
    let combined = try #require(turn1.systemPrompt)
    let cPin = try #require(combined.range(of: "PIN-MARKER-BEFORE-ANCHOR"))
    let cHeader = try #require(combined.range(of: SessionDigestProvider.headerLine))
    let cRecall = try #require(combined.range(of: "RECALL-MARKER-DYNAMIC"))
    #expect(cPin.lowerBound < cHeader.lowerBound)
    #expect(cHeader.lowerBound < cRecall.lowerBound)
    #expect(turn1.systemPrompt == seg1.combined)
    #expect(seg1.reassembles(into: turn1.systemPrompt ?? ""))

    // TURN 2 — the session now has rows of its own. The continuity card
    // carries the thread; the anchor would be duplication.
    try write(
        """
        {"role": "user", "content": "CURRENT-CONVERSATION-MARKER", "createdAt": "2026-06-10T10:00:00Z"}
        {"role": "assistant", "content": "CURRENT-REPLY-MARKER", "createdAt": "2026-06-10T10:00:01Z"}
        """ + "\n",
        to: root.appendingPathComponent("chat/messages/\(currentTelegram).jsonl")
    )
    let turn2 = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "second", sessionId: currentTelegram,
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let seg2 = try #require(turn2.systemSegments)
    #expect(!(turn2.systemPrompt ?? "").contains(SessionDigestProvider.headerLine))
    #expect((turn2.systemPrompt ?? "").contains("CURRENT-CONVERSATION-MARKER"))
    // The cacheable prefix is unchanged between the two turns.
    #expect(seg1.stable == seg2.stable)
    #expect(seg2.reassembles(into: turn2.systemPrompt ?? ""))
}

@Test(arguments: [false, true])
func buildTurnContextWithHistory_without_a_provider_omits_the_anchor(
    hasPersistedAnchor: Bool
) async throws {
    let root = try makeTempRoot("ordinary-no-anchor")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSurfaceFixture(root: root)
    let digestPath = root.appendingPathComponent(
        "chat/session_state/\(currentTelegram)/digest.txt")
    let cached = SessionDigestProvider.headerLine + "\nCACHED-ANCHOR-MARKER"
    if hasPersistedAnchor { try write(cached, to: digestPath) }
    let personaDir = try makeTempRoot("persona-ordinary")
    defer { try? FileManager.default.removeItem(at: personaDir) }
    try write("PERSONA-MARKER-STABLE", to: personaDir.appendingPathComponent("SOUL.md"))
    let engine = makeDigestEngine(personaRoot: personaDir, remPinsDataRoot: root)
    let reader = SessionHistoryReader(dataRoot: root)

    // The default overload — background loops, triggers, evaluation harnesses.
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: currentTelegram,
        historyLimit: 8, historyReader: reader
    )
    let prompt = try #require(ctx.systemPrompt)
    #expect(!prompt.contains(SessionDigestProvider.headerLine))
    #expect(!prompt.contains("CACHED-ANCHOR-MARKER"))
    #expect(!prompt.contains("Genuine prior"))
    #expect(ctx.systemSegments?.reassembles(into: prompt) == true)
    if hasPersistedAnchor {
        // Not reading an anchor never deletes or rewrites one.
        #expect(try String(contentsOf: digestPath, encoding: .utf8) == cached)
    } else {
        #expect(!FileManager.default.fileExists(atPath: digestPath.path))
    }
}

/// REGRESSION GUARD (2026-07-24): the stable segment must be byte-identical
/// across two DIFFERENT sessions. The prompt cache is an exact-prefix match
/// scoped to the ORGANIZATION, not to a session, so anything per-session
/// inside the stable block makes the stable-end breakpoint a guaranteed miss
/// on every fresh session.
@Test
func stable_segment_is_byte_identical_across_different_sessions() async throws {
    let root = try makeTempRoot("cross-session")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSurfaceFixture(root: root)
    let provider = SessionDigestProvider(dataRoot: root)
    let personaDir = try makeTempRoot("persona-cross")
    defer { try? FileManager.default.removeItem(at: personaDir) }
    try write("PERSONA-BYTES", to: personaDir.appendingPathComponent("SOUL.md"))
    let reader = SessionHistoryReader(dataRoot: root)
    let engine = makeDigestEngine(personaRoot: personaDir)

    let a = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: currentTelegram,
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let b = try await engine.buildTurnContextWithHistory(
        surface: "chat", userMessage: "hi", sessionId: otherTelegram,
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: provider
    )
    let segA = try #require(a.systemSegments)
    let segB = try #require(b.systemSegments)
    #expect(segA.stable == segB.stable)
    #expect(!segA.stable.contains(SessionDigestProvider.headerLine))
    #expect(!segB.stable.contains(SessionDigestProvider.headerLine))
    #expect(segA.reassembles(into: a.systemPrompt ?? ""))
    #expect(segB.reassembles(into: b.systemPrompt ?? ""))
}

// 2026-08-11 humanizer-v2 live-gap repro: the bridge probe showed
// expression.rhythmCuePending=false on a wrapped social serve that the unit
// classifier accepts — this drives the REAL builder end-to-end to find which
// rung drops the cue.
@Test
func buildTurnContextWithHistory_socialServe_setsServeCue() async throws {
    let root = try makeTempRoot("serve-cue")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSessions(root: root, [
        sessionRow(id: currentTelegram, title: "Serve",
                   created: "2026-08-11T09:00:00Z", updated: "2026-08-11T09:00:00Z"),
    ])
    let personaDir = try makeTempRoot("persona-serve")
    defer { try? FileManager.default.removeItem(at: personaDir) }
    try write("PERSONA-SERVE", to: personaDir.appendingPathComponent("SOUL.md"))
    let engine = makeDigestEngine(personaRoot: personaDir)
    let reader = SessionHistoryReader(dataRoot: root)
    let ctx = try await engine.buildTurnContextWithHistory(
        surface: "chat",
        userMessage: "[from: claude, via bridge] goodnight silly \u{1F49C}",
        sessionId: currentTelegram,
        historyLimit: 8, historyReader: reader,
        personaOverride: nil, sessionDigest: nil
    )
    #expect(ctx.naturalExpressionCue == NaturalExpressionGuidance.serveCue)
}
