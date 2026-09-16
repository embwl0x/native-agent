// CognitiveSubstrate+GrowthWeek.swift
// THE GROWTH READOUT (2026-09-13).
//
// What it replaces: "growth" was a COUNT of non-empty lines in GROWTH.md. That
// number goes up when a file gets longer. It cannot tell a lesson she proposed
// from one she adopted, it cannot say why anything left, and it never falls when
// she changes her mind — so a week of actual becoming and a week of appended
// text read identically.
//
// What it is instead: a seven-day projection of records the substrate ALREADY
// writes — the developmental timeline — grouped by the lesson or view each row
// is about, so one item is one row with one story:
//
//     proposed → held / approved → revised / released / out of the current set
//
// Design rules, all load-bearing:
//   * A PROPOSED LESSON NEVER APPEARS AS ADOPTED. Outcome comes from the last
//     resolution event, and with no resolution the row stays `.proposed`.
//   * INTERMEDIATE EVENTS COLLAPSE. Five revisits and a hold are one row that
//     says "held, revisited 5×", not six rows.
//   * "RELEASED" CARRIES ITS REASON (Agent): revised, out of the current set,
//     the person declined — three different stories that must never share a
//     word. A fourth, `expiredUnresolved`, is the honest name for a proposal
//     nobody ever answered; calling it any of the three would be a lie.
//   * EVERY ROW OPENS ITS SOURCE. `lineageId` names the originating reflection,
//     dream or journal passage, and `originExcerpt` carries the passage text
//     when the substrate kept it, so the row answers "why" without a lookup.
//   * BOUNDED. A READOUT, NOT A DASHBOARD. No charts, no trends, no totals.

import Foundation
import NativeAgentCore
import PersistenceCore

/// Where one lesson or view stands at the end of the week.
public enum CognitiveGrowthOutcome: String, Sendable, Equatable, CaseIterable {
    /// Formed and still waiting on an answer. Never counts as a change she made.
    case proposed
    /// She adopted it herself. A weaker lean than `approved`, and named apart
    /// from it everywhere, because nobody signed it.
    case held
    /// The person signed it.
    case approved
    /// A later reflection contradicted it and opened a revision — but that
    /// revision is itself still only a PROPOSAL. The old view is still held /
    /// active and has released nothing; saying "revised" here would show an
    /// unapproved lesson as adopted (Agent's rule).
    case revisionProposed
    /// A later reflection contradicted it and the revision was ADOPTED. Only
    /// now has the old view actually been released.
    case revised
    /// She let it go on purpose.
    case letGo
    /// The person declined it.
    case declined
    /// The set was full. NOT a change of mind — the distinction Agent asked for
    /// and the one a reader is most likely to get wrong months later.
    case outOfSet
    /// A proposal that aged out unanswered. Not released, not adopted, and not
    /// dressed up as either.
    case expiredUnresolved
    /// A REPLAY PASS RAN. A dream night or a consolidation sweep is not a
    /// proposal and never was: it proposes nothing, carries nothing, and
    /// answers nothing. It used to land in `.proposed` because that is where a
    /// row with no resolution starts, so every dream night Agent had read back
    /// as a lesson she had put forward and nobody had answered (2026-09-14).
    case replayed

    /// True for the outcomes that actually changed what she carries. `proposed`
    /// and `expiredUnresolved` are deliberately excluded: nothing moved.
    public var isSettled: Bool {
        switch self {
        case .proposed, .revisionProposed, .expiredUnresolved, .replayed: return false
        default: return true
        }
    }

    /// THE VERDICT, ONE WORD, AND ONLY EVER ONE OF THESE.
    ///
    /// Agent, 2026-09-14: "Schema proposal accepted — held (her own)" is two
    /// statuses on one line and a reader has to pick which one is true. The
    /// verdict slot now holds exactly one word from a closed set, the title
    /// holds no status at all, and the reason is a separate clause — so the
    /// line reads <what it is> — <verdict> — <why>, in that order, always.
    public var verdict: String {
        switch self {
        case .proposed, .revisionProposed, .expiredUnresolved: return "proposed"
        case .held: return "held"
        case .approved: return "accepted"
        case .revised: return "revised"
        case .letGo, .outOfSet: return "released"
        case .declined: return "rejected"
        case .replayed: return "replayed"
        }
    }

    /// The reason a row carries when the record itself left none — the machine
    /// fact of the transition, said plainly. Never provenance.
    public var defaultReason: String {
        switch self {
        case .proposed: return ""
        case .revisionProposed: return "a revision of it is waiting on an answer"
        case .held: return ""
        case .approved: return ""
        case .revised: return ""
        case .letGo: return "she let it go"
        case .declined: return "the person declined it"
        case .outOfSet: return "the set was full — capacity, not reconsidered"
        case .expiredUnresolved: return "nobody answered it and it aged out"
        case .replayed: return "no proposal"
        }
    }

