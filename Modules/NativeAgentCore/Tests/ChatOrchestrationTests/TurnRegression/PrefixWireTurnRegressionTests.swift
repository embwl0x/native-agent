import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration
@testable import ProviderRouting

// MARK: - INVARIANT (1) — THE CACHED PREFIX, ACROSS SIX REAL TURNS
//
// Live d83b71d3: the cursor reported stable and every turn's first provider
// call still read exactly 11,215 tokens — tools plus system and nothing else —
// because `messages[0..]` differed between requests. Sizes could not show it:
// two different first messages have the same length. Nothing threw. The only
// symptom was the bill.
//
// The unit suites pin each producer. These pin the ASSEMBLED REQUEST across six
// consecutive turns of one 150-row session, which is the only place the defect
// was ever visible.

@Suite("TurnRegression.Prefix")
struct PrefixWireTurnRegressionTests {

    // MARK: - The head does not move

    /// THE LOAD-BEARING ONE. Six turns, six different questions, a growing
    /// transcript, a whole rebuilt volatile mass each time — and the first six
    /// messages of the wire request are byte-identical every turn, because the
    /// window did not slide.
    @Test("messageDigests[0..5] are identical across six consecutive turns")
    func headDigestsAreIdenticalAcrossSixTurns() throws {
        let turns = TurnRegression.sixTurns()
        #expect(turns.count == 6)
        let head = try #require(turns.first).digests
        #expect(head.count == 6, "six digests, or the comparison is weaker than it reads")
        #expect(head.allSatisfy { $0.count == 12 })
        for turn in turns {
            #expect(!turn.telemetry.windowSlid, "turn \(turn.index) slid a pinned window")
            #expect(
                turn.digests == head,
                "turn \(turn.index) moved the replayed head: \(turn.digests) vs \(head)"
            )
        }
    }

    /// The same property one level lower, on the bytes rather than the digests:
    /// the wire `messages` array agrees element-for-element through the head.
    @Test("the wire head is byte-identical across six turns, not merely digest-equal")
    func wireHeadBytesAreIdenticalAcrossSixTurns() throws {
        let turns = TurnRegression.sixTurns()
        let firstTurn = try #require(turns.first)
        let first = TurnRegression.wireMessages(firstTurn.body)
        for turn in turns.dropFirst() {
            let messages = TurnRegression.wireMessages(turn.body)
            for index in 0..<6 {
                #expect(
                    messages[index]["role"] as? String == first[index]["role"] as? String,
                    "turn \(turn.index) message \(index) changed role"
                )
                #expect(
                    TurnRegression.text(messages[index]) == TurnRegression.text(first[index]),
                    "turn \(turn.index) message \(index) changed text"
                )
            }
        }
    }

    /// The prefix digest chain is the receipt the Doctor reads. Each turn's
    /// cacheable prefix must EXTEND the previous turn's — the previous digest
    /// list is a prefix of the next — and grow by exactly the appended
    /// exchange. (The whole-prefix fingerprint moves every turn by
    /// construction and is never compared between turns.)
    @Test("each turn's prefix digests extend the previous turn's")
    func prefixDigestChainExtendsAcrossSixTurns() throws {
        let turns = TurnRegression.sixTurns()
        for (previous, turn) in zip(turns, turns.dropFirst()) {
            let before = previous.telemetry.prefixMessageDigests
            let now = turn.telemetry.prefixMessageDigests
            #expect(!before.isEmpty)
            #expect(now.starts(with: before), "turn \(turn.index) rewrote the cacheable prefix")
            #expect(now.count == before.count + 2, "turn \(turn.index) grew by \(now.count - before.count), not the one appended exchange")
        }
        let fingerprints = Set(turns.map(\.telemetry.prefixFingerprintSHA256))
        #expect(fingerprints.count == turns.count, "the whole-prefix hash must move with every appended exchange")
    }

    /// THE NEGATIVE CONTROL, which is what makes the exemption honest. A turn
    /// whose window ACTUALLY slid moves the head — and says so. Without this,
    /// "identical unless windowSlid" would be satisfied by a harness that never
    /// slides anything.
    @Test("a slid window is the one licensed way the head may move, and it reports itself")
    func aSlidWindowMovesTheHeadAndSaysSo() throws {
        let rows = TurnRegression.session()
        let before = TurnRegression.wire(
            TurnRegression.context(
                turn: 0, session: rows, cursor: TurnRegression.cursor(),
                windowReceipt: HistoryWindowReceipt(advanceCount: 1, slid: false)
            ),
            index: 0
        )
        let after = TurnRegression.wire(
            TurnRegression.context(
                turn: 1, session: rows,
                cursor: TurnRegression.cursor(boundary: "id\u{1F}m100"),
                windowReceipt: HistoryWindowReceipt(advanceCount: 2, slid: true)
            ),
            index: 1
        )
        #expect(!before.telemetry.windowSlid)
        #expect(after.telemetry.windowSlid)
        #expect(after.telemetry.windowCursorAdvanceCount == 2)
        #expect(
            after.digests != before.digests,
            "a slid window that did not move the head is a cursor nobody applied"
        )
    }

    /// A session LOAD in the middle of the six turns is the everyday event that
    /// used to reshuffle the array. The head must be blind to it.
    @Test("loading a tool mid-session does not move the replayed head")
    func aMidSessionToolLoadDoesNotMoveTheHead() throws {
        let cold = try #require(TurnRegression.sixTurns(tools: TurnRegression.tools(loaded: [])).first)
        let warm = try #require(
            TurnRegression.sixTurns(
                tools: TurnRegression.tools(loaded: ["workshop_submit", "task_ledger_post"])
            ).first
        )
        #expect(cold.digests == warm.digests)
    }

    // MARK: - The tool contract does not move

    /// The fixture floor is the REAL floor. A fixture that drifted out of
    /// `alwaysOnCoreNames` would keep passing while testing nothing.
    @Test("the fixture tool floor is the real always-on floor")
    func toolFloorFixtureIsTheRealAlwaysOnFloor() {
        for name in TurnRegression.floorNames {
            #expect(
                SwiftToolDispatcher.alwaysOnCoreNames.contains(name),
                "\(name) is not in the production always-on floor"
            )
        }
    }

    @Test("the tools array and its fingerprint are identical across six turns")
    func toolArrayAndFingerprintAreIdenticalAcrossSixTurns() throws {
        let turns = TurnRegression.sixTurns()
        let firstTurn = try #require(turns.first)
        let firstNames = TurnRegression.wireTools(firstTurn.body)
            .compactMap { $0["name"] as? String }
        #expect(!firstNames.isEmpty)
        let fingerprint = SwiftNativeTurnEngine.toolSchemaFingerprint(
            firstTurn.seed.context.toolSchemas
        )
        for turn in turns {
            let names = TurnRegression.wireTools(turn.body).compactMap { $0["name"] as? String }
            #expect(names == firstNames, "turn \(turn.index) reshuffled the tools array")
            #expect(
                SwiftNativeTurnEngine.toolSchemaFingerprint(turn.seed.context.toolSchemas)
                    == fingerprint,
                "turn \(turn.index) moved the tool contract fingerprint"
            )
        }
    }

    /// The TEXT lane's contract is prose in the stable suffix, not an array.
    /// It has to be as stable as the array is.
    @Test("the text-lane tool contract prose is byte-identical across six turns")
    func textToolContractProseIsIdenticalAcrossSixTurns() throws {
        let turns = TurnRegression.sixTurns(stableSuffix: TurnRegression.stableSuffix)
        for turn in turns {
            let system = TurnRegression.systemText(turn.body)
            #expect(
                system.contains(TurnRegression.stableSuffix),
                "turn \(turn.index) lost the session tool contract from the stable head"
            )
            #expect(
                turn.seed.context.systemSegments?.stableSuffix == TurnRegression.stableSuffix,
                "turn \(turn.index) rewrote the contract instead of re-sending it"
            )
        }
    }

    /// The text lane's WHOLE POINT (2026-09-01): a `tool_load` appends its rows
    /// to the volatile block, so the cacheable prefix — which on that lane is
    /// the floor alone — does not move. This is the invariant a load used to
    /// break on every tool-heavy day.
    @Test("a session load moves nothing in the cached prefix on the text lane")
    func aSessionLoadMovesNothingInTheTextLaneCachedPrefix() throws {
        let rows = TurnRegression.session()
        func textLaneTurn(_ appendix: String, loaded: [String]) -> ConversationPrefixTelemetrySnapshot {
            let context = TurnRegression.context(
                turn: 0, session: rows, cursor: TurnRegression.cursor(),
                tools: TurnRegression.tools(loaded: loaded),
                stableSuffix: TurnRegression.stableSuffix
            )
            let seed = ConversationPrefixSeeding.seed(
                context, shape: .v2Prefix, textToolCatalogAppendix: appendix
            )
            #expect(
                seed.textToolCatalogRidesVolatileBlock,
                "declaring a text lane must move the catalog run out of the prefix"
            )
            return ConversationPrefixSeeding.telemetry(
                seed,
                shape: seed.shape,
                toolSchemaFingerprint: SwiftNativeTurnEngine
                    .toolSchemaFingerprint(context.toolSchemas)
            )
        }
        let before = textLaneTurn("", loaded: [])
        let after = textLaneTurn(
            "Also loaded this session:\n- workshop_submit\n- task_ledger_post",
            loaded: ["workshop_submit", "task_ledger_post"]
        )
        #expect(
            before.prefixFingerprintSHA256 == after.prefixFingerprintSHA256,
            "a text-lane load moved the cached prefix"
        )
        #expect(before.messageDigests == after.messageDigests)
        #expect(
            after.volatileBlockChars > before.volatileBlockChars,
            "the appended run has to actually land somewhere"
        )
    }

    /// `context_expand` is advertised on EVERY turn (2026-09-01), including the
    /// turns whose packet offers no pointer. It used to be added or omitted per
    /// turn, which rewrote the tools array for a reason the model never asked
    /// about.
    @Test("context_expand is advertised on every one of the six turns")
    func contextExpandIsAdvertisedOnEveryTurn() {
        for turn in TurnRegression.sixTurns() {
            let names = TurnRegression.wireTools(turn.body).compactMap { $0["name"] as? String }
            #expect(
                names.contains("context_expand"),
                "turn \(turn.index) dropped context_expand from the advertised set"
            )
        }
    }

    // MARK: - Cache markers

    /// THE BUDGET. Anthropic allows four breakpoints. v2 spends them on:
    /// stable-end, the previous-turn conversation boundary, the current user
    /// message, and the last tool definition — and on nothing else, ever.
    @Test("every turn carries at most four cache_control markers")
    func everyTurnCarriesAtMostFourCacheMarkers() {
        for turn in TurnRegression.sixTurns() {
            let markers = TurnRegression.markers(turn.body)
            #expect(
                markers.count <= 4,
                "turn \(turn.index) shipped \(markers.count) breakpoints: \(markers)"
            )
        }
    }

    /// The TTLs are not decoration: the two CROSS-turn reads take the GA 1h
    /// TTL, and the current user message — re-read only inside this turn's own
    /// loop — takes plain 5m, which on the wire is the ABSENT `ttl` key.
    @Test("1h rides the stable end and the previous-turn boundary; 5m rides the current message")
    func markerTTLsMatchWhatEachBreakpointIsFor() throws {
        let turns = TurnRegression.sixTurns()
        let turn = try #require(turns.dropFirst().first)  // not a one-shot
        let markers = TurnRegression.markers(turn.body)

        let system = markers.filter { $0.region == "system" }
        #expect(system.count == 1, "exactly one system breakpoint, at the stable end")
        #expect(system.first?.ttl == "1h", "the stable head is the cross-turn read")

        let messages = markers.filter { $0.region == "messages" }
        #expect(messages.count == 2, "the previous-turn boundary and the current message")
        #expect(messages.first?.ttl == "1h", "the previous-turn boundary is the cross-turn read")
        #expect(messages.first?.role == "assistant", "the boundary is the last prior assistant")
        #expect(messages.last?.ttl == "5m", "the current message is re-read within this turn only")
        #expect(messages.last?.role == "user", "and the current message is the user's")

        // The last tool definition may take the fourth slot; when it does it is
        // the same cross-turn read as the stable head.
        for tool in markers.filter({ $0.region == "tools" }) {
            #expect(tool.ttl == "1h")
            #expect(tool.index == TurnRegression.wireTools(turn.body).count - 1)
        }
    }

    /// The one-shot exception, so the 1h assertion above is not read as
    /// unconditional: a request carrying fewer than two prior turns must NOT
    /// speculatively pay the extended-TTL write premium.
    @Test("a one-shot turn does not speculatively buy the 1h write")
    func aOneShotTurnStaysOnThePlainFiveMinuteTTL() {
        let segments = SystemPromptSegments(
            stable: TurnRegression.personaStable, dynamic: "VOLATILE"
        )
        let context = TurnContext(
            surface: TurnRegression.surface, personaDocs: [:], recalled: [],
            modelId: TurnRegression.model, reasoningEffort: "medium",
            providerId: TurnRegression.providerId,
            toolsAvailable: TurnRegression.tools().map(\.name),
            systemPrompt: segments.combined, userMessage: "first thing I ever said",
            toolSchemas: TurnRegression.tools(), systemSegments: segments,
            historyMessages: [.user("opening"), .assistantText("reply")]
        )
        let turn = TurnRegression.wire(context, index: 0)
        for marker in TurnRegression.markers(turn.body) {
            #expect(
                marker.ttl == "5m",
                "a one-turn request bought a 1h write it has no reader for: \(marker)"
            )
        }
    }

    /// A `system` message is turn-scoped by construction — it may even carry
    /// `clear_at`. Caching it is meaningless at best and pins disappearing
    /// bytes into the prefix at worst. Enforced HERE because this is where the
    /// whole assembled request can be looked at.
    @Test("no mid-conversation system message ever carries a cache_control marker")
    func noSystemMessageEverCarriesACacheMarker() {
        for turn in TurnRegression.sixTurns() {
            for marker in TurnRegression.markers(turn.body) where marker.region == "messages" {
                #expect(
                    marker.role != "system",
                    "turn \(turn.index) cached a turn-scoped system message"
                )
            }
        }
    }

    // MARK: - Cleared blocks are still replayed

    /// A `clear_at` block costs 0 input tokens once the provider drops it — and
    /// must STAY in `messages` byte-for-byte anyway, or the next turn's array
    /// diverges at the very element after the previous user turn and everything
    /// behind it is re-created at full price.
    @Test("a cleared clear_at block is replayed byte-for-byte in its original position")
    func clearedBlocksAreReplayedByteForByte() throws {
        let archived = "VOLATILE TURN 41 — the exact bytes that turn sent"
        let rows = TurnRegression.session()
        // The run id the projection will find in the window.
        let replayRun = "run-41"
        let context = TurnRegression.context(
            turn: 0, session: rows, cursor: TurnRegression.cursor(),
            archivedTurnMessages: [
                replayRun: [.system(archived, clearAtNextUserMessage: true)],
            ]
        )
        let turn = TurnRegression.wire(context, index: 0)

        let replays = turn.seed.messages.filter {
            $0.role == .system && TurnRegression.text($0) == archived
        }
        let replayed = try #require(replays.first, "the archived block was not replayed at all")
        // BYTE-FOR-BYTE: one text block, re-rendered from nothing.
        #expect(replayed.content.count == 1)
        #expect(replayed.turnScopedClearAtNextUserMessage)
        #expect(replayed.toolChanges.isEmpty, "a clear_at message is text-only or it 400s")

        // …and it reaches the wire wearing its clear_at, with no marker on it.
        let candidates = TurnRegression.wireMessages(turn.body)
            .filter { TurnRegression.text($0) == archived }
        let wire = try #require(candidates.first)
        #expect(wire["clear_at"] as? String == "next_user_message")
        #expect(
            (wire["content"] as? [[String: Any]] ?? []).allSatisfy { $0["cache_control"] == nil }
        )
    }

    /// The wire rule the replay must never break: a text-carrying system
    /// message may end the array or precede an assistant turn, never a user
    /// turn. A replay that lands in front of a user message is a 400.
    @Test("no replayed block is ever positioned in front of a user turn")
    func noReplayedBlockPrecedesAUserTurn() {
        let rows = TurnRegression.session()
        var archive: [String: [LLMMessage]] = [:]
        for run in 40...48 {
            archive["run-\(run)"] = [.system("VOLATILE \(run)", clearAtNextUserMessage: true)]
        }
        let turn = TurnRegression.wire(
            TurnRegression.context(
                turn: 0, session: rows, cursor: TurnRegression.cursor(),
                archivedTurnMessages: archive
            ),
            index: 0
        )
        for pair in zip(turn.seed.messages, turn.seed.messages.dropFirst()) {
            #expect(
                !(pair.0.role == .system && pair.1.role == .user),
                "a system message immediately before a user turn is a wire 400"
            )
            #expect(pair.0.role != pair.1.role, "adjacent same-role rows must merge")
        }
    }

    /// Replaying archived blocks must not move the head either — they sit at
    /// their own historical positions, which are the same positions every turn.
    @Test("replayed blocks are part of the stable head, not a per-turn addition")
    func replayedBlocksAreThemselvesStableAcrossTurns() throws {
        let archive: [String: [LLMMessage]] = [
            "run-41": [.system("VOLATILE 41", clearAtNextUserMessage: true)],
        ]
        var rows = TurnRegression.session()
        var digests: [[String]] = []
        for index in 0..<6 {
            let turn = TurnRegression.wire(
                TurnRegression.context(
                    turn: index, session: rows, cursor: TurnRegression.cursor(),
                    archivedTurnMessages: archive
                ),
                index: index
            )
            digests.append(turn.digests)
            let next = rows.count
            rows.append(ChatMessage(
                role: "user", content: "q\(index)", timestamp: "2026-09-02T12:00:00Z",
                extras: .object(["id": .string("m\(next)"), "runId": .string("live-\(index)")])
            ))
            rows.append(ChatMessage(
                role: "assistant", content: "a\(index)", timestamp: "2026-09-02T12:00:01Z",
                extras: .object(["id": .string("m\(next + 1)"), "runId": .string("live-\(index)")])
            ))
        }
        #expect(Set(digests.map { $0.joined(separator: ",") }).count == 1)
    }

    // MARK: - A session load moves nothing in the cached prefix

    /// Loading the session's transcript from disk (a relaunch, a second window,
    /// the iPhone opening the same session) rebuilds the projection from the
    /// same rows and the same persisted cursor. On the TEXT lane it must move
    /// nothing at all in the cached prefix.
    @Test("reloading the session from its rows moves nothing in the cached prefix")
    func aSessionLoadMovesNothingInTheCachedPrefix() throws {
        let rows = TurnRegression.session()
        let cursor = TurnRegression.cursor()
        func load() -> TurnRegression.Turn {
            TurnRegression.wire(
                TurnRegression.context(
                    turn: 0, session: rows, cursor: cursor,
                    stableSuffix: TurnRegression.stableSuffix
                ),
                index: 0
            )
        }
        let first = load()
        let second = load()
        #expect(first.digests == second.digests)
        #expect(
            first.telemetry.prefixFingerprintSHA256 == second.telemetry.prefixFingerprintSHA256
        )
        #expect(
            TurnRegression.systemText(first.body) == TurnRegression.systemText(second.body),
            "a reload rewrote the cached system head"
        )
    }

    // MARK: - The v1Legacy rollback arm

    /// The kill switch has to be a real rollback. Under `.v1Legacy` the seed
    /// relocates nothing, the array is the single current user message, the
    /// identity block keeps its own breakpoint, and no `clear_at` appears
    /// anywhere — the exact pre-v2 shape.
    @Test("v1Legacy produces the pre-v2 shape, byte-identical on every rebuild")
    func v1LegacyIsTheUnchangedPreV2Shape() throws {
        let rows = TurnRegression.session()
        func v1() -> TurnRegression.Turn {
            TurnRegression.wire(
                TurnRegression.context(turn: 0, session: rows, cursor: TurnRegression.cursor()),
                index: 0,
                shape: .v1Legacy
            )
        }
        let turn = v1()
        #expect(turn.seed.shape == .v1Legacy)
        #expect(turn.seed.messages.count == 1, "v1 sends one user message, not a transcript")
        #expect(turn.seed.messages.first?.role == .user)
        #expect(turn.seed.volatileIndex == nil, "v1 relocates nothing")
        #expect(
            turn.seed.context.turnVolatileBlock == nil,
            "the volatile mass stays in the system prompt on v1"
        )

        let system = TurnRegression.systemBlocks(turn.body)
        let identity = try #require(system.first)
        #expect(
            TurnRegression.cacheControl(identity) != nil,
            "v1 keeps the identity-block breakpoint; that IS the rollback arm"
        )
        for message in TurnRegression.wireMessages(turn.body) {
            #expect(message["clear_at"] == nil, "v1 has no mid-conversation system messages")
        }

        // Byte identity across rebuilds: two v1 turns off the same inputs.
        let again = v1()
        #expect(
            TurnRegression.systemText(turn.body) == TurnRegression.systemText(again.body)
        )
        #expect(turn.telemetry == again.telemetry)
    }

    /// The dynamic mass really does still ride the system prompt on v1 — the
    /// half of "byte-identical" that a shape check alone would miss.
    @Test("v1Legacy still carries the per-turn volatile mass inside the system prompt")
    func v1LegacyKeepsTheVolatileMassInTheSystemPrompt() {
        let rows = TurnRegression.session()
        let turn = TurnRegression.wire(
            TurnRegression.context(turn: 3, session: rows, cursor: TurnRegression.cursor()),
            index: 3,
            shape: .v1Legacy
        )
        #expect(TurnRegression.systemText(turn.body).contains("Recent memory:\n- hit 3"))
    }
}
