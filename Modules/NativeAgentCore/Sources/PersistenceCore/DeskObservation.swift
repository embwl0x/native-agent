import Foundation

// MARK: - Desk Wave 5 — the desk learns from OBSERVED REALITY
//
// Waves 1–4 made the desk a real project board: sequencing edges, one-call
// breakdown, a User-gated nag lane, UI pills. Every one of those still trusts
// what somebody TYPED. This file is the part that trusts what actually
// HAPPENED — a PR merged, an issue closed, a blocker shipped — and reconciles
// the board against it.
//
// Two decisions come out of one observation pass:
//
//   1. AUTO-RESOLUTION. A tracked external item that reached a terminal state
//      in reality closes its desk item, with the receipt attached. NO RECEIPT,
//      NO CLOSE: an observation carrying empty evidence can never mutate an
//      item — it degrades to drift instead. That is the hard line on "no
//      silent mutations without receipts".
//
//   2. DRIFT. Desk state that CONTRADICTS reality is flagged, never silently
//      rewritten. "blocked on X" while X shipped, an item closed here that
//      reopened there, work parked until Friday that already landed. Drift is
//      loud and inert: it annotates, it does not decide.
//
// WHY NO NEW OP TOKEN: every decision here lands through ops the store already
// has (appendNote, closeItemIfUnchanged). The op-log vocabulary is unchanged,
// so replay determinism, the compaction strict-decode rules, and old-binary
// byte-compat are all untouched by this wave. Drift dedupe rides on a marker
// inside the note text rather than a new state field, so there is no drift
// flag that can get stuck ON after reality moves again.
//
// WHY CAS: auto-resolution runs on a background pass while User and Agent are
// both live on the same desk. Every close goes through
// `closeItemIfUnchanged(expectedUpdatedAt:)`, so an item edited between the
// evaluation and the write is SKIPPED, not stomped. The next pass re-evaluates
// it against fresh state.

/// One external thing, as reality reports it. Built by a sensing lane (today:
/// the GitHub tracker) and handed to the evaluator, which is pure and does no
/// IO of its own — that is what makes the whole reconciliation unit-testable
/// against a synthetic reality.
public struct DeskObservedRef: Sendable, Equatable {
    /// Canonical external identity, matching `DeskObservedRef.key(for:)` on the
    /// desk side: `owner/repo#pr#123`. Identity, never display.
    public var refKey: String
    /// Raw status word from the source ("open", "closed", "merged"). Kept
    /// verbatim for the receipt — a paraphrase is not a receipt.
    public var status: String
    /// Reality says this is finished. The source decides; the evaluator does
    /// not re-derive terminality from a status string it may not understand.
    public var terminal: Bool
    /// Human-readable proof, e.g. "merged into main 2026-08-04 (github)".
    /// EMPTY EVIDENCE DISABLES MUTATION — see `autoResolve` gating below.
    public var evidence: String
    /// Sensing lane that produced this, e.g. "github". Matched against the
    /// item's `cadence.refreshSources` to decide what "tracked" means.
    public var source: String
    /// ISO stamp of the observation itself (not of the remote event).
    public var observedAt: String
    /// Opaque change token for cadence learning: differing fingerprint between
    /// passes == the thing changed. Not interpreted here.
    public var fingerprint: String

    public init(
        refKey: String,
        status: String,
        terminal: Bool,
        evidence: String,
        source: String,
        observedAt: String,
        fingerprint: String
    ) {
        self.refKey = refKey
        self.status = status
        self.terminal = terminal
        self.evidence = evidence
        self.source = source
        self.observedAt = observedAt
        self.fingerprint = fingerprint
    }

    /// Canonical key for a desk ref, or nil when the ref names nothing
    /// externally observable (a file path, a free-form note). Lowercased repo
    /// so `User/Repo#pr#1` and `user/repo#pr#1` are the same thing.
    public static func key(for ref: DeskRef) -> String? {
        switch ref.kind {
        case let .ghPr(repo, number, _, _, _):
            return "\(repo.lowercased())#pr#\(number)"
        case let .ghIssue(repo, number, _, _):
            return "\(repo.lowercased())#issue#\(number)"
        default:
            return nil
        }
    }
}

