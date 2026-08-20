import Foundation
import Testing
import NativeAgentShared
@testable import NativeAgentApp

/// 658.14 — session provenance and active-work navigation.
@Suite("Mac chat session provenance")
struct MacChatSessionProvenanceTests {

    // MARK: - Provenance projection

    @Test func humanTypedMessageCarriesNoBadge() {
        // The ordinary case must stay silent. A badge on every row is noise
        // that trains the eye past the badge, defeating its purpose.
        #expect(MacChatMessageProvenance.make(role: "user", source: "app", origin: nil) == nil)
        #expect(MacChatMessageProvenance.make(role: "user", source: nil, origin: nil) == nil)
        #expect(MacChatMessageProvenance.make(role: "user", source: "chat", origin: nil) == nil)
    }

    @Test func bridgeMessageIsMarkedEvenThoughItsSourceIsApp() {
        // THE defect. The bridge persists source "app" on purpose (surface is
        // also the tool-authorization surface), so source alone cannot tell a
        // wake payload from User. The out-of-band origin record must.
        let origin = ChatMessageOriginMetadata(surface: "claude-bridge", agent: "claude")
        let badge = MacChatMessageProvenance.make(role: "user", source: "app", origin: origin)
        #expect(badge?.label == "Claude - bridge")
        #expect(badge?.isAutomated == true)
    }

    @Test func codexBridgeIsDistinguishedFromClaude() {
        let codex = MacChatMessageProvenance.make(
            role: "user", source: "app",
            origin: ChatMessageOriginMetadata(surface: "codex-bridge", agent: "codex")
        )
        let claude = MacChatMessageProvenance.make(
            role: "user", source: "app",
            origin: ChatMessageOriginMetadata(surface: "claude-bridge", agent: "claude")
        )
        #expect(codex?.label == "Codex - bridge")
        #expect(codex?.label != claude?.label)
    }

    @Test func explicitOriginCanNeverHideBehindALocalLookingSurface() {
        for surface in ["app", "chat", "mac", "default"] {
            let badge = MacChatMessageProvenance.make(
                role: "user",
                source: "app",
                origin: ChatMessageOriginMetadata(surface: surface, agent: nil)
            )
            #expect(badge?.label == "Automated", "explicit \(surface) origin looked human")
            #expect(badge?.isAutomated == true)
        }
    }

