import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Experiences
// Blueprint: | `TurnTraceWindowReader.swift` | Measurement-window policy and coverage through canonical TurnTrace framing |

// MARK: - Bounded reader for trace details
// Explicit off-turn checks share a time-bounded record query. Empty input remains unmeasured; unreadable rows are named coverage gaps.

/// Preserve coverage evidence so callers cannot imply they measured unreadable or absent input.
struct TurnTraceScanSummary: Sendable {
    let from: Date
    let through: Date
    let eventsRead: Int
    let unreadableRows: Int
    let observedDays: Int
    let earlierHistoryExcluded: Bool

    var isEmptyFeed: Bool { eventsRead == 0 && unreadableRows == 0 }

    var windowCovered: String {
        let formatter = ISO8601DateFormatter()
        return "record queried from \(formatter.string(from: from)) through \(formatter.string(from: through))"
            + "; \(eventsRead) event(s) read over \(observedDays) day(s) with matching events"
    }

    var coverageParts: [String] {
        var parts: [String] = []
        if earlierHistoryExcluded {
            parts.append("earlier launch history is outside the queried window")
        }
        if unreadableRows > 0 {
            parts.append("\(unreadableRows) record row(s) could not decode as trace events")
        }
        return parts
    }

    var coverageDetail: String {
        "; " + ([windowCovered] + coverageParts).joined(separator: "; ")
    }
}

// MARK: - DoctorMeasurementWindow
// Only this process's valid launch stamp can establish its measurement window.

struct DoctorMeasurementWindow: Sendable {
    /// Older rows describe a different build and cannot enter this window.
    let floor: Date
    let describedAs: String
}

enum DoctorWindowFloor {
    static func resolve(
        root: URL,
        now: Date
    ) -> DoctorMeasurementWindow? {
        guard let stamp = launchStamp(root: root, identity: .current), stamp <= now else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return DoctorMeasurementWindow(
            floor: stamp,
            describedAs: "since this build launched at \(formatter.string(from: stamp))"
        )
    }

    /// Require this process's current-build stamp; an earlier launch cannot establish the running build's floor.
    private static func launchStamp(root: URL, identity: NativeAgentBuildIdentity) -> Date? {
        launchStamp(path: root.appendingPathComponent(NativeAgentBuildIdentity.launchStampFilename), identity: identity)
    }

    private static func launchStamp(path: URL, identity: NativeAgentBuildIdentity) -> Date? {
        guard identity.unavailableReason == nil else { return nil }
        guard let data = try? Data(contentsOf: path),
              let value = try? JSONValue.parse(data),
              case .object(let object) = value,
              let writtenAt = object["writtenAt"]?.stringValue,
              let stamp = TurnTraceEvent.parseISO8601(writtenAt)
        else { return nil }
        // Refuse stamps from other launches, including when this launch failed to write its own.
        guard object["build"]?.stringValue == identity.build,
              object["version"]?.stringValue == identity.version,
              object["pid"] == .int(Int64(ProcessInfo.processInfo.processIdentifier))
        else { return nil }
        // Archives may lack revision identity, but both sides must agree; missing evidence cannot certify a known revision.
        guard object["sourceRevision"]?.stringValue?.lowercased() == identity.sourceRevision?.lowercased() else { return nil }
        return stamp
    }
}

enum TurnTraceWindowReader {
    static let source = "experiences/experiences.sqlite"

    /// Keep the launch floor and the same newest calendar-day window; deliver record order without a row-count tail.
    static func scan(
        root: URL,
        now: Date,
        floor: Date,
        kinds: Set<String>,
        maximumDays: Int = 7,
        handle: (TurnTraceEvent) -> Void
    ) async throws -> TurnTraceScanSummary {
        let calendar = TurnTracePersistLane.dayCalendar
        guard let oldestDay = calendar.date(byAdding: .day, value: 1 - max(1, maximumDays), to: calendar.startOfDay(for: now)) else {
            throw WindowError.invalidCalendarWindow
        }
        let from = max(floor, oldestDay)
        let read = try await TurnTracePersistLane(dataRootOverride: root).events(
            ExperienceStore.DetailQuery(kinds: kinds.sorted(), from: from, through: now)
        )
        for event in read.events { handle(event) }
        return TurnTraceScanSummary(from: from, through: now, eventsRead: read.events.count, unreadableRows: read.unreadable,
            observedDays: Set(read.events.map { TurnTracePersistLane.dayString(from: $0.ts) }).count,
            earlierHistoryExcluded: from > floor)
    }

    private enum WindowError: Error { case invalidCalendarWindow }
}

// MARK: - JSONValue numeric accessors
// Token counts are ints and ratios doubles; accepting just one numeric shape would silently drop valid data.

extension JSONValue {
    var intValue: Int? {
        if case .double(let number) = self { return Int(exactly: number.rounded()) }
        return integerValue.flatMap(Int.init(exactly:))
    }
}

// MARK: - DoctorScanCache
// Memoize off-turn readings across renders so opening Doctor does not repeatedly read the feed. A short lifetime permits fresh manual readings; cached rows
// retain their actual measurement age.
actor DoctorScanCache {
    private var cached: (result: CheckResult, at: Date)?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    func fresh(now: Date) -> CheckResult? {
        guard let cached, now.timeIntervalSince(cached.at) < ttl else { return nil }
        return cached.result
    }

    func store(_ result: CheckResult, at moment: Date) {
        cached = (result, moment)
    }
}
