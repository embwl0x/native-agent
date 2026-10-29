import EngineRuntime
import Foundation
import MemoryV2
import NativeAgentShared
import SwiftUI
import AppKit
import Combine
import Cognition
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoriesRowText.swift` | Memory provenance, time, ordering and page/row wording from canonical records; no store ownership |

// MARK: - Where a memory came from

/// Provenance names only recognized stored source handles; missing or unknown stays unknown.
enum MemoriesProvenance: Equatable {
    case fromHim
    case fromTalking
    case fromAMoment
    case wroteItDown
    case tidiedUp
    case unknown

    var words: String {
        switch self {
        case .fromHim: "Shared by you"
        case .fromTalking: "I picked it up while we talked"
        case .fromAMoment: "I kept it from something that happened"
        case .wroteItDown: "I wrote it down myself"
        case .tidiedUp: "I tidied it up from older notes"
        case .unknown: "I don't remember where this came from"
        }
    }

    static func classify(_ sourceRunId: String?) -> MemoriesProvenance {
        let raw = (sourceRunId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The app's own word for "a person typed this". ONLY that.
        if raw == "manual" || raw == "user" { return .fromHim }
        // Missing provenance stays unknown and never implies human authorship.
        if raw.isEmpty { return .unknown }
        // Her own commit_memory tool: she wrote it down herself.
        if raw.hasPrefix("chat.commit_memory") || raw.hasPrefix("commit_memory") { return .wroteItDown }
        if raw.hasPrefix(MemoryMoments.sourcePrefix) { return .fromAMoment }
        if raw.hasPrefix("adaptive-promoter") || raw.hasPrefix("semantic-adaptive-extractor") {
            return .fromTalking
        }
        if raw.hasPrefix("consolidat") || raw.hasPrefix("hygiene") { return .tidiedUp }
        return .unknown
    }
}

// MARK: - When, in plain words

/// "today" · "yesterday" · "2 weeks ago" · "in July" · "in July 2025". A
/// timestamp that will not parse says so; it never becomes "just now".
enum MemoriesWhen {
    static func words(_ iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let iso,
              let at = UserDisplayFormatters.parseISOTimestamp(iso)
        else { return "when, I'm not sure" }
        if calendar.isDateInToday(at) { return "today" }
        if calendar.isDateInYesterday(at) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: at, to: now).day ?? 0
        if days >= 0, days < 30 {
            return relativeLock.withLock { relative.localizedString(for: at, relativeTo: now) }
        }
        if calendar.component(.year, from: at) == calendar.component(.year, from: now) {
            return "in \(at.formatted(.dateTime.month(.wide)))"
        }
        return "in \(at.formatted(.dateTime.month(.wide).year()))"
    }

    /// One formatter for every row, not one built per row per redraw. Used
    /// only under `relativeLock`, since the caller is not tied to one thread.
    private static let relativeLock = NSLock()
    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// The row sorts on the newest of the two stamps the store keeps.
    static func sortDate(_ memory: MemoryV2.MemoryRecord) -> Date {
        let updated = memory.updatedAt.flatMap { UserDisplayFormatters.parseISOTimestamp($0) }
        let created = UserDisplayFormatters.parseISOTimestamp(memory.createdAt)
        return updated ?? created ?? .distantPast
    }

    /// The stamp the meta line shows: the update if there is one, else the save.
    static func stamp(_ memory: MemoryV2.MemoryRecord) -> String? {
        if let updated = memory.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !updated.isEmpty {
            return updated
        }
        return memory.createdAt
    }
}

// MARK: - What the page says

/// Pure projections, so the copy can be reasoned about without a store.
enum MemoriesPageContent {
    /// The one line under the title. Counts are spelled, the way Today and the
    /// Desk spell them; `DeskPageWords` is the same rule carried past ten.
    static func keptLine(_ count: Int) -> String {
        switch count {
        case 0: return "Nothing kept yet."
        case 1: return "One thing I've kept."
        default: return "\(DeskPageWords.spelled(count)) things I've kept."
        }
    }

    /// The header stays nil until read and names proposals as memories to look at, not work awaiting the person.
    static func headerLine(loaded: Bool, failed: Bool, kept: Int?, toLookAt: Int) -> String? {
        guard loaded else { return nil }
        guard !failed, let kept else { return "I couldn't refresh all my memories just now." }
        let keep: String
        switch kept {
        case 0: keep = "No memories loaded."
        case 1: keep = "1 memory loaded."
        default: keep = "\(kept) memories loaded."
        }
        guard toLookAt > 0 else { return keep }
        return "\(keep) \(toLookAt) \(toLookAt == 1 ? "memory" : "memories") to look at."
    }

    @MainActor
    static func headerLine(_ appModel: AppModel) -> String? {
        let status = appModel.panelRefreshStatus[.memories]
        return headerLine(
            loaded: status != nil,
            failed: status?.failedEndpoints.contains("memories") == true,
            kept: appModel.engine.memory.totalCount,
            toLookAt: appModel.engine.memory.proposals.filter { $0.status == "pending" }.count)
    }

    /// Pinned first, then newest. The same order the conversations list keeps.
    static func ordered(_ memories: [MemoryV2.MemoryRecord]) -> [MemoryV2.MemoryRecord] {
        // Each stamp parsed once, not twice per comparison.
        memories.map { ($0, MemoriesWhen.sortDate($0)) }.sorted { l, r in
            let (lhs, la) = l, (rhs, ra) = r
            let lp = lhs.pinned == true, rp = rhs.pinned == true
            if lp != rp { return lp }
            if la != ra { return la > ra }
            return lhs.id < rhs.id
        }.map(\.0)
    }

    /// "Pinned · in July · I checked it myself".
    static func meta(_ memory: MemoryV2.MemoryRecord, now: Date) -> String {
        var parts: [String] = []
        if let warning = MemorySenseProvenance.warning(in: memory.extras) { parts.append(warning) }
        if memory.pinned == true { parts.append("Pinned") }
        if MemoryLifecycle.normalized(memory.lifecycle) == MemoryLifecycle.graduated { parts.append("graduated → GROWTH") }
        parts.append(MemoriesWhen.words(MemoriesWhen.stamp(memory), now: now))
        parts.append(MemoriesProvenance.classify(memory.sourceRunId).words)
        return parts.joined(separator: " · ")
    }

    /// One line of the memory, cut at a word boundary and stripped of markdown.
    static func line(_ text: String) -> String {
        TodayWords.line(text, limit: MemoriesPageMetrics.rowLineLimit)
    }

    /// The lane first — Correction or Fact — so a card says what Keep writes.
    static func proposalMeta(_ proposal: ProposalRecord, staged: String) -> String {
        let lane = proposal.metadata?.objectValue?["kind"]?.stringValue == "correction" ? "Correction" : "Fact"
        return "\(lane) · \(staged)"
    }
}
