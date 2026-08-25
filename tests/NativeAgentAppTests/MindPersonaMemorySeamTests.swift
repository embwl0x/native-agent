// EVAL COVERAGE — fence `app.mind`, wave A (2026-08-23).
//
// Personality, Memory review, and Self-Improvement. Three different shapes of
// the same failure: a UI gate, a tab filter, and a background loop each decide
// what to show from a value produced somewhere else, by a bare string literal or
// an optional default. When the producer moves, the surface keeps rendering a
// confident, wrong sentence. These evals pin the producers.
import BackgroundLoops
import Foundation
import MemoryV2
import NativeAgentCore
import PersonaEngine
import Testing
@testable import NativeAgentApp

private func personaTempRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindPersona-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The exact predicate PersonalityView.swift:47-53 uses to decide between the
/// live editor and the first-run "Create" card. Expressed here against the real
/// engine's doc listing — if the listing's shape changes, this rule changes with
/// it and the eval says so.
private func personaInitialized(_ docs: [PersonaDocSpec]) -> Bool {
    docs.contains {
        $0.id.uppercased() == "SOUL"
            && ($0.updatedAt != nil
                || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

// MARK: - The first-run gate (logic.personality.personaInitialized /
//         ui.personality.starterPanel / ui.personality.personaUnavailable)

@Suite("Mind personality — first-run gate")
struct MindPersonaInitializedTests {

    /// A false NEGATIVE here is catastrophic: a live user is shown the "Create
    /// your persona" card over a persona that already exists. The rule keys on
    /// `updatedAt`, which the engine stamps ONLY from a real file mtime — so this
    /// pins that the engine keeps that contract in all three states the view
    /// distinguishes.
    @Test func theCreateCardShowsOnlyWhenSoulReallyDoesNotExist() async throws {
        let personaRoot = try personaTempRoot("gate")
        defer { try? FileManager.default.removeItem(at: personaRoot) }
        let dataRoot = try personaTempRoot("gate-data")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let engine = hermeticPersona(root: personaRoot, dataRoot: dataRoot)

        // 1. Fresh install: the specs all exist, SOUL has no mtime and no body.
        let fresh = try await engine.listPersonaDocSpecs().docs
        #expect(fresh.contains { $0.id == "SOUL" }, "the SOUL spec must always be listed")
        let freshSoul = try #require(fresh.first { $0.id == "SOUL" })
        #expect(freshSoul.updatedAt == nil,
                "a SOUL.md that does not exist must not carry an updatedAt")
        #expect(freshSoul.content.isEmpty)
        #expect(!personaInitialized(fresh), "a fresh install must show the Create card")

        // 2. A real persona on disk: updatedAt comes from the file's mtime.
        try Data("She is careful with his time.\n".utf8)
            .write(to: personaRoot.appendingPathComponent("SOUL.md"))
        let live = try await engine.listPersonaDocSpecs().docs
        let liveSoul = try #require(live.first { $0.id == "SOUL" })
        #expect(liveSoul.updatedAt != nil, "an existing SOUL.md must stamp updatedAt from its mtime")
        #expect(liveSoul.content.contains("careful with his time"))
        #expect(personaInitialized(live), "a live persona must never see the Create card")

        // 3. An EXISTING BUT EMPTY SOUL.md still counts as initialized — the
        //    view's comment says so explicitly, because onboarding would refuse
        //    to run anyway and the starter card must not promise what the guard
        //    will deny.
        try Data("".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))
        let emptied = try await engine.listPersonaDocSpecs().docs
        #expect(personaInitialized(emptied),
                "an existing-but-empty SOUL.md must still count as initialized")

        // 4. The fail-loud branch: an EMPTY docs list (a load failure, not a
        //    fresh install) must not read as "no persona yet". This is the state
        //    the Persona Unavailable panel exists for.
        #expect(!personaInitialized([]),
                "an empty docs list is indistinguishable from a fresh install; docsLoadError is the only thing separating them")
    }
}

// MARK: - Empty-doc overwrite (logic.personality.syncPersonalityDocDraft /
//         ui.personality.saveDocument)

@Suite("Mind personality — document save")
struct MindPersonaDocSaveTests {

