import XCTest
@testable import CommandPalette

/// Subsystem #17 cluster C4: SwiftNative command palette tests.
///
/// Parity reference: the retired daemon::command_palette_entries() at
/// :5769-5928 (14 entries) and command_palette(q, limit) at :5930-5984.
final class SwiftNativeCommandPaletteTests: XCTestCase {

    // MARK: - Static manifest (defaults context)

    func testStaticManifestEntryCount() {
        // The daemon ships exactly 14 entries in command_palette_entries().
        // Verified on 2026-05-31 via `grep '"id":' the retired daemon |
        // awk -F: '$2>=5769 && $2<=5973'`.
        XCTAssertEqual(commandPaletteEntries().count, 14)
    }

    func testStaticManifestIdsAreUniqueAndStable() {
        // Spotlight + the operating-map index both depend on these ids being
        // stable. Hard-pin to catch a silent reorder/rename.
        let ids = commandPaletteEntries().map { $0.id }
        let expected: [String] = [
            "chat",
            "telegram-config",
            "memory-hygiene",
            "provider-settings",
            "connector-proof",
            "mac-assistant-watch-setup",
            "capability-foundry",
            "approvals",
            "doctor",
            "logs",
            "skills",
            "self-improvement-scoreboard",
            "screen-vision",
            "operating-map",
        ]
        XCTAssertEqual(ids, expected)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
    }

    func testStaticManifestEveryEntryHasCoreFields() {
        // The Mac UI dereferences these without optional chains; an empty
        // value breaks Spotlight's row render.
        for entry in commandPaletteEntries() {
            XCTAssertFalse(entry.id.isEmpty, "id empty for \(entry)")
            XCTAssertFalse(entry.title.isEmpty, "title empty for \(entry.id)")
            XCTAssertFalse(entry.subtitle.isEmpty, "subtitle empty for \(entry.id)")
            XCTAssertFalse(entry.category.isEmpty, "category empty for \(entry.id)")
            XCTAssertFalse(entry.systemImage.isEmpty, "systemImage empty for \(entry.id)")
            XCTAssertFalse(entry.route.isEmpty, "route empty for \(entry.id)")
            XCTAssertFalse(entry.endpoint.isEmpty, "endpoint empty for \(entry.id)")
        }
    }

    // MARK: - Dynamic value injection (wave 5)

    func testPersonaNameInjectedIntoChatSubtitle() {
        // Wave 5: chat entry subtitle must use the live persona name from
        // CommandPaletteContext, not the hardcoded "NativeAgent" of wave 2.
        let ctx = CommandPaletteContext(personaName: "Claude")
        let entries = commandPaletteEntries(context: ctx)
        guard let chat = entries.first(where: { $0.id == "chat" }) else {
            return XCTFail("chat entry missing")
        }
        XCTAssertEqual(chat.subtitle, "Talk to Claude with routed context and lazy tools.")
        XCTAssertFalse(chat.subtitle.contains("NativeAgent"))
        // The persona name (lowercased) is also injected into the keywords array.
        XCTAssertTrue(chat.keywords.contains("claude"), "keywords=\(chat.keywords)")
    }

    func testPersonaNameInjectedIntoOperatingMapTitle() {
        // Wave 5: operating-map title is f"{agent_name} Operating Map" in Python
        // (L5965). Swift must use the live name, not the hardcoded "NativeAgent".
        let ctx = CommandPaletteContext(personaName: "Claude")
        let entries = commandPaletteEntries(context: ctx)
        guard let map = entries.first(where: { $0.id == "operating-map" }) else {
            return XCTFail("operating-map entry missing")
        }
        XCTAssertEqual(map.title, "Claude Operating Map")
        XCTAssertFalse(map.title.contains("NativeAgent"))
    }

    func testApprovalsStatusFlipsOnPendingCount() {
        // Wave 5: approvals entry status is "attention" when pending > 0,
        // "ready" otherwise (Python L5904). Count badge equals the integer.
        let ready = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", pendingApprovalsCount: 0))
        let attention = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", pendingApprovalsCount: 3))
        XCTAssertEqual(ready.first(where: { $0.id == "approvals" })?.status, "ready")
        XCTAssertEqual(ready.first(where: { $0.id == "approvals" })?.count, 0)
        XCTAssertEqual(attention.first(where: { $0.id == "approvals" })?.status, "attention")
        XCTAssertEqual(attention.first(where: { $0.id == "approvals" })?.count, 3)
    }

