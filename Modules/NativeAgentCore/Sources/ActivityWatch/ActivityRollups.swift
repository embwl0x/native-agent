import Foundation

// MARK: - Rollup shapes

/// One bucket of time in the ASKING timezone.
///
/// `start`/`end` are epoch seconds, so the bucket carries no day string. That is
/// deliberate: a stored "2026-08-14" can disagree with the timezone the question
/// is asked in, and then no amount of care downstream recovers the truth.
public struct ActivityBucket: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let bundleId: String
    public let appName: String
    /// Seconds of this app's span time that fall INSIDE this bucket.
    public let seconds: Double
    /// Spans contributing to this bucket (a span split across two buckets
    /// counts in both — it really was open in both).
    public let spanCount: Int
    /// Events attributed to the part of each span inside this bucket, prorated
    /// by duration. Fractional by construction; rounded only for display.
    public let eventCount: Double

    public init(
        start: Double, end: Double, bundleId: String, appName: String,
        seconds: Double, spanCount: Int, eventCount: Double
    ) {
        self.start = start
        self.end = end
        self.bundleId = bundleId
        self.appName = appName
        self.seconds = seconds
        self.spanCount = spanCount
        self.eventCount = eventCount
    }
}

/// A bounded top-N result that says out loud what it dropped.
///
/// HONEST TRUNCATION: `rows` is never the whole story when `truncated` is true,
/// and the caller (and the model reading the tool answer) is told exactly how
/// many rows and how many seconds went missing. A silent cut here is how a
/// "you spent 20 minutes in Mail" answer gets built out of a day that had six
/// hours of other things in it.
public struct ActivityTopN: Sendable, Equatable {
    public let rows: [ActivityAppTotal]
    public let truncated: Bool
    public let droppedRowCount: Int
    public let droppedSeconds: Double
    /// Total distinct apps before truncation.
    public let totalRowCount: Int

    public init(
        rows: [ActivityAppTotal], truncated: Bool,
        droppedRowCount: Int, droppedSeconds: Double, totalRowCount: Int
    ) {
        self.rows = rows
        self.truncated = truncated
        self.droppedRowCount = droppedRowCount
        self.droppedSeconds = droppedSeconds
        self.totalRowCount = totalRowCount
    }
}

public struct ActivityAppTotal: Sendable, Equatable {
    public let bundleId: String
    public let appName: String
    public let seconds: Double
    public let spanCount: Int
    public let eventCount: Int

    public init(
        bundleId: String, appName: String, seconds: Double,
        spanCount: Int, eventCount: Int
    ) {
        self.bundleId = bundleId
        self.appName = appName
        self.seconds = seconds
        self.spanCount = spanCount
        self.eventCount = eventCount
    }
}

/// The whole answer to one question, hard-capped so it fits a context window.
public struct ActivityAnswerBundle: Sendable, Equatable {
    public let from: Double
    public let to: Double
    public let timezoneIdentifier: String
    public let totalSeconds: Double
    public let topApps: ActivityTopN
    public let buckets: [ActivityBucket]
    public let exemplars: [ActivitySpan]
    /// Rows the cap removed, across every section. Reported, never silent.
    public let truncatedSections: [String]
    /// Every row this answer contains. Pinned by a test at <= `rowCap`.
    public var rowCount: Int { topApps.rows.count + buckets.count + exemplars.count }

    public init(
        from: Double, to: Double, timezoneIdentifier: String, totalSeconds: Double,
        topApps: ActivityTopN, buckets: [ActivityBucket], exemplars: [ActivitySpan],
        truncatedSections: [String]
    ) {
        self.from = from
        self.to = to
        self.timezoneIdentifier = timezoneIdentifier
        self.totalSeconds = totalSeconds
        self.topApps = topApps
        self.buckets = buckets
        self.exemplars = exemplars
        self.truncatedSections = truncatedSections
    }
}

// MARK: - The rollup tier

/// W4 — the deterministic rollup tier. Pure SQL + pure Swift. ZERO inference,
/// zero model calls, no materialized tables.
///
/// Buckets are computed HERE, at query time, in the CALLER'S timezone. The
/// stored `tz_offset_min` is provenance only — "what offset was in force when
/// this row was written" — and is never used to decide which day a span belongs
/// to. That is what makes a DST day come out as 23 or 25 hours instead of a
/// fixed 24, and what lets the same rows answer correctly from another timezone.
public struct ActivityRollups: Sendable {
    public enum Grain: String, Sendable, CaseIterable {
        case hourly
        case daily

