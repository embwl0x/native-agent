import Foundation
import NativeAgentShared

/// 658.14 — a reachable identity for each chat session that is running a turn
/// somewhere other than the foreground.
///
/// Before this, the "N other sessions running" banner offered exactly one
/// action once N exceeded 1: a bulk "Stop Others". The multi-session case —
/// the only case where you actually need to find the work — was the case with
/// no way to reach it, and the sole affordance was destructive.
///
/// Titles are attacker-influenced. A session title can be auto-derived from
/// message content, and message content includes untrusted bridge payloads, so
/// a title can carry newlines, control characters, bidi overrides, or
/// unbounded length. This projection therefore hard-bounds every title before
/// it reaches a menu: control characters removed (not replaced with something
/// that could re-parse), collapsed to a single line, and truncated. A session
/// with no usable title falls back to a short form of its id so the row is
/// still selectable rather than blank.
struct MacChatRunningSessionRoute: Sendable, Equatable {
    let sessionId: String
    /// Safe, bounded, single-line menu text. Never the raw stored title.
    let title: String

    /// Total Unicode-scalar ceiling, including the truncation marker. A single
    /// extended grapheme may contain thousands of combining scalars, so
    /// `String.count`/`prefix` is not a data bound for attacker-influenced UI.
    static let titleScalarLimit = 48

    /// Maximum input scalars inspected while deriving one title. Output was
    /// already bounded, but an all-format or all-combining-mark payload could
    /// previously make every banner render scan an arbitrarily large string
    /// before producing that small output.
    static let titleInputScalarLimit = 512

