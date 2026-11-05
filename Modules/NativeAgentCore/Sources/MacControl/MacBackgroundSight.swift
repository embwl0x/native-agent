// Resolve without activation so missing, ambiguous and self-process targets can refuse without walking a guessed or unsafe tree.

import Foundation

// Blueprint: | `MacBackgroundSight.swift` | `MacBackgroundSight.resolve`: Exact identities precede partial names; preserve ambiguity and source failures |

public enum MacBackgroundSight {
    /// Keep nonmatches distinct so callers can choose between launching, disambiguating and refusing.
    public enum Resolution: Sendable, Equatable {
        case matched(MacAXAppInfo)
        /// Retain running candidates so a missing-target reply can offer real alternatives.
        case notRunning(candidates: [String])
        case ambiguous(candidates: [String])
        case indexUnavailable
        /// Refuse self-process names before AX resolution because in-process AppKit re-entry can deadlock.
        case selfProcess

        var failureCode: String? {
            switch self {
            case .matched: return nil
            case .selfProcess: return "self_inspection_refused"
            case .ambiguous: return "app_ambiguous"
            case .notRunning: return "app_not_running"
            case .indexUnavailable: return "app_index_unavailable"
            }
        }
    }

    public static let maxCandidates = 40

    /// Exact running identity precedes installed identity and partial running names so Mail cannot resolve to MailMate. Installed display names can differ from
    /// process names. Multiple matches remain ambiguous; never pick a window by guessing.
    public static func resolve(_ name: String, among apps: [MacAXAppInfo]) -> Resolution {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return .notRunning(candidates: candidateNames(apps))
        }
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // `.app` is how a person writes an app's name half the time, and it is never part of the localized name AppKit reports.
        let bare = needle.hasSuffix(".app") ? String(needle.dropLast(4)) : needle

        func squashed(_ text: String) -> String { normalized(text).filter { $0.isLetter || $0.isNumber } }
        let flat = squashed(bare)
        func resolution(_ hits: [MacAXAppInfo]) -> Resolution? {
            guard let first = hits.first else { return nil }
            if Set(hits.map(\.processIdentifier)).count > 1 {
                return .ambiguous(candidates: candidateNames(hits))
            }
            return first.processIdentifier == getpid() ? .selfProcess : .matched(first)
        }
        if let exact = resolution(apps.filter {
            normalized($0.name) == bare || normalized($0.bundleIdentifier ?? "") == bare
        }) { return exact }
        // The hot path never waits for Spotlight, and never guesses a partial name before the installed identities are available.
        guard let indexed = MacAppIndex.shared.readyApps() else { return .indexUnavailable }
        // Incomplete matching identity cannot authorize a partial-name guess at another running app. Exact running identities above need no census.
        if indexed.contains(where: {
            $0.installationUncertain && (
                normalized($0.bundleID ?? "") == needle || normalized($0.name) == bare
                || normalized($0.url.deletingPathExtension().lastPathComponent) == bare
                || squashed($0.name) == flat || squashed($0.url.deletingPathExtension().lastPathComponent) == flat)
        }) { return .indexUnavailable }
        let installed = MacAppIndex.installed(indexed)
        let exact = installed.filter {
            normalized($0.bundleID ?? "") == needle || normalized($0.name) == bare
                || normalized($0.url.deletingPathExtension().lastPathComponent) == bare
        }
        let known = exact.isEmpty ? installed.filter {
            squashed($0.name) == flat || squashed($0.url.deletingPathExtension().lastPathComponent) == flat
        } : exact
        if !known.isEmpty {
            let bundles = Set(known.compactMap { $0.bundleID?.lowercased() })
            return resolution(apps.filter { bundles.contains(normalized($0.bundleIdentifier ?? "")) })
                ?? .notRunning(candidates: candidateNames(apps))
        }
        let passes: [(MacAXAppInfo) -> Bool] = [
            { normalized($0.name).hasPrefix(bare) },
            { normalized($0.name).contains(bare) },
            { normalized($0.bundleIdentifier ?? "").contains(bare) },
            { !flat.isEmpty && (squashed($0.name) == flat || squashed($0.bundleIdentifier ?? "").contains(flat)) },
        ]
        for pass in passes {
            if let match = resolution(apps.filter(pass)) { return match }
        }
        return .notRunning(candidates: candidateNames(apps))
    }

    /// Every running app by name, sorted, so the list is the real answer to "what is running"; a list past the cap says how many it left out.
    static func candidateNames(_ apps: [MacAXAppInfo]) -> [String] {
        let names = Set(apps.filter { $0.processIdentifier != getpid() }.map(\.name))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard names.count > maxCandidates else { return names }
        return Array(names.prefix(maxCandidates)) + ["and \(names.count - maxCandidates) more"]
    }

    /// The resolution, in words. A stopped app is an empty look observation; a caller that needs a running app still treats it as a precondition failure.
    public static func words(for resolution: Resolution, requested name: String) -> String? {
        switch resolution {
        case .matched:
            return nil
        case .indexUnavailable:
            return "The installed-app index is not ready or the matching app's classification is unavailable, so I can't resolve \"\(name)\" without guessing. "
                + "Use the running app's exact name or bundle identifier, or try again once Spotlight has gathered the apps."
        case .selfProcess:
            // Match the AX path's `selfInspectionNote` refusal and recovery direction.
            return "\"\(name)\" is NativeAgent itself, and this app's own window can never be "
                + "captured — reading our own UI over accessibility deadlocks the app. "
                + "Use app (desk.read, mind.inner_state, agent.introspect) for our own state, and "
                + "screen only for another app's window."
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