    func testSelfImprovementStatusFlipsOnImprovementFailed() {
        // Wave 10: self-improvement-scoreboard status is "attention" when
        // improvementFailed > 0, "ready" otherwise (Python L5950).
        let ready = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", improvementFailedCount: 0))
        let attention = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", improvementFailedCount: 3))
        XCTAssertEqual(ready.first(where: { $0.id == "self-improvement-scoreboard" })?.status, "ready")
        XCTAssertEqual(attention.first(where: { $0.id == "self-improvement-scoreboard" })?.status, "attention")
    }

    func testOperatingMapStatusFlipsOnEnableAutonomy() {
        // Wave 5: operating-map status is "ready" when enableAutonomy is true,
        // "attention" otherwise (Python L5972).
        let on = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", enableAutonomy: true))
        let off = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", enableAutonomy: false))
        XCTAssertEqual(on.first(where: { $0.id == "operating-map" })?.status, "ready")
        XCTAssertEqual(off.first(where: { $0.id == "operating-map" })?.status, "attention")
    }

    func testConnectorProofStatusFlipsOnNeedsProof() {
        // Wave 5: connector-proof status is "attention" when needsProof is
        // true, "ready" otherwise (Python L5869).
        let ready = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", connectorNeedsProof: false))
        let attention = commandPaletteEntries(context: CommandPaletteContext(personaName: "Claude", connectorNeedsProof: true))
        XCTAssertEqual(ready.first(where: { $0.id == "connector-proof" })?.status, "ready")
        XCTAssertEqual(attention.first(where: { $0.id == "connector-proof" })?.status, "attention")
    }

    func testMacAssistantStatusAndCountInjected() {
        // Wave 5: mac-assistant-watch-setup entry takes both status and count
        // from context (Python L5880-L5881).
        let ctx = CommandPaletteContext(
            personaName: "Claude",
            macAssistantStatus: "attention",
            macAssistantTemplateAttentionCount: 2
        )
        let entries = commandPaletteEntries(context: ctx)
        let mac = entries.first(where: { $0.id == "mac-assistant-watch-setup" })
        XCTAssertEqual(mac?.status, "attention")
        XCTAssertEqual(mac?.count, 2)
    }

    func testDefaultsContextMatchesPythonMissingPolicyBaseline() {
        // The CommandPaletteContext.wave2NeutralBaseline value renders the
        // manifest with persona name "NativeAgent" and the missing-policy baseline:
        // when no live trust policy is loaded, `enableAutonomy` is treated as
        // false (Python L5972: "ready" if trust.get("enableAutonomy") else
        // "attention"), so the operating-map entry surfaces "attention". This
        // is the baseline used by the MacSyncEngine/SpotlightOverlay carve
        // where runtime is nil and no CommandPaletteContext can be built.
        let entries = commandPaletteEntries(context: .wave2NeutralBaseline)
        XCTAssertEqual(entries.first(where: { $0.id == "chat" })?.subtitle,
                       "Talk to NativeAgent with routed context and lazy tools.")
        XCTAssertEqual(entries.first(where: { $0.id == "operating-map" })?.title,
                       "NativeAgent Operating Map")
        XCTAssertEqual(entries.first(where: { $0.id == "telegram-config" })?.status, "optional")
        XCTAssertEqual(entries.first(where: { $0.id == "approvals" })?.status, "ready")
        XCTAssertEqual(entries.first(where: { $0.id == "approvals" })?.count, 0)
        // Default enableAutonomy=false → "attention" (matches Python missing-policy).
        XCTAssertEqual(entries.first(where: { $0.id == "operating-map" })?.status, "attention")
        XCTAssertEqual(entries.first(where: { $0.id == "screen-vision" })?.status, "ready")
        XCTAssertEqual(entries.first(where: { $0.id == "self-improvement-scoreboard" })?.status, "ready")
    }

