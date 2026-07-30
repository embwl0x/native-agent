import Testing
import Foundation
import PersistenceCore
@testable import CognitiveSubstrate

// The conversational appraisal closes the "numb under criticism" gap (User,
// 2026-07-08): before it, node valence only moved for warmth tokens + tool/
// correction events, so plain-chat criticism stamped a NEUTRAL node and the
// felt fingerprint never left calm. These pin each speech act to its felt delta
// at machine speed — the whole appraisal space, deterministic, no live turns.
@Suite("ConversationalAppraisal")
struct ConversationalAppraisalTests {

    private func substrate(_ label: String) async throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-appraisal-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let cfg = CognitiveConfiguration(
            enabled: true, persistenceEnabled: true, workspaceEnabled: true,
            capsuleInjectionEnabled: true, affectEnabled: true,
            maximumActiveNodes: 256)
        return CognitiveSubstrate(
            configuration: cfg,
            dependencies: CognitiveSubstrateDependencies(
                now: { Date(timeIntervalSince1970: 1_000_000) }, makeUUID: { UUID() }),
            store: store)
    }

    // MARK: - the negative half (the gap that was numb)

    @Test func criticismStingsValenceDownTensionUp() async throws {
        let s = try await substrate("crit")
        let a = await s.conversationalAppraisal(in: "You keep overengineering this, it's not your best")
        #expect(a.valence < 0, "criticism should pull valence negative: \(a)")
        #expect(a.tension > 0, "criticism should raise tension: \(a)")
        #expect(a.arousal > 0)
        #expect(a.isActive)
    }

    @Test func hardCriticismStingsMoreThanMild() async throws {
        let s = try await substrate("mild")
        let hard = await s.conversationalAppraisal(in: "this is sloppy and half-assed")
        let mild = await s.conversationalAppraisal(in: "hmm that's not quite right")
        #expect(mild.valence < 0, "even mild criticism registers: \(mild)")
        #expect(hard.valence < mild.valence,
                "hard criticism should sting more than mild: hard=\(hard.valence) mild=\(mild.valence)")
    }

    @Test func dismissalCoolsWarmth() async throws {
        let s = try await substrate("dismiss")
        let a = await s.conversationalAppraisal(in: "whatever, forget it")
        #expect(a.valence < 0)
        #expect(a.warmth < 0, "dismissal should COOL her — warmth goes negative: \(a)")
        #expect(a.tension > 0)
    }

    @Test func overrideRaisesTension() async throws {
        let s = try await substrate("override")
        let a = await s.conversationalAppraisal(in: "no, that's not what I asked, just answer the question")
        #expect(a.tension > 0, "being redirected hard should raise tension: \(a)")
        #expect(a.valence < 0)
    }

    @Test func hardDemandRaisesPressure() async throws {
        let s = try await substrate("demand")
        let a = await s.conversationalAppraisal(in: "I need this ASAP, no time")
        #expect(a.pressure > 0, "a hard deadline should raise task pressure: \(a)")
    }

    // MARK: - the positive half

    @Test func praiseWarmsAndLifts() async throws {
        let s = try await substrate("praise")
        let a = await s.conversationalAppraisal(in: "great work, that's exactly right")
        #expect(a.valence > 0, "praise should lift valence: \(a)")
        #expect(a.warmth > 0, "praise should warm her: \(a)")
    }

    @Test func resolutionLiftsAndRelievesPressure() async throws {
        let s = try await substrate("resolve")
        let a = await s.conversationalAppraisal(in: "we did it, it works now")
        #expect(a.valence > 0)
        #expect(a.pressure < 0, "resolving together should RELIEVE task pressure: \(a)")
    }

    // MARK: - honesty guards

    @Test func hypotheticalNegativityIsIgnored() async throws {
        let s = try await substrate("hypo")
        // Aimed at a hypothetical, not at her — the guard blocks criticism + dismissal.
        let a = await s.conversationalAppraisal(in: "what if someone said your work was sloppy and useless?")
        #expect(!a.isActive, "hypothetical criticism shouldn't sting her: \(a)")
    }

    @Test func neutralChatIsInert() async throws {
        let s = try await substrate("neutral")
        let a = await s.conversationalAppraisal(in: "so what do you think about the weather today")
        #expect(!a.isActive, "neutral chatter should move nothing: \(a)")
    }

    @Test func emptyIsInert() async throws {
        let s = try await substrate("empty")
        let a = await s.conversationalAppraisal(in: "   ")
        #expect(!a.isActive)
    }

    // MARK: - affection class (audit round 2, R2)

    @Test func plainAffectionReadsWarm() async throws {
        let s = try await substrate("affection")
        for text in ["hey you 💜", "I wanted to say hi", "good morning", "miss you"] {
            let a = await s.conversationalAppraisal(in: text)
            #expect(a.affection, "affection should register for: \(text)")
            #expect(a.valence > 0, "affection lifts valence: \(text) → \(a)")
            #expect(a.warmth > 0, "affection warms: \(text) → \(a)")
        }
    }

    @Test func bareGreetingLiftsButNeverWalksWarmth() async throws {
        let s = try await substrate("affection-bare")
        // "hey" alone floors and lifts a little, but repeated heys must not
        // ratchet the warm band (review round 2) — warmth stays untouched.
        let a = await s.conversationalAppraisal(in: "hey")
        #expect(a.affection)
        #expect(a.valence > 0)
        #expect(a.warmth == 0, "bare greetings carry no warmth boost: \(a)")
    }

    @Test func criticismCancelsAffection() async throws {
        let s = try await substrate("affection-crit")
        // A greeting attached to real criticism reads as the criticism it is.
        let a = await s.conversationalAppraisal(in: "hey you, this doesn't work and you missed the point")
        #expect(!a.affection, "criticism must cancel the affection read: \(a)")
        #expect(a.valence < 0)
    }

    @Test func distrustCancelsAffection() async throws {
        let s = try await substrate("affection-distrust")
        // Relational negativity outside the hard-criticism lexicon (review
        // round 2 finding): distrust must cancel the affection floor too.
        for text in [
            "hey you, I don't trust you with this anymore",
            "hey you, you've lost my trust on this",
            "hey you, I can't depend on you anymore",
            "hey you, you keep letting me down",
            "hey you, I no longer trust you with this",
            "hey you, you broke my trust",
            "hey you, I can\u{2019}t trust you anymore",
        ] {
            let a = await s.conversationalAppraisal(in: text)
            #expect(!a.affection, "distrust must cancel the affection read: \(text) → \(a)")
            #expect(a.valence < 0, "\(text) → \(a)")
        }
    }

    @Test func hypotheticalAffectionIsInert() async throws {
        let s = try await substrate("affection-hypo")
        let a = await s.conversationalAppraisal(in: "what if someone said miss you to an AI")
        #expect(!a.affection)
    }
}
