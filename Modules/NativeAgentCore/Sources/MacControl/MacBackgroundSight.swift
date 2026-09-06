// MacBackgroundSight.swift — LOOKING WITHOUT LOOKING AWAY (fable51 item 32a).
//
// `lookSnapshot(limits:scope:anchorPid:anchorWindow:)` has been able to walk a
// NAMED process's window since the act loop needed a post-act read anchored to
// the window the act happened in. Nothing ever called it with an anchor the
// CALLER chose, so "what does Mail say?" cost a focus steal: `go Mail`, look,
// `go` back — three acts, a visible window flip on User's screen, and a real
// chance of landing somewhere else if he was typing.
//
// A person glances at another window without moving. This is that: the anchor
// already existed, so the only thing missing was a way to NAME the app.
//
// WHAT THIS FILE IS: the pure name → running-app resolution. It is pure so the
// three answers that are not "here it is" — not running, ambiguous, our own
// process — are testable without a window server, and so each of them can be
// returned to the model AS WORDS rather than as an empty read.

import Foundation

public enum MacBackgroundSight {
    /// What naming an app resolved to. Every non-match is its own case because
    /// they lead to different next moves: launch it, disambiguate, or stop.
    public enum Resolution: Sendable, Equatable {
        case matched(MacAXAppInfo)
        /// No running app answers to that name. The candidates are what IS
        /// running, so the reply can say what she could have meant.
        case notRunning(candidates: [String])
        /// Two or more running apps answer equally well.
        case ambiguous(candidates: [String])
        /// NativeAgent itself. An AX walk of our own tree re-enters AppKit
        /// in-process and can deadlock (see `MacAnchoredRead.selfProcess`), so
        /// this is refused by NAME here, before an element is ever resolved.
        case selfProcess
    }

    /// How many running app names a refusal is allowed to list back.
    public static let maxCandidates = 12

    /// Resolve `name` against the running apps, WITHOUT activating anything.
    ///
    /// Four passes, narrowest first, and each pass is only consulted when the
    /// one before it found nothing — so an exact name always beats a substring
    /// and "Mail" can never be stolen by "Mailplane" while Mail is running:
    ///   1. exact name or exact bundle id (case-insensitive);
    ///   2. name prefix;
    ///   3. name substring;
    ///   4. bundle-id substring.
    ///
    /// A pass that finds exactly one match wins. A pass that finds several
    /// returns `.ambiguous` rather than picking one: guessing which window she
    /// meant is the failure mode this whole organ exists to avoid.
    public static func resolve(_ name: String, among apps: [MacAXAppInfo]) -> Resolution {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return .notRunning(candidates: candidateNames(apps))
        }
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // `.app` is how a person writes an app's name half the time, and it is
        // never part of the localized name AppKit reports.
        let bare = needle.hasSuffix(".app") ? String(needle.dropLast(4)) : needle

        let passes: [(MacAXAppInfo) -> Bool] = [
            { normalized($0.name) == bare || normalized($0.bundleIdentifier ?? "") == bare },
            { normalized($0.name).hasPrefix(bare) },
            { normalized($0.name).contains(bare) },
            { normalized($0.bundleIdentifier ?? "").contains(bare) },
        ]
        for pass in passes {
            let hits = apps.filter(pass)
            if hits.count == 1 {
                return hits[0].processIdentifier == getpid()
                    ? .selfProcess
                    : .matched(hits[0])
            }
            if hits.count > 1 {
                // Identical names for one app (a helper process sharing the
                // bundle id) are not a real ambiguity.
                let distinct = Set(hits.map(\.processIdentifier))
                if distinct.count == 1 {
                    return hits[0].processIdentifier == getpid()
                        ? .selfProcess
                        : .matched(hits[0])
                }
                return .ambiguous(candidates: candidateNames(hits))
            }
        }
        return .notRunning(candidates: candidateNames(apps))
    }

    static func candidateNames(_ apps: [MacAXAppInfo]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for app in apps where app.processIdentifier != getpid() {
            guard !seen.contains(app.name) else { continue }
            seen.insert(app.name)
            out.append(app.name)
            if out.count >= maxCandidates { break }
        }
        return out.sorted()
    }

    /// The refusal, in words. A model that gets "app_not_running" and nothing
    /// else re-tries the same spelling forever.
    public static func words(for resolution: Resolution, requested name: String) -> String? {
        switch resolution {
        case .matched:
            return nil
        case .selfProcess:
            return "\"\(name)\" is NativeAgent itself, and I can't read my own window that way."
        case .notRunning(let candidates):
            guard !candidates.isEmpty else {
                return "Nothing called \"\(name)\" is running, so there is no window of it to read."
            }
            return "Nothing called \"\(name)\" is running. What is running: "
                + candidates.joined(separator: ", ") + "."
        case .ambiguous(let candidates):
            return "\"\(name)\" matches more than one running app — "
                + candidates.joined(separator: ", ")
                + ". Say which one and I'll read that window."
        }
    }
}