    func testWave2NeutralBaselineMatchesPreviousDefaults() {
        // Wave 10 prereq C: `.defaults` was renamed to `.wave2NeutralBaseline`
        // (the rename is the semantic-honesty fix — it is the zero-state
        // baseline, NOT a Python `include_dynamic_statuses=False` match).
        // Field-for-field equality with what the old `.defaults` was.
        let ctx = CommandPaletteContext.wave2NeutralBaseline
        XCTAssertEqual(ctx.personaName, "NativeAgent")
        XCTAssertEqual(ctx.telegramHealthStatus, "optional")
        XCTAssertEqual(ctx.connectorNeedsProof, false)
        XCTAssertEqual(ctx.macAssistantStatus, "ready")
        XCTAssertEqual(ctx.macAssistantTemplateAttentionCount, 0)
        XCTAssertEqual(ctx.foundryReviewCount, 0)
        XCTAssertEqual(ctx.pendingApprovalsCount, 0)
        XCTAssertEqual(ctx.skillDraftCount, 0)
        XCTAssertEqual(ctx.multimodalStatus, "ready")
        XCTAssertEqual(ctx.enableAutonomy, false)
        XCTAssertEqual(ctx.improvementFailedCount, 0)
    }

    func testLightweightFactoryMatchesPythonLightweightBranch() {
        // Wave 10 prereq C: `.lightweight(...)` matches the Python
        // `include_dynamic_statuses=False` branch (daemon the retired daemon
        // L5811-5813). Live persona / autonomy.counts.* / trust / telegram
        // health are preserved; ONLY connector / multimodal / mac-assistant
        // go neutral.
        let ctx = CommandPaletteContext.lightweight(
            personaName: "Agent",
            telegramHealthStatus: "healthy",
            pendingApprovalsCount: 2,
            foundryReviewCount: 4,
            skillDraftCount: 5,
            improvementFailedCount: 2,
            enableAutonomy: true
        )
        let entries = commandPaletteEntries(context: ctx)
        // Live: persona name flows into chat subtitle.
        XCTAssertEqual(entries.first(where: { $0.id == "chat" })?.subtitle,
                       "Talk to Agent with routed context and lazy tools.")
        // Live: telegram health status.
        XCTAssertEqual(entries.first(where: { $0.id == "telegram-config" })?.status, "healthy")
        // Live: approvals status flips + count badge.
        XCTAssertEqual(entries.first(where: { $0.id == "approvals" })?.status, "attention")
        XCTAssertEqual(entries.first(where: { $0.id == "approvals" })?.count, 2)
        // Live: enableAutonomy → operating-map "ready".
        XCTAssertEqual(entries.first(where: { $0.id == "operating-map" })?.status, "ready")
        // Lightweight-neutralized: connector-proof needsProof forced false → "ready".
        XCTAssertEqual(entries.first(where: { $0.id == "connector-proof" })?.status, "ready")
        // Lightweight-neutralized: mac-assistant forced "ready"/0.
        XCTAssertEqual(entries.first(where: { $0.id == "mac-assistant-watch-setup" })?.status, "ready")
        XCTAssertEqual(entries.first(where: { $0.id == "mac-assistant-watch-setup" })?.count, 0)
        // Lightweight-neutralized: multimodal forced "ready".
        XCTAssertEqual(entries.first(where: { $0.id == "screen-vision" })?.status, "ready")
        // Live: foundry / skills / self-improvement counts preserved.
        XCTAssertEqual(entries.first(where: { $0.id == "capability-foundry" })?.count, 4)
        XCTAssertEqual(entries.first(where: { $0.id == "skills" })?.count, 5)
        XCTAssertEqual(entries.first(where: { $0.id == "self-improvement-scoreboard" })?.status, "attention")
    }

    // MARK: - Keyword tokenizer

    func testKeywordTokensMatchesDaemonRegex() {
        // [a-zA-Z0-9_][a-zA-Z0-9_-]{2,} after lowercasing.
        // "Tell me about Vision" -> "tell"/"about"/"vision". "me" is too short
        // to match (need 3+ trailing word chars). "about" is NOT in the daemon's
        // keyword_tokens stopword set, only
        // in the separate MEMORY_QUERY_STOPWORDS / ADAPTIVE_HINT_STOPWORDS sets
        // which are not used by the command_palette search path. Result: all 3.
        let toks = commandPaletteKeywordTokens("Tell me about Vision")
        XCTAssertEqual(Set(toks), Set(["tell", "about", "vision"]))
    }

    func testKeywordTokensDropsStopwords() {
        // The Python set is {the, and, for, with, that, this, from, into,
        //                    your, you, are, how, what}.
        let toks = commandPaletteKeywordTokens("what are the connector approvals")
        // "what", "are", "the" drop. "connector" + "approvals" survive.
        XCTAssertEqual(Set(toks), Set(["connector", "approvals"]))
    }

