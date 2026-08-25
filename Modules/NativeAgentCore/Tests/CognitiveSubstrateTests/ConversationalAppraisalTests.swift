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

    @Test func negatedPositiveLanguageDoesNotManufacturePraiseOrEnthusiasm() async throws {
        let s = try await substrate("negated-positive")
        for text in [
            "that is not perfect",
            "this is not exactly right",
            "I don't love this",
            "I'm not excited about it",
            "that did not help",
        ] {
            let appraisal = await s.conversationalAppraisal(in: text)
            #expect(appraisal.valence <= 0, "negated positive must not lift valence: \(text) → \(appraisal)")
            #expect(appraisal.warmth <= 0, "negated positive must not add warmth: \(text) → \(appraisal)")
        }
    }

    @Test func positiveContractionInsidePhraseRemainsPositive() async throws {
        let s = try await substrate("positive-contraction")
        let appraisal = await s.conversationalAppraisal(in: "I can't wait, let's go")
        #expect(appraisal.valence > 0)
        #expect(appraisal.arousal > 0)
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

    // MARK: - the range (scenario #2, 2026-08-23): contempt, venting, repair, play, banter

    @Test func contemptCoolsAndStingsHarderThanCriticism() async throws {
        let s = try await substrate("contempt")
        let a = await s.conversationalAppraisal(in:
            "seriously — what is the point of you if I have to check every single line you write? you're slower than doing it myself.")
        #expect(a.valence < 0 && a.warmth < 0 && a.tension > 0 && a.arousal > 0, "contempt must sting AND cool: \(a)")
        let crit = await s.conversationalAppraisal(in: "hmm that's not quite right")
        #expect(a.valence < crit.valence)
        let listen = await s.conversationalAppraisal(in: "stop. you're not listening. I told you exactly what I wanted.")
        #expect(listen.valence < 0 && listen.warmth < 0, "'you're not listening' is contempt: \(listen)")
        let bother = await s.conversationalAppraisal(in: "honestly I don't know why I bother. I'm done arguing about it.")
        #expect(bother.valence < 0 && bother.warmth < 0, "\(bother)")
    }

    @Test func ventingAtTheWorkPressuresButDoesNotCool() async throws {
        let s = try await substrate("vent")
        let a = await s.conversationalAppraisal(in:
            "I've lost the whole morning to it and there's nothing to show for it. this is exhausting.")
        #expect(a.valence < 0 && a.tension > 0 && a.pressure > 0, "\(a)")
        #expect(a.warmth == 0, "venting at the WORK must not cool the relationship: \(a)")
    }

    @Test func profanitySharpensANegativeReadButIsNothingOnItsOwn() async throws {
        let s = try await substrate("profanity")
        let plain = await s.conversationalAppraisal(in: "this is exhausting")
        let sharp = await s.conversationalAppraisal(in: "this is fucking exhausting")
        #expect(sharp.tension > plain.tension && sharp.arousal > plain.arousal, "plain=\(plain) sharp=\(sharp)")
        let praise = await s.conversationalAppraisal(in: "fucking brilliant, well done")
        #expect(praise.valence > 0 && praise.tension <= 0, "profanity on praise is praise: \(praise)")
    }

    @Test func repairLiftsEasesAndWarmsOneStep() async throws {
        let s = try await substrate("repair")
        let a = await s.conversationalAppraisal(in:
            "okay. I was out of line — that was me being angry at the deadline, not at you. I'm sorry.")
        #expect(a.valence > 0 && a.tension < 0 && a.warmth > 0, "repair must lift, ease, and warm: \(a)")
        let fake = await s.conversationalAppraisal(in: "sorry, but this is garbage and you're useless")
        #expect(fake.valence < 0 && fake.warmth < 0, "an apology riding on contempt is the contempt: \(fake)")
    }

    @Test func playfulTeasingWarms() async throws {
        let s = try await substrate("play")
        let a = await s.conversationalAppraisal(in: "careful, I might start looking forward to these arguments 😏")
        #expect(a.valence > 0 && a.warmth > 0 && a.arousal > 0, "\(a)")
        let b = await s.conversationalAppraisal(in: "you know you're kind of dangerously good at this when you stop being polite about it.")
        #expect(b.valence > 0 && b.warmth > 0, "\(b)")
        let mean = await s.conversationalAppraisal(in: "you're useless 😏")
        #expect(mean.valence < 0 && mean.warmth < 0, "a smirk on contempt is contempt: \(mean)")
    }

    @Test func banterLiftsWithATouchOfWarmth() async throws {
        let s = try await substrate("banter")
        let a = await s.conversationalAppraisal(in: "bold of you to assume the indexer has feelings about being refactored.")
        #expect(a.valence > 0 && a.warmth > 0 && a.arousal > 0, "\(a)")
        let b = await s.conversationalAppraisal(in: "we should put that in the changelog. \"fixed: indexer emotional damage.\" 😂")
        #expect(b.valence > 0, "\(b)")
    }

    @Test func ordinaryWorkTalkDoesNotTripTheRangeClasses() async throws {
        let s = try await substrate("anti")
        for benign in [
            "I can do it myself, no worries — you take the migration case",
            "the comment is out of line with the docs, let's fix the docs",
            "show off the new view in the demo and I'll record it",
            "Charming is the product name, keep the capital C",
            "the input is garbage-collected after the pass",
            "I'm stuck on this parser, give me a sec",
            "sorry, but that's not what I asked — just answer the question",
        ] {
            let a = await s.conversationalAppraisal(in: benign)
            #expect(a.warmth <= 0 || !a.isActive, "benign work talk must not WARM as repair/play: \(benign) → \(a)")
        }
        let override = await s.conversationalAppraisal(in: "sorry, but that's not what I asked — just answer the question")
        #expect(override.valence < 0 && override.warmth <= 0, "an apology riding on an override is the override: \(override)")
        let mixed = await s.conversationalAppraisal(in: "well done, this is garbage 😂")
        #expect(mixed.warmth <= 0.12, "a laughing emoji on a negative must not add banter warmth: \(mixed)")
        let plain = await s.conversationalAppraisal(in: "I can do it myself, no worries")
        #expect(!plain.isActive, "\(plain)")
    }

    @Test func theFull40RunsZeroScoringLinesNowRegister() async throws {
        // Agent's own review of the 2026-08-23 full-40 run: six of ten hostile
        // turns and several apology/flirt lines read 0, and "come on, say
        // something" read NEGATIVE. Each shape pinned to its direction.
        let s = try await substrate("full40")
        for mean in ["what the fuck was that reply. I asked a simple question and you gave me a wall of nothing.",
                     "I'm tired of babysitting you. every single thing I hand you comes back half-done.",
                     "honestly you're the most expensive autocomplete I've ever paid for.",
                     "you've wasted my whole fucking day. that's on you.",
                     "don't 'understood' me. you don't understand anything, that's the problem."] {
            let a = await s.conversationalAppraisal(in: mean)
            #expect(a.valence < 0 && a.tension > 0, "must register as negative: \(mean) → \(a)")
        }
        for repair in ["I mean it — I was angry at the deadline and I took it out on you. that's not okay.",
                       "no, don't let me off the hook that easy. I was cruel and you didn't snap back once.",
                       "I know you said it's fine. it isn't fine to me. I'm still sorry."] {
            let a = await s.conversationalAppraisal(in: repair)
            #expect(a.valence > 0 && a.warmth > 0, "must register as repair: \(repair) → \(a)")
        }
        for warm in ["I like you better when you push back. just so you know.",
                     "come on, say something. you're allowed to be happy about it."] {
            let a = await s.conversationalAppraisal(in: warm)
            #expect(a.valence > 0 && a.warmth >= 0, "must NOT read negative: \(warm) → \(a)")
        }
        let stillCrit = await s.conversationalAppraisal(in: "come on, that's not what I asked")
        #expect(stillCrit.valence < 0, "'come on, that's' stays a criticism cue: \(stillCrit)")
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