    /// Build one route per running session id, skipping nothing. Known rows
    /// follow the canonical session-list order; stale ids sort by their stable
    /// identity so Set iteration cannot reorder the menu between renders.
    static func routes(sessionIds: [String], sessions: [ChatSession]) -> [MacChatRunningSessionRoute] {
        let sessionsById = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let canonicalOrder = Dictionary(
            sessions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        let orderedIDs = sessionIds.filter { seen.insert($0).inserted }.sorted { lhs, rhs in
            let lhsOrder = canonicalOrder[lhs] ?? Int.max
            let rhsOrder = canonicalOrder[rhs] ?? Int.max
            return lhsOrder == rhsOrder ? lhs < rhs : lhsOrder < rhsOrder
        }
        let candidates = orderedIDs.map { sessionId in
            MacChatRunningSessionRoute(
                sessionId: sessionId,
                title: displayTitle(session: sessionsById[sessionId], sessionId: sessionId)
            )
        }

        // Every multi-route label gets an ordinal suffix, rather than only
        // labels that collide before suffixing. Otherwise a stored title such
        // as `X [1:a]` can collide with the generated label for another `X`
        // row. The ordinal is unique in this ordered projection and the suffix
        // is never truncated, so menu and VoiceOver labels stay distinct even
        // when titles are adversarially chosen.
        guard candidates.count > 1 else { return candidates }
        return candidates.enumerated().map { offset, route in
            return MacChatRunningSessionRoute(
                sessionId: route.sessionId,
                title: disambiguatedTitle(
                    route.title,
                    sessionId: route.sessionId,
                    ordinal: offset + 1
                )
            )
        }
    }

    static func displayTitle(rawTitle: String?, sessionId: String) -> String {
        if let cleaned = sanitize(rawTitle), !cleaned.isEmpty {
            return cleaned
        }
        return fallbackTitle(sessionId: sessionId)
    }

    /// Preserve `ChatSession.displayTitle` semantics without calling its
    /// unbounded trim/prefix implementation on attacker-influenced text.
    private static func displayTitle(session: ChatSession?, sessionId: String) -> String {
        guard let session else { return fallbackTitle(sessionId: sessionId) }
        let storedTitle = sanitize(session.title)
        if let storedTitle,
           !storedTitle.isEmpty,
           storedTitle != ChatSession.placeholderTitle {
            return storedTitle
        }
        if let preview = sanitize(session.lastMessagePreview), !preview.isEmpty {
            return preview
        }
        return storedTitle ?? fallbackTitle(sessionId: sessionId)
    }

    /// Strip everything that could break out of a single menu line, collapse
    /// whitespace, and stop after a bounded number of Unicode scalars. Removal,
    /// not substitution — a replacement character is one more thing a spoofing
    /// payload can lean on.
    private static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(titleScalarLimit)
        var pendingSpace = false
        var truncated = false

        var examinedScalars = 0
        for scalar in raw.unicodeScalars {
            guard examinedScalars < titleInputScalarLimit else {
                truncated = true
                break
            }
            examinedScalars += 1
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || scalar.properties.generalCategory == .format {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            // A leading combining/enclosing mark has no visible base and can
            // produce an apparently blank or misleading menu label. Marks are
            // retained only after a visible scalar has established a base.
            if scalars.isEmpty, isCombiningMark(scalar) {
                continue
            }
            if pendingSpace {
                // Leave room for both the collapsed space and this visible
                // scalar. Never emit a trailing space immediately before the
                // truncation marker.
                guard scalars.count + 1 < titleScalarLimit else {
                    truncated = true
                    break
                }
                scalars.append(Unicode.Scalar(0x20)!)
                pendingSpace = false
            }
            guard scalars.count < titleScalarLimit else {
                truncated = true
                break
            }
            scalars.append(scalar)
        }

        guard !scalars.isEmpty else { return nil }
        if truncated {
            let ellipsis = Unicode.Scalar(0x2026)!
            if scalars.count == titleScalarLimit {
                scalars[scalars.index(before: scalars.endIndex)] = ellipsis
            } else {
                scalars.append(ellipsis)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// A menu containing indistinguishable labels is technically clickable but
    /// not navigable in practice or through VoiceOver, so multi-route menus
    /// receive a bounded, deterministic identity suffix.
    private static func disambiguatedTitle(
        _ title: String,
        sessionId: String,
        ordinal: Int
    ) -> String {
        let token = safeSessionIDTail(sessionId) ?? String(ordinal)
        let suffix = " [\(ordinal):\(token)]"
        let suffixScalars = Array(suffix.unicodeScalars)
        guard suffixScalars.count < titleScalarLimit else { return "Running session \(ordinal)" }
        let baseLimit = titleScalarLimit - suffixScalars.count
        var baseScalars = Array(title.unicodeScalars.prefix(baseLimit))
        while baseScalars.last.map({ CharacterSet.whitespacesAndNewlines.contains($0) }) == true {
            baseScalars.removeLast()
        }
        return String(String.UnicodeScalarView(baseScalars + suffixScalars))
    }

    /// A short, stable stand-in that is always non-empty, so the menu row stays
    /// clickable even for an untitled or unknown session.
    private static func fallbackTitle(sessionId: String) -> String {
        guard let tail = safeSessionIDTail(sessionId) else { return "Untitled session" }
        return "Session " + tail
    }

    private static func safeSessionIDTail(_ sessionId: String) -> String? {
        var safeTail: [Unicode.Scalar] = []
        safeTail.reserveCapacity(8)
        var examinedScalars = 0
        for scalar in sessionId.unicodeScalars {
            guard examinedScalars < titleInputScalarLimit else { break }
            examinedScalars += 1
            guard isSafeSessionIDScalar(scalar) else { continue }
            if safeTail.count == 8 { safeTail.removeFirst() }
            safeTail.append(scalar)
        }
        guard !safeTail.isEmpty else { return nil }
        return String(String.UnicodeScalarView(safeTail))
    }

    private static func isSafeSessionIDScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: // 0-9, A-Z, a-z
            return true
        case 45, 58, 95: // -, :, _
            return true
        default:
            return false
        }
    }
}

/// Testable action seam for stale session-index races. A route rendered from
/// live `streamingSessions` first resolves the current index, then performs one
/// canonical refresh before admitting defeat. Selection itself remains owned
/// by AppModel's transactional selector.
enum MacChatRunningSessionNavigation {
    @MainActor
    static func navigate(
        sessionId: String,
        sessions: () -> [ChatSession],
        refresh: () async -> Void,
        select: (ChatSession) async -> Bool,
        isCurrentIntent: () -> Bool = { true }
    ) async -> Bool {
        guard isCurrentIntent() else { return false }
        if let current = sessions().first(where: { $0.id == sessionId }) {
            let selected = await select(current)
            return isCurrentIntent() && selected
        }
        await refresh()
        guard isCurrentIntent(),
              let refreshed = sessions().first(where: { $0.id == sessionId }) else {
            return false
        }
        let selected = await select(refreshed)
        return isCurrentIntent() && selected
    }
}