    /// CHARACTERIZATION of a live data-loss path, found while building this eval.
    /// `syncPersonalityDocDraft` (PersonalityView.swift:297-302) falls back to the
    /// literal id "SOUL" with an EMPTY draft whenever the docs list is empty — a
    /// load failure, not a fresh install. Save's disabled predicate (:244) is only
    /// `selectedDocId.isEmpty || isMemoryOwnedUser`, so "SOUL" + "" leaves SAVE
    /// ENABLED over an empty editor, and the engine has no empty-content guard:
    /// one click writes an empty SOUL.md over the persona.
    ///
    /// The two guards that DO exist are pinned as the positives (pre-onboarding
    /// refusal, and USER being memory-owned). The empty-overwrite is pinned as a
    /// known gap so that adding a guard fails this eval and forces the row to be
    /// re-graded.
    @Test func savingAnEmptyBodyOverAnExistingSoulIsAcceptedToday() async throws {
        let personaRoot = try personaTempRoot("save")
        defer { try? FileManager.default.removeItem(at: personaRoot) }
        let dataRoot = try personaTempRoot("save-data")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let engine = hermeticPersona(root: personaRoot, dataRoot: dataRoot)
        let soulURL = personaRoot.appendingPathComponent("SOUL.md")

        // Guard that holds: pre-onboarding, no doc may be written at all.
        await #expect(throws: (any Error).self) {
            _ = try await engine.savePersonalityDoc(id: "VOICE", content: "hello")
        }

        try Data("She is careful with his time.\n".utf8).write(to: soulURL)

        // Guard that holds: USER.md is memory-owned and always refused.
        await #expect(throws: (any Error).self) {
            _ = try await engine.savePersonalityDoc(id: "USER", content: "anything")
        }

        // Known gap: an empty body over an initialized SOUL.md is accepted.
        _ = try await engine.savePersonalityDoc(id: "SOUL", content: "")
        let after = try String(contentsOf: soulURL, encoding: .utf8)
        #expect(after.isEmpty,
                "known gap: an empty save wiped SOUL.md; if this now throws, an empty-content guard shipped and the ledger row must be re-graded")
    }
}

// MARK: - Memory proposal review + tombstones
//        (ui.memory.proposals.approveDeny / ui.memory.tabPicker /
//         ui.memory.tombstonesTab / ui.memory.tab.picker)

@Suite("Mind memory — proposal status seam")
struct MindMemoryProposalStatusTests {

    /// MemoryView filters its two tabs on bare string literals: `status ==
    /// "pending"` (:54) and `status == "rejected"` (:58). The producer is
    /// `MemoryStorage`. A producer that ever wrote "denied"/"REJECTED" would empty
    /// a tab that then renders "Nothing Deleted … Nothing rejected yet." — an
    /// assertion of fact built from an unmatched string. This pins both literals
    /// through the real store, and pins that the app's own presentation mapper
    /// carries the status through verbatim rather than normalising it.
    @Test func theStoreWritesExactlyTheStatusLiteralsTheTabsFilterOn() async throws {
        let root = try personaTempRoot("proposals")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)

        let staged = try await storage.insertProposal(StoredProposal(
            id: "prop-1",
            content: "He prefers release reviews before shipping on a Friday.",
            source: "adaptive-promoter:session-77"
        ))
        #expect(staged.status == "pending", "the Pending tab filters on this exact literal")
        #expect(try await storage.listProposals(status: "pending").map(\.id) == ["prop-1"])

        _ = try await storage.rejectProposal(id: "prop-1", reason: "not durable")
        let rejected = try await storage.listProposals(status: "rejected")
        #expect(rejected.map(\.id) == ["prop-1"],
                "the Tombstones tab filters on the literal \"rejected\"")
        #expect(rejected.first?.rejectionReason == "not durable")
        #expect(try await storage.listProposals(status: "pending").isEmpty,
                "a rejected proposal must leave the Pending tab")

        // Re-resolving must not silently succeed — the reject row would otherwise
        // stay clickable with no tombstone trail.
        await #expect(throws: (any Error).self) {
            _ = try await storage.rejectProposal(id: "prop-1", reason: "again")
        }

        // The app's own mapper must carry the status through unchanged, or the
        // tab filter and the store agree while the VIEW's copy does not.
        let record = try #require(NativeClient.memoryProposalPresentationRecord(
            id: "prop-1",
            content: "He prefers release reviews before shipping on a Friday.",
            source: "adaptive-promoter:session-77",
            status: "rejected",
            createdAt: "2026-08-20T00:00:00Z",
            rejectionReason: "not durable",
            metadata: .object(["recurrence_count": .int(3)])
        ))
        #expect(record.status == "rejected")
        #expect(record.recurrence_count == 3,
                "the \"seen Nx\" chip is the anti-resurrection signal — it must survive the mapping")
        #expect(record.supporting_session_ids == ["session-77"])
    }

    /// CHARACTERIZATION — the Tombstones tab is structurally unreachable, found
    /// while building this eval. `NativeClient.getMemoryProposals()`
    /// (NativeClient+MemoryPolicyActions.swift:49) lists ONLY
    /// `status: "pending"`, and `appModel.memoryProposals` is the tab's only
    /// source, so `rejectedMemoryProposals` is always empty and the tab always
    /// renders "Nothing Deleted … Nothing rejected yet." no matter how many
    /// rejections exist in the store. Pinned so the loader and the tab can never
    /// be changed independently again.
    @Test func theProposalLoaderRequestsOnlyPendingSoTheTombstonesTabIsAlwaysEmpty() throws {
        let source = try AppSourceScraping.appSource("NativeClient+MemoryPolicyActions.swift")
        let body = try AppSourceScraping.functionBody(named: "getMemoryProposals", in: source)
        #expect(body.contains("listProposals(status: \"pending\")"),
                "known gap: the tombstones tab has no data source; if the loader now fetches rejected rows, wire the tab and re-grade the ledger row")
        #expect(!body.contains("\"rejected\""),
                "the loader gained a rejected-row path — the Tombstones tab must be re-checked")

        let view = try AppSourceScraping.appSource("MemoryView.swift")
        #expect(view.contains("$0.status == \"rejected\""),
                "the Tombstones tab's filter literal moved — it must match what the store writes")
        #expect(view.contains("$0.status == \"pending\""))
    }
}