        var component: Calendar.Component { self == .hourly ? .hour : .day }
    }

    /// Adjacent spans of the same app separated by less than this coalesce
    /// (W4 "span merge"). Purely a presentation concern for exemplars — bucket
    /// totals sum real observed time either way.
    public static let mergeGapSeconds: Double = 30

    /// The acceptance criterion from the plan, as a constant: any single answer
    /// fits in ~50 rows.
    public static let answerRowCap = 50

    private let store: ActivitySpanStore
    private let policy: ActivityPolicy

    public init(store: ActivitySpanStore, policy: ActivityPolicy) {
        self.store = store
        self.policy = policy
    }

    // MARK: Bucketing

    /// Cap on generated buckets. A caller asking for a decade of HOURLY buckets
    /// must not hang — but it must also not be told it got the whole decade.
    public static let maxBuckets = 24 * 400

    /// Bucket boundaries in `timezone`, computed with `Calendar` so DST is the
    /// calendar's problem and not ours. A 25-hour day yields 25 hourly buckets
    /// and one daily bucket 90,000 s long; a 23-hour day yields 23 and 82,800.
    public static func bucketBoundaries(
        from: Double, to: Double, grain: Grain, timezone: TimeZone
    ) -> [(start: Double, end: Double)] {
        boundedBuckets(from: from, to: to, grain: grain, timezone: timezone).boundaries
    }