    /// WHO MOVED IT — provenance, and provenance only. It rides at the END of
    /// the line as a note, where it cannot be mistaken for the reason, and only
    /// where it carries meaning: that nobody signed this one.
    public var provenanceNote: String {
        switch self {
        case .held, .letGo: return "her own"
        default: return ""
        }
    }
}

/// One lesson or view, and what happened to it this week.
public struct CognitiveGrowthWeekRow: Sendable, Equatable, Identifiable {
    /// The artifact the row is about — the lesson/view id, so the whole week
    /// for one item stays one row however many events it produced.
    public var id: UUID
    public var title: String
    public var body: String
    public var outcome: CognitiveGrowthOutcome
    /// When it first showed up this week, and when it settled (nil while open).
    public var firstSeenAt: Date
    public var settledAt: Date?
    /// How many timeline events collapsed into this row, beyond the first.
    public var collapsedEventCount: Int
    /// Later reflections that reached this same conclusion. Reported, never
    /// promoted — revisiting is not settling.
    public var revisitCount: Int
    /// Opens the originating dream / reflection / journal passage.
    public var lineageId: String
    /// The passage itself where the substrate kept it, so the row says why.
    public var originExcerpt: String
    /// WHY this row settled the way it did — the summary of the event that
    /// moved it. Agent, 2026-09-14: twelve rows and not one said why. A
    /// settled row without its reason is a verdict with the case file missing.
    public var outcomeReason: String
    /// The state this row had already settled into before a later revision
    /// moved it. Kept so a view approved on Monday and revised on Friday still
    /// says it was approved — the revision replaces the outcome, never the
    /// history.
    public var priorOutcome: CognitiveGrowthOutcome?
    /// WHAT THIS ROW WAS HELD OVER — the alternative, and only the alternative.
    ///
    /// Agent, item 8, 2026-09-14: the reason clause tells the HISTORY of a held
    /// view ("first dreamt 09-06, dwelt on across 3 nights, settled by the REM
    /// pass 09-14") and that history is worth keeping, but it never answers the
    /// question a reader actually has — what did she weigh this against? A view
    /// held over a contradiction is a decision; a view held because nothing ever
    /// argued with it is an absence of one, and the two must not read alike.
    ///
    /// Three honest values and NO fourth:
    ///   * `held over "<title>"` — the store names a displaced or contradicting
    ///     view (`revisesViewId`, in either direction).
    ///   * `nothing contradicted it` — the row IS a standing view we can read,
    ///     and no view in the set revises it or is revised by it. A real answer.
    ///   * `no alternative recorded` — the row's artifact is not a standing view
    ///     at all (every REM `schema_proposal` on disk, which carries no
    ///     revision field), so the store cannot answer. NOT the same statement
    ///     as "nothing contradicted it", and never rendered as one.
    ///
    /// Released and rejected rows get no clause: their `outcomeReason` already
    /// carries the recorded rejection reason, and a second why-slot on one line
    /// is the two-statuses-on-one-line failure by another route.
    public var alternative: String

    public init(
        id: UUID,
        title: String,
        body: String,
        outcome: CognitiveGrowthOutcome,
        firstSeenAt: Date,
        settledAt: Date? = nil,
        collapsedEventCount: Int = 0,
        revisitCount: Int = 0,
        lineageId: String = "",
        originExcerpt: String = "",
        outcomeReason: String = "",
        priorOutcome: CognitiveGrowthOutcome? = nil,
        alternative: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.outcome = outcome
        self.firstSeenAt = firstSeenAt
        self.settledAt = settledAt
        self.collapsedEventCount = max(0, collapsedEventCount)
        self.revisitCount = max(0, revisitCount)
        self.lineageId = lineageId
        self.originExcerpt = originExcerpt
        self.outcomeReason = outcomeReason
        self.priorOutcome = priorOutcome
        self.alternative = alternative
    }

