import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// W7/P6 — the felt delivery envelope, TELEMETRY STAGE ONLY.
//
// P6 is the highest-impact and highest-risk item on the board: reply length is
// the most visible surface in the product, and a mis-sized envelope truncates
// real work. Its own staging instruction is "telemetry-only first — log the
// envelope the mechanism WOULD have chosen against the length actually produced,
// enable after the distribution is understood."
//
// So the load-bearing test in this file is not the arithmetic. It is
// `envelopeHasNoConsumerOutsideTelemetry`, which pins the ABSENCE of the enable
// flag. That is the whole contract of a staged ship, and absence is the one
// thing a green build will never tell you about.
@Suite("DeliveryEnvelopeTelemetry")
struct DeliveryEnvelopeTelemetryTests {

    private let now = Date(timeIntervalSince1970: 30_000_000)

    private func config() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumActiveNodes: 256
        )
    }

    private func substrate() async throws -> (CognitiveSubstrate, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let s = CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { self.now }, makeUUID: { UUID() }),
            store: store
        )
        try await s.restorePersistentState()
        return (s, root)
    }

    private func signals(
        valence: Double = 0, arousal: Double = 0.3, warmth: Double = 0.5,
        tension: Double = 0.2, pressure: Double = 0.2,
        fatigue: Double? = nil, curiosity: Double? = nil
    ) -> CognitiveSubstrate.FeltSignals {
        CognitiveSubstrate.FeltSignals(
            valence: valence, arousal: arousal, warmth: warmth,
            tension: tension, pressure: pressure,
            fatigue: fatigue, curiosity: curiosity)
    }

    // MARK: - The envelope itself

    /// Bounded for EVERY input, including the absurd ones. This is the property
    /// that makes "a mis-sized envelope truncates real work" impossible rather
    /// than unlikely, and it must hold before anything is ever allowed to act.
    @Test("the band is hard-bounded for every input")
    func bandIsAlwaysBounded() {
        let extremes: [Double] = [-10, -1, -0.5, 0, 0.5, 1, 10]
        var dials = PersonalityTraitDials(brevity: 0)
        for serve in [0, 1, 40, 900, 50_000] {
            for v in extremes {
                for f in extremes {
                    for b in [0.0, 0.5, 1.0] {
                        dials.brevity = b
                        let e = CognitiveSubstrate.deliveryEnvelope(
                            signals: signals(
                                valence: v, arousal: v, warmth: v, tension: v, pressure: v,
                                fatigue: f, curiosity: f),
                            serveCharacters: serve,
                            dynamics: .derived(from: dials))
                        #expect(e.minimumCharacters >= CognitiveSubstrate.envelopeFloorCharacters)
                        #expect(e.maximumCharacters <= CognitiveSubstrate.envelopeCeilingCharacters)
                        #expect(e.minimumCharacters <= e.maximumCharacters)
                        #expect(e.sizePrior >= 0 && e.sizePrior <= 1)
                    }
                }
            }
        }
    }

    /// Serve size is the leading term — the continuous generalization of the
    /// boolean lexicon classifier, and unlike it, this reads every turn.
    @Test("a one-word ping and a long brief get different bands")
    func serveSizeLeads() {
        let ping = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(), serveCharacters: 3, dynamics: .default)
        let brief = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(), serveCharacters: 900, dynamics: .default)
        #expect(ping.maximumCharacters < brief.minimumCharacters)
        #expect(ping.sizePrior < brief.sizePrior)
        #expect(ping.oneBeat)
        #expect(!brief.oneBeat)
    }

    /// "Feeling changes how much you say" — the sentence the item exists for.
    /// Same serve, different felt state, different band.
    @Test("felt state moves the band with the serve held constant")
    func feltStateMovesTheBand() {
        let tired = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(tension: 0.2, pressure: 0.8, fatigue: 0.9, curiosity: 0.1),
            serveCharacters: 200, dynamics: .default)
        let lit = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(valence: 0.7, arousal: 0.8, tension: 0.2, pressure: 0.2, fatigue: 0.1, curiosity: 0.9),
            serveCharacters: 200, dynamics: .default)
        #expect(tired.sizePrior < lit.sizePrior)
        #expect(tired.maximumCharacters < lit.maximumCharacters)
    }

    /// A short message during a tense push is often the most load-bearing turn
    /// of the session. One-beat must not fire there.
    @Test("one-beat requires a calm moment, not just a short serve")
    func oneBeatRequiresBothHalves() {
        let calm = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(tension: 0.1, pressure: 0.1), serveCharacters: 6, dynamics: .default)
        let tense = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(tension: 0.9, pressure: 0.9), serveCharacters: 6, dynamics: .default)
        #expect(calm.oneBeat)
        #expect(!tense.oneBeat)
    }

    /// P1's `brevity` dial, finally driving something. Neutral dials must be a
    /// no-op, exactly as the P1 contract promises.
    @Test("the brevity trait leans the band and neutral dials are a no-op")
    func brevityTraitLeansTheBand() {
        let neutral = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(), serveCharacters: 200, dynamics: .default)
        let fromNeutralDials = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(), serveCharacters: 200,
            dynamics: .derived(from: .neutral))
        #expect(neutral == fromNeutralDials)

        let terse = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(), serveCharacters: 200,
            dynamics: .derived(from: PersonalityTraitDials(brevity: 1)))
        let verbose = CognitiveSubstrate.deliveryEnvelope(
            signals: signals(), serveCharacters: 200,
            dynamics: .derived(from: PersonalityTraitDials(brevity: 0)))
        #expect(terse.maximumCharacters < verbose.maximumCharacters)
    }

    // MARK: - The pairing

    /// The row carries the envelope AND what actually happened — that pairing is
    /// the entire point of the telemetry stage.
    @Test("the completion pairs the stashed envelope with the real reply length")
    func completionPairsTheEnvelope() async throws {
        let (s, root) = try await substrate()
        let session = "s-envelope"
        await s.stashDeliveryEnvelope(
            signals: signals(),
            request: CognitiveCapsuleRequest(
                surface: "chat", userMessage: "hey", sessionId: session, mode: .inspectOnly),
            at: now)
        let reply = String(repeating: "x", count: 640)
        let row = try #require(
            await s.consumeDeliveryEnvelopeTelemetry(
                replyCharacters: reply.count, sessionId: session, at: now.addingTimeInterval(4)))
        guard case .object(let fields) = row else { Issue.record("row is not an object"); return }
        #expect(fields["schema"] == .string("delivery_envelope_telemetry.v1"))
        #expect(fields["serveCharacters"] == .int(3))
        #expect(fields["replyCharacters"] == .int(640))
        #expect(fields["envelopeOneBeat"] == .bool(true))
        #expect(fields["insideBand"] != nil)
        // No conversation content in a length telemetry file, ever.
        #expect(fields["reply"] == nil)
        #expect(fields["userMessage"] == nil)
        #expect(fields["sessionId"] == nil)

        // The stash is CONSUMED: a second completion has nothing to pair with,
        // so a stale envelope can never be logged against a later reply.
        #expect(await s.consumeDeliveryEnvelopeTelemetry(
            replyCharacters: 100, sessionId: session, at: now.addingTimeInterval(5)) == nil)

        // …and it lands on disk, under logs/, in the STORE's data root.
        let path = root.appendingPathComponent("logs/delivery_envelope_telemetry.jsonl")
        var landed = false
        for _ in 0..<100 where !landed {
            if FileManager.default.fileExists(atPath: path.path) { landed = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(landed)
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("delivery_envelope_telemetry.v1"))
        #expect(text.contains("\"replyCharacters\""))
    }

    /// THE PRODUCTION WIRING PIN (2026-08-11). The first cut stashed on
    /// `compileCapsule`'s live path — which real turns never hit, because the
    /// chat turn compiles capsules on the FROZEN path. The telemetry was dark
    /// for a full live QA pass and every test here still passed, because they
    /// all drive `stashDeliveryEnvelope` directly. This pin exercises the
    /// entry the app runtime actually calls from `commitTurnProjection`, so
    /// the wiring can't silently detach again.
    @Test("the committed-turn entry point stashes an envelope that pairs")
    func committedTurnEntryStashes() async throws {
        let (s, _) = try await substrate()
        let session = "s-committed"
        await s.stashDeliveryEnvelopeForCommittedTurn(
            CognitiveCapsuleRequest(
                surface: "chat", userMessage: "hey", sessionId: session, mode: .inject),
            at: now)
        let row = try #require(
            await s.consumeDeliveryEnvelopeTelemetry(
                replyCharacters: 200, sessionId: session, at: now.addingTimeInterval(3)))
        guard case .object(let fields) = row else { Issue.record("row is not an object"); return }
        #expect(fields["serveCharacters"] == .int(3))
        #expect(fields["replyCharacters"] == .int(200))
    }

    @Test("assistant completion uses original reply count metadata, not capped summary")
    func completionEventUsesOriginalReplyCountMetadata() async throws {
        let (s, root) = try await substrate()
        let session = "s-original-length"
        await s.stashDeliveryEnvelopeForCommittedTurn(
            CognitiveCapsuleRequest(
                surface: "chat", userMessage: "hey", sessionId: session, mode: .inject),
            at: now
        )
        await s.ingest(CognitiveEvent(
            id: "completion-original-length",
            kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "turn-1"),
            sourceClass: .selfReported,
            occurredAt: now.addingTimeInterval(2),
            summary: String(repeating: "x", count: 500),
            importance: 0.5,
            metadata: [
                "sessionId": .string(session),
                CognitiveSubstrate.replyCharacterCountMetadataKey: .int(640),
            ]
        ))

        let path = root.appendingPathComponent("logs/delivery_envelope_telemetry.jsonl")
        var text = ""
        for _ in 0..<100 {
            text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            if text.contains("\"replyCharacters\"") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let row = try #require(text.split(separator: "\n").last)
        guard case .object(let fields) = try JSONValue.parse(Data(row.utf8)) else {
            Issue.record("telemetry row is not an object")
            return
        }
        #expect(fields["replyCharacters"] == .int(640))
    }

    /// A completion from a different session is not the reply this envelope was
    /// computed for — the same rule the reaction linkage already enforces.
    @Test("a cross-session or stale completion logs nothing")
    func staleOrCrossSessionPairsNothing() async throws {
        let (s, _) = try await substrate()
        let request = CognitiveCapsuleRequest(
            surface: "chat", userMessage: "hey", sessionId: "a", mode: .inspectOnly)

        await s.stashDeliveryEnvelope(signals: signals(), request: request, at: now)
        #expect(await s.consumeDeliveryEnvelopeTelemetry(
            replyCharacters: 100, sessionId: "b", at: now.addingTimeInterval(1)) == nil)

        await s.stashDeliveryEnvelope(signals: signals(), request: request, at: now)
        let stale = now.addingTimeInterval(CognitiveSubstrate.pendingCompletionMaxAge + 1)
        #expect(await s.consumeDeliveryEnvelopeTelemetry(
            replyCharacters: 100, sessionId: "a", at: stale) == nil)
    }

    /// HERMETICITY. A substrate with no store has no telemetry path, so no test
    /// and no store-less runtime can leak a row into the live app's data root.
    @Test("a store-less substrate has no telemetry path at all")
    func storeLessSubstrateWritesNothing() async {
        let s = CognitiveSubstrate(
            configuration: config(),
            dependencies: CognitiveSubstrateDependencies(now: { self.now }))
        #expect(await s.deliveryEnvelopeTelemetryPath == nil)
        #expect(await s.storeDataRoot == nil)
    }

    // MARK: - ZERO EFFECT (the staged-ship contract)

    /// The capsule is byte-identical whether or not the envelope ran. Nothing
    /// the envelope computes reaches a single prompt byte.
    @Test("the envelope adds no capsule bytes")
    func envelopeAddsNoCapsuleBytes() async throws {
        let (s, _) = try await substrate()
        let request = CognitiveCapsuleRequest(
            surface: "chat", userMessage: "hey", sessionId: "s", mode: .inject)
        let first = await s.compileCapsule(request)
        // A wildly different envelope, forced into the stash between compiles.
        await s.stashDeliveryEnvelope(
            signals: signals(valence: 1, arousal: 1, fatigue: 0, curiosity: 1),
            request: CognitiveCapsuleRequest(
                surface: "chat",
                userMessage: String(repeating: "context ", count: 400),
                sessionId: "s", mode: .inject),
            at: now)
        let second = await s.compileCapsule(request)
        #expect(first.stableKernel == second.stableKernel)
        #expect(first.dynamicContext == second.dynamicContext)
        let text = first.stableKernel + first.dynamicContext
        for leak in ["envelope", "Envelope", "one beat", "one-beat", "characters", "brevity", "band"] {
            #expect(!text.contains(leak))
        }
    }

    /// THE STAGED-SHIP CONTRACT, PINNED AS SOURCE FACT: the enable flag does not
    /// exist. `DeliveryEnvelope` may be referenced by its own file, by the stash
    /// call site, and by the completion that logs it — nowhere else. If a later
    /// wave wires an actuator, this test fails and that wave has to say so out
    /// loud instead of the flag arriving quietly with a default.
    @Test("the envelope has no consumer outside the telemetry seam")
    func envelopeHasNoConsumerOutsideTelemetry() throws {
        let sources = URL(fileURLWithPath: #filePath)      // …/Tests/CognitiveSubstrateTests/<this>
            .deletingLastPathComponent()                   // …/Tests/CognitiveSubstrateTests
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // …/NativeAgentCore
            .appendingPathComponent("Sources", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: sources.path))

        let allowedFiles: Set<String> = [
            "CognitiveSubstrate+DeliveryEnvelope.swift",   // the organ itself
            "CognitiveSubstrate.swift",                    // the stash slot + the log call
            "CognitiveSubstrate+Capsule.swift",            // the stash call site
        ]
        let needles = ["DeliveryEnvelope", "deliveryEnvelope", "pendingDeliveryEnvelope"]
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !allowedFiles.contains(url.lastPathComponent) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if needles.contains(where: text.contains) {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "envelope referenced outside the telemetry seam: \(offenders)")

        // And no flag was smuggled in under another name.
        let organ = try String(
            contentsOf: sources
                .appendingPathComponent("CognitiveSubstrate/CognitiveSubstrate+DeliveryEnvelope.swift"),
            encoding: .utf8)
        for flagShape in [
            "deliveryEnvelopeEnabled", "envelopeEnabled", "applyDeliveryEnvelope",
            "enforceDeliveryEnvelope", "deliveryEnvelopeActive",
        ] {
            #expect(!organ.contains(flagShape))
        }
    }
}