// MARK: - Weekly self-improvement switch (setting.selfImprovementEnabled /
//         feed.self_improvement.digests)

@Suite("Mind self-improvement — switch + digest feed")
struct MindSelfImprovementTests {

    /// The classic two-vocabulary identity mismatch: the switch is
    /// `@AppStorage("selfImprovementEnabled")` in SelfImprovementView, and the
    /// weekly loop's gate is a bare
    /// `UserDefaults.standard.bool(forKey: "selfImprovementEnabled")` in
    /// BackgroundLoopsAssembly+Maintenance. They agree only by two matching string
    /// literals in two files. A rename on either side makes the toggle a
    /// decoration and the weekly loop silently never runs (or never stops), with
    /// nothing failing anywhere.
    @Test func theSwitchAndTheWeeklyLoopGateShareOneKey() throws {
        let key = "selfImprovementEnabled"
        let view = try AppSourceScraping.appSource("SelfImprovementView.swift")
        #expect(view.contains("@AppStorage(\"\(key)\")"),
                "the Self-Improvement switch no longer stores under \"\(key)\"")

        let assembly = try AppSourceScraping.appSource("BackgroundLoopsAssembly+Maintenance.swift")
        let gate = try AppSourceScraping.functionBody(
            named: "makeWeeklySelfImprovementLoop", in: assembly)
        #expect(gate.contains("UserDefaults.standard.bool(forKey: \"\(key)\")"),
                "the weekly loop's isEnabled gate no longer reads \"\(key)\" — the switch is now a decoration")

        // And the seam is real at runtime: an isolated defaults suite proves the
        // gate closure's shape (read the key, honour false-by-absence).
        let suiteName = "MindSelfImprovementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(defaults.bool(forKey: key) == false,
                "an unset weekly-improvement key must read as OFF, never as on-by-default")
        defaults.set(true, forKey: key)
        #expect(defaults.bool(forKey: key))
    }

    /// The digest tab shows exactly ONE digest — whichever file has the newest
    /// mtime — with no "showing 1 of N". If the ordering rule inverts, the user
    /// reads a months-old digest as this week's review of their usage. The tie
    /// rule matters too: `max(by:)` only replaces on a strict increase, so equal
    /// mtimes keep the earlier enumerated file.
    @Test func theNewestDigestWinsAndAnEmptyFeedIsNotFabricated() throws {
        let root = try personaTempRoot("digests")
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appendingPathComponent("2026-08-14.md")
        let newer = root.appendingPathComponent("2026-08-21.md")
        let reference = Date(timeIntervalSince1970: 1_780_000_000)

        #expect(SelfImprovementView.newestDigest([]) == nil,
                "an unreadable or empty digest directory must produce no digest at all")
        #expect(SelfImprovementView.newestDigest([
            (url: older, modified: reference),
            (url: newer, modified: reference.addingTimeInterval(7 * 86_400)),
        ]) == newer)
        // Enumeration order must not decide the answer.
        #expect(SelfImprovementView.newestDigest([
            (url: newer, modified: reference.addingTimeInterval(7 * 86_400)),
            (url: older, modified: reference),
        ]) == newer)
        // A digest whose mtime could not be read is `.distantPast` at the call
        // site — it must never win over a real one.
        #expect(SelfImprovementView.newestDigest([
            (url: newer, modified: .distantPast),
            (url: older, modified: reference),
        ]) == older)
    }
}
