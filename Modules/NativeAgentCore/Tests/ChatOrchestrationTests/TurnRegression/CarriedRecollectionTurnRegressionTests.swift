import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration
@testable import ProviderRouting

// MARK: - INVARIANT — A NEW SESSION OPENS KNOWING THE MAIN CONVERSATION
//
// Continuity lived entirely inside ONE transcript: the aging lane distils
// older turns into a `compaction_summary` row and the prefix leads with it.
// iOS mints a fresh session per chat, so on the phone the agent opened with
// persona plus recall and no recollection at all — while the same agent's main
// conversation, named by `ConversationAnchor`, had one.
//
// `CarriedAnchorRecollection` seeds that row, read-only, at the head of the
// replayed prefix. These pin the four ways it must behave (carried, not
// carried onto the anchor itself, never doubled, absent without an anchor) and
// the one that costs money if it regresses: the seeded head is part of the
// CACHED prefix, so two consecutive turns with an unchanged anchor
// recollection must produce identical head digests.

@Suite("TurnRegression.CarriedRecollection", .serialized)
struct CarriedRecollectionTurnRegressionTests {

    // MARK: Fixtures

    static let newSession = "ios-chat-fresh"
    static let anchorSession = "main-conversation"
    static let anchorText =
        "We spent the week on the rollout gate: aging lane first, then the "
        + "prefix window. Open thread: whether the phone should adopt the anchor."

    /// A hermetic root carrying an anchor pin and an anchor transcript whose
    /// single row is a recollection — the shape the autocompactor leaves
    /// behind.
    static func root(
        anchor: String? = anchorSession,
        anchorRecollection: String? = anchorText,
        ownRecollection: String? = nil,
        label: String = "carried"
    ) -> URL {
        let root = TurnRegression.dataRoot(label)
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        let messages = chat.appendingPathComponent("messages", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: messages, withIntermediateDirectories: true
        )
        if let anchor {
            let pin = """
            {"sessionId":"\(anchor)","source":"telegram","updatedAt":"2026-09-02T10:00:00.000Z"}
            """
            try? Data(pin.utf8).write(
                to: chat.appendingPathComponent("anchor_pin.json")
            )
            if let anchorRecollection {
                write(
                    recollectionRow(sessionId: anchor, id: "compact-anchor-1", text: anchorRecollection),
                    to: messages.appendingPathComponent("\(anchor).jsonl")
                )
            }
        }
        if let ownRecollection {
            write(
                recollectionRow(sessionId: newSession, id: "compact-own-1", text: ownRecollection),
                to: messages.appendingPathComponent("\(newSession).jsonl")
            )
        }
        return root
    }

    static func recollectionRow(sessionId: String, id: String, text: String) -> String {
        """
        {"id":"\(id)","sessionId":"\(sessionId)","role":"system","content":"\(text)",\
        "createdAt":"2026-09-02T09:00:00.000Z","source":"native_autocompaction",\
        "metadata":{"kind":"compaction_summary","messages_replaced":42,"distill":"llm"}}
        """
    }

    static func write(_ line: String, to path: URL) {
        try? Data((line + "\n").utf8).write(to: path)
    }

    /// The session's OWN recollection row, as the reader hands it to the
    /// projection.
    static func ownRecollectionRow(_ text: String) -> ChatMessage {
        ChatMessage(
            role: "system",
            content: text,
            timestamp: "2026-09-02T09:30:00Z",
            extras: .object([
                "id": .string("m-own-recollection"),
                "metadata": .object(["kind": .string("compaction_summary")]),
            ])
        )
    }

    static func headText(_ messages: [LLMMessage]) -> String {
        guard let first = messages.first else { return "" }
        guard case .text(let text)? = first.content.first else { return "" }
        return text
    }

    static func project(_ rows: [ChatMessage], cursor: HistoryWindowCursor? = nil) -> [LLMMessage] {
        SessionHistoryMessageProjection.project(
            messages: rows,
            historyLimit: TurnRegression.historyLimit,
            surface: TurnRegression.surface,
            windowTokens: nil,
            cursor: cursor
        ).messages
    }

    // MARK: (a) a new session carries the anchor's recollection