    func testKeywordTokensIgnoresShortTokens() {
        // Need length >= 3.
        let toks = commandPaletteKeywordTokens("a b cd")
        XCTAssertTrue(toks.isEmpty, "expected empty got \(toks)")
    }

    func testKeywordTokensAcceptsHyphensAndUnderscores() {
        let toks = commandPaletteKeywordTokens("test-name some_id")
        XCTAssertTrue(toks.contains("test-name"), "got \(toks)")
        XCTAssertTrue(toks.contains("some_id"), "got \(toks)")
    }

    // MARK: - Search scoring

    func testSearchEmptyQueryReturnsAllEntriesUpToLimit() {
        let result = searchCommandPalette("", limit: 50)
        XCTAssertEqual(result.count, commandPaletteEntries().count)
        // Order preserved when no tokens.
        XCTAssertEqual(result.map(\.id), commandPaletteEntries().map(\.id))
    }

    func testSearchWhitespaceOnlyQueryReturnsAllEntries() {
        // No tokens come out -> no-token branch.
        let result = searchCommandPalette("   ", limit: 50)
        XCTAssertEqual(result.count, commandPaletteEntries().count)
    }

    func testSearchTitleHitBeatsKeywordOnlyHit() {
        // "approvals" is in the title of the approvals entry AND in keywords
        // of approvals (so score = 3 + 1 = 4 there). It's not in any other
        // entry's title or keywords. Top result must be the approvals entry.
        let result = searchCommandPalette("approvals", limit: 5)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.first?.id, "approvals")
    }

    func testSearchKeywordHitFindsExpectedEntry() {
        // "telegram" appears in the telegram-config entry's title, subtitle,
        // and keywords. No other entry has it. Top must be telegram-config.
        let result = searchCommandPalette("telegram", limit: 3)
        XCTAssertEqual(result.first?.id, "telegram-config")
    }

    func testSearchVisionQueryFindsScreenVision() {
        // Documented live check in docs/HANDOFF_CURRENT.md:543 expects
        // /v1/command/search?q=vision to return screen-vision first.
        let result = searchCommandPalette("vision", limit: 3)
        XCTAssertEqual(result.first?.id, "screen-vision")
    }

    func testSearchProofQueryFindsConnectorProof() {
        // Documented live check in docs/HANDOFF_CURRENT.md:543 expects
        // /v1/command/search?q=proof to return connector-proof.
        let result = searchCommandPalette("proof", limit: 3)
        XCTAssertEqual(result.first?.id, "connector-proof")
    }

    func testSearchNoMatchReturnsEmpty() {
        // No entry has the token "xyzzy".
        let result = searchCommandPalette("xyzzy", limit: 5)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Limit clamping

    func testLimitClampedToOneFromBelow() {
        // limit=0 must clamp to 1 (max(1, min(0, 100)) == 1), matching the
        // daemon's `limit = max(1, min(int(limit or 50), 100))`.
        let result = searchCommandPalette("", limit: 0)
        XCTAssertEqual(result.count, 1)
    }

    func testLimitClampedToHundredFromAbove() {
        // limit=500 clamps to 100. There are only 14 entries so we get 14.
        let result = searchCommandPalette("", limit: 500)
        XCTAssertEqual(result.count, 14)
    }

    func testLimitOneReturnsExactlyOne() {
        let result = searchCommandPalette("", limit: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "chat")
    }

    func testLimitGreaterThanTotalReturnsAllEntries() {
        let result = searchCommandPalette("", limit: 50)
        XCTAssertEqual(result.count, 14)
    }

    // MARK: - Envelope

    func testEnvelopeShape() {
        let resp = commandPaletteResponse(query: "", limit: 50)
        XCTAssertEqual(resp.status, "ready")
        XCTAssertEqual(resp.query, "")
        XCTAssertEqual(resp.entries.count, 14)
        XCTAssertEqual(resp.lazyContract.chatInjection, "none")
        XCTAssertEqual(resp.lazyContract.inventoryMode, "manifest_routed")
        XCTAssertEqual(resp.lazyContract.opens, "route or endpoint only; command bodies stay lazy until selected")
        XCTAssertFalse(resp.createdAt.isEmpty)
    }
}
