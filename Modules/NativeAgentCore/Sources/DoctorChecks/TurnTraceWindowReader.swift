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

    var isEmptyFeed: Bool { eventsRead == 0 && unreadableRows == 0 }

    var windowCovered: String {
        let formatter = ISO8601DateFormatter()
        return "record queried from \(formatter.string(from: from)) through \(formatter.string(from: through))"
            + "; \(eventsRead) event(s) read over \(observedDays) day(s) with matching events"
    }

    var coverageParts: [String] {
        var parts: [String] = []
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
// The running build is measured from its first launch, across its relaunches; a replaced build's rows describe another build.

struct DoctorMeasurementWindow: Sendable {
    let floor: Date
    let describedAs: String
}

enum DoctorWindowFloor {
    /// Nil when the launch stamp does not name the running build, so no window can be certified for it.
    static func resolve(root: URL, now: Date) -> DoctorMeasurementWindow? {
        let identity = NativeAgentBuildIdentity.current
        guard let data = try? Data(contentsOf: root.appendingPathComponent(NativeAgentBuildIdentity.launchStampFilename)),
              let stamp = try? JSONSerialization.jsonObject(with: data) as? [String: Any], identity.sameBuild(as: stamp),
              let first = (stamp["firstLaunchedAt"] ?? stamp["writtenAt"]) as? String,
              let launched = TurnTraceEvent.parseISO8601(first), launched <= now else { return nil }
        let floor = max(launched, now.addingTimeInterval(-ExperienceStore.detailHorizon))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return DoctorMeasurementWindow(floor: floor, describedAs: "since this build first launched at \(formatter.string(from: floor))")
    }
}

enum TurnTraceWindowReader {
    static let source = "experiences/experiences.sqlite"

    /// Query event timestamps from the window's floor; deliver record order without a row-count tail.
    static func scan(
        root: URL,
        now: Date,
        floor: Date,
        kinds: Set<String>,
        handle: (TurnTraceEvent) -> Void
    ) async throws -> TurnTraceScanSummary {
        let read = try await TurnTracePersistLane(dataRootOverride: root).events(
            ExperienceStore.DetailQuery(kinds: kinds.sorted(), from: floor, through: now)
        )
        for event in read.events { handle(event) }
        return TurnTraceScanSummary(from: floor, through: now, eventsRead: read.events.count, unreadableRows: read.unreadable,
            observedDays: Set(read.events.map { TurnTracePersistLane.dayString(from: $0.ts) }).count)
    }
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