/// What the desk got wrong, in reality's opinion. Each case is a CONTRADICTION,
/// not a staleness complaint — a merely out-of-date cached field is the cadence
/// lane's problem, not drift.
public enum DeskDriftKind: String, Sendable, CaseIterable, Equatable {
    /// Desk says blocked / waiting; every external thing it points at is done.
    case blockedButShipped = "blocked_but_shipped"
    /// Desk closed it; reality reopened it after the close.
    case reopenedAfterClose = "reopened_after_close"
    /// Parked until a future date; the work it points at already landed.
    case parkedButShipped = "parked_but_shipped"
    /// Everything it tracks is terminal and it carries a receipt, but the item
    /// is not marked as externally tracked, so auto-resolution stays out of it.
    case untrackedButShipped = "untracked_but_shipped"
    /// Reality says done but arrived with NO evidence. Never mutates. This is
    /// the case that exists so a receiptless observation is loud instead of
    /// either silent or destructive.
    case shippedWithoutReceipt = "shipped_without_receipt"

    /// Sentence fragment used in the note the flag writes.
    public var phrase: String {
        switch self {
        case .blockedButShipped: return "desk says blocked, but everything it tracks has shipped"
        case .reopenedAfterClose: return "closed on the desk, but reopened upstream"
        case .parkedButShipped: return "parked for later, but the work already landed"
        case .untrackedButShipped: return "tracked work has shipped, but this item is not marked externally tracked, so it was left alone"
        case .shippedWithoutReceipt: return "reality reports this finished but sent no evidence, so nothing was closed"
        }
    }
}

/// WHEN a drift may be written, relative to this pass's auto-resolves.
///
/// Most contradictions are about the item alone and can be written straight
/// away. Two are not: "your sub-items are still open" and "your blocker
/// auto-resolved" are premises about OTHER items that this same pass is in the
/// middle of changing. Written up front, they can be false by the time the pass
/// ends — a parent told its child is open moments before the child closes, or an
/// item told its blocker resolved when that resolve then lost its CAS race.
public enum DeskDriftTiming: Sendable, Equatable {
    /// Written in the first phase, guarded only by the item's own fingerprint.
    case immediate
    /// Written after the auto-resolve phase, and only if every listed handle
    /// actually closed. An empty list means "ordering only" — the item's
    /// fingerprint re-check (which folds in the open-child count) is what
    /// invalidates the premise.
    case afterResolves(requiring: [String])
}

/// A flagged contradiction. Carries the refs that prove it so the note is
/// checkable rather than an assertion.
public struct DeskDrift: Sendable, Equatable {
    public var timing: DeskDriftTiming = .immediate
    public var handle: String
    public var kind: DeskDriftKind
    public var refKeys: [String]
    public var detail: String
    public var observedAt: String
    /// The item's substance at evaluation time, stamped by the evaluator (see
    /// `DeskObservationEvaluator.materialFingerprint`). The applier refuses to
    /// write the flag if the item's substance moved between decision and write:
    /// a card whose GitHub ref was removed, or that just had `github` added to
    /// its refresh sources, is no longer the card this verdict is about, and
    /// annotating it would flag a contradiction that no longer exists. nil means
    /// "unstamped" and the applier writes unconditionally — only hand-built
    /// verdicts in tests take that path.
    public var materialFingerprint: String?

    public init(handle: String, kind: DeskDriftKind, refKeys: [String], detail: String, observedAt: String) {
        self.handle = handle
        self.kind = kind
        self.refKeys = refKeys
        self.detail = detail
        self.observedAt = observedAt
    }

    /// Stable dedupe identity: one flag per (item, kind, refs). Deliberately
    /// EXCLUDES the timestamp and the detail text — the same standing
    /// contradiction must not re-annotate the item on every pass.
    public var signature: String { "\(kind.rawValue):\(refKeys.sorted().joined(separator: ","))" }

    /// Marker-prefixed note text. The marker is what the applier greps to know
    /// this flag is already on the item, which is why dedupe needs no new state.
    public var noteText: String {
        let refs = refKeys.sorted().joined(separator: ", ")
        return "\(DeskObservationEvaluator.driftMarker)[\(signature)] \(kind.phrase). Refs: \(refs). \(detail)"
    }
}

