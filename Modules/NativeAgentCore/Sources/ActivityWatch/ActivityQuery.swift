import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ActivityQuery.swift` | `ActivityQueries.run`: gated activity reads, current-policy re-filtering, bounded rows and honest truncation |

/// The activity store's read path owns capture, exclusions, row caps and
/// refusals. Queries use only Calendar, SQL and arithmetic, with no inference.
public struct ActivityQueries: Sendable {
    /// Hard ceiling on rows in any answer, whatever the caller asks for.
    public static let maxRows = ActivityRollups.answerRowCap

    public enum QueryError: Error, CustomStringConvertible, Equatable {
        case captureDisabled
        case modelAccessDisabled
        case policyUnavailable(String)
        case remoteSurfaceRefused(surface: String)
        case badRange(String)

        public var description: String {
            switch self {
            case .captureDisabled:
                return """
                activity_capture_disabled: Activity capture is off. Only the owner can enable \
                Trust > Features > Activity capture > Record which apps you use. This action \
                cannot read history while capture is off; enabling cannot recover activity \
                from when it was off.
                """
            case .modelAccessDisabled:
                return "activity_model_access_disabled: This request has neither activity model access nor admitted Full Mac authority. Only the owner can enable Trust > Features > My access > Let me answer from activity history."
            case .policyUnavailable(let detail):
                return "activity_policy_unavailable: \(detail). Ask the owner to repair activity_watch/activity_policy.json from its retained bytes, preserving every saved choice; history access remains blocked until it is readable."
            case .remoteSurfaceRefused(let surface):
                return """
                activity_surface_denied: Activity history is refused on '\(surface)' without \
                admitted Full Mac authority. Ask in NativeAgent's Mac chat; activity model \
                access is also required there without Full Mac.
                """
            case .badRange(let detail):
                return "activity_range_invalid: \(detail)"
            }
        }
    }

    private let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    // MARK: - Surface gate

    /// Only these local surfaces may read history without admitted Full Mac.
    /// The dispatcher checks actual-origin Full Mac admission first.
    public static func isRefusedSurface(_ surface: String) -> Bool {
        let id = surface
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return !["chat", "mac", "observatory", "workshop", ""].contains(id)
    }

    // MARK: - The query

    public struct Request: Sendable, Equatable {
        public var from: Double
        public var to: Double
        public var bundleID: String?
        public var timezone: TimeZone
        public var rowCap: Int

        public init(
            from: Double, to: Double, bundleID: String? = nil,
            timezone: TimeZone = .current,
            rowCap: Int = ActivityQueries.maxRows
        ) {
            self.from = from
            self.to = to
            self.bundleID = bundleID
            self.timezone = timezone
            self.rowCap = rowCap
        }
    }

    /// Runs the query. Throws `.captureDisabled` when the Trust Center toggle
    /// is off — the tool must never answer from rows recorded before a user
    /// turned capture off, and must never imply it has data it does not have.
    public func run(_ request: Request, fullMacAdmitted: Bool = false) async throws -> JSONValue {
        let policy: ActivityPolicy
        do {
            policy = try ActivityPolicyStore(dataRoot: dataRoot).loadChecked()
        } catch {
            throw QueryError.policyUnavailable(error.localizedDescription)
        }
        guard policy.captureEnabled else { throw QueryError.captureDisabled }
        // The caller must obtain this per-call authority from TrustCenter,
        // including the actual origin. It does not alter capture or retention.
        guard policy.allowModelAccess || fullMacAdmitted else { throw QueryError.modelAccessDisabled }
        guard request.from.isFinite, request.to.isFinite, request.to > request.from else {
            throw QueryError.badRange("the end of the range must be after its start")
        }
        guard request.to - request.from <= Self.maximumRangeSeconds else {
            throw QueryError.badRange("the requested range is longer than 366 days; ask for a shorter range")
        }

        let store = try await ActivitySpanStore.acquire(dataRoot: dataRoot)!
        // Current exclusions also govern history recorded under older policies.
        let rollups = ActivityRollups(store: store, policy: policy)
        let bundle: ActivityAnswerBundle
        do {
            bundle = try await rollups.answerBundle(
                from: request.from,
                to: request.to,
                timezone: request.timezone,
                rowCap: min(max(3, request.rowCap), Self.maxRows),
                bundleID: request.bundleID
            )
        } catch let error as ActivityRollups.RollupError {
            throw QueryError.badRange(error.localizedDescription)
        }
        return Self.encode(bundle, bundleIDFilter: request.bundleID, policy: policy)
    }

    // MARK: - Encoding

    /// Turns the bundle into the tool result. Two things this does NOT do, both
    /// load-bearing:
    ///   * it never emits an unredacted title — the only title-ish field on a
    ///     span is `titleRedacted`, and it is emitted under a name that says so;
    ///   * it never invents a total. `total_seconds` is what the spans say.
    static func encode(
        _ bundle: ActivityAnswerBundle,
        bundleIDFilter: String?,
        policy: ActivityPolicy
    ) -> JSONValue {
        // Broken into named sub-expressions rather than one literal: the single
        // literal exceeded the type-checker's budget outright (it refused to
        // compile), and a nested `.object([...])` tree is exactly the shape
        // that does that.
        let topJSON: [JSONValue] = bundle.topApps.rows.map { row in
            var out: [String: JSONValue] = [:]
            out["bundle_id"] = .string(row.bundleId)
            out["app_name"] = .string(row.appName)
            out["seconds"] = .double(row.seconds)
            out["span_count"] = .int(Int64(row.spanCount))
            out["event_count"] = .int(Int64(row.eventCount))
            return .object(out)
        }
        let bucketJSON: [JSONValue] = bundle.buckets.map { bucket in
            var out: [String: JSONValue] = [:]
            out["start"] = .double(bucket.start)
            out["end"] = .double(bucket.end)
            out["bundle_id"] = .string(bucket.bundleId)
            out["app_name"] = .string(bucket.appName)
            out["seconds"] = .double(bucket.seconds)
            out["span_count"] = .int(Int64(bucket.spanCount))
            out["event_count"] = .double(bucket.eventCount)
            return .object(out)
        }
        let exemplarJSON: [JSONValue] = bundle.exemplars.map { span in
            var out: [String: JSONValue] = [:]
            out["started_at"] = .double(span.startedAt)
            out["ended_at"] = span.endedAt.map { JSONValue.double($0) } ?? .null
            out["bundle_id"] = .string(span.bundleId)
            out["app_name"] = .string(span.appName)
            // The ONLY title-ish field, named so nobody mistakes it for the raw
            // window title. Nil whenever titles are off, the app is a browser
            // without the browser opt-in, or app-name-only mode is set.
            let title = policy.allowsTitleCapture(bundleID: span.bundleId) ? span.titleRedacted : nil
            out["title_redacted"] = title.map { JSONValue.string($0) } ?? .null
            out["seconds"] = .double(span.duration)
            out["event_count"] = .int(Int64(span.eventCount))
            out["close_reason"] = span.closeReason.map { JSONValue.string($0.rawValue) } ?? .null
            return .object(out)
        }

        // What the answer could NOT contain, stated rather than implied.
        var limits: [String: JSONValue] = [:]
        let titlesOn = policy.captureTitles && !policy.appNameOnlyMode
        limits["titles_recorded"] = .bool(titlesOn)
        limits["browser_titles_recorded"] = .bool(titlesOn && policy.browserTitlesEnabled)
        limits["app_name_only_mode"] = .bool(policy.appNameOnlyMode)
        limits["excluded_app_count"] = .int(Int64(policy.effectiveExcludedBundleIDs.count))
        limits["retention_days"] = .int(Int64(policy.retentionDays))
        limits["note"] = .string(
            "Excluded apps are filtered on read as well as at capture time, so this "
            + "answer omits them even for days when they were still being recorded. "
            + "Window titles, where recorded, are secret-redacted only — redaction "
            + "catches shaped secrets such as tokens and codes, it does not make a "
            + "title private."
        )

        var out: [String: JSONValue] = [:]
        out["status"] = .string("ok")
        out["from"] = .double(bundle.from)
        out["to"] = .double(bundle.to)
        out["timezone"] = .string(bundle.timezoneIdentifier)
        out["total_seconds"] = .double(bundle.totalSeconds)
        out["bundle_id_filter"] = bundleIDFilter.map { JSONValue.string($0) } ?? .null
        out["top_apps"] = .array(topJSON)
        out["buckets"] = .array(bucketJSON)
        out["exemplars"] = .array(exemplarJSON)
        // HONEST TRUNCATION. Empty array means "this is the whole answer";
        // a non-empty one names every section that lost rows and why.
        out["truncated"] = .array(bundle.truncatedSections.map { JSONValue.string($0) })
        out["row_count"] = .int(Int64(topJSON.count + bucketJSON.count + exemplarJSON.count))
        out["row_cap"] = .int(Int64(Self.maxRows))
        out["recording_limits"] = .object(limits)
        return .object(out)
    }

    // MARK: - Range parsing

    /// Named ranges the tool accepts, resolved in the ASKING timezone.
    /// Deterministic `Calendar` arithmetic; no natural-language parsing, which
    /// is where a model call would otherwise sneak into a "zero LLM" feature.
    public static func resolveRange(
        named name: String, timezone: TimeZone, now: Date
    ) -> (from: Double, to: Double)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "today":
            guard let day = calendar.dateInterval(of: .day, for: now) else { return nil }
            return (day.start.timeIntervalSince1970, min(now.timeIntervalSince1970, day.end.timeIntervalSince1970))
        case "yesterday":
            guard let today = calendar.dateInterval(of: .day, for: now),
                  let yesterday = calendar.date(byAdding: .day, value: -1, to: today.start),
                  let day = calendar.dateInterval(of: .day, for: yesterday) else { return nil }
            return (day.start.timeIntervalSince1970, day.end.timeIntervalSince1970)
        case "last_hour", "past_hour":
            return (now.timeIntervalSince1970 - 3600, now.timeIntervalSince1970)
        case "last_24_hours", "past_24_hours":
            return (now.timeIntervalSince1970 - 86_400, now.timeIntervalSince1970)
        case "last_7_days", "past_week", "this_week":
            return (now.timeIntervalSince1970 - 7 * 86_400, now.timeIntervalSince1970)
        case "last_30_days", "past_month":
            return (now.timeIntervalSince1970 - 30 * 86_400, now.timeIntervalSince1970)
        default:
            return nil
        }
    }

    /// Epoch seconds, an ISO-8601 instant, or a bare `YYYY-MM-DD` (midnight in
    /// the asking timezone). Anything else is nil — the tool then says what it
    /// accepts rather than guessing at a date and answering about the wrong day.
    public static func parseInstant(_ value: String, timezone: TimeZone) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let epoch = Double(trimmed), epoch.isFinite,
           epoch >= minimumSupportedEpoch, epoch <= maximumSupportedEpoch { return epoch }

        if let date = NativeTimestampFormat.parseISO8601FractionalFirst(trimmed) { return date.timeIntervalSince1970 }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timezone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.isLenient = false
        if let date = dayFormatter.date(from: trimmed) { return date.timeIntervalSince1970 }
        return nil
    }

    public static let maximumRangeSeconds: Double = 366 * 86_400
    private static let minimumSupportedEpoch: Double = 0
    private static let maximumSupportedEpoch: Double = 32_503_680_000 // 3000-01-01 UTC
}