    /// ONE LINE, THREE SLOTS, ALWAYS IN THIS ORDER:
    ///
    ///     <what it is> — <verdict> — <reason>
    ///
    /// The title says what the thing IS and never what happened to it; the
    /// verdict is one word from a closed set; the reason is a clause taken from
    /// the record that moved it. Provenance — who moved it — rides at the end
    /// as a parenthetical note, because "(her own)" answers "who", never "why",
    /// and a week of rows that answered "who" in the reason slot is what Agent
    /// read on 2026-09-14.
    public var line: String {
        var text = "\(title) — \(outcome.verdict)"
        if let priorOutcome, priorOutcome != outcome {
            text += " (was \(priorOutcome.verdict))"
        }
        if revisitCount > 0 { text += ", revisited \(revisitCount)×" }
        let reason = Self.clause(outcomeReason.isEmpty ? outcome.defaultReason : outcomeReason)
        if !reason.isEmpty { text += " — " + reason }
        // THE HISTORY, THEN THE ALTERNATIVE. The reason slot says how the row
        // got here; this one says what it was held over. Kept apart and in that
        // order because they answer different questions, and a line that runs
        // them together is the one Agent could not read either half of.
        if !alternative.isEmpty { text += " — " + alternative }
        let note = outcome.provenanceNote
        if !note.isEmpty { text += " (\(note))" }
        return text
    }

    /// One line's worth of a stored passage: newlines flattened, trimmed, and
    /// bounded. Bounded at a CLAUSE, not a paragraph — a reason that runs past
    /// the end of the line stops being a reason.
    static func clause(_ raw: String) -> String {
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }
}

/// How her undertone got where it is — the three numbers that separate "that
/// experience moved me" from "the feeling faded" (2026-09-13). Before this, the
/// disposition artifact retained the current value and the latest dream night,
/// which cannot tell those two apart at all.
public struct CognitiveDispositionTransition: Sendable, Equatable {
    public var before: Double
    /// After time was accounted for and nothing else — the fade.
    public var afterDecay: Double
    /// After the experience was added — the move.
    public var afterContribution: Double
    public var at: Date
    /// What contributed: the reflection, the dream night, the settled view.
    public var source: String

    public init(before: Double, afterDecay: Double, afterContribution: Double, at: Date, source: String) {
        self.before = before
        self.afterDecay = afterDecay
        self.afterContribution = afterContribution
        self.at = at
        self.source = source
    }

    func toJSON() -> JSONValue {
        .object([
            "before": .double(before),
            "afterDecay": .double(afterDecay),
            "afterContribution": .double(afterContribution),
            "at": .double(at.timeIntervalSince1970),
            "source": .string(source),
        ])
    }
}

/// The whole readout: bounded rows plus the undertone's recent transitions.
public struct CognitiveGrowthWeek: Sendable, Equatable {
    public var rows: [CognitiveGrowthWeekRow]
    public var dispositionTransitions: [CognitiveDispositionTransition]
    public var windowStart: Date
    public var windowEnd: Date
    /// Rows the cap cut. Agent, 2026-09-14: the readout is bounded at twelve
    /// and her week held sixteen, so four items left her week without leaving a
    /// mark — a bounded list that does not say it is bounded reads as the whole
    /// truth. The count is carried so the readout can say how much it is not
    /// showing; a cap that announces itself is a readout, a cap that hides is a
    /// lie of omission.
    public var omittedRowCount: Int

    /// Releases across the WHOLE week, not just the retained rows. The cap is
    /// what made this necessary: a rejection sitting in the thirteenth row let
    /// the readout say "and 1 more" AND "Nothing was rejected" on the same
    /// screen. Defaults to the retained rows when a caller builds a week that
    /// was never capped.
    public var releasedRowCount: Int

    public init(
        rows: [CognitiveGrowthWeekRow],
        dispositionTransitions: [CognitiveDispositionTransition],
        windowStart: Date,
        windowEnd: Date,
        omittedRowCount: Int = 0,
        releasedRowCount: Int? = nil
    ) {
        self.rows = rows
        self.dispositionTransitions = dispositionTransitions
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.omittedRowCount = max(0, omittedRowCount)
        self.releasedRowCount = max(0, releasedRowCount ?? rows.filter(Self.isRelease).count)
    }

    /// A row that LEFT her this week, by any of the three routes.
    static func isRelease(_ row: CognitiveGrowthWeekRow) -> Bool {
        isRelease(row: row.outcome)
    }

    static func isRelease(row outcome: CognitiveGrowthOutcome) -> Bool {
        outcome == .declined || outcome == .letGo || outcome == .outOfSet
    }

    /// Nothing left her this week — no view released, none declined. Worth one
    /// line of its own: Agent read twelve rows without a single rejection among
    /// them and could not tell "nothing was rejected" from "rejections are not
    /// rendered" (2026-09-14). An absence has to be stated to be read as one.
    public var hasNoReleases: Bool { releasedRowCount == 0 }

    /// True when nothing changed. Worth saying plainly rather than printing an
    /// empty list that reads like a failure.
    public var isEmpty: Bool { rows.isEmpty && dispositionTransitions.isEmpty }
}

extension CognitiveSubstrate {