/// An item reality says is finished, with the proof required to close it.
public struct DeskAutoResolve: Sendable, Equatable {
    public var handle: String
    /// CAS token — the item's `updatedAt` at evaluation time. The close is
    /// abandoned if the item moved underneath us.
    public var expectedUpdatedAt: String
    public var refKeys: [String]
    /// Receipt lines, one per ref, verbatim from the source.
    public var evidence: [String]
    public var observedAt: String
    /// Everything about the item this verdict actually depends on, EXCLUDING
    /// notes and `updatedAt`. `expectedUpdatedAt` alone cannot distinguish "the
    /// applier's own receipt note moved this item" from "User retitled it while
    /// we were mid-pass" — both just bump the stamp. The applier compares this
    /// instead, so its own annotations are transparent while any real edit to
    /// the item's substance aborts the close.
    public var materialFingerprint: String

    public init(
        handle: String,
        expectedUpdatedAt: String,
        refKeys: [String],
        evidence: [String],
        observedAt: String,
        materialFingerprint: String
    ) {
        self.handle = handle
        self.expectedUpdatedAt = expectedUpdatedAt
        self.refKeys = refKeys
        self.evidence = evidence
        self.observedAt = observedAt
        self.materialFingerprint = materialFingerprint
    }

    /// The receipt that gets appended to the item BEFORE the close op, so the
    /// evidence is on the record even if the close itself loses the CAS race.
    public var receiptNote: String {
        "\(DeskObservationEvaluator.receiptMarker) auto-resolved from observed reality at \(observedAt). "
            + evidence.joined(separator: " | ")
    }

    /// Outcome summary written into the close op.
    public var outcomeSummary: String {
        "Closed automatically: " + evidence.joined(separator: " | ")
    }
}

/// A contradiction that has RESOLVED ITSELF: the item still carries a drift flag
/// as its latest note, but this pass — with full knowledge of the item's refs —
/// found nothing wrong with it.
///
/// This exists because the drift flag is derived from the tail of the note trail
/// (nothing stored, nothing to get stuck), and a reopened ref produces silence,
/// not a new flag: the item is no longer terminal-in-reality, so no drift kind
/// applies. Without an explicit clear, that silence would leave the last drift
/// note at the tail forever and the desk would keep shouting about a
/// contradiction reality already withdrew. Appending the clear is what moves the
/// tail; it is also self-deduping, since after it lands the tail is not a drift.
public struct DeskDriftClear: Sendable, Equatable {
    public var handle: String
    /// The signature of the flag being withdrawn, quoted so the trail is readable.
    public var clearedSignature: String
    public var observedAt: String
    /// Same guard as `DeskDrift.materialFingerprint`.
    public var materialFingerprint: String?

    public init(handle: String, clearedSignature: String, observedAt: String, materialFingerprint: String? = nil) {
        self.handle = handle
        self.clearedSignature = clearedSignature
        self.observedAt = observedAt
        self.materialFingerprint = materialFingerprint
    }

    public var noteText: String {
        "\(DeskObservationEvaluator.clearMarker)[\(clearedSignature)] reality no longer contradicts this item as of \(observedAt)."
    }
}

/// The whole verdict of one observation pass. Sorted, deterministic, pure.
public struct DeskObservationVerdict: Sendable, Equatable {
    public var autoResolves: [DeskAutoResolve]
    public var drifts: [DeskDrift]
    public var driftClears: [DeskDriftClear] = []

    public init(autoResolves: [DeskAutoResolve] = [], drifts: [DeskDrift] = [], driftClears: [DeskDriftClear] = []) {
        self.autoResolves = autoResolves
        self.drifts = drifts
        self.driftClears = driftClears
    }

    public var isEmpty: Bool { autoResolves.isEmpty && drifts.isEmpty && driftClears.isEmpty }
}

/// Pure reconciliation of desk state against observed reality.
///
/// Deliberately has NO knowledge of stores, locks, or clocks beyond the `now`
/// it is handed: every decision is a function of (state, observations, now), so
/// the same inputs always produce the same verdict and the tests are a
/// synthetic reality rather than a mocked network.
public enum DeskObservationEvaluator {
    /// Prefix on receipt notes written by auto-resolution.
    public static let receiptMarker = "✅ receipt"
    /// Prefix on drift notes. Also the dedupe grep target.
    public static let driftMarker = "⚑ drift"
    /// Prefix on the note that WITHDRAWS a drift flag. See `DeskDriftClear`.
    public static let clearMarker = "✅ drift cleared"