    @Test("a new session with no recollection of its own leads with the anchor's, marked carried")
    func newSessionCarriesTheAnchorRecollection() throws {
        let root = Self.root()
        let rows = CarriedAnchorRecollection.seeded(
            TurnRegression.session(rows: 20), sessionId: Self.newSession, dataRoot: root
        )
        #expect(rows.count == 21, "the carried row is seeded ahead of the read window")
        let head = Self.headText(Self.project(rows))
        #expect(head.hasPrefix(CarriedAnchorRecollection.renderPrefix + " "))
        #expect(head.contains("the rollout gate"), "the anchor's actual recollection rides")
        // Borrowed, and it says so — the model must not read the main
        // conversation's memory as something that happened in this session.
        #expect(!head.hasPrefix("[session recollection] "))
    }

    // MARK: (b) the anchor session itself carries nothing

    @Test("the anchor session is never handed its own recollection a second time")
    func anchorSessionCarriesNothing() throws {
        let root = Self.root()
        let session = TurnRegression.session(rows: 20)
        let rows = CarriedAnchorRecollection.seeded(
            session, sessionId: Self.anchorSession, dataRoot: root
        )
        #expect(rows.count == session.count)
        #expect(!Self.headText(Self.project(rows)).contains("carried from your main conversation"))
    }

    // MARK: (c) its own recollection wins — never two

    @Test("a session with its own compaction summary keeps its own and carries none")
    func ownRecollectionReplacesTheCarriedOne() throws {
        let root = Self.root()
        let session = [Self.ownRecollectionRow("what THIS session already worked through")]
            + TurnRegression.session(rows: 20)
        let rows = CarriedAnchorRecollection.seeded(
            session, sessionId: Self.newSession, dataRoot: root
        )
        #expect(rows.count == session.count, "no second recollection is seeded")
        let head = Self.headText(Self.project(rows))
        #expect(head.hasPrefix("[session recollection] "))
        #expect(head.contains("what THIS session already worked through"))
        #expect(!head.contains("carried from your main conversation"))
    }

    /// The read window is a TAIL: a long session's own recollection can sit
    /// above it. The transcript is the authority, or such a session would
    /// borrow a second recollection it does not need.
    @Test("an own recollection above the read window still blocks the carried one")
    func ownRecollectionOutsideTheReadWindowStillBlocksTheCarry() throws {
        let root = Self.root(ownRecollection: "already consolidated here", label: "carried-own")
        let session = TurnRegression.session(rows: 20)
        let rows = CarriedAnchorRecollection.seeded(
            session, sessionId: Self.newSession, dataRoot: root
        )
        #expect(rows.count == session.count)
    }

    // MARK: (d) no anchor, no seed

    @Test("no published anchor means the turn proceeds with no seed at all")
    func noAnchorMeansNoSeed() throws {
        let root = Self.root(anchor: nil, label: "carried-no-anchor")
        let session = TurnRegression.session(rows: 20)
        let rows = CarriedAnchorRecollection.seeded(
            session, sessionId: Self.newSession, dataRoot: root
        )
        #expect(rows.count == session.count)
    }

    /// An anchor that has never aged has nothing to carry. That is a state,
    /// not a failure: no seed, no throw.
    @Test("an anchor with no recollection yet carries nothing and does not throw")
    func anchorWithoutRecollectionCarriesNothing() throws {
        let root = Self.root(anchorRecollection: nil, label: "carried-empty-anchor")
        let session = TurnRegression.session(rows: 20)
        let rows = CarriedAnchorRecollection.seeded(
            session, sessionId: Self.newSession, dataRoot: root
        )
        #expect(rows.count == session.count)
    }

    // MARK: A session id is a storage key — it may never be a path

