// CognitiveSubstrate+Opinions.swift
// Phase 5 D (2026-10-03) — opinions and interests, an experiment behind
// `personality.views_experiment` (CognitiveConfiguration.viewsExperimentEnabled).
//
// Both live in the standing-view store as two statuses of their own, so the
// store's lifecycle, caps, persistence, undo, reject and mind.why serve them
// unchanged, and nothing that reads `.active`/`.held` (the felt lane, pursuits,
// shoulder taps) ever sees them.
//
// D1, Agent's minimal spec: an opinion is what she thinks, why, what would
// change her mind, and the evidence behind any revision. It forms only when a
// view with its reasons recurs INDEPENDENTLY — a distinct day and distinct
// source material — never from re-reading the same thing. Age asks her
// reflection to reconsider it; it never changes or retires anything.
//
// D2: what she explores in her hour becomes an interest with her open
// question. It fades slowly unless she comes back to it, and the next hour
// offers it first. It is never a Desk item.

import Foundation
import NativeAgentCore
import PersistenceCore
import Studio

extension CognitiveSubstrate {
    static let maximumOpinions = 8
    static let maximumInterests = 5
    static let opinionMinimumIndependentOccurrences = 2

    // MARK: - Independent occurrences

    static func occurrenceKey(day: Date, source: String) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            + "|" + source
    }

    /// The experience a reflection read: the dream entry it reflected on, else
    /// the exact messages it quoted, else the nodes it was built from.
    static func reflectionSourceKey(_ request: CognitiveReflectionRequest) -> String {
        if let material = request.materialProvenance, !material.isEmpty { return material }
        let messages = request.sourceExcerpts.compactMap { line -> String? in
            guard let range = line.range(of: #"message [0-9A-Fa-f-]{36}"#, options: .regularExpression) else { return nil }
            return String(line[range].dropFirst(8))
        }
        let ids = messages.isEmpty ? request.sourceNodeIds.map(\.uuidString) : messages
        return Set(ids).sorted().joined(separator: ",")
    }

    static func reflectionOccurrenceKey(_ receipt: CognitiveReflectionReceipt) -> String {
        occurrenceKey(day: receipt.createdAt, source: reflectionSourceKey(receipt.request))
    }

    /// Independent of every known occurrence: another day AND no shared source.
    static func isIndependentOccurrence(_ key: String, of known: [String]) -> Bool {
        func split(_ key: String) -> (String, Set<String>) {
            let bare = key.hasPrefix(taintedOccurrencePrefix) ? String(key.dropFirst(taintedOccurrencePrefix.count)) : key
            let parts = bare.split(separator: "|", maxSplits: 1).map(String.init)
            let sources = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init))
            return (parts.first ?? "", sources)
        }
        let (day, sources) = split(key)
        return !known.contains { other in
            let (otherDay, otherSources) = split(other)
            return otherDay == day || !otherSources.isDisjoint(with: sources)
        }
    }

    // MARK: - Claim filter (Agent: titles are not thoughts)

    /// Cheap: enough words to say something, and not shaped like a heading
    /// ("Reflection: after the dream, 2026-10-02", "**What's actually observed:**").
    public static func isClaimShaped(_ text: String, minimumWords: Int = 6) -> Bool {
        let cleaned = text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        guard words.count >= minimumWords, !cleaned.hasSuffix(":") else { return false }
        let lower = cleaned.lowercased()
        let headingLead = ["reflection", "private reflection", "reflection takeaway: reflection",
                           "dream", "what's actually", "what is actually", "what the record"]
        if headingLead.contains(where: { lower.hasPrefix($0) }),
           lower.range(of: #"\d{4}-\d{2}-\d{2}|^[^.!?]*:\s*$"#, options: .regularExpression) != nil
            || words.count < 9 {
            return false
        }
        // A date-stamped line that never makes a sentence is a title.
        if lower.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil,
           cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) == nil, words.count < 12 {
            return false
        }
        return true
    }

    // MARK: - Reflection protocol lines

    struct ReflectionOpinionLines {
        var viewBecause = ""
        var viewUnless = ""
        var revise = ""
        var reviseBecause = ""
        var reviseUnless = ""
    }

    /// `because:` and `unless:` belong to the `view:` or `revise:` line above them.
    static func reflectionOpinionLines(_ text: String) -> ReflectionOpinionLines {
        var out = ReflectionOpinionLines()
        var current = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = normalizedProposalLine(raw).replacingOccurrences(of: "**", with: "")
            let lower = line.lowercased()
            func rest(_ prefix: String) -> String {
                String(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            }
            if lower.hasPrefix("view:") { current = "view" }
            else if lower.hasPrefix("revise:") { current = "revise"; out.revise = rest("revise:") }
            else if lower.hasPrefix("because:") {
                if current == "view", out.viewBecause.isEmpty { out.viewBecause = rest("because:") }
                if current == "revise", out.reviseBecause.isEmpty { out.reviseBecause = rest("because:") }
            } else if lower.hasPrefix("unless:") {
                if current == "view", out.viewUnless.isEmpty { out.viewUnless = rest("unless:") }
                if current == "revise", out.reviseUnless.isEmpty { out.reviseUnless = rest("unless:") }
            }
        }
        return out
    }

    static let opinionProtocolPrefixes = ["because:", "unless:", "revise:"]

    // MARK: - D1 paraphrase (local embedder)

    /// bge-large cosine between two `view:` lines that say the same thing in
    /// other words. Calibrated on her 17 real views (08-19…09-22): every
    /// same-theme pair scored 0.726–0.881, every cross-theme pair ≤ 0.71,
    /// median 0.54. 0.80 would have missed 5 of the 8 true pairs.
    static let paraphraseCosineFloor = 0.72

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(dot / (na.squareRoot() * nb.squareRoot())) : 0
    }

    /// The existing view this body restates, if the embedder can say so.
    func paraphraseTwin(of body: String, among views: [CognitiveStandingView]) async -> CognitiveStandingView? {
        guard !views.isEmpty, let vectors = await dependencies.embedTexts([body] + views.map(\.body)),
              vectors.count == views.count + 1 else { return nil }
        let scored = views.indices.map { (views[$0], Self.cosine(vectors[0], vectors[$0 + 1])) }
            .filter { $0.1 >= Self.paraphraseCosineFloor }
        return scored.max { $0.1 < $1.1 }?.0
    }

    // MARK: - D1 formation: independent recurrence

    /// Occurrences that count: her own `view:` lines from reflections no
    /// untrusted peer fed (`x:` marks one that only blocks independence).
    static func countedOccurrences(_ view: CognitiveStandingView) -> [String] {
        view.occurrences.filter { !$0.hasPrefix(taintedOccurrencePrefix) }
    }

    static let taintedOccurrencePrefix = "x:"

    // MARK: - Peer taint (Sol, binding): peer words are not her conviction

    /// True when this reflection read anything from a peer the owner has not
    /// elevated in Trust (`PeerTrust`): a source node whose out-of-band origin
    /// is a peer, a peer conversation, or a quoted excerpt from one. A
    /// request without captured peer provenance cannot be checked and fails closed.
    func reflectionIsTainted(_ request: CognitiveReflectionRequest) -> Bool {
        guard let peers = request.sourcePeerIds else { return true }
        return peers.contains { !dependencies.peerTrusted($0) }
    }

    /// `peer:<uuid>` for an agent conversation, the lane name for a built-in
    /// one; an unknown peer session is returned as is (and trusts no one).
    static func peerIdentity(session: String) -> String? {
        let lowered = session.lowercased()
        guard lowered.hasPrefix("agent-") || lowered.hasPrefix("bot-") else { return nil }
        if let range = lowered.range(of: "-mcp-") {
            let tail = String(lowered[range.upperBound...])
            return UUID(uuidString: tail) != nil ? "peer:" + tail : tail
        }
        return lowered
    }

    static func peerIdentity(metadata: [String: JSONValue]) -> String? {
        var session: String?
        if case .string(let value)? = metadata["sessionId"] { session = value }
        if case .object(let origin)? = metadata["origin"], case .string(let authored)? = origin["authored"],
           authored.lowercased() == peerAuthoredAttestation {
            if case .string(let agent)? = origin["agent"], agent.lowercased() != "agent" { return agent }
            return session.flatMap(peerIdentity(session:)) ?? "agent"
        }
        return session.flatMap(peerIdentity(session:))
    }

    // MARK: - View-to-view lexical match (the fast first pass)

    /// The same conclusion in other words, by her own terms: at least three
    /// shared, and at least half of the shorter view's. On her 17 real views
    /// this matched two true paraphrase pairs and nothing else.
    func lexicalTwin(of body: String, among views: [CognitiveStandingView]) -> CognitiveStandingView? {
        let terms = Self.appraisalConcernTerms(in: body)
        return views.first { view in
            let other = Self.appraisalConcernTerms(in: view.body)
            let shared = terms.filter { term in other.contains { Self.standingViewTermsMatch(term, $0) } }.count
            return shared >= 3 && shared * 2 >= min(terms.count, other.count)
        }
    }

    /// A proposed view with its reasons that has recurred independently
    /// becomes her opinion. No signature: it is hers, and it never leans a
    /// pursuit, a tap or the felt lane. Only THIS reflection can tip it — the
    /// one that just landed must be one of the occurrences — so a formation
    /// she undid stays undone until the theme comes back on its own again.
    func formOpinionsFromIndependentRecurrence(trigger: CognitiveReflectionReceipt, at now: Date) async {
        guard configuration.enabled, configuration.viewsExperimentEnabled else { return }
        let candidates = standingViews.values
            .filter { $0.status == .proposed && $0.hasReasons && Self.isClaimShaped($0.body) }
            .sorted { $0.createdAt < $1.createdAt }
        for proposal in candidates {
            await waitForMaintenanceTransition()
            // Only her own view lines, matched view to view, from reflections
            // no untrusted peer fed — never topic words in the prose.
            let occurrences = Self.countedOccurrences(proposal)
            guard occurrences.count >= Self.opinionMinimumIndependentOccurrences,
                  occurrences.contains(Self.reflectionOccurrenceKey(trigger)),
                  standingViews[proposal.id] == proposal else { continue }
            var opinion = proposal
            opinion.status = .opinion
            opinion.updatedAt = now
            let previousViews = standingViews
            standingViews[opinion.id] = opinion
            let released = releaseOverflow(status: .opinion, cap: Self.maximumOpinions, protecting: opinion.id, at: now)
            markDirty(at: now)
            guard await saveOwnViewTransition(opinion, released: released, previousViews: previousViews, at: now) else {
                continue
            }
            await recordUndo(key: "view:\(opinion.id.uuidString)", what: "formed opinion: \(opinion.title)",
                             previous: proposal.toJSON(), stamp: Self.undoStamp(opinion))
            await recordReceipt(kind: "opinion.formed", payload: .object([
                "id": .string(opinion.id.uuidString),
                "occurrences": .array(opinion.occurrences.map { .string(String($0.prefix(60))) }),
            ]))
            _ = await recordTimelineEvent(
                kind: .proposalResolution,
                title: "Opinion formed (came back on \(opinion.occurrences.count) separate days)",
                summary: "\(opinion.body)\nbecause: \(opinion.because)\nunless: \(opinion.wouldChangeMind)",
                artifactId: opinion.id, lineageId: opinion.lineageId,
                externalEvidenceIds: [CognitiveSubstrate.growthOutcomeTag(.held)])
            await recordCapacityRelease(released)
        }
    }

    /// Her own set is full: the least recently touched one leaves the current
    /// set. Capacity, recorded as such — not a change of mind, not age.
    func recordCapacityRelease(_ released: [CognitiveStandingView]) async {
        for old in released {
            _ = await recordTimelineEvent(
                kind: .proposalResolution, title: "Out of the current set",
                summary: "out of the current set (capacity, not reconsidered): \(old.body)",
                artifactId: old.id, lineageId: old.lineageId,
                externalEvidenceIds: [CognitiveSubstrate.growthOutcomeTag(.outOfSet)])
        }
        let current = standingViews.values.filter { $0.status != .retired }
        var protected = Set(current.compactMap(\.revisesViewId))
        for entry in undoLedger where entry.key.hasPrefix("view:") {
            if let id = UUID(uuidString: String(entry.key.dropFirst(5))) { protected.insert(id) }
            if let prior = standingView(fromPayload: entry.previous), let id = prior.revisesViewId {
                protected.insert(id)
            }
        }
        // Retired history already lives in the timeline. Keep only rows still
        // needed by a current view or an available undo.
        standingViews = standingViews.filter { $0.value.status != .retired || protected.contains($0.key) }
    }

    /// LRU by `updatedAt` within one of her own tiers, never `protecting`.
    func releaseOverflow(
        status: CognitiveStandingView.Status, cap: Int, protecting: UUID, at now: Date
    ) -> [CognitiveStandingView] {
        let rows = standingViews.values
            .filter { $0.status == status && $0.id != protecting }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard rows.count + 1 > cap else { return [] }
        let released = rows.prefix(rows.count + 1 - cap).map { row in
            var row = row
            row.status = .retired
            row.updatedAt = now
            standingViews[row.id] = row
            return row
        }
        return released
    }

    /// Save the replacement and every capacity deletion together. Retain the
    /// previous set until this write succeeds so a failed transition can retry.
    private func saveOwnViewTransition(
        _ view: CognitiveStandingView,
        released: [CognitiveStandingView],
        previousViews: [UUID: CognitiveStandingView],
        at now: Date
    ) async -> Bool {
        beginMaintenanceTransition()
        defer { endMaintenanceTransition() }
        do {
            try await persistArtifactTransition(
                artifacts: [CognitiveArtifactWrite(
                    kind: "standing_view", id: view.id, status: view.status.rawValue,
                    score: max(0, view.moodValenceAtFormation), payload: view.toJSON())],
                deletedArtifactIDs: released.map(\.id), at: now)
            pruneRetiredStandingViews()
            return true
        } catch {
            for changed in [view] + released where standingViews[changed.id] == changed {
                standingViews[changed.id] = previousViews[changed.id]
            }
            markDirty(at: dependencies.now())
            return false
        }
    }

    // MARK: - D1 reconsideration: age asks, she answers

    /// The opinion longest unreconsidered among those due, if any.
    func opinionDueForReconsideration(at now: Date) -> CognitiveStandingView? {
        guard configuration.viewsExperimentEnabled else { return nil }
        return standingViews.values
            .filter { $0.dueForReconsideration(at: now) }
            .min { $0.stanceSince < $1.stanceSince }
    }

    func reconsiderationInvitation(for view: CognitiveStandingView) -> String {
        "\n\nYou have held this opinion for a while: \"\(view.body)\" — because \(view.because); "
            + "it would change if \(view.wouldChangeMind). Reconsider it against what is here. Only if "
            + "something here is real evidence or a better argument against it, close with:\n"
            + "  revise: <what you think now>\n  because: <that evidence>\n"
            + "Otherwise leave it; still holding it is a full answer."
    }

    /// The reflection that was shown a due opinion has answered: a `revise:`
    /// with its evidence revises it; anything else means it still stands, and
    /// the clock that asked starts again. Never a change by age.
    func settleOpinionReconsideration(receipt: CognitiveReflectionReceipt, source: String) async {
        await waitForMaintenanceTransition()
        guard configuration.viewsExperimentEnabled,
              let shown = standingViews.values.first(where: {
                  $0.status == .opinion && receipt.request.prompt.contains("opinion for a while: \"\($0.body)\"")
              }) else { return }
        let lines = Self.reflectionOpinionLines(source)
        // A reflection an untrusted peer fed may not revise her opinion.
        if !lines.revise.isEmpty, !reflectionIsTainted(receipt.request), !lines.reviseBecause.isEmpty {
            _ = await reviseOpinion(id: shown.id, stance: lines.revise, evidence: lines.reviseBecause,
                                    wouldChangeMind: lines.reviseUnless, by: "reflection")
            return
        }
        var kept = shown
        kept.lastRevisitedAt = dependencies.now()
        standingViews[kept.id] = kept
        markDirty(at: dependencies.now())
        do {
            try await persistStandingViewChecked(kept)
        } catch {
            if standingViews[kept.id] == kept { standingViews[kept.id] = shown }
            return
        }
        _ = await recordTimelineEvent(
            kind: .proposalResolution, title: "Opinion reconsidered — still holds",
            summary: kept.body, artifactId: kept.id, lineageId: kept.lineageId, externalEvidenceIds: [])
    }

    // MARK: - D1 revision: evidence, never a count

    /// Revise one of her opinions. Needs the evidence or argument that moved
    /// her; keeps the stance it replaces and that evidence (last three).
    /// Returns nil when revised, else why not.
    @discardableResult
    func reviseOpinion(
        id: UUID, stance: String, evidence: String, wouldChangeMind: String = "", by: String
    ) async -> String? {
        await waitForMaintenanceTransition()
        guard configuration.enabled, configuration.viewsExperimentEnabled else {
            return "opinions are switched off (personality.views_experiment)"
        }
        guard var view = standingViews[id], view.status == .opinion else { return "that is not one of your opinions" }
        let newStance = bounded(stance.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 300)
        let because = bounded(evidence.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 240)
        guard Self.isClaimShaped(because, minimumWords: 4) else {
            return "a revision needs the evidence or argument that changed your mind"
        }
        guard Self.isClaimShaped(newStance, minimumWords: 4),
              Self.normalizedStandingViewBody(newStance) != Self.normalizedStandingViewBody(view.body) else {
            return "say what you think now; it has to differ from what you thought"
        }
        let previous = view
        let now = dependencies.now()
        view.revisions = Array((view.revisions + [CognitiveViewRevision(
            priorStance: view.body, priorBecause: view.because, evidence: because, at: now)])
            .suffix(CognitiveStandingView.maximumRevisions))
        view.body = newStance
        view.title = bounded(standingViewTitle(from: newStance), maxCharacters: 80)
        view.because = because
        let unless = wouldChangeMind.trimmingCharacters(in: .whitespacesAndNewlines)
        if !unless.isEmpty { view.wouldChangeMind = bounded(unless, maxCharacters: 200) }
        view.updatedAt = now
        standingViews[id] = view
        markDirty(at: now)
        do {
            try await persistStandingViewChecked(view)
        } catch {
            if standingViews[id] == view { standingViews[id] = previous }
            return "the opinion revision was not saved: \(error)"
        }
        await recordUndo(key: "view:\(id.uuidString)", what: "revised opinion: \(view.title)",
                         previous: previous.toJSON(), stamp: Self.undoStamp(view))
        await dependencies.feltCause(0, 0.05)
        await recordReceipt(kind: "opinion.revised", payload: .object([
            "id": .string(id.uuidString), "by": .string(by),
            "from": .string(bounded(previous.body, maxCharacters: 200)),
            "evidence": .string(because),
        ]))
        _ = await recordTimelineEvent(
            kind: .proposalResolution, title: "Opinion revised",
            summary: "I used to think: \(previous.body)\nNow: \(newStance)\nWhat changed it: \(because)",
            artifactId: id, lineageId: view.lineageId,
            externalEvidenceIds: [Self.growthOutcomeTag(.revised)])
        return nil
    }

    /// Her own seat's revision — the seat hold/release/reject/undo use.
    public func reviseOpinion(
        id: UUID, stance: String, evidence: String, wouldChangeMind: String, seat: StudioCanonTurnProvenance
    ) async -> String? {
        guard seat.isComplete else { return "an opinion is revised from inside your own turn" }
        await waitForMaintenanceTransition()
        return await reviseOpinion(id: id, stance: stance, evidence: evidence,
                                   wouldChangeMind: wouldChangeMind, by: "her seat")
    }

    // MARK: - D2 interests

    /// What her hour left her wondering. A return to an open interest (same
    /// topic, shared terms) refreshes it with the better question and keeps
    /// the earlier ones; anything else is a new interest. Never a Desk item.
    @discardableResult
    public func noteInterest(question: String, topic: String?) async -> CognitiveStandingView? {
        guard configuration.enabled, configuration.viewsExperimentEnabled else { return nil }
        await waitForMaintenanceTransition()
        let asked = bounded(question.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 240)
        guard Self.isClaimShaped(asked, minimumWords: 4) else { return nil }
        let now = dependencies.now()
        let title = bounded(
            (topic?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? standingViewTitle(from: asked), maxCharacters: 80)
        let newTerms = Self.appraisalConcernTerms(in: "\(title) \(asked)")
        let match = standingViews.values
            .filter { $0.status == .interest && $0.interestWeight(at: now) >= CognitiveStandingView.interestFloor }
            .first { open in
                if Self.normalizedStandingViewBody(open.title) == Self.normalizedStandingViewBody(title) { return true }
                let terms = Self.appraisalConcernTerms(in: "\(open.title) \(open.body)")
                return newTerms.filter { term in terms.contains { Self.standingViewTermsMatch(term, $0) } }.count >= 2
            }
        let previous = match
        var interest: CognitiveStandingView
        if var open = match {
            // She came back to it. The earlier question is kept, not lost.
            if Self.normalizedStandingViewBody(open.body) != Self.normalizedStandingViewBody(asked) {
                open.evidenceExcerpts = Self.boundedEvidenceExcerpts(
                    Array((open.evidenceExcerpts + [open.body]).suffix(CognitiveStandingView.maximumEvidenceExcerpts)))
                open.body = asked
            }
            open.revisitCount += 1
            open.lastRevisitedAt = now
            open.updatedAt = now
            interest = open
        } else {
            interest = CognitiveStandingView(
                id: stableArtifactID("studio_interest|\(stableDigest(Self.normalizedStandingViewBody(asked)))"),
                title: title, body: asked, status: .interest,
                moodValenceAtFormation: derivedMood(at: now).valence,
                createdAt: now, updatedAt: now, lineageId: "studio_wander")
        }
        let previousViews = standingViews
        standingViews[interest.id] = interest
        let released = releaseOverflow(status: .interest, cap: Self.maximumInterests, protecting: interest.id, at: now)
        markDirty(at: now)
        guard await saveOwnViewTransition(interest, released: released, previousViews: previousViews, at: now) else {
            return nil
        }
        await recordUndo(key: "view:\(interest.id.uuidString)",
                         what: (previous == nil ? "new interest: " : "returned to interest: ") + interest.title,
                         previous: previous?.toJSON() ?? .null, stamp: Self.undoStamp(interest))
        _ = await recordTimelineEvent(
            kind: .schemaProposal,
            title: previous == nil ? "Interest from her hour" : "Returned to an interest (\(interest.revisitCount))",
            summary: "\(interest.title): \(interest.body)",
            artifactId: interest.id, lineageId: interest.lineageId, externalEvidenceIds: [])
        await recordCapacityRelease(released)
        await dependencies.feltCause(previous == nil ? 0.03 : 0.05, 0)
        return interest
    }

    /// Her open questions for her hour, newest first. Bare titles never
    /// (Agent). With the experiment on, the substrate's own pressure readings
    /// ("Re-check high-pressure cognitive state after …") are left out too:
    /// on the live install they were every line of "Still open for you".
    public func curiosityForHour() -> [String] {
        let experiment = configuration.viewsExperimentEnabled
        return projectedThoughtSeeds(at: dependencies.now())
            .filter { ($0.kind == .openQuestion || $0.kind == .anomaly)
                && (!experiment || isUsefulThoughtSeed($0))
                && Self.isClaimShaped($0.text, minimumWords: 4) }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .map(\.text)
    }

    public func viewsExperimentEnabled() -> Bool {
        configuration.enabled && configuration.viewsExperimentEnabled
    }

    /// Her live interests, strongest first — what her next hour offers first.
    public func openInterests() -> [CognitiveStandingView] {
        guard configuration.enabled, configuration.viewsExperimentEnabled else { return [] }
        let now = dependencies.now()
        return standingViews.values
            .filter { $0.status == .interest && $0.interestWeight(at: now) >= CognitiveStandingView.interestFloor }
            .sorted { $0.interestWeight(at: now) > $1.interestWeight(at: now) }
    }
}