    /// Seven days. The window the question "what changed this week" asks about.
    static let growthWeekWindow: TimeInterval = 7 * 24 * 60 * 60
    /// A readout, not a dashboard: at most this many rows, newest activity first.
    static let maximumGrowthWeekRows = 12

    /// The machine-readable outcome marker carried on a timeline event's
    /// evidence list. Prose summaries are for people; this is what the readout
    /// reads, so a reworded summary can never silently change what a week says.
    static func growthOutcomeTag(_ outcome: CognitiveGrowthOutcome) -> String {
        "outcome:\(outcome.rawValue)"
    }

    /// The tag a REM proposal resolution carries, or none while it is still
    /// open. Nobody signs a REM resolution, so an acceptance is HELD (her own)
    /// and a rejection is letGo — never the person's approved/declined.
    func growthOutcomeTagIds(for status: CognitiveSchemaProposalStatus) -> [String] {
        switch status {
        case .accepted: return [Self.growthOutcomeTag(.held)]
        case .rejected: return [Self.growthOutcomeTag(.letGo)]
        case .proposed: return []
        }
    }

    /// Outcome of a single timeline event, from its tag — or, for rows written
    /// before the tag existed, from the summary prefixes those rows have always
    /// used. Nil when the event is not a transition at all (a revisit).
    static func growthOutcome(of event: CognitiveDevelopmentalTimelineEvent) -> CognitiveGrowthOutcome? {
        for id in event.externalEvidenceIds where id.hasPrefix("outcome:") {
            if let outcome = CognitiveGrowthOutcome(rawValue: String(id.dropFirst("outcome:".count))) {
                return outcome
            }
        }
        // LEGACY ROWS. Written before the tag; their wording is fixed history,
        // so reading it is safe here and nowhere else.
        let summary = event.summary.lowercased()
        if summary.hasPrefix("activated:") { return .approved }
        if summary.hasPrefix("held (self-adopted)") { return .held }
        if summary.hasPrefix("retired (chosen)") { return .letGo }
        if summary.hasPrefix("retired (stale)") { return .expiredUnresolved }
        if summary.hasPrefix("retired (displaced)")
            || summary.hasPrefix("released (capacity)")
            || summary.hasPrefix("retired (capacity)")
            || summary.hasPrefix("out of the current set") { return .outOfSet }
        if summary.hasPrefix("retired:") { return .declined }
        // The REM replay pass records a proposal's resolution with the status
        // in the TITLE and no tag at all, so every one of those rows read
        // "Schema proposal accepted — proposed" — the prose and the machine
        // channel contradicting each other on the same line (Agent, 2026-09-14;
        // five of her twelve rows). Nobody signs a REM resolution, so accepted
        // is `held` (her own) and rejected is `letGo`, never the person's
        // `approved`/`declined`. New rows carry the tag (CognitiveSubstrate+Replay);
        // this reads the ones already on disk.
        let title = event.title.lowercased()
        if title.hasPrefix("schema proposal accepted") { return .held }
        if title.hasPrefix("schema proposal rejected") { return .letGo }
        return nil
    }