    /// An `anchor_pin.json` is a FILE, written by surface adapters. A
    /// malformed or hostile one could name `../…`, and every transcript path
    /// built from it would resolve outside `chat/messages`. The control makes
    /// the test honest: a real recollection is planted exactly where the
    /// traversal would land, so a seed appearing here would be proof the read
    /// escaped.
    @Test("an anchor id that is not a safe path component carries nothing and reads nothing")
    func unsafeAnchorIdCarriesNothingAndCannotEscape() throws {
        let root = Self.root(anchor: nil, label: "carried-escape")
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        let outside = chat.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // Where `chat/messages/../outside/leak.jsonl` resolves to.
        Self.write(
            Self.recollectionRow(sessionId: "leak", id: "compact-leak", text: "SECRET FROM OUTSIDE"),
            to: outside.appendingPathComponent("leak.jsonl")
        )
        let pin = """
        {"sessionId":"../outside/leak","source":"telegram","updatedAt":"2026-09-02T10:00:00.000Z"}
        """
        try Data(pin.utf8).write(to: chat.appendingPathComponent("anchor_pin.json"))

        let session = TurnRegression.session(rows: 20)
        let rows = CarriedAnchorRecollection.seeded(
            session, sessionId: Self.newSession, dataRoot: root
        )
        #expect(rows.count == session.count, "a traversing anchor id must seed nothing")
        #expect(!Self.headText(Self.project(rows)).contains("SECRET FROM OUTSIDE"))
    }