    @Test func namedBridgeBadgeRequiresAnAgreeingExplicitAgent() {
        let cases: [(surface: String, agent: String?)] = [
            ("claude-bridge", nil),
            ("claude-bridge", "codex"),
            ("codex-bridge", nil),
            ("codex-bridge", "claude"),
        ]
        for value in cases {
            let badge = MacChatMessageProvenance.make(
                role: "user",
                source: "app",
                origin: ChatMessageOriginMetadata(surface: value.surface, agent: value.agent)
            )
            #expect(badge?.label == "Automated")
        }

        // A source string by itself is routing data, not a named identity.
        #expect(
            MacChatMessageProvenance.make(
                role: "user", source: "claude-bridge", origin: nil
            )?.label == "Automated"
        )
    }

    @Test func machineAgentCannotBorrowAHumanTransportBadge() {
        for surface in ["telegram", "slack", "ios"] {
            let badge = MacChatMessageProvenance.make(
                role: "user",
                source: "app",
                origin: ChatMessageOriginMetadata(surface: surface, agent: "codex")
            )
            #expect(badge?.label == "Automated")
            #expect(badge?.isAutomated == true)
        }
    }

    @Test func nonUserRolesAreNeverBadged() {
        // Marking an assistant row with the bridge's origin would read as
        // "the reply came from the bridge", which is false.
        let origin = ChatMessageOriginMetadata(surface: "claude-bridge", agent: "claude")
        #expect(MacChatMessageProvenance.make(role: "assistant", source: "app", origin: origin) == nil)
        #expect(MacChatMessageProvenance.make(role: "tool", source: "app", origin: origin) == nil)
    }

    @Test func truthfulSourcesStillBadgeWithoutOriginMetadata() {
        // Human ingress surfaces already record honest sources; they get the
        // badge without an explicit bridge origin object.
        #expect(MacChatMessageProvenance.make(role: "user", source: "telegram", origin: nil)?.label == "Telegram")
        let slack = MacChatMessageProvenance.make(role: "user", source: "slack", origin: nil)
        #expect(slack?.label == "Slack")
        #expect(slack?.isAutomated == false)
        #expect(MacChatMessageProvenance.make(role: "user", source: "ios", origin: nil)?.label == "iPhone")
    }

    // MARK: - Injection surface

    @Test func unrecognizedOriginNeverRendersItsOwnText() {
        // A trust badge that prints attacker-influenced text is not a trust
        // badge. messageSource(for:) passes unknown surfaces through verbatim,
        // so this input shape is reachable. Every hostile variant must land on
        // the SAME fixed label, and none may leak any of their own characters.
        let hostile = [
            "\u{202E}ppa",                      // bidi override: renders as "app"
            "app\nClaude - bridge",            // newline break-out
            "user",                              // plain impersonation
            String(repeating: "x", count: 5000),// unbounded length
            "app\u{0000}",                      // control character
            "<script>alert(1)</script>",
            "javascript:alert(1)",
        ]
        for value in hostile {
            let badge = MacChatMessageProvenance.make(
                role: "user", source: "app",
                origin: ChatMessageOriginMetadata(surface: value, agent: value)
            )
            let label = badge?.label ?? ""
            #expect(label == "Automated", "leaked label for \(value.debugDescription)")
            #expect(badge?.isAutomated == true)
            // No fragment of the hostile value may appear in the rendered text.
            #expect(!label.contains("\u{202E}"))
            #expect(!label.contains("\n"))
            #expect(label.count <= 32)
        }
    }

    @Test func zeroWidthPaddedKnownOriginNormalisesRatherThanDowngrading() {
        // Foundation's whitespace set includes U+200B, so "  TELEGRAM<ZWSP> "
        // folds to "telegram" and matches the allowlist. That is correct and
        // not a leak: matching an allowlist entry is the design, and the
        // rendered label is still this file's own constant, never the input.
        // (This case was originally written as a hostile-input expectation and
        // failed; the test was wrong, the code was right.)
        let badge = MacChatMessageProvenance.make(
            role: "user", source: "  TELEGRAM\u{200B}  ", origin: nil
        )
        #expect(badge?.label == "Telegram")
    }

    @Test func everyRenderedLabelComesFromTheClosedSet() {
        // The invariant that actually carries the security weight, asserted
        // over arbitrary input: whatever is recorded, the badge text is always
        // one of this file's constants. No recorded byte ever reaches the view.
        let allowed: Set<String> = [
            "Claude - bridge", "Codex - bridge", "Telegram",
            "Slack", "iPhone", "Scheduled", "Automated",
        ]
        let inputs = [
            "\u{202E}egdirb - anatroC", "Claude - bridge\u{0000}evil",
            "iphone; rm -rf /", "data:text/html,<b>x", "file:///etc/passwd",
            String(repeating: "\u{202E}", count: 200), "\u{1F600}",
            "claude-bridge extra", "", " ",
        ]
        for value in inputs {
            let badge = MacChatMessageProvenance.make(
                role: "user", source: value,
                origin: ChatMessageOriginMetadata(surface: value, agent: value)
            )
            guard let label = badge?.label else { continue }
            #expect(allowed.contains(label), "escaped closed set: \(label.debugDescription)")
        }
    }

    @Test func unknownOriginFailsTowardMachineNotHuman() {
        // The failure direction matters: unknown must never read as the human.
        let badge = MacChatMessageProvenance.make(
            role: "user", source: "some-future-transport", origin: nil
        )
        #expect(badge != nil, "unknown origin must not silently render as human-typed")
        #expect(badge?.isAutomated == true)
    }

    // MARK: - Active-work navigation

    @Test func everyRunningSessionGetsAReachableRoute() throws {
        // The defect: 2+ running sessions offered only a destructive bulk stop.
        let sessions = try [session(id: "s1", title: "Memory work"), session(id: "s2", title: "Telegram fix")]
        let routes = MacChatRunningSessionRoute.routes(sessionIds: ["s1", "s2"], sessions: sessions)
        #expect(routes.count == 2)
        #expect(routes.map(\.sessionId) == ["s1", "s2"])
        #expect(routes[0].title.hasPrefix("Memory work"))
        #expect(routes[1].title.hasPrefix("Telegram fix"))
        #expect(Set(routes.map(\.title)).count == 2)
    }

    @Test func runningSessionMissingFromTheListStillGetsARoutePendingRefresh() {
        // A stale index must not remove the action before navigation gets its
        // one canonical refresh opportunity.
        let routes = MacChatRunningSessionRoute.routes(sessionIds: ["abcdef123456"], sessions: [])
        #expect(routes.count == 1)
        #expect(routes[0].sessionId == "abcdef123456")
        #expect(!routes[0].title.isEmpty)
    }

    @Test func hostileSessionTitleIsBoundedBeforeReachingTheMenu() {
        // Session titles derive from message content, which includes untrusted
        // bridge payloads.
        let nasty = "Real\u{202E}gnihtemos\nSECOND LINE\u{0007}" + String(repeating: "y", count: 500)
        let title = MacChatRunningSessionRoute.displayTitle(rawTitle: nasty, sessionId: "s1")
        #expect(!title.contains("\n"))
        #expect(!title.contains("\u{202E}"))
        #expect(!title.contains("\u{0007}"))
        #expect(title.unicodeScalars.count <= MacChatRunningSessionRoute.titleScalarLimit)
        #expect(title.utf8.count <= MacChatRunningSessionRoute.titleScalarLimit * 4)
    }

    @Test func oneGraphemeCannotBypassTheScalarAndByteBound() {
        let combiningBomb = "A" + String(repeating: "\u{0301}", count: 10_000)
        #expect(combiningBomb.count == 1)
        let title = MacChatRunningSessionRoute.displayTitle(
            rawTitle: combiningBomb,
            sessionId: "s1"
        )
        #expect(title.unicodeScalars.count <= MacChatRunningSessionRoute.titleScalarLimit)
        #expect(title.utf8.count <= MacChatRunningSessionRoute.titleScalarLimit * 4)
    }

    @Test func duplicateStoredTitlesGetDistinctBoundedMenuLabels() throws {
        let sessions = try [
            session(id: "session-aaaaaaaa", title: "New Chat"),
            session(id: "session-bbbbbbbb", title: "New Chat"),
        ]
        let routes = MacChatRunningSessionRoute.routes(
            sessionIds: ["session-bbbbbbbb", "session-aaaaaaaa"],
            sessions: sessions
        )
        #expect(routes.map(\.sessionId) == ["session-aaaaaaaa", "session-bbbbbbbb"])
        #expect(Set(routes.map(\.title)).count == 2)
        #expect(routes.allSatisfy {
            $0.title.unicodeScalars.count <= MacChatRunningSessionRoute.titleScalarLimit
        })
    }

    @Test func storedTitleCannotForgeAnotherRowsGeneratedSuffix() throws {
        let sessions = try [
            session(id: "a", title: "X"),
            session(id: "b", title: "X"),
            session(id: "c", title: "X [1:a]"),
        ]
        let routes = MacChatRunningSessionRoute.routes(
            sessionIds: ["a", "b", "c"],
            sessions: sessions
        )
        #expect(routes.count == 3)
        #expect(Set(routes.map(\.title)).count == routes.count)
    }

    @Test func invisibleOrUnboundedDiscardedScalarsCannotHideWorkInTheMenu() {
        let markOnly = String(repeating: "\u{0301}", count: 20_000)
        let markTitle = MacChatRunningSessionRoute.displayTitle(
            rawTitle: markOnly,
            sessionId: "mark-session"
        )
        #expect(markTitle.hasPrefix("Session "))

        // Content beyond the fixed inspection budget is never consulted. An
        // attacker cannot force an unbounded scan by front-loading only bidi
        // controls/format scalars before a plausible title.
        let skippedBomb = String(
            repeating: "\u{202E}",
            count: MacChatRunningSessionRoute.titleInputScalarLimit + 1
        ) + "Looks legitimate"
        let skippedTitle = MacChatRunningSessionRoute.displayTitle(
            rawTitle: skippedBomb,
            sessionId: "format-session"
        )
        #expect(skippedTitle.hasPrefix("Session "))
        #expect(!skippedTitle.contains("Looks legitimate"))
    }

    @Test func placeholderTitleUsesTheCanonicalPreview() throws {
        let item = try session(
            id: "s-preview",
            title: ChatSession.placeholderTitle,
            lastMessagePreview: "Resume the provenance audit"
        )
        let route = try #require(
            MacChatRunningSessionRoute.routes(sessionIds: [item.id], sessions: [item]).first
        )
        #expect(route.title == "Resume the provenance audit")
    }

    @MainActor
    @Test func missingRouteRefreshesBeforeTransactionalSelection() async throws {
        let target = try session(id: "late-session", title: "Late index row")
        var indexed: [ChatSession] = []
        var refreshCount = 0
        var selectedID: String?

        let navigated = await MacChatRunningSessionNavigation.navigate(
            sessionId: target.id,
            sessions: { indexed },
            refresh: {
                refreshCount += 1
                indexed = [target]
            },
            select: {
                selectedID = $0.id
                return true
            }
        )

        #expect(navigated)
        #expect(refreshCount == 1)
        #expect(selectedID == target.id)
    }

    @MainActor
    @Test func missingRouteFailsHonestlyAfterOneRefresh() async {
        var refreshCount = 0
        var selected = false
        let navigated = await MacChatRunningSessionNavigation.navigate(
            sessionId: "not-indexed",
            sessions: { [] },
            refresh: { refreshCount += 1 },
            select: {
                _ in selected = true
                return true
            }
        )

        #expect(!navigated)
        #expect(refreshCount == 1)
        #expect(!selected)
    }

    @MainActor
    @Test func selectorFailureIsNotReportedAsSuccessfulNavigation() async throws {
        let target = try session(id: "load-fails", title: "Cannot load")
        var attempted = false
        let navigated = await MacChatRunningSessionNavigation.navigate(
            sessionId: target.id,
            sessions: { [target] },
            refresh: {},
            select: {
                _ in attempted = true
                return false
            }
        )

        #expect(attempted)
        #expect(!navigated)
    }

    @MainActor
    @Test func staleNavigationIntentCannotSelectAfterItsRefresh() async throws {
        let target = try session(id: "old-click", title: "Old click")
        var indexed: [ChatSession] = []
        var isCurrent = true
        var selected = false
        let navigated = await MacChatRunningSessionNavigation.navigate(
            sessionId: target.id,
            sessions: { indexed },
            refresh: {
                // Models click B arriving while click A is suspended in the
                // index refresh. A may finish refreshing, but may not select.
                isCurrent = false
                indexed = [target]
            },
            select: {
                _ in selected = true
                return true
            },
            isCurrentIntent: { isCurrent }
        )

        #expect(!navigated)
        #expect(!selected)
    }

    @Test func blankTitleFallsBackRatherThanRenderingEmpty() {
        // An empty menu row is an unclickable dead end.
        for raw in ["", "   ", "\n\n", "\u{202E}"] {
            let title = MacChatRunningSessionRoute.displayTitle(rawTitle: raw, sessionId: "sess-12345678")
            #expect(!title.trimmingCharacters(in: .whitespaces).isEmpty, "blank for \(raw.debugDescription)")
        }
    }

    /// ChatSession's memberwise init is not public across the module boundary;
    /// the existing app tests build one by decoding, so this does too.
    private func session(
        id: String,
        title: String,
        lastMessagePreview: String? = nil
    ) throws -> ChatSession {
        var object: [String: Any] = [
            "id": id, "title": title, "createdAt": "2026-08-19T00:00:00Z",
        ]
        if let lastMessagePreview { object["lastMessagePreview"] = lastMessagePreview }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ChatSession.self, from: data)
    }
}