    /// The drift kind a note announces, or nil if the note is not a drift note
    /// this module authored.
    ///
    /// Strict on purpose. `hasPrefix(driftMarker)` alone would accept human prose
    /// that merely OPENS with the marker — `"⚑ drift: discussing [foo:bar]"` —
    /// and a loose bracket scan would then render `foo` as a drift kind. The
    /// contract here is the exact shape `noteText` writes: marker, immediately
    /// `[`, a kind that is a real `DeskDriftKind`, `:`, refs, `]`.
    public static func driftKind(inNote text: String) -> DeskDriftKind? {
        let opening = "\(driftMarker)["
        guard text.hasPrefix(opening) else { return nil }
        let body = text.dropFirst(opening.count)
        guard let close = body.firstIndex(of: "]") else { return nil }
        guard let colon = body[..<close].firstIndex(of: ":") else { return nil }
        return DeskDriftKind(rawValue: String(body[..<colon]))
    }

    /// An item participates in auto-resolution only if it was declared to
    /// follow an external source. Two accepted declarations:
    ///   • `cadence.refreshSources` names the observing lane (explicit, and
    ///     what the GitHub tracker already stamps on rows it creates), or
    ///   • the item's kind is `.gh` (the tracker's own row shape).
    /// Anything else is somebody's hand-written card that happens to link a PR.
    /// Those still get DRIFT flags — the desk tells you reality moved — but the
    /// desk never closes a card nobody asked it to follow.
    /// `sources` MUST be the sources of the observations for THIS item's own
    /// refs. An earlier cut passed the pass-global source set, which let an
    /// item opted into lane A be closed by lane B merely because some unrelated
    /// item in the same pass was observed by A.
    public static func isExternallyTracked(_ item: DeskItem, sources: Set<String>) -> Bool {
        if item.kind == .gh { return true }
        for source in item.cadence.refreshSources where sources.contains(source.lowercased()) {
            return true
        }
        return false
    }

    /// The item's substance, order-stable and note-free. See
    /// `DeskAutoResolve.materialFingerprint` for why notes are excluded.
    ///
    /// The membership rule is not "important fields" — it is EVERY FIELD ANY
    /// VERDICT READS. `kind` and `cadence.refreshSources` are here because
    /// `isExternallyTracked` reads them: without them, adding `github` to a
    /// card's refresh sources between decision and write left the guard
    /// satisfied, and the applier would flag `untracked_but_shipped` on a card
    /// that had just opted IN (and, in the mirror case, close a card that had
    /// just opted OUT). Anything a new verdict starts reading belongs here too.
    public static func materialFingerprint(_ item: DeskItem) -> String {
        let refs = trackedKeys(item).joined(separator: ",")
        return [
            item.status.rawValue,
            item.title,
            item.summary ?? "",
            item.parent ?? "",
            item.blockedReason ?? "",
            item.waitingOn ?? "",
            item.deferUntil ?? "",
            item.blockedOn.sorted().joined(separator: ","),
            item.kind.rawValue,
            item.cadence.refreshSources.map { $0.lowercased() }.sorted().joined(separator: ","),
            refs,
        ].joined(separator: "\u{1F}")
    }

    /// The guard token the applier compares before writing.
    ///
    /// `materialFingerprint` covers what the item itself says; this adds the one
    /// piece of SURROUNDING state a verdict depends on — how many non-terminal
    /// children it has. Both the parent's "shipped but sub-items are still open"
    /// drift and the refusal to auto-close a parent read that count, so a child
    /// closing between decision and write invalidates the verdict just as surely
    /// as an edit to the parent. Composed rather than folded into
    /// `materialFingerprint` so the item-local notion stays available on its own.
    public static func verdictFingerprint(_ item: DeskItem, in state: DeskState) -> String {
        let openChildren = state.items.filter { !$0.status.isTerminal && $0.parent == item.handle }.count
        return "\(materialFingerprint(item))\u{1F}children:\(openChildren)"
    }

    /// Chronological max of ISO stamps. String `.max()` is wrong the moment two
    /// sources disagree on offset or fractional precision.
    public static func latestStamp(_ stamps: [String]) -> String? {
        stamps.compactMap { raw -> (Date, String)? in
            guard let parsed = DeskClock.parseISO(raw) else { return nil }
            return (parsed, raw)
        }
        .max { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }?.1
    }