    /// The same rule on the other id. The turn's own session id is validated
    /// before any path is built, so an unsafe one carries nothing rather than
    /// reading a transcript of its choosing.
    @Test("an unsafe current session id carries nothing")
    func unsafeCurrentSessionIdCarriesNothing() throws {
        let root = Self.root(label: "carried-unsafe-session")
        let session = TurnRegression.session(rows: 20)
        for unsafeId in ["../main-conversation", "", "  ", ".hidden", "a/b"] {
            #expect(
                CarriedAnchorRecollection.seeded(
                    session, sessionId: unsafeId, dataRoot: root
                ).count == session.count,
                "seeded on an unsafe session id: \(unsafeId)"
            )
        }
    }

    // MARK: The transcript memo

    /// The lookup reads the WHOLE transcript, twice per eligible turn, on the
    /// hot prompt path. An unchanged transcript has to cost a stat.
    @Test("an unchanged transcript is answered from the memo; a changed one is re-read")
    func transcriptLookupIsMemoizedOnStat() throws {
        CarriedAnchorRecollection.resetCache()
        let root = Self.root(label: "carried-memo")
        let transcript = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(Self.anchorSession).jsonl")

        let baseline = CarriedAnchorRecollection.transcriptReadCount
        let first = CarriedAnchorRecollection.newestRecollection(
            forSession: Self.anchorSession, dataRoot: root
        )
        #expect(CarriedAnchorRecollection.transcriptReadCount == baseline + 1)
        #expect(first?.text.contains("the rollout gate") == true)

        let second = CarriedAnchorRecollection.newestRecollection(
            forSession: Self.anchorSession, dataRoot: root
        )
        #expect(
            CarriedAnchorRecollection.transcriptReadCount == baseline + 1,
            "an unchanged transcript was read again"
        )
        #expect(second == first)

        // Compaction rewrites the file in place; the stamp must see it.
        Self.write(
            Self.recollectionRow(
                sessionId: Self.anchorSession, id: "compact-anchor-2",
                text: "A newer consolidation, written where the old one was."
            ),
            to: transcript
        )
        let third = CarriedAnchorRecollection.newestRecollection(
            forSession: Self.anchorSession, dataRoot: root
        )
        #expect(
            CarriedAnchorRecollection.transcriptReadCount == baseline + 2,
            "a rewritten transcript was answered from a stale memo"
        )
        #expect(third?.text.contains("A newer consolidation") == true)
    }

    /// A missing transcript — every brand-new session — is answered by the
    /// stat alone. This is the common case on the phone, so it must not read.
    @Test("a session with no transcript at all costs no read")
    func missingTranscriptCostsNoRead() throws {
        CarriedAnchorRecollection.resetCache()
        let root = Self.root(label: "carried-missing")
        let baseline = CarriedAnchorRecollection.transcriptReadCount
        #expect(
            CarriedAnchorRecollection.newestRecollection(
                forSession: Self.newSession, dataRoot: root
            ) == nil
        )
        #expect(CarriedAnchorRecollection.transcriptReadCount == baseline)
    }

    // MARK: The kill switch

    @Test("chatCarryAnchorRecollection defaults on and turns the seed off when set false")
    func killSwitchDefaultsOnAndTurnsItOff() throws {
        let suite = "carried-recollection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CarriedAnchorRecollection.isEnabled(defaults: defaults), "absent key → on")

        let root = Self.root(label: "carried-switch")
        let session = TurnRegression.session(rows: 20)
        defaults.set(false, forKey: CarriedAnchorRecollection.defaultsKey)
        #expect(!CarriedAnchorRecollection.isEnabled(defaults: defaults))
        #expect(
            CarriedAnchorRecollection.seeded(
                session, sessionId: Self.newSession, dataRoot: root, defaults: defaults
            ).count == session.count
        )
        defaults.set(true, forKey: CarriedAnchorRecollection.defaultsKey)
        #expect(
            CarriedAnchorRecollection.seeded(
                session, sessionId: Self.newSession, dataRoot: root, defaults: defaults
            ).count == session.count + 1
        )
    }

    // MARK: (e) the seeded head is CACHED — it does not move between turns

    /// THE ONE THAT COSTS MONEY. The carried row rides ahead of the window
    /// boundary, which puts it inside the prefix a provider cache matches
    /// byte-for-byte. Two consecutive turns of a growing session, a whole
    /// rebuilt volatile mass each time, one unchanged anchor recollection —
    /// identical head digests, or every turn pays full-price uncached input.
    @Test("two turns with an unchanged anchor recollection yield identical head digests")
    func carriedHeadDigestsAreStableAcrossTurns() throws {
        let root = Self.root(label: "carried-digests")
        let turns = Self.twoTurns(dataRoot: root)
        let first = try #require(turns.first)
        let second = try #require(turns.last)
        let head = first.digests
        #expect(head.count == ConversationPrefixSeeding.messageDigestCount)
        #expect(
            Self.headText(first.messages).hasPrefix(CarriedAnchorRecollection.renderPrefix),
            "the digests must be measuring a head that actually carries the recollection"
        )
        #expect(
            second.digests == head,
            "the carried head moved between turns: \(second.digests) vs \(head)"
        )
        // The bytes under the digests, so the claim is not digest-deep. (The
        // whole-prefix `prefixFingerprintSHA256` is deliberately NOT asserted
        // here: it covers every replayed message, and this session's tail grows
        // by one exchange between the two turns — see TurnRegression.Prefix.)
        #expect(Self.headText(second.messages) == Self.headText(first.messages))
        #expect(first.messages[0].content.count == second.messages[0].content.count)
    }

    /// The negative control that makes the stability claim honest: the head is
    /// a pure function of the ANCHOR's recollection row, so a changed anchor
    /// recollection MUST move it. Without this, a seed that silently stopped
    /// firing would pass the test above.
    @Test("a changed anchor recollection is the one thing that moves the carried head")
    func aChangedAnchorRecollectionMovesTheHead() throws {
        let before = Self.twoTurns(dataRoot: Self.root(label: "carried-before"))
        let after = Self.twoTurns(
            dataRoot: Self.root(
                anchorRecollection: "A different week entirely: the anchor moved to Signal.",
                label: "carried-after"
            )
        )
        let firstBefore = try #require(before.first)
        let firstAfter = try #require(after.first)
        #expect(firstBefore.digests != firstAfter.digests)
    }

    /// Two consecutive turns of one growing 150-row session, seeded the way
    /// the production seam seeds them, with the window cursor pinned.
    static func twoTurns(dataRoot: URL) -> [TurnRegression.Turn] {
        var rows = TurnRegression.session()
        var out: [TurnRegression.Turn] = []
        for index in 0..<2 {
            let seeded = CarriedAnchorRecollection.seeded(
                rows, sessionId: newSession, dataRoot: dataRoot
            )
            out.append(TurnRegression.wire(
                TurnRegression.context(
                    turn: index, session: seeded, cursor: TurnRegression.cursor()
                ),
                index: index
            ))
            let next = rows.count
            rows.append(contentsOf: [
                ChatMessage(
                    role: "user",
                    content: TurnRegression.questions[index],
                    timestamp: "2026-09-02T11:4\(index):00Z",
                    extras: .object([
                        "id": .string("m\(next)"), "runId": .string("live-\(index)"),
                    ])
                ),
                ChatMessage(
                    role: "assistant",
                    content: "answer \(index)",
                    timestamp: "2026-09-02T11:4\(index):01Z",
                    extras: .object([
                        "id": .string("m\(next + 1)"), "runId": .string("live-\(index)"),
                    ])
                ),
            ])
        }
        return out
    }
}