/// The navigation half of 658.14, at the seam where the banner decides what to
/// offer. The route projection alone proves routes can be BUILT; this proves
/// the banner actually offers a way in at every count.
@Suite("Mac chat active-work navigation affordances")
struct MacChatOtherSessionsAffordancesTests {
    @Test func navigationIsOfferedAtEveryRunningCount() {
        // The regression this pins: at 2+ the banner used to offer ONLY a bulk
        // "Stop Others", so the case where you most need to find the work was
        // the case with no way to reach it.
        for count in 1...8 {
            let ids = (0..<count).map { "session-\($0)" }
            let decided = MacChatOtherSessionsAffordances.decide(otherRunning: ids)
            #expect(decided.offersNavigation, "no way to reach work at count \(count)")
        }
    }

    @Test func stoppingIsNeverTheOnlyExit() {
        for count in 1...8 {
            let ids = (0..<count).map { "session-\($0)" }
            let decided = MacChatOtherSessionsAffordances.decide(otherRunning: ids)
            #expect(!(decided.offersStop && !decided.offersNavigation),
                    "destructive-only affordance at count \(count)")
        }
    }

    @Test func noBannerWithoutBackgroundWork() {
        let decided = MacChatOtherSessionsAffordances.decide(otherRunning: [])
        #expect(decided == .none)
        #expect(!decided.offersNavigation)
    }

    @Test func singleRunningSessionNamesTheSessionItReturnsTo() {
        #expect(MacChatOtherSessionsAffordances.decide(otherRunning: ["only"])
                == .single(sessionId: "only"))
        #expect(MacChatOtherSessionsAffordances.decide(otherRunning: ["a", "b"])
                == .many(count: 2))
    }
}