    /// Resolvable external refs on an item, as canonical keys (deduped, sorted).
    public static func trackedKeys(_ item: DeskItem) -> [String] {
        var seen = Set<String>()
        for ref in item.refs {
            if let key = DeskObservedRef.key(for: ref) { seen.insert(key) }
        }
        return seen.sorted()
    }

    /// Reconcile. Duplicate refKeys resolve to the CHRONOLOGICALLY NEWEST
    /// observation, ties broken on the observation's own fields — never on
    /// array position. A caller merging several lanes must get the same verdict
    /// no matter what order it concatenated them in.
    /// `now` has NO default on purpose. A default of `Date()` would leave a
    /// wall-clock read inside the one function in this file whose entire value
    /// is being a pure function of its arguments — one caller forgetting the
    /// argument is all it takes to make two replays of the same inputs disagree.
    public static func evaluate(
        _ state: DeskState,
        observations: [DeskObservedRef],
        now: Date
    ) -> DeskObservationVerdict {
        guard !observations.isEmpty else { return DeskObservationVerdict() }

        var byKey: [String: DeskObservedRef] = [:]
        for observation in observations {
            guard let incumbent = byKey[observation.refKey] else {
                byKey[observation.refKey] = observation
                continue
            }
            if prefer(observation, over: incumbent) { byKey[observation.refKey] = observation }
        }

        // A parent must never be auto-closed out from under live children. The
        // store refuses it anyway; deciding it here keeps the verdict honest
        // instead of emitting a decision we know will be rejected.
        var openChildCount: [String: Int] = [:]
        for item in state.items where !item.status.isTerminal {
            guard let parent = item.parent else { continue }
            openChildCount[parent, default: 0] += 1
        }

        var autoResolves: [DeskAutoResolve] = []
        var drifts: [DeskDrift] = []
        /// Items whose EVERY tracked ref was observed in this pass — the only
        /// ones this pass knows enough about to withdraw a standing flag from.
        var fullyObserved: Set<String> = []
        var observedStamp: [String: String] = [:]

        for item in state.items.sorted(by: { $0.handle < $1.handle }) {
            let keys = trackedKeys(item)
            guard !keys.isEmpty else { continue }
            // Only reconcile against refs we actually observed this pass. An
            // item whose refs were not all observed is NOT a candidate for
            // closure — partial knowledge closes nothing.
            let observed = keys.compactMap { byKey[$0] }
            guard observed.count == keys.count else {
                // Partial observation can still prove a REOPEN, which needs
                // only one contradicting ref, so fall through to that check.
                if let drift = reopenDrift(item: item, observed: keys.compactMap { byKey[$0] }) {
                    drifts.append(drift)
                }
                continue
            }
            // `now`, not a fresh clock read: this function must be a pure
            // function of (state, observations, now) or two replays of the same
            // inputs can disagree.
            let observedAt = latestStamp(observed.map(\.observedAt)) ?? DeskClock.nowISO(now)
            fullyObserved.insert(item.handle)
            observedStamp[item.handle] = observedAt
            // Opt-in is decided against THIS item's own observations only.
            let itemSources = Set(observed.map { $0.source.lowercased() }.filter { !$0.isEmpty })

            if item.status.isTerminal {
                if let drift = reopenDrift(item: item, observed: observed) { drifts.append(drift) }
                continue
            }

            guard observed.allSatisfy({ $0.terminal }) else {
                // Reality says there is still open work. Nothing to resolve and
                // nothing contradictory — the board and reality agree.
                continue
            }

            let evidence = observed
                .sorted { $0.refKey < $1.refKey }
                .map { "\($0.refKey): \($0.status) — \($0.evidence)" }
            let receiptless = observed.contains { $0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            // ── Everything below here is "reality says this is finished". ──

            if receiptless {
                // The hard line: no receipt, no mutation. Loud instead.
                drifts.append(DeskDrift(
                    handle: item.handle,
                    kind: .shippedWithoutReceipt,
                    refKeys: keys,
                    detail: "Observed terminal by \(sourceList(observed)) with no evidence attached; the item was left open on purpose.",
                    observedAt: observedAt
                ))
                continue
            }

            if !isExternallyTracked(item, sources: itemSources) {
                drifts.append(DeskDrift(
                    handle: item.handle,
                    kind: .untrackedButShipped,
                    refKeys: keys,
                    detail: "Add \(sourceList(observed)) to this item's refresh sources if it should close itself. Evidence: \(evidence.joined(separator: " | "))",
                    observedAt: observedAt
                ))
                continue
            }

            if (openChildCount[item.handle] ?? 0) > 0 {
                var drift = DeskDrift(
                    handle: item.handle,
                    kind: .blockedButShipped,
                    refKeys: keys,
                    detail: "Its external work shipped, but \(openChildCount[item.handle] ?? 0) sub-item(s) are still open, so the parent stays open.",
                    observedAt: observedAt
                )
                // A child of this parent may itself be auto-resolving in this
                // very pass. Deferring the write means the parent's fingerprint
                // re-check — which folds in the open-child count — sees the
                // child's close and refuses a flag whose premise just expired.
                drift.timing = .afterResolves(requiring: [])
                drifts.append(drift)
                continue
            }

            // A parked item that already landed is a contradiction worth
            // surfacing even though we are about to resolve it — the flag is
            // what tells User his park was wrong, and the close is what tells
            // him it no longer matters. Both, in that order.
            if DeskSequencing.isDeferred(item, now: now) {
                drifts.append(DeskDrift(
                    handle: item.handle,
                    kind: .parkedButShipped,
                    refKeys: keys,
                    detail: "Parked until \(item.deferUntil ?? "?") but already shipped; resolving it now.",
                    observedAt: observedAt
                ))
            }

            // Prose blockedness that reality has overtaken. Flagged alongside
            // the resolve so the stale reason is visible in the receipt trail
            // rather than just vanishing with the close.
            if item.status == .blocked || item.blockedReason?.isEmpty == false || item.waitingOn?.isEmpty == false {
                drifts.append(DeskDrift(
                    handle: item.handle,
                    kind: .blockedButShipped,
                    refKeys: keys,
                    detail: "Recorded blocker: \(item.blockedReason ?? item.waitingOn ?? "blocked"). Reality: \(evidence.joined(separator: " | "))",
                    observedAt: observedAt
                ))
            }

            autoResolves.append(DeskAutoResolve(
                handle: item.handle,
                expectedUpdatedAt: item.updatedAt,
                refKeys: keys,
                evidence: evidence,
                observedAt: observedAt,
                materialFingerprint: verdictFingerprint(item, in: state)
            ))
        }

        // Items blocked on an item that reality already resolved: the edge
        // itself is derived and self-clears (Wave 1), but a status field still
        // reading `blocked` after its blocker is auto-resolved is exactly the
        // stale state this wave refuses to let sit.
        let resolving = Set(autoResolves.map(\.handle))
        // Deterministic stamp: derived from the resolving blockers, never from
        // a wall clock read inside a pure function.
        let resolveStamp = latestStamp(autoResolves.map(\.observedAt))
        if !resolving.isEmpty {
            for item in state.items.sorted(by: { $0.handle < $1.handle })
            where !item.status.isTerminal && item.status == .blocked {
                let freed = item.blockedOn.filter { resolving.contains($0) }.sorted()
                guard !freed.isEmpty else { continue }
                var drift = DeskDrift(
                    handle: item.handle,
                    kind: .blockedButShipped,
                    refKeys: freed,
                    detail: "Blocker(s) \(freed.joined(separator: ", ")) auto-resolved from observed reality; this item is no longer blocked by them.",
                    observedAt: resolveStamp ?? DeskClock.nowISO(now)
                )
                // The note ASSERTS that those blockers closed. It may only be
                // written once they actually have — a resolve that loses its CAS
                // race must not leave behind a note claiming it won.
                drift.timing = .afterResolves(requiring: freed)
                drifts.append(drift)
            }
        }

        // A flag this pass did NOT re-raise, on an item this pass fully observed,
        // is a contradiction reality withdrew — withdraw the flag too. Scoped to
        // `fullyObserved` for the same reason nothing else here is global:
        // partial knowledge clears nothing, or one lane's incomplete fetch would
        // wipe a flag another lane is still standing behind. A STANDING
        // contradiction is re-raised every pass (dedupe lives in the applier, not
        // here), so it lands in `flagged` and is never cleared.
        let flagged = Set(drifts.map(\.handle))
        var clears: [DeskDriftClear] = []
        for handle in fullyObserved.subtracting(flagged).sorted() {
            guard let item = state.items.first(where: { $0.handle == handle }),
                  let last = item.notes.last,
                  let kind = driftKind(inNote: last.text) else { continue }
            clears.append(DeskDriftClear(
                handle: handle,
                clearedSignature: signature(inNote: last.text) ?? kind.rawValue,
                observedAt: observedStamp[handle] ?? last.ts
            ))
        }

        // Substance at decision time, so the applier can refuse to act on an
        // item that moved underneath the verdict. Stamped in ONE place rather
        // than at each of the seven construction sites — a missed site would be
        // a silently unguarded write.
        var fingerprints: [String: String] = [:]
        for item in state.items { fingerprints[item.handle] = verdictFingerprint(item, in: state) }

        return DeskObservationVerdict(
            autoResolves: autoResolves.sorted { $0.handle < $1.handle },
            drifts: drifts
                .map { drift in
                    var stamped = drift
                    stamped.materialFingerprint = fingerprints[drift.handle]
                    return stamped
                }
                // Signature is the tiebreak, not decoration: `blockedButShipped`
                // has THREE producers (prose-blocked, parent-with-open-children,
                // dependent-blocker), and a prose-blocked item that is also
                // blockedOn a resolving item emits two of them for one handle.
                // (handle, kind) alone is not a total order there, and Swift's
                // sort is not stable, so the verdict would vary run to run.
                .sorted { ($0.handle, $0.kind.rawValue, $0.signature) < ($1.handle, $1.kind.rawValue, $1.signature) },
            driftClears: clears.map { clear in
                var stamped = clear
                stamped.materialFingerprint = fingerprints[clear.handle]
                return stamped
            }
        )
    }

    /// The full `kind:refs` signature a drift note announces. Same strictness as
    /// `driftKind(inNote:)`, which it validates through.
    public static func signature(inNote text: String) -> String? {
        guard driftKind(inNote: text) != nil else { return nil }
        let body = text.dropFirst("\(driftMarker)[".count)
        guard let close = body.firstIndex(of: "]") else { return nil }
        return String(body[..<close])
    }

    /// Reality reopened something the desk considers finished. Requires the
    /// observation to be NEWER than the close, otherwise a stale snapshot of a
    /// pre-close state would reopen every item it touched.
    private static func reopenDrift(item: DeskItem, observed: [DeskObservedRef]) -> DeskDrift? {
        guard item.status.isTerminal else { return nil }
        let reopened = observed.filter { !$0.terminal }
        guard !reopened.isEmpty else { return nil }
        guard let closedAtRaw = item.closedAt, let closedAt = DeskClock.parseISO(closedAtRaw) else { return nil }
        let fresh = reopened.filter { observation in
            guard let stamp = DeskClock.parseISO(observation.observedAt) else { return false }
            return stamp > closedAt
        }
        guard !fresh.isEmpty else { return nil }
        let keys = fresh.map(\.refKey).sorted()
        return DeskDrift(
            handle: item.handle,
            kind: .reopenedAfterClose,
            refKeys: keys,
            detail: "Closed \(closedAtRaw); "
                + fresh.sorted { $0.refKey < $1.refKey }
                    .map { "\($0.refKey) is \($0.status) as of \($0.observedAt)" }
                    .joined(separator: ", "),
            observedAt: latestStamp(fresh.map(\.observedAt)) ?? closedAtRaw
        )
    }

    /// Total order over two observations of the SAME ref: newest wins; on an
    /// identical (or unparseable) stamp, fall back to the observation's own
    /// fields so the choice is a function of content, not of arrival order.
    private static func prefer(_ candidate: DeskObservedRef, over incumbent: DeskObservedRef) -> Bool {
        let lhs = DeskClock.parseISO(candidate.observedAt)
        let rhs = DeskClock.parseISO(incumbent.observedAt)
        switch (lhs, rhs) {
        case let (.some(l), .some(r)) where l != r:
            return l > r
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        let candidateKey = "\(candidate.status)\u{1F}\(candidate.fingerprint)\u{1F}\(candidate.source)"
        let incumbentKey = "\(incumbent.status)\u{1F}\(incumbent.fingerprint)\u{1F}\(incumbent.source)"
        return candidateKey < incumbentKey
    }

    private static func sourceList(_ observed: [DeskObservedRef]) -> String {
        let names = Set(observed.map(\.source).filter { !$0.isEmpty }).sorted()
        return names.isEmpty ? "an unnamed source" : names.joined(separator: "+")
    }
}