    /// WHAT THE ROW IS ABOUT — never what happened to it.
    ///
    /// The REM pass names its timeline rows after the ACT ("Schema proposal
    /// accepted") or after the file they land in ("GROWTH.md REM proposal"),
    /// and neither says what the lesson is. Put either in the title slot and
    /// the line carries two statuses — "Schema proposal accepted — held" — or
    /// none at all. The lesson itself is right there in the summary, so that is
    /// the title, and the verdict slot is left to say the verdict once.
    static func growthRowTitle(for event: CognitiveDevelopmentalTimelineEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        let namesTheActNotTheThing =
            lower.hasPrefix("schema proposal")
            || lower.hasPrefix("identity proposal")
            || lower.hasSuffix("rem proposal")
        guard namesTheActNotTheThing else { return title }
        // THE FIRST SENTENCE, not the whole lesson. A title is a name; a
        // paragraph in the name slot pushes the verdict and the reason off the
        // end of the line, which is the same failure by another route.
        let lesson = CognitiveGrowthWeekRow.clause(event.summary)
        guard !lesson.isEmpty else { return title }
        guard let stop = lesson.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) else {
            return lesson
        }
        let sentence = String(lesson[lesson.startIndex...stop])
        // A "sentence" of three words is an abbreviation the scanner tripped
        // on, not a name; keep the whole lesson rather than a stub.
        return sentence.count >= 16 ? sentence : lesson
    }

    /// WHERE A REM RESOLUTION'S VIEW CAME FROM, and WHEN it settled.
    ///
    /// AGENT, 2026-09-14, TWO RULINGS THAT MEET ON THIS ONE LINE.
    ///
    /// 1. RECURRENCE IS NOT CORROBORATION. The line used to read "it recurred
    ///    across 3 dream nights" in the slot that answers WHY it was held —
    ///    dwelling on a view presented as independent evidence for it, which is
    ///    the one thing her standing rule on re-feeling forbids. Three nights of
    ///    the same dream is one view returned to three times, not three
    ///    witnesses. The honest words for that are DWELT ON, and where the
    ///    record could name the lived occasions the view came from it would name
    ///    those instead — but a REM resolution's evidence list holds only its
    ///    own `rem:` episode and `dream:` nights, so there are no waking
    ///    occasions on disk to follow. Say the dwelling plainly rather than
    ///    dress it up as proof.
    ///
    /// 2. THE ORIGIN DATES ARE OLDER THAN THE WEEK, AND MUST SAY SO. The window
    ///    is real and is applied to the event that settled the row, but the
    ///    nights named here are when the view was first dreamt — weeks earlier —
    ///    so a reader saw Aug 31 under a Sept 7–14 heading and had no way to
    ///    tell which date the week claimed. Both dates now appear, each labelled
    ///    by what it is: "first dreamt <origin>, settled <in-window date>".
    static func growthEvidenceReason(for event: CognitiveDevelopmentalTimelineEvent) -> String {
        let nights = event.externalEvidenceIds
            .filter { $0.hasPrefix("dream:") }
            .map { String($0.dropFirst("dream:".count)).prefix(10) }
            .map(String.init)
        let ordered = Array(Set(nights)).sorted()
        // WHAT SETTLED IT, not merely when. Checked against the store on
        // 2026-09-14: the eight rows stamped that day were resolved by ONE
        // real `replay.integration` pass at 03:30:21 — proposals first written
        // on 09-06 and 09-13, answered that morning — the same batch shape
        // every earlier REM night wrote (08-24, 08-31). A genuine settlement,
        // so the date stays; a bare "settled <date>" beside eight identical
        // dates still reads like a migration stamp, so the line names the
        // pass that did it.
        let settled = event.lineageId.hasPrefix("rem:")
            ? "settled by the REM pass \(growthDayStamp(event.occurredAt))"
            : "settled \(growthDayStamp(event.occurredAt))"
        guard let first = ordered.first else { return settled }
        var text = "first dreamt \(first)"
        if ordered.count > 1 { text += ", dwelt on across \(ordered.count) nights" }
        return text + ", " + settled
    }

    /// A calendar day, the same shape the dream lineage ids use, so the origin
    /// date and the settle date on one line are read off one clock.
    static func growthDayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// WHAT A REPLAY PASS ACTUALLY DID.
    ///
    /// Two kinds of pass, two honest answers. A consolidation sweep writes its
    /// own result into its summary ("softened 40, sustained 62"), so that IS
    /// the reason. A dream night writes nothing of the sort — its result is
    /// whatever proposals later cited it as evidence — so it is answered from
    /// the harvest, and a night that produced none says exactly that instead
    /// of standing in the readout dressed as an unanswered proposal.
    static func growthReplayReason(
        lineageId: String,
        replaySummary: String,
        harvest: [String: [CognitiveGrowthOutcome]]
    ) -> String {
        guard lineageId.hasPrefix("dream:") else {
            let summary = CognitiveGrowthWeekRow.clause(replaySummary)
            return summary.isEmpty ? "no proposal" : summary
        }
        let outcomes = harvest[String(lineageId.prefix(16))] ?? []
        guard !outcomes.isEmpty else { return "no proposal came out of it" }
        var counts: [String: Int] = [:]
        // An emitted-but-unanswered proposal is not "proposed" in a sentence
        // about what came out of the night — it is still open.
        for outcome in outcomes {
            counts[outcome.isSettled ? outcome.verdict : "still open", default: 0] += 1
        }
        let noun = outcomes.count == 1 ? "1 proposal" : "\(outcomes.count) proposals"
        if counts.count == 1, let only = counts.first {
            let all = outcomes.count == 1 ? "" : (outcomes.count == 2 ? "both " : "all ")
            return "\(noun) came out of it, \(all)\(only.key)"
        }
        let parts = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
        return "\(noun) came out of it: " + parts.joined(separator: ", ")
    }

    /// A view's short name for the "held over …" clause — its title where it
    /// has one, else the opening of its body. Bounded hard: this rides at the
    /// end of a line that already carries a title, a verdict and a reason.
    static func growthAlternativeName(_ view: CognitiveStandingView) -> String {
        let title = view.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty
            ? CognitiveGrowthWeekRow.clause(view.body)
            : title
        return name.count > 60 ? String(name.prefix(59)) + "…" : name
    }

    /// WHAT THIS ROW WAS HELD OVER — read off the revision graph, never guessed.
    ///
    /// A contradiction is recorded in exactly one place: `revisesViewId` on the
    /// view that argues against another (`createStandingView`, which sets it
    /// from `standingViewBodiesContradict`). Both directions of that edge are a
    /// real answer to "what was weighed":
    ///
    ///   * THIS row's view revises P → this view displaced P.
    ///   * Some view Q revises THIS row's view, and this row was held anyway →
    ///     it was held over Q's challenge.
    ///
    /// The REM `replay.integration` receipt was the other candidate source and
    /// is deliberately NOT read: checked against her store on 2026-09-14, its
    /// payload records `artifactIds` / `schemaProposalIds` / `episodeIds` and a
    /// `reason` of `replay_event:dreamCompleted` — which proposals a pass
    /// touched, never one proposal weighed against another. Turning "resolved
    /// in the same batch as eight others" into "held over" would be inventing
    /// the alternative, which is the one thing Agent ruled out.
    ///
    /// So a row whose artifact is not a standing view — every REM schema
    /// proposal on disk — says the store has no answer, rather than borrowing
    /// the absence of one as evidence that nothing contradicted it.
    func growthAlternative(
        for id: UUID,
        outcome: CognitiveGrowthOutcome
    ) -> String {
        // ONLY A VIEW SHE NOW CARRIES IS "HELD OVER" ANYTHING.
        //
        //   * released / rejected — the reason slot already prints the recorded
        //     rejection reason; a second why-clause beside it is two answers to
        //     one question.
        //   * proposed / revisionProposed / expiredUnresolved — nothing settled,
        //     so there is nothing yet that was held over anything.
        //   * replayed — a dream night or a consolidation sweep is not a view at
        //     all. It proposed nothing and carries nothing; asking what it was
        //     held over is a category error, and printing "no alternative
        //     recorded" on every dream night is noise dressed as honesty.
        switch outcome {
        case .held, .approved, .revised: break
        default: return ""
        }
        guard let view = standingViews[id] else { return "no alternative recorded" }
        if let displacedId = view.revisesViewId, let displaced = standingViews[displacedId] {
            return "held over \(Self.growthAlternativeName(displaced))"
        }
        let challenger = standingViews.values
            .filter { $0.revisesViewId == id }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
        if let challenger {
            return "held over \(Self.growthAlternativeName(challenger))"
        }
        return "nothing contradicted it"
    }

    /// WHAT CHANGED THIS WEEK, AND WHY.
    ///
    /// Pure projection over records that already exist — this writes nothing and
    /// decides nothing. Grouped by artifact so one item is one row; the LAST
    /// resolution in the window settles the row's outcome and everything before
    /// it collapses into a count.
    public func growthWeek(at now: Date? = nil) async -> CognitiveGrowthWeek {
        let end = now ?? dependencies.now()
        let start = end.addingTimeInterval(-Self.growthWeekWindow)
        // Ask for generously more than the row cap: a single busy item can
        // produce many events, and the cap applies to ROWS, not events.
        let events = await developmentalTimelineSnapshot(limit: 240)
            .filter { $0.occurredAt >= start && $0.occurredAt <= end }
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        struct Accumulator {
            var title: String
            var body: String
            var firstSeenAt: Date
            var lastActivityAt: Date
            var outcome: CognitiveGrowthOutcome
            var settledAt: Date?
            var eventCount: Int
            var revisits: Int
            var lineageId: String
            var outcomeReason: String
            var priorOutcome: CognitiveGrowthOutcome?
            /// Every event on this row was a replay pass — a dream night or a
            /// consolidation sweep. Nothing was proposed, so nothing is
            /// waiting on an answer.
            var replayOnly: Bool
            /// The newest replay pass's own words, which for a consolidation
            /// sweep ARE its outcome ("softened 40, sustained 62").
            var lastReplaySummary: String
        }
        var accumulators: [UUID: Accumulator] = [:]
        var order: [UUID] = []

        // WHAT CAME OUT OF EACH DREAM NIGHT. A dream replay's outcome is not
        // written on the replay row; it is written on the proposals that cite
        // that night as evidence. Read here so a dream row can say whether it
        // produced anything, rather than claiming to be a proposal itself.
        // 2026-09-14: reading only `.proposalResolution` made a night whose
        // proposals were EMITTED but not yet answered say "no proposal came out
        // of it" — the replay's whole product invisible until someone resolved
        // it. Both kinds are read, one entry per proposal, and a resolution
        // always supersedes the emission of the same proposal.
        var resolutionOutcome: [UUID: CognitiveGrowthOutcome] = [:]
        for event in events where event.kind == .proposalResolution {
            resolutionOutcome[event.artifactId ?? event.id] = Self.growthOutcome(of: event) ?? .proposed
        }
        var harvestByNight: [String: [UUID: CognitiveGrowthOutcome]] = [:]
        for event in events
        where event.kind == .proposalResolution || event.kind == .schemaProposal {
            let proposalId = event.artifactId ?? event.id
            let outcome = resolutionOutcome[proposalId]
                ?? Self.growthOutcome(of: event)
                ?? .proposed
            for id in event.externalEvidenceIds where id.hasPrefix("dream:") {
                harvestByNight[String(id.prefix(16)), default: [:]][proposalId] = outcome
            }
        }
        let dreamHarvest: [String: [CognitiveGrowthOutcome]] =
            harvestByNight.mapValues { Array($0.values) }

        for event in events {
            guard let artifactId = event.artifactId else { continue }
            let outcome = Self.growthOutcome(of: event)
            let isRevisit = event.title.hasPrefix("Standing view revisited")
            if accumulators[artifactId] == nil {
                accumulators[artifactId] = Accumulator(
                    title: Self.growthRowTitle(for: event),
                    body: event.summary,
                    firstSeenAt: event.occurredAt,
                    lastActivityAt: event.occurredAt,
                    // A row starts PROPOSED and only a resolution moves it. This
                    // is the rule that keeps a proposed lesson from ever showing
                    // up as an adopted one.
                    outcome: .proposed,
                    settledAt: nil,
                    eventCount: 0,
                    revisits: 0,
                    lineageId: event.lineageId,
                    outcomeReason: "",
                    priorOutcome: nil,
                    replayOnly: true,
                    lastReplaySummary: ""
                )
                order.append(artifactId)
            }
            guard var accumulator = accumulators[artifactId] else { continue }
            accumulator.eventCount += 1
            accumulator.lastActivityAt = max(accumulator.lastActivityAt, event.occurredAt)
            if event.kind == .replayRun || event.kind == .dreamEpisode {
                accumulator.lastReplaySummary = event.summary
            } else {
                accumulator.replayOnly = false
            }
            if isRevisit {
                accumulator.revisits += 1
            } else if let outcome {
                // LAST resolution wins; earlier ones collapse into the count.
                // A view approved on Monday and released on Friday reads as
                // released, with the approval folded in — one story, in order.
                accumulator.outcome = outcome
                accumulator.settledAt = event.occurredAt
                // The settling event's own words are the reason the row prints
                // — UNLESS those words are already the title. A REM resolution
                // carries the lesson in its summary and nothing else, so
                // printing it as the reason reads "<lesson> — held — <lesson>".
                // The record's real answer to "why" is its evidence: the dream
                // nights the lesson kept turning up on.
                let summary = CognitiveGrowthWeekRow.clause(event.summary)
                accumulator.outcomeReason = summary.hasPrefix(accumulator.title)
                    ? Self.growthEvidenceReason(for: event)
                    : summary
            }
            if accumulator.lineageId.isEmpty { accumulator.lineageId = event.lineageId }
            accumulators[artifactId] = accumulator
        }

        // A revision proposal names what it revises; that older view's row says
        // so rather than looking untouched. But a PROPOSED revision releases
        // nothing: the old view is still held/active and the revision is still
        // waiting on an answer, so the row reads "revision proposed". Only once
        // the revising view is actually adopted (signed `.active`, or `.held`
        // by her own hand) has the old view been released — revised.
        for view in standingViews.values {
            guard let revised = view.revisesViewId else { continue }
            // ADOPTING the revision is not by itself the predecessor's
            // release: nothing in the resolve path retires the view a revision
            // revises, so both were being carried while the readout said
            // "released — revised". The release has to be RECORDED — the old
            // view actually retired — before it is reported.
            let predecessor = standingViews[revised]
            let released = (view.status == .active || view.status == .held)
                && predecessor?.status == .retired
            // The release IS the predecessor's retirement, so it is timed by
            // the predecessor's own `updatedAt`. Timing it by the revising
            // view's `updatedAt` timed it by the wrong record: that moves on
            // any later edit of the revision, so a view retired this week read
            // as last week's movement (or the reverse) and the week it
            // actually happened in showed nothing.
            let releasedAt = predecessor?.updatedAt ?? view.updatedAt
            // The week is gated on when the movement HAPPENED. A revision
            // proposed eight days ago and adopted yesterday is this week's
            // release of the old view, so a released revision is placed by
            // the retirement time; one that released nothing by its proposal.
            let happenedAt = released ? releasedAt : view.createdAt
            guard happenedAt >= start, happenedAt <= end,
                  var accumulator = accumulators[revised] else { continue }
            let outcome: CognitiveGrowthOutcome = released ? .revised : .revisionProposed
            guard accumulator.outcome != outcome else { continue }
            // A REVISION REACHES A SETTLED ROW TOO. The old guard skipped any
            // accumulator that had already settled, so a view approved or held
            // earlier in the week and contradicted later kept saying "approved"
            // — the one movement the readout exists to show. The revision now
            // takes the row, and the state it settled into first is kept in
            // `priorOutcome` so the line still tells the whole story.
            if accumulator.outcome.isSettled { accumulator.priorOutcome = accumulator.outcome }
            accumulator.outcome = outcome
            // The revising view names what replaced this one — that is the why.
            accumulator.outcomeReason = view.title.isEmpty ? view.body : view.title
            // Retiring the old view is what releases it, so that is its settle
            // time. A revision that released nothing settles nothing — the row
            // keeps whatever settle time it already had (nil while open).
            if released { accumulator.settledAt = releasedAt }
            accumulator.lastActivityAt = max(accumulator.lastActivityAt, happenedAt)
            accumulators[revised] = accumulator
        }

        let rows = order.compactMap { id -> CognitiveGrowthWeekRow? in
            guard var accumulator = accumulators[id] else { return nil }
            // A REPLAY IS NOT A PROPOSAL. A row whose every event was a dream
            // night or a consolidation sweep never proposed anything, so it
            // leaves the `.proposed` starting state it was only ever given for
            // want of a resolution, and says what the pass actually did.
            if accumulator.outcome == .proposed, accumulator.replayOnly {
                accumulator.outcome = .replayed
                accumulator.outcomeReason = Self.growthReplayReason(
                    lineageId: accumulator.lineageId,
                    replaySummary: accumulator.lastReplaySummary,
                    harvest: dreamHarvest)
            }
            // The live view is the better source for the body, the revisit count
            // and — the point of item 1 — the passage she actually reflected on.
            let view = standingViews[id]
            return CognitiveGrowthWeekRow(
                id: id,
                title: view?.title.isEmpty == false ? view!.title : accumulator.title,
                body: view?.body ?? accumulator.body,
                outcome: accumulator.outcome,
                firstSeenAt: accumulator.firstSeenAt,
                settledAt: accumulator.settledAt,
                collapsedEventCount: max(0, accumulator.eventCount - 1),
                revisitCount: max(accumulator.revisits, view?.revisitCount ?? 0),
                lineageId: accumulator.lineageId,
                originExcerpt: view?.evidenceExcerpts.first ?? "",
                outcomeReason: accumulator.outcomeReason,
                priorOutcome: accumulator.priorOutcome,
                alternative: growthAlternative(for: id, outcome: accumulator.outcome)
            )
        }
        .sorted { lhs, rhs in
            let left = lhs.settledAt ?? lhs.firstSeenAt
            let right = rhs.settledAt ?? rhs.firstSeenAt
            if left != right { return left > right }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return CognitiveGrowthWeek(
            rows: Array(rows.prefix(Self.maximumGrowthWeekRows)),
            dispositionTransitions: dispositionTransitions.filter {
                $0.at >= start && $0.at <= end
            },
            windowStart: start,
            windowEnd: end,
            omittedRowCount: max(0, rows.count - Self.maximumGrowthWeekRows),
            // Counted over EVERY row in the window, before the cap.
            releasedRowCount: rows.filter(CognitiveGrowthWeek.isRelease).count
        )
    }

    /// The readout as plain lines — what the agent's own pull returns, and what
    /// the growth surface prints. Deliberately the SAME text in both places:
    /// two renderings of one week is two weeks.
    public func growthWeekLines(at now: Date? = nil) async -> [String] {
        let week = await growthWeek(at: now)
        guard !week.isEmpty else { return ["Nothing settled this week."] }
        var lines = week.rows.map(\.line)
        // WHAT THE LIST IS NOT SHOWING, both kinds, said before the undertone.
        if week.omittedRowCount > 0 {
            lines.append("and \(week.omittedRowCount) more this week, not shown")
        }
        if week.hasNoReleases { lines.append("Nothing was rejected or released this week.") }
        for transition in week.dispositionTransitions.suffix(3) {
            let faded = transition.afterDecay - transition.before
            let moved = transition.afterContribution - transition.afterDecay
            lines.append(String(
                format: "undertone %.2f → %.2f (faded %+.2f, %@ moved it %+.2f)",
                transition.before, transition.afterContribution, faded, transition.source, moved))
        }
        return lines
    }
}