/// 658.14 — the WIRE seam.
///
/// Why this suite exists as a separate thing: the projection tests above construct
/// `ChatMessageOriginMetadata` in memory and hand it straight to the
/// projection. Every one of them passed against a tree in which the badge was
/// inert on real data, because `ChatMessageMetadata` declares a custom
/// `init(from:)` — which suppresses the synthesized decoder, so adding a
/// `CodingKey` for `origin` without adding a matching `decodeIfPresent` line
/// decoded exactly nothing. A projection test cannot see that. Only a test
/// that starts from BYTES can.
///
/// The fixture below is the literal row shape written by
/// `ChatOrchestrationClient+MessagePersistence.swift` (`record` at :666,
/// `metadata["origin"]` at :704) — camelCase top-level keys, origin as a
/// nested object under `metadata`.
@Suite("Mac chat provenance decodes from persisted bytes")
struct MacChatProvenanceWireTests {

    /// A claude bridge wake exactly as it lands in `chat/messages/<sid>.jsonl`.
    /// Note `"source": "app"` — that is truthful and deliberate (the bridge
    /// runs on chat's tool surface), and it is why origin has to carry the
    /// provenance instead.
    private static let bridgeRowJSON = """
    {
      "id": "msg-658-14",
      "sessionId": "sess-658-14",
      "role": "user",
      "content": "[from: claude, via bridge] resume 658.14",
      "createdAt": "2026-08-19T21:11:08Z",
      "source": "app",
      "runId": "run-1",
      "metadata": {
        "origin": { "surface": "claude-bridge", "agent": "claude" }
      }
    }
    """

