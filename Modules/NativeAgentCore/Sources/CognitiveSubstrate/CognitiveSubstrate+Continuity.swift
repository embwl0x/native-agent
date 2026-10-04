// CognitiveSubstrate+Continuity.swift
// Phase 5 B (2026-10-03) — two continuity cues that compete for the one felt
// slot like every other cue. Neither is ever always-on.
//
// B1 DREAM RESIDUE. Last night's diary themes (her own phrases, embedded on
// device by the wiring) surface only when THIS message is about one of them,
// and only as a dream association. Agent: a dream can suggest an association;
// it can never establish something User said or something she did. Nothing here
// writes memory.
//
// B2 SINCE. The gap is measured on User's own turns across his doors (Mac,
// phone, Telegram); a door switch is not a gap, and her wakes and peer threads
// never open or close one. The line is built from what actually happened in
// between, or it is not built at all.

import Foundation
import NativeAgentCore

/// One residue phrase from last night's diary, scored against this message.
public struct CognitiveDreamTheme: Sendable, Equatable {
    /// `<diary date>#<n>`: stable per phrase per diary. The ledger key, and
    /// `dream:<id>` is the source `mind.why` shows and `mind.reject` takes.
    public let id: String
    /// The diary's own words.
    public let text: String
    /// Similarity to this message, as the wiring scored it.
    public let score: Double

    public init(id: String, text: String, score: Double) {
        self.id = id
        self.text = text
        self.score = score
    }
}

extension CognitiveSubstrate {
    /// One dream line at most every three hours, whichever phrase.
    static let dreamThemeCooldown: TimeInterval = 3 * 3_600
    /// A phrase surfaces once in its diary's life (the wiring retires a diary
    /// after 60 h; this outlives it).
    static let dreamThemeRepeatWindow: TimeInterval = 72 * 3_600
    static let dreamThemeLedgerCapacity = 16
    /// "ok", "lol", "yes do it" have nothing for a dream to rhyme with.
    static let dreamThemeMinimumTerms = 2

    // MARK: - B1 dream residue

    static func dreamThemeCadenceAllows(_ ledger: [String: Date], at now: Date) -> Bool {
        guard let last = ledger.values.max() else { return true }
        return now.timeIntervalSince(last) >= dreamThemeCooldown
    }

    /// The one residue phrase this message connects to, if any. One local
    /// lookup at most, and none while the cooldown is closed. Re-checked
    /// against the LIVE ledger after the await, as Reminded-of is.
    func dreamThemeCue(
        for request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) async -> CognitiveDreamTheme? {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live,
              Self.dreamThemeCadenceAllows(
                read.capsulePresentationState.dreamThemeSurfaced, at: read.fixedAt) else { return nil }
        let terms = Self.appraisalConcernTerms(in: request.userMessage)
        guard terms.count >= Self.dreamThemeMinimumTerms else { return nil }
        let spent = Set(read.capsulePresentationState.dreamThemeSurfaced
            .filter { read.fixedAt.timeIntervalSince($0.value) < Self.dreamThemeRepeatWindow }.keys)
        let residues = await dependencies.dreamThemes(request.userMessage, spent)
        let live = capsulePresentationStateSnapshot().dreamThemeSurfaced
        guard !residues.isEmpty, Self.dreamThemeCadenceAllows(live, at: read.fixedAt) else { return nil }
        return residues
            .filter { !isSuppressed("dream:" + $0.id, messageTerms: terms) }
            .filter { residue in
                live[residue.id].map { read.fixedAt.timeIntervalSince($0) >= Self.dreamThemeRepeatWindow } ?? true
            }
            .max { $0.score != $1.score ? $0.score < $1.score : $0.id > $1.id }
    }

    /// Marked as a dream, and as an association rather than an event, in the
    /// line itself: the cue must never read as something that happened.
    func dreamCapsuleLine(for residue: CognitiveDreamTheme) -> String? {
        let text = capsuleLineText(residue.text, maxCharacters: 120)
        guard text.count >= 8 else { return nil }
        let line = "- Dream: last night's dream kept circling \"\(text)\""
            + " (an association from a dream, not something that happened)"
        return line
    }

    static func boundDreamThemeLedger(_ ledger: inout [String: Date]) {
        guard ledger.count > dreamThemeLedgerCapacity else { return }
        for key in ledger.sorted(by: { $0.value < $1.value }).prefix(ledger.count - dreamThemeLedgerCapacity).map(\.key) {
            ledger.removeValue(forKey: key)
        }
    }

    // MARK: - B2 since we last talked

    /// When the gap this turn closes opened, if it is a real one that has not
    /// spoken yet. Measured from User's previous verified turn (`UserTurnStamp`,
    /// the one source E's initiative reads too), so a door switch inside
    /// minutes is not a gap and her wakes and peers never move it. A gap whose
    /// line lost the slot stays owed.
    static func sinceGapOpened(
        _ state: CognitiveCapsulePresentationState,
        previousUserTurn: Date?,
        dynamics dyn: PersonalityDynamicsConfiguration,
        at now: Date
    ) -> Date? {
        if let owed = state.owedSinceGap { return owed }
        let gap = dyn.sessionBridgeGapHours * 3_600
        guard gap > 0, let last = previousUserTurn,
              now.timeIntervalSince(last) >= gap else { return nil }
        // Once per gap: `lastSessionBridgeAt` holds the opening of the gap a
        // bridge last spoke for, so only that same gap is closed.
        if state.lastSessionBridgeAt == last { return nil }
        return last
    }

    /// What happened while User was away, read only on the first turn back
    /// after a real gap; nil (no lookup at all) on every other turn.
    func sinceGapItems(
        for request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) async -> [String]? {
        guard read.configuration.enabled,
              read.configuration.affectEnabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live,
              request.fromUser,
              let opened = Self.sinceGapOpened(
                read.capsulePresentationState, previousUserTurn: request.previousUserTurnAt,
                dynamics: read.personalityDynamics, at: read.fixedAt) else { return nil }
        return await dependencies.sinceGap(opened, read.fixedAt, request.surface)
    }

    static func sinceGapPhrase(_ elapsed: TimeInterval) -> String {
        let hours = Int((elapsed / 3_600).rounded())
        guard hours >= 36 else { return "\(hours) hours" }
        let days = Int((elapsed / 86_400).rounded())
        return days == 1 ? "a day" : "\(days) days"
    }
}
