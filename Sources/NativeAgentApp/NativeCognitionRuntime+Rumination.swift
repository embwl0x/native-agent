// NativeCognitionRuntime+Rumination.swift
// PERSONALITY DEPTH · item 6, second half (2026-09-02)
//
// Live on the first build, Agent pulled `inner_state` and reported the `-
// Thread:` line empty while a real open thing — a tool audit she had opened on
// the Desk and not finished — should have been itching. She was right, and the
// reason was structural: rumination candidates came only from thought seeds,
// and a seed is something the microcycle or reflection minted. A commitment she
// opened herself lives in the Desk, and the Desk had no way into the lane.
//
// THIS IS THE READER, and it is deliberately thin. The substrate owns the
// weight law, the slot budget, the label bound and the healing; this file owns
// exactly one thing — which Desk rows count, and getting them across the seam
// payload-free.
//
// ADMISSION (canonical Desk facts, never re-litigated from a title string):
//   • `origin == .agent` — she opened it. An owner-filed item is User's, and her
//     nagging about his list is not the feature.
//   • `!status.isTerminal` — open/blocked/watch/flag/now/next/todo. `done` and
//     `canceled` are the heal, not the nag.
//   • not deferred — an item parked on purpose is not an open loop
//     (`deferUntil` exists precisely because half her "stale" items are parked).
//
// TURNS NEVER TOUCH THE DESK. `+Pursuit.swift` states that invariant in its own
// words ("a user turn can never initiate Desk I/O") and this obeys it: the
// staleness question is asked of the substrate (a clock, no disk), the window is
// claimed before the read, and the read itself runs detached off the turn path.
// A five-minute-stale nag is not a defect; a turn that blocks on a file is.

import Foundation
import CognitiveSubstrate
import MemoryV2
import NativeAgentCore
import PersistenceCore

extension NativeCognitionRuntime {

    /// At most this many open commitments cross per read. The substrate caps
    /// the set it keeps and the slots it will spend; this keeps the crossing
    /// itself bounded.
    private static let maximumDeskRuminations = 8

    /// MOMENTS AS THE SECOND SOURCE (2026-09-02). The Desk holds what she said
    /// she would move; the moments lane holds what actually happened between
    /// them, and a hard word is an open loop in exactly the way an unfinished
    /// item is. Same weight law, same slot budget, same payload-free crossing —
    /// the substrate is not told which owner a row came from, only that it is
    /// external, so neither source outranks the other.
    ///
    /// A moment leaves this set when it heals (a warm moment later in the same
    /// conversation) or when it ages past three days, and LEAVING the set is
    /// what mints the relief — the same door the Desk's close already uses.
    private static let maximumMomentRuminations = 4

    /// Ask the clock, claim the window, read off the turn path. Cheap enough to
    /// call from the ordinary body-sample cadence.
    func refreshDeskRuminationsIfStale(at now: Date) async {
        guard !isFlushedForTermination else { return }
        guard await substrate.externalRuminationsAreStale(at: now) else { return }
        // Claimed BEFORE the load so a burst of turns starts one read, not one
        // each. A failed read simply waits out the window.
        await substrate.noteExternalRuminationRefreshStarted(at: now)
        let loader = pursuitStateLoader
        Task.detached(priority: .utility) { [weak self] in
            guard let state = try? await loader() else { return }
            await self?.applyDeskRuminations(from: state)
        }
    }

    /// Map canonical Desk rows to the payload-free shape the lane consumes, and
    /// push. The push is also the heal: anything that has left this set has
    /// closed, and the substrate stages one relief for whatever was itching.
    func applyDeskRuminations(from state: DeskState) async {
        guard !isFlushedForTermination else { return }
        let now = self.now()
        let items: [CognitiveSubstrate.CognitiveExternalRumination] = state.items
            .filter { item in
                item.origin == .agent
                    && !item.status.isTerminal
                    && !Self.deskItemIsDeferred(item, at: now)
            }
            .compactMap { item in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                // `updatedAt` is when the owner last touched it; the weight ages
                // from there, so an item worked on this morning is not a nag.
                // An unparsable stamp falls back to `openedAt`, then to now —
                // never to `.distantPast`, which would mint a full-weight nag
                // out of a formatting bug.
                let touched = Self.deskDate(item.updatedAt)
                    ?? Self.deskDate(item.openedAt)
                    ?? now
                return CognitiveSubstrate.CognitiveExternalRumination(
                    // The handle is stable and opaque; it is never rendered.
                    id: item.handle,
                    label: title,
                    lastTouchedAt: touched
                )
            }
            // Oldest touch first: heaviest first, so the crossing cap takes the
            // ones that would have won the slots anyway.
            .sorted { $0.lastTouchedAt < $1.lastTouchedAt }
            .prefix(Self.maximumDeskRuminations)
            .map { $0 }

        await substrate.setExternalRuminations(items + momentRuminations(at: now), at: now)
        // The heal rides the same drain the seed lane uses.
        await drainRuminationReleasesIntoSubstrate()
    }

    /// The moments half. `MemoryMoments.ruminationCandidates` owns the whole
    /// rule (admission, healing, window) and is pure; this only reads her own
    /// store and maps into the payload-free shape. A read failure yields an
    /// empty half, never a fabricated one — and never disturbs the Desk half.
    func momentRuminations(at now: Date) async -> [CognitiveSubstrate.CognitiveExternalRumination] {
        guard let moments = try? await SwiftNativeMemoryV2.shared.listMemory(
            kind: MemoryMoments.kind
        ) else { return [] }
        return MemoryMoments.ruminationCandidates(
            from: moments,
            now: now,
            limit: Self.maximumMomentRuminations
        ).map { candidate in
            CognitiveSubstrate.CognitiveExternalRumination(
                id: candidate.id,
                label: candidate.label,
                lastTouchedAt: candidate.occurredAt
            )
        }
    }

    /// An item parked until a future day is not an open loop.
    private static func deskItemIsDeferred(_ item: DeskItem, at now: Date) -> Bool {
        guard let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        guard let until = deskDate(raw) else { return false }
        return until > now
    }

    /// Desk stamps are ISO-8601, with or without fractional seconds, and
    /// `deferUntil` may be a bare `yyyy-MM-dd` day.
    static func deskDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }
}