    @Test func persistedOriginSurvivesTheDecoderAndRendersTheBadge() throws {
        let data = Data(Self.bridgeRowJSON.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)

        // The decode itself is the thing that was broken.
        #expect(message.metadata?.origin?.surface == "claude-bridge")
        #expect(message.metadata?.origin?.agent == "claude")

        // And the badge the human actually sees, from that decoded row.
        let badge = MacChatMessageProvenance.make(
            role: message.role,
            source: message.source,
            origin: message.metadata?.origin
        )
        #expect(badge?.label == "Claude - bridge")
        #expect(badge?.isAutomated == true)
    }

    @Test func originSurvivesMacReEncodingAndSnapshotEmission() throws {
        // MacSyncEngine re-encodes through `encode(to:)`. An unencoded field is
        // dropped there silently. The current iOS receiver ignores this
        // additive field, so this test intentionally makes no phone-UI claim.
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(Self.bridgeRowJSON.utf8))
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(ChatMessage.self, from: reencoded)

        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        let encodedMetadata = try #require(encodedObject["metadata"] as? [String: Any])
        #expect(encodedMetadata["origin"] != nil)

        #expect(roundTripped.metadata?.origin?.surface == "claude-bridge")
        #expect(
            MacChatMessageProvenance.make(
                role: roundTripped.role,
                source: roundTripped.source,
                origin: roundTripped.metadata?.origin
            )?.label == "Claude - bridge"
        )
    }

    @Test func rowWithoutOriginStillDecodesAndStaysUnbadged() throws {
        // Negative control for the fix: adding the decode line must not make
        // ordinary human rows throw or start rendering a badge. Every message
        // User has ever typed lacks this key.
        let plain = """
        {"id":"m","sessionId":"s","role":"user","content":"hi","createdAt":"2026-08-19T00:00:00Z","source":"app","metadata":{"model":"claude-opus-5"}}
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(plain.utf8))
        #expect(message.metadata?.model == "claude-opus-5")
        #expect(message.metadata?.origin == nil)
        #expect(
            MacChatMessageProvenance.make(
                role: message.role, source: message.source, origin: message.metadata?.origin
            ) == nil
        )
    }

    @Test func missingAndNullMetadataRemainOrdinaryHistoricalRows() throws {
        let fixtures = [
            """
            {"id":"missing","role":"user","content":"hi","source":"app"}
            """,
            """
            {"id":"null","role":"user","content":"hi","source":"app","metadata":null}
            """,
        ]
        for fixture in fixtures {
            let message = try JSONDecoder().decode(ChatMessage.self, from: Data(fixture.utf8))
            #expect(message.metadata == nil)
            #expect(
                MacChatMessageProvenance.make(
                    role: message.role,
                    source: message.source,
                    origin: message.metadata?.origin
                ) == nil
            )
        }
    }

    @Test func presentUnreadableMetadataFailsClosedInsteadOfLookingHuman() throws {
        for metadataJSON in ["\"broken\"", "[]", "7"] {
            let fixture = """
            {"id":"m","role":"user","content":"wake","source":"app","metadata":\(metadataJSON)}
            """
            let message = try JSONDecoder().decode(ChatMessage.self, from: Data(fixture.utf8))
            #expect(message.metadata?.origin?.surface == "unreadable")
            #expect(
                MacChatMessageProvenance.make(
                    role: message.role,
                    source: message.source,
                    origin: message.metadata?.origin
                )?.label == "Automated"
            )
        }
    }

    @Test func provenanceBearingRowWithUnreadableRoleCannotMasqueradeAsAgent() throws {
        let fixtures = [
            """
            {"id":"missing-role","content":"wake","source":"app","metadata":{"origin":{"surface":"codex-bridge","agent":"codex"}}}
            """,
            """
            {"id":"wrong-role","role":7,"content":"wake","source":"app","metadata":{"origin":{"surface":"codex-bridge","agent":"codex"}}}
            """,
            """
            {"id":"contradictory-role","role":"assistant","content":"wake","source":"app","metadata":{"origin":{"surface":"codex-bridge","agent":"codex"}}}
            """,
        ]
        for fixture in fixtures {
            let message = try JSONDecoder().decode(ChatMessage.self, from: Data(fixture.utf8))
            #expect(message.role == "user")
            #expect(
                MacChatMessageProvenance.make(
                    role: message.role,
                    source: message.source,
                    origin: message.metadata?.origin
                )?.label == "Codex - bridge"
            )
        }
    }

    @Test func malformedOriginDoesNotDestroyTheWholeRow() throws {
        // A row whose origin is the wrong JSON type must not fail the decode of
        // the entire message — that would blank the transcript, which is a far
        // worse outcome than a missing badge. This is the failure direction the
        // getChatMessages decode has been bitten by before (see ChatMessage's
        // 2026-05-28 note).
        let hostile = """
        {"id":"m","sessionId":"s","role":"user","content":"hi","createdAt":"2026-08-19T00:00:00Z","source":"app","metadata":{"origin":"claude-bridge"}}
        """
        let message = try? JSONDecoder().decode(ChatMessage.self, from: Data(hostile.utf8))
        #expect(message != nil, "a string-typed origin must not blank the transcript")
        #expect(message?.content == "hi")

        // ...and it must not read as human either. Unreadable provenance is
        // still provenance: the row is marked machine-authored, and none of
        // its raw text reaches the badge.
        let badge = MacChatMessageProvenance.make(
            role: message?.role ?? "", source: message?.source,
            origin: message?.metadata?.origin
        )
        #expect(badge?.label == "Automated")
        #expect(badge?.isAutomated == true)
    }

    @Test func realHistoryReaderPreservesValidOriginAcrossMalformedSiblings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-provenance-wire-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = root.appendingPathComponent("chat/messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let row = """
        {"id":"m","sessionId":"s","role":"user","content":"wake",\
        "createdAt":"2026-08-19T00:00:00Z","source":7,"metadata":{\
        "duration_ms":"wrong","attachments":{"wrong":"shape"},\
        "origin":{"surface":"codex-bridge","agent":"codex"}}}
        """
        try Data((row + "\n").utf8).write(
            to: messages.appendingPathComponent("s.jsonl"),
            options: .atomic
        )

        let decoded = try await NativeClient.getChatMessages(sessionId: "s", dataRoot: root)
        let message = try #require(decoded.first)
        #expect(message.content == "wake")
        #expect(message.source == nil, "wrong-typed source should degrade independently")
        #expect(message.metadata?.origin?.surface == "codex-bridge")
        #expect(message.metadata?.origin?.agent == "codex")
        #expect(
            MacChatMessageProvenance.make(
                role: message.role,
                source: message.source,
                origin: message.metadata?.origin
            )?.label == "Codex - bridge"
        )
    }

    @Test func realHistoryReaderDistinguishesUnreadableMetadataFromAbsence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-provenance-container-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = root.appendingPathComponent("chat/messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let rows = [
            "{\"id\":\"bad\",\"sessionId\":\"s\",\"role\":\"user\",\"content\":\"wake\",\"source\":\"app\",\"metadata\":\"wrong\"}",
            "{\"id\":\"missing\",\"sessionId\":\"s\",\"role\":\"user\",\"content\":\"typed\",\"source\":\"app\"}",
            "{\"id\":\"null\",\"sessionId\":\"s\",\"role\":\"user\",\"content\":\"typed\",\"source\":\"app\",\"metadata\":null}",
        ]
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(
            to: messages.appendingPathComponent("s.jsonl"),
            options: .atomic
        )

        let decoded = try await NativeClient.getChatMessages(sessionId: "s", dataRoot: root)
        let byID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        let unreadable = try #require(byID["bad"])
        #expect(unreadable.metadata?.origin?.surface == "unreadable")
        #expect(
            MacChatMessageProvenance.make(
                role: unreadable.role,
                source: unreadable.source,
                origin: unreadable.metadata?.origin
            )?.label == "Automated"
        )
        #expect(byID["missing"]?.metadata == nil)
        #expect(byID["null"]?.metadata == nil)
    }

    @Test func debugJSONIncludesTheCanonicalOriginObject() throws {
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(Self.bridgeRowJSON.utf8))
        let debugData = Data(ChatMessageDebugJSON.text(for: message).utf8)
        let object = try #require(
            JSONSerialization.jsonObject(with: debugData) as? [String: Any]
        )
        let metadata = try #require(object["metadata"] as? [String: Any])
        let origin = try #require(metadata["origin"] as? [String: Any])
        #expect(origin["surface"] as? String == "claude-bridge")
        #expect(origin["agent"] as? String == "claude")
    }

    /// Defect 5, found reviewing my own diff after the second watchdog kill.
    ///
    /// `ChatMessageOriginMetadata.surface` is Optional, so an origin object
    /// that simply OMITS the key decodes cleanly with surface == nil — it is
    /// not the "undecodable" case that init(from:) rescues to "unreadable".
    /// The projection used to resolve `origin?.surface ?? source`, so such a
    /// row fell through to source "app" and rendered with NO BADGE: a bridge
    /// message displayed exactly like one User typed. Absent provenance is
    /// unattributed, never human.
    @Test func originRecordWithNoSurfaceIsStillNeverRenderedAsHuman() throws {
        // Both shapes decode successfully — surface is simply missing.
        for originJSON in ["{}", "{\"agent\":\"claude\"}"] {
            let row = """
            {"id":"m","sessionId":"s","role":"user","content":"[from: claude, via bridge] x",\
            "createdAt":"2026-08-19T00:00:00Z","source":"app","metadata":{"origin":\(originJSON)}}
            """
            let message = try JSONDecoder().decode(ChatMessage.self, from: Data(row.utf8))
            // Precondition: this really is the decodes-fine-but-empty case.
            #expect(message.metadata?.origin != nil, "origin \(originJSON) should decode")
            #expect(message.metadata?.origin?.surface == nil)

            let badge = MacChatMessageProvenance.make(
                role: message.role, source: message.source, origin: message.metadata?.origin
            )
            #expect(badge != nil, "origin \(originJSON) must not render as the human")
            #expect(badge?.label == "Automated")
            #expect(badge?.isAutomated == true)
        }
    }

    /// The same invariant stated directly against the projection, including the
    /// blank/whitespace surface a future or foreign producer could emit. The
    /// point is structural: presence of the record, not its contents, decides.
    @Test func anyPresentOriginRecordAlwaysProducesABadge() {
        for surface in [nil, "", "   ", "\n", "\u{202E}", "totally-unknown-lane"] {
            let badge = MacChatMessageProvenance.make(
                role: "user",
                source: "app", // the human-looking source the bridges really persist
                origin: ChatMessageOriginMetadata(surface: surface, agent: nil)
            )
            #expect(badge != nil, "surface \(String(describing: surface)) rendered as human")
            #expect(badge?.isAutomated == true)
            #expect(badge?.label == "Automated")
        }
    }

    /// Guard the other direction so the fix above cannot be "achieved" by
    /// badging everything: with NO origin record at all, an ordinary typed
    /// message must still be unbadged.
    @Test func absentOriginRecordStillMeansNoBadge() {
        #expect(
            MacChatMessageProvenance.make(role: "user", source: "app", origin: nil) == nil
        )
        #expect(
            MacChatMessageProvenance.make(role: "user", source: nil, origin: nil) == nil
        )
    }
}


/// 658.14 — the SENDER->SURFACE map at the bridge.
///
/// Found by the post-kill adversarial pass. The first cut of this used a
/// two-way ternary (`sender == "codex" ? codex : claude`), which quietly
/// labelled the third bridge lane (defaultSender "omp", ClaudeBridge.swift:503)
/// as "claude-bridge" — a badge naming the wrong agent, which is worse than
/// no badge at all.
@Suite("Bridge sender maps to a truthful origin surface")
struct MacChatBridgeOriginSurfaceTests {

    @Test func knownLanesKeepTheirNamedSurfaces() {
        #expect(ClaudeBridge.bridgeSurfaceName(forSender: "claude") == "claude-bridge")
        #expect(ClaudeBridge.bridgeSurfaceName(forSender: "codex") == "codex-bridge")
    }

    @Test func thirdLaneIsNeverLabelledAsClaude() {
        // THE bug. "omp" is a real, live lane.
        let surface = ClaudeBridge.bridgeSurfaceName(forSender: "omp")
        #expect(surface != "claude-bridge")
        #expect(surface != "codex-bridge")
        #expect(surface == "omp-bridge")
    }

    @Test func anUnknownSenderRendersAsUnattributedRatherThanAsAnAgent() {
        // The render side of the same guarantee: a lane this file has never
        // heard of must badge as machine-authored without claiming an identity.
        for sender in ["omp", "somefuturelane", ""] {
            let origin = ChatMessageOriginMetadata(
                surface: ClaudeBridge.bridgeSurfaceName(forSender: sender),
                agent: sender
            )
            let badge = MacChatMessageProvenance.make(role: "user", source: "app", origin: origin)
            #expect(badge?.label == "Automated", "sender \(sender) must not borrow a named agent's badge")
            #expect(badge?.isAutomated == true)
        }
    }

    @Test func everySenderProducesANonEmptySurface() {
        for sender in ["claude", "codex", "omp", "", "   ", "MiXeD"] {
            #expect(!ClaudeBridge.bridgeSurfaceName(forSender: sender).isEmpty)
        }
    }
}