    /// Boundaries plus how far they actually reach.
    ///
    /// `coveredTo` exists because the bucket cap is a SILENT CAP otherwise: ask
    /// for ten years of hourly buckets and you get the first 9,600 hours, which
    /// on a window ending at "now" is nine and a half years of empty buckets and
    /// none of your data — reported as a complete answer. Callers must be able
    /// to see that the range was cut, so `answerBundle` can say so.
    public static func boundedBuckets(
        from: Double, to: Double, grain: Grain, timezone: TimeZone
    ) -> (boundaries: [(start: Double, end: Double)], coveredTo: Double) {
        guard to > from else { return ([], to) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        var boundaries: [(start: Double, end: Double)] = []
        var cursor = calendar.dateInterval(
            of: grain.component, for: Date(timeIntervalSince1970: from)
        )?.start ?? Date(timeIntervalSince1970: from)

        while cursor.timeIntervalSince1970 < to, boundaries.count < maxBuckets {
            let interval = calendar.dateInterval(of: grain.component, for: cursor)
            guard let interval, interval.duration > 0 else { break }
            boundaries.append((interval.start.timeIntervalSince1970,
                               interval.end.timeIntervalSince1970))
            cursor = interval.end
        }
        return (boundaries, min(to, boundaries.last?.end ?? to))
    }

    /// Per-app buckets over the window. Zero-length buckets (no activity) are
    /// omitted — an answer full of empty hours is noise, and the caller has the
    /// window bounds to know what is missing.
    public func buckets(
        from: Double, to: Double, grain: Grain, timezone: TimeZone
    ) async throws -> [ActivityBucket] {
        let spans = try await store.spansOverlapping(from: from, to: to, policy: policy)
        return Self.buckets(spans: spans, from: from, to: to, grain: grain, timezone: timezone)
    }

    /// Pure function over already-fetched spans. Split out so the DST tests can
    /// hit it with a hand-built fixture and no database at all.
    public static func buckets(
        spans: [ActivitySpan], from: Double, to: Double, grain: Grain, timezone: TimeZone
    ) -> [ActivityBucket] {
        let boundaries = bucketBoundaries(from: from, to: to, grain: grain, timezone: timezone)
        var out: [ActivityBucket] = []

        for (bucketStart, bucketEnd) in boundaries {
            // Key by bundle id; carry the most recent app name seen for it.
            var seconds: [String: Double] = [:]
            var names: [String: String] = [:]
            var counts: [String: Int] = [:]
            var events: [String: Double] = [:]

            for span in spans {
                let spanEnd = span.endedAt ?? span.lastSeenAt
                let overlapStart = max(span.startedAt, max(bucketStart, from))
                let overlapEnd = min(spanEnd, min(bucketEnd, to))
                let overlap = overlapEnd - overlapStart
                guard overlap > 0 else { continue }
                let total = max(spanEnd - span.startedAt, 0)
                // Prorate events by the fraction of the span inside the bucket.
                // A zero-length span contributes its events to whichever bucket
                // contains its instant, undivided.
                let share = total > 0 ? overlap / total : 1
                seconds[span.bundleId, default: 0] += overlap
                names[span.bundleId] = span.appName
                counts[span.bundleId, default: 0] += 1
                events[span.bundleId, default: 0] += Double(span.eventCount) * share
            }

            for (bundleId, secs) in seconds.sorted(by: { $0.value > $1.value }) {
                out.append(ActivityBucket(
                    start: bucketStart,
                    end: bucketEnd,
                    bundleId: bundleId,
                    appName: names[bundleId] ?? bundleId,
                    seconds: secs,
                    spanCount: counts[bundleId] ?? 0,
                    eventCount: events[bundleId] ?? 0
                ))
            }
        }
        return out
    }

    // MARK: Top-N

    /// Bounded top-N by observed seconds, with the truncation stated.
    public func topApps(
        from: Double, to: Double, limit: Int
    ) async throws -> ActivityTopN {
        let spans = try await store.spansOverlapping(from: from, to: to, policy: policy)
        return Self.topApps(spans: spans, from: from, to: to, limit: limit)
    }

    public static func topApps(
        spans: [ActivitySpan], from: Double, to: Double, limit: Int
    ) -> ActivityTopN {
        var seconds: [String: Double] = [:]
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        var events: [String: Int] = [:]

        for span in spans {
            let spanEnd = span.endedAt ?? span.lastSeenAt
            let overlap = min(spanEnd, to) - max(span.startedAt, from)
            guard overlap >= 0 else { continue }
            seconds[span.bundleId, default: 0] += max(0, overlap)
            names[span.bundleId] = span.appName
            counts[span.bundleId, default: 0] += 1
            events[span.bundleId, default: 0] += span.eventCount
        }

        let all = seconds
            .map { bundleId, secs in
                ActivityAppTotal(
                    bundleId: bundleId,
                    appName: names[bundleId] ?? bundleId,
                    seconds: secs,
                    spanCount: counts[bundleId] ?? 0,
                    eventCount: events[bundleId] ?? 0
                )
            }
            // Deterministic order: seconds desc, then bundle id — never
            // dictionary order, or two identical questions disagree.
            .sorted { ($0.seconds, $1.bundleId) > ($1.seconds, $0.bundleId) }

        let kept = Array(all.prefix(max(0, limit)))
        let dropped = all.dropFirst(kept.count)
        return ActivityTopN(
            rows: kept,
            truncated: !dropped.isEmpty,
            droppedRowCount: dropped.count,
            droppedSeconds: dropped.reduce(0) { $0 + $1.seconds },
            totalRowCount: all.count
        )
    }

    // MARK: Exemplars

    /// The longest spans in the window, after merging adjacent same-app spans
    /// separated by less than `mergeGapSeconds`.
    public static func exemplars(
        spans: [ActivitySpan], limit: Int
    ) -> [ActivitySpan] {
        let merged = merge(spans: spans)
        return Array(
            merged
                .sorted { ($0.duration, $1.startedAt) > ($1.duration, $0.startedAt) }
                .prefix(max(0, limit))
        )
    }

    /// W4 span merge. Same app, same redacted title, gap under the threshold →
    /// one span. Keeps the first row's id so an exemplar still points at a real
    /// stored row.
    public static func merge(spans: [ActivitySpan]) -> [ActivitySpan] {
        let ordered = spans.sorted { $0.startedAt < $1.startedAt }
        var out: [ActivitySpan] = []
        for span in ordered {
            guard let previous = out.last,
                  previous.bundleId == span.bundleId,
                  previous.titleRedacted == span.titleRedacted else {
                out.append(span)
                continue
            }
            let previousEnd = previous.endedAt ?? previous.lastSeenAt
            guard span.startedAt - previousEnd <= mergeGapSeconds else {
                out.append(span)
                continue
            }
            let spanEnd = span.endedAt ?? span.lastSeenAt
            out[out.count - 1] = ActivitySpan(
                id: previous.id,
                startedAt: previous.startedAt,
                endedAt: max(previousEnd, spanEnd),
                lastSeenAt: max(previous.lastSeenAt, span.lastSeenAt),
                bundleId: previous.bundleId,
                appName: previous.appName,
                titleRedacted: previous.titleRedacted,
                eventCount: previous.eventCount + span.eventCount,
                closeReason: span.closeReason,
                tzOffsetMin: previous.tzOffsetMin
            )
        }
        return out
    }

    // MARK: The single answer

    /// The whole answer to "what was I doing on X", hard-capped at ~50 rows.
    ///
    /// Budget, spent in priority order: top apps first (the headline), then
    /// buckets (the shape of the day), then exemplars (the evidence). Whatever
    /// the cap removes is named in `truncatedSections` — the cap is honest or
    /// it is a lie with a small footprint.
    public func answerBundle(
        from: Double,
        to: Double,
        timezone: TimeZone,
        grain: Grain? = nil,
        rowCap: Int = ActivityRollups.answerRowCap
    ) async throws -> ActivityAnswerBundle {
        let spans = try await store.spansOverlapping(from: from, to: to, policy: policy)
        // A window longer than ~36 h is a day-scale question; below that the
        // hour is the interesting unit.
        let chosenGrain = grain ?? ((to - from) > 36 * 3600 ? .daily : .hourly)

        let cap = max(3, rowCap)
        let topLimit = min(10, max(1, cap / 5))
        let exemplarLimit = min(10, max(1, cap / 5))
        let bucketLimit = max(0, cap - topLimit - exemplarLimit)

        let top = Self.topApps(spans: spans, from: from, to: to, limit: topLimit)

        // Detect the bucket-generation cap BEFORE bucketing, so a window too
        // large for the requested grain is reported rather than silently
        // answered from its first 9,600 buckets.
        let coverage = Self.boundedBuckets(
            from: from, to: to, grain: chosenGrain, timezone: timezone
        )
        let bucketedTo = coverage.coveredTo

        let allBuckets = Self.buckets(
            spans: spans, from: from, to: to, grain: chosenGrain, timezone: timezone
        )
        // Keep the heaviest buckets, then restore chronological order — a
        // timeline that jumps around is unreadable, and sorting by weight is
        // only how we choose WHICH rows survive the cap.
        let keptBuckets = allBuckets
            .sorted { $0.seconds > $1.seconds }
            .prefix(bucketLimit)
            .sorted { ($0.start, $0.seconds) < ($1.start, $1.seconds) }

        let allExemplars = Self.exemplars(spans: spans, limit: Int.max)
        let keptExemplars = Array(allExemplars.prefix(exemplarLimit))

        var truncated: [String] = []
        if bucketedTo < to {
            let hours = Int(((to - bucketedTo) / 3600).rounded())
            truncated.append(
                "buckets: the \(chosenGrain.rawValue) grain covers only up to "
                    + "\(Int(bucketedTo)) (epoch) — \(hours) h of the requested window "
                    + "is beyond the \(Self.maxBuckets)-bucket limit. Ask a shorter "
                    + "window, or the daily grain."
            )
        }
        if top.truncated {
            truncated.append(
                "topApps: \(top.droppedRowCount) of \(top.totalRowCount) apps omitted "
                    + "(\(Int(top.droppedSeconds.rounded())) s)"
            )
        }
        if keptBuckets.count < allBuckets.count {
            truncated.append(
                "buckets: \(allBuckets.count - keptBuckets.count) of \(allBuckets.count) omitted"
            )
        }
        if keptExemplars.count < allExemplars.count {
            truncated.append(
                "exemplars: \(allExemplars.count - keptExemplars.count) of "
                    + "\(allExemplars.count) omitted"
            )
        }

        let totalSeconds = spans.reduce(0.0) { sum, span in
            let spanEnd = span.endedAt ?? span.lastSeenAt
            return sum + max(0, min(spanEnd, to) - max(span.startedAt, from))
        }

        return ActivityAnswerBundle(
            from: from,
            to: to,
            timezoneIdentifier: timezone.identifier,
            totalSeconds: totalSeconds,
            topApps: top,
            buckets: Array(keptBuckets),
            exemplars: keptExemplars,
            truncatedSections: truncated
        )
    }
}
