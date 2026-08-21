// CognitiveSubstrate+AttentionSignals.swift
// Mind-into-circulation (2026-07-10, fence A). See docs/build_plans/mind-into-circulation.md
//
// A bounded, PURE read of what she is currently holding, shaped for Fluid
// Context's dormant NeedSignal inputs. No mutation, no persistence, no LLM —
// this is a projection of live state the turn engine folds into context
// selection so her selection follows her mind, not just the message. When
// there is genuinely nothing to add the result is `nil`, which the default
// protocol path treats as inert (turn preparation stays byte-identical).

import Foundation
import PersistenceCore

extension CognitiveSubstrate {
    public func attentionSignals(at date: Date) async -> CognitiveAttentionSignals? {
        makeAttentionSignals(at: date)
    }

    /// Actor-isolated synchronous compiler used both by the compatibility read
    /// above and by owner-published resident snapshots after mutations.
    func makeAttentionSignals(
        at date: Date,
        honorCancellation: Bool = true
    ) -> CognitiveAttentionSignals? {
        guard !honorCancellation || !Task.isCancelled else { return nil }
        // Gate exactly the way the capsule path does: disabled cognition adds
        // nothing; workspace off yields no items below.
        guard configuration.enabled, configuration.workspaceEnabled else { return nil }

        // PURE hot-set read (gpt-5.5 HIGH, 2026-07-10): `workspaceSnapshot()`
        // routes through the field's MUTATING snapshot (decay writes, anchor
        // advances, capacity eviction) — reading her attention must never
        // change her mind. This peek path computes the SAME decayed
        // activations on copies (`peekDecayedNodes`), reuses the same
        // eligibility + scoring, and takes the same top-N — but leaves the
        // field untouched. Deliberately omitted vs the capsule workspace:
        // association-edge reasons (mutating read; attention doesn't need
        // reasons) and the per-session user-turn/system caps (machine subjects
        // never become terms anyway, so the caps don't change this output).
        let mood = derivedMood(at: date)
        let currentAffect = projectedAffect(at: date)
        let hotItems = field.peekDecayedNodes(at: date)
            .map { node in
                (node: node, turnKind: field.cachedTurnKind(for: node))
            }
            .filter {
                workspaceEligible(
                    $0.node,
                    currentSessionId: nil,
                    at: date,
                    turnKind: $0.turnKind
                )
            }
            .map { candidate in
                (
                    node: candidate.node,
                    score: workspaceScore(
                        for: candidate.node,
                        mood: mood,
                        affect: currentAffect,
                        turnKind: candidate.turnKind
                    )
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(max(1, configuration.maximumWorkspaceItems))

        // 1. TERMS — hot subjects, cleaned to human lexical tokens. Weight =
        //    the clamped selection score.
        var terms: [String: Double] = [:]
        for item in hotItems {
            guard let term = Self.lexicalTerm(from: item.node.subjectReference) else { continue }
            terms[term] = max(terms[term] ?? 0, (item.score).clamped01())
        }
        // 1b. SUMMARY keywords (live-battery finding, 2026-07-10): in
        //    production EVERY node subject is machine-keyed (chat.user_turn /
        //    tool — verified against her real store: 256/256 nodes), so
        //    subject-derived terms alone never fire. What she's actually
        //    thinking about lives in the node SUMMARIES — human prose. Pull
        //    salient content words from the hottest few summaries, weighted by
        //    the node's score and discounted so a subject-level topic (when one
        //    exists) still outranks summary shrapnel.
        for item in hotItems.prefix(6) {
            // 2026-07-21 audit: .system-turn nodes (toolObservation /
            // feltResolution) are workspace-eligible but their summaries are
            // machine status text ("Exact tool receipt says failed."), not
            // what she's thinking about — tokenizing them re-opened the
            // machine-handle leak lexicalTerm guards on the subject path.
            // Mirror capsuleEligibleWorkspaceNode's live-only gate: system
            // nodes still count toward the hot set, they just never mint
            // terms.
            guard item.node.turnKind == .live else { continue }
            let weight = (item.score).clamped01() * 0.8
            for word in Self.summaryKeywords(from: item.node.summary) {
                terms[word] = max(terms[word] ?? 0, weight)
            }
        }

        // 2. UNRESOLVED QUESTION — the U1 pendingCompletion slot, if one is open:
        //    her latest completed turn still waiting to find out how it landed.
        let unresolvedQuestion = unresolvedQuestionFromPendingCompletion(at: date)

        // 3. MEMORY ACTIVATION — hot nodes that reference MemoryV2 records
        //    carry those RECORD ids; map each to the node's clamped activation.
        //    Record ids (never atom ids) cross the seam; the app layer owns the
        //    projection's record→atom derivation (Decision, 2026-07-10).
        var memoryActivation: [String: Double] = [:]
        var workingMemoryRecordIDs: Set<String> = []
        for item in hotItems {
            let recordIDs = Self.memoryRecordIDs(from: item.node)
            guard !recordIDs.isEmpty else { continue }
            let activation = (item.node.activation).clamped01()
            for recordID in recordIDs {
                memoryActivation[recordID] = max(memoryActivation[recordID] ?? 0, activation)
                workingMemoryRecordIDs.insert(recordID)
            }
        }

        let signals = CognitiveAttentionSignals(
            terms: terms,
            unresolvedQuestion: unresolvedQuestion,
            memoryActivation: memoryActivation,
            workingMemoryRecordIDs: workingMemoryRecordIDs
        )
        // Empty → nil, so the default inert path stays byte-identical. Never
        // return an empty struct (that would still be a distinct packet input).
        return signals.isEmpty ? nil : signals
    }

    func publishAttentionProjection(at date: Date) {
        dependencies.attentionProjectionSink(
            makeAttentionSignals(at: date, honorCancellation: false),
            date
        )
    }

    // MARK: - Unresolved question

    /// Phrase the open U1 completion as a short, human "what's unresolved" line.
    /// Returns nil when no slot is open, the slot has aged past
    /// `pendingCompletionMaxAge` (a stale completion is no longer a live
    /// question), or the remembered node was evicted since it was recorded.
    private func unresolvedQuestionFromPendingCompletion(at now: Date) -> String? {
        guard let pending = pendingCompletion else { return nil }
        // The read is defensive about expiry: the reconsolidation sweep only
        // drops a stale slot on the NEXT ingest, so a read between turns could
        // otherwise surface a completion that has already gone quiet.
        let age = now.timeIntervalSince(pending.recordedAt)
        guard age >= 0, age <= Self.pendingCompletionMaxAge else { return nil }
        guard let node = field.node(forKey: pending.nodeKey) else { return nil }

        let summary = node.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        // The constructor bounds to 200; clip the summary first so the framing
        // prefix always survives the bound.
        let snippet = bounded(summary, maxCharacters: 150)
        return "Still waiting to see how this landed: \(snippet)"
    }

    // MARK: - Subject → lexical term cleaning

    /// Subject `type`s that are MACHINE ROUTING KEYS, not topics. Their id/label
    /// is an opaque handle (`<session>:<message>`, a tool name, a provider id, a
    /// uuid) the lexical ranker can't meaningfully match against persona/memory
    /// text — so they never become terms. Grounded in the real subject formats
    /// this codebase emits:
    ///   - ChatOrchestration message persistence: `chat.user_turn`,
    ///     `chat.assistant_turn`, `chat.session`, `chat.surface` (id =
    ///     `<sessionId>:<messageId>` or a surface/session handle), `tool`
    ///     (id/label = tool name).
    ///   - NativeCognitionRuntime event factory: `chat_turn` (id =
    ///     `<session>:<message>`, label = "<surface> <role>"), `provider`,
    ///     `approval`, `mission_step`, `memory_proposal`, `promotion_candidate`,
    ///     `inbox_item`, `chat_session`, `remote_action`, `ios_action`.
    ///   - Memory-derived nodes: `memory` / `memory_record` (id = record id, an
    ///     opaque digest) — excluded here because their record id is surfaced
    ///     through `memoryActivation`, not as a lexical term.
    /// Any namespaced type (one containing ".") is treated as machine-keyed too:
    /// every namespaced subject in the codebase is a `chat.*` routing key.
    static let machineSubjectTypes: Set<String> = [
        "chat", "chat_turn", "chat_session",
        "chat.user_turn", "chat.assistant_turn", "chat.session", "chat.surface",
        "tool", "provider", "approval",
        "mission_step", "memory_proposal", "promotion_candidate",
        "inbox_item", "remote_action", "ios_action", "app", "image",
        "memory", "memory_record",
    ]

    /// Clean a subject into a human lexical term, or `nil` to EXCLUDE it.
    ///
    /// Rule (documented here because it is the seam's contract):
    ///   1. EXCLUDE machine-keyed subject types outright (see
    ///      `machineSubjectTypes`) — their id/label is a routing handle.
    ///   2. For the remaining subjects (topic, mention, person, Workshop execution, file,
    ///      and any future human-topic type), take the human-facing string —
    ///      the `label` when present, else the `id` — and keep it only if it
    ///      still reads as a topic after cleaning: no `:`-composite handle, not
    ///      a uuid/hex digest, and containing a real alphabetic run.
    /// This strips-or-excludes rather than passing opaque ids through, so terms
    /// stay words the ranker can match.
    static func lexicalTerm(from subject: CognitiveSubjectReference) -> String? {
        let type = subject.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type.isEmpty || type.contains(".") || machineSubjectTypes.contains(type) {
            return nil
        }
        let candidate = (subject.label ?? subject.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        // A ":"-composite is a machine handle (session:message, missionId:stepId).
        if candidate.contains(":") { return nil }

        let cleaned = candidate
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard cleaned.count >= 2 else { return nil }
        // Reject opaque ids: a uuid, or a token that is all hex/digits/dashes
        // with no vowel-bearing word. Require at least two consecutive letters.
        if isOpaqueIdentifier(cleaned) { return nil }
        guard cleaned.range(of: "[a-z]{2,}", options: .regularExpression) != nil else { return nil }
        return cleaned
    }

    /// Common words that carry no topical signal — kept SHORT and boring on
    /// purpose (the ranker's lexical overlap tolerates a little noise; a big
    /// clever list is maintenance debt). Bracketed routing prefixes like
    /// "[from: claude, via bridge]" are stripped before tokenizing.
    private static let summaryStopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "was", "were", "you",
        "your", "yours", "she", "her", "hers", "him", "his", "its", "our",
        "are", "but", "not", "all", "any", "can", "had", "has", "have",
        "how", "what", "when", "where", "which", "who", "why", "will",
        "would", "could", "should", "been", "being", "from", "into", "just",
        "like", "more", "most", "much", "about", "after", "before", "over",
        "under", "again", "then", "than", "them", "they", "there", "here",
        "did", "does", "doing", "don", "let", "lets", "got", "get", "gets",
        "one", "two", "out", "still", "same", "some", "such", "too", "very",
        "yeah", "yes", "okay", "hey", "well", "also", "really", "actually",
        "thing", "things", "today", "tonight", "day", "long", "via", "bridge",
        "assistant", "agent", "owner",
    ]

    /// Up to 4 salient content words from a node summary: bracketed routing
    /// prefixes stripped, lowercased word-boundary tokens, stopwords and
    /// opaque ids dropped, ≥4 letters, first-seen order (the summary leads
    /// with its subject more often than not).
    static func summaryKeywords(from summary: String, limit: Int = 4) -> [String] {
        var text = summary
        // Strip a leading "[...]" routing prefix ("[from: claude, via bridge]").
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...])
        }
        var seen: Set<String> = []
        var keywords: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(raw)
            guard word.count >= 4,
                  !summaryStopwords.contains(word),
                  !isOpaqueIdentifier(word),
                  !seen.contains(word) else { continue }
            seen.insert(word)
            keywords.append(word)
            if keywords.count >= limit { break }
        }
        return keywords
    }

    /// A conservative opaque-id test: canonical uuid shape, or an all
    /// hex/digit/dash blob (a digest or numeric id) with no letters at all.
    private static func isOpaqueIdentifier(_ value: String) -> Bool {
        if value.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: .regularExpression
        ) != nil {
            return true
        }
        // Long unbroken hex/digit run (>= 16) reads as a digest, never a topic.
        if value.range(of: "^[0-9a-f]{16,}$", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Node → memory record ids

    /// The MemoryV2 record ids a workspace node references, if any.
    ///
    /// Convention (this seam's contract):
    ///   - metadata key `memoryRecordIds`: a JSON array of record-id strings, OR
    ///   - metadata key `memoryRecordId`: a single record-id string, OR
    ///   - a subject of type `memory` / `memory_record` whose `id` IS the record
    ///     id (the natural shape a recalled-memory node would take; `memory_record`
    ///     already exists as a projection entity kind).
    /// LIVE since the chat path began stamping `memoryRecordIds` onto
    /// assistant-turn events (ChatOrchestrationClient+MessagePersistence,
    /// deduped, capped 32; the key is priority-protected in ContinuityField's
    /// metadata bounding). Verified against the live store + turn traces
    /// 2026-08-20: stamped nodes present and per-turn
    /// contextFlow.attentionWorkingAtoms > 0. An earlier note here claimed the
    /// lane was inert — that predated the producer and cost an investigation;
    /// re-verify from traces, not from this comment, before declaring it dead.
    static func memoryRecordIDs(from node: CognitiveNode) -> [String] {
        var ids: [String] = []

        if case .array(let values)? = node.metadata["memoryRecordIds"] {
            for value in values {
                if case .string(let id) = value {
                    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { ids.append(trimmed) }
                }
            }
        }
        if case .string(let id)? = node.metadata["memoryRecordId"] {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ids.append(trimmed) }
        }
        let subjectType = node.subjectReference.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if subjectType == "memory" || subjectType == "memory_record" {
            let recordID = node.subjectReference.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recordID.isEmpty { ids.append(recordID) }
        }

        // De-dup, preserve first-seen order.
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
