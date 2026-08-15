import Foundation
import PersistenceCore

/// W7 — the ONLY read path into the activity store.
///
/// Deliberately a plain value type in THIS module rather than logic living in
/// the dispatcher: the tool impl in ChatOrchestration is a thin adapter that
/// hands over a dictionary and gets a `JSONValue` back, so every rule that
/// matters (the capture gate, the query-time exclusion re-filter, the row cap,
/// the honest truncation, the refusal text) is testable headlessly without a
/// chat turn, a model, or a dispatcher.
///
/// ZERO INFERENCE. Everything below is `Calendar`, SQL and arithmetic. There is
/// no summarizer, no embedding, no model call — see
/// `ActivityWatchArchitectureTests.noInferenceInTheWatcher`, which greps this
/// module for the ways one could arrive.
public struct ActivityQueryService: Sendable {
    /// Hard ceiling on rows in ANY answer, whatever the caller asks for. The
    /// build plan's acceptance criterion, as a constant.
    public static let maxRows = ActivityRollups.answerRowCap

    public enum QueryError: Error, CustomStringConvertible, Equatable {
        case captureDisabled
        case remoteSurfaceRefused(surface: String)
        case badRange(String)

        public var description: String {
            switch self {
            case .captureDisabled:
                return """
                Activity capture is turned OFF, so there is nothing recorded to answer from. \
                Turn it on in Trust Center → Activity Capture. Nothing was recorded while it \
                was off, so enabling it now starts from this moment — it cannot answer about \
                the past.
                """
            case .remoteSurfaceRefused(let surface):
                return """
                activity_query is Mac-local and is refused on the '\(surface)' surface by \
                design. Activity data never leaves this Mac: answering here would put it \
                through the iCloud/chat-sync path the feature exists to avoid. Ask on the Mac.
                """
            case .badRange(let detail):
                return "activity_query: \(detail)"
            }
        }
    }

    private let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    // MARK: - Surface gate (W7 decision: the bridge REFUSES, it does not 404)

    /// Mac-local only. The build plan (W7, gpt-5.5 BLOCKING B2) settled this:
    /// routing the tool through the iOS/HTTP bridge means activity data can be
    /// pulled from the phone and the answer traverses iCloud/chat-sync — which
    /// breaks "everything stays on the Mac". The refusal is EXPLICIT rather
    /// than a silent 404 so a future reader sees a decision, not an omission,
    /// and so User can lift it in one line if he ever wants phone access.
    public static func isRefusedSurface(_ surface: String) -> Bool {
        ConversationSurfaceProfileShim(surface).isRemote
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
            rowCap: Int = ActivityQueryService.maxRows
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
    public func run(_ request: Request) async throws -> JSONValue {
        let policy = ActivityPolicyStore(dataRoot: dataRoot).load()
        guard policy.captureEnabled else { throw QueryError.captureDisabled }
        guard request.to > request.from else {
            throw QueryError.badRange("the end of the range must be after its start")
        }

        let store = try ActivitySpanStore(dataRoot: dataRoot)
        // W5 LAYER 2 — query-time exclusion. The policy is passed to the store,
        // which re-filters on read, because exclusion lists change: adding
        // 1Password today must make yesterday unanswerable even for rows that
        // were legal when written.
        let rollups = ActivityRollups(store: store, policy: policy)
        let bundle = try await rollups.answerBundle(
            from: request.from,
            to: request.to,
            timezone: request.timezone,
            rowCap: min(max(3, request.rowCap), Self.maxRows)
        )
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
        var topRows = bundle.topApps.rows
        var buckets = bundle.buckets
        var exemplars = bundle.exemplars
        var truncated = bundle.truncatedSections

        if let filter = bundleIDFilter, !filter.isEmpty {
            topRows = topRows.filter { $0.bundleId == filter }
            buckets = buckets.filter { $0.bundleId == filter }
            exemplars = exemplars.filter { $0.bundleId == filter }
        }

        // The cap is enforced HERE as well as inside answerBundle, because the
        // caller can lower it and because a future section would otherwise
        // slip past the one check. Anything dropped is named.
        let rowTotal = topRows.count + buckets.count + exemplars.count
        if rowTotal > Self.maxRows {
            let overflow = rowTotal - Self.maxRows
            let trimmed = min(overflow, buckets.count)
            buckets = Array(buckets.prefix(buckets.count - trimmed))
            truncated.append("buckets: \(trimmed) further rows dropped by the \(Self.maxRows)-row answer cap")
        }

        // Broken into named sub-expressions rather than one literal: the single
        // literal exceeded the type-checker's budget outright (it refused to
        // compile), and a nested `.object([...])` tree is exactly the shape
        // that does that.
        let topJSON: [JSONValue] = topRows.map { row in
            var out: [String: JSONValue] = [:]
            out["bundle_id"] = .string(row.bundleId)
            out["app_name"] = .string(row.appName)
            out["seconds"] = .double(row.seconds)
            out["span_count"] = .int(Int64(row.spanCount))
            out["event_count"] = .int(Int64(row.eventCount))
            return .object(out)
        }
        let bucketJSON: [JSONValue] = buckets.map { bucket in
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
        let exemplarJSON: [JSONValue] = exemplars.map { span in
            var out: [String: JSONValue] = [:]
            out["started_at"] = .double(span.startedAt)
            out["ended_at"] = span.endedAt.map { JSONValue.double($0) } ?? .null
            out["bundle_id"] = .string(span.bundleId)
            out["app_name"] = .string(span.appName)
            // The ONLY title-ish field, named so nobody mistakes it for the raw
            // window title. Nil whenever titles are off, the app is a browser
            // without the browser opt-in, or app-name-only mode is set.
            out["title_redacted"] = span.titleRedacted.map { JSONValue.string($0) } ?? .null
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
        out["truncated"] = .array(truncated.map { JSONValue.string($0) })
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
        if let epoch = Double(trimmed), epoch > 1_000_000_000 { return epoch }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date.timeIntervalSince1970 }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date.timeIntervalSince1970 }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timezone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dayFormatter.date(from: trimmed) { return date.timeIntervalSince1970 }
        return nil
    }
}

/// Local mirror of `TrustCenter.ConversationSurfaceProfile`'s remote set.
///
/// It is COPIED rather than imported on purpose: importing TrustCenter here
/// would give the watcher module a dependency on the policy layer, and this
/// module's whole architectural argument is that it depends on as little as
/// possible and is depended on by nothing. `ActivityWatchArchitectureTests`
/// pins the two sets equal, so the copy cannot drift into being narrower than
/// the real one (which is the direction that would leak).
struct ConversationSurfaceProfileShim {
    let id: String

    init(_ rawValue: String) {
        self.id = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    /// FAIL CLOSED (gpt-5.5 BLOCKING, 2026-08-14).
    ///
    /// This was a denylist — a set of surfaces to refuse, with everything else
    /// treated as local. That is fail-OPEN, and it had already failed open: the
    /// app's own local HTTP bridges (`claude-bridge`, `codex-bridge`) were in
    /// nobody's denylist, so `POST /claude/tool {name: "activity_query"}`
    /// returned activity rows over HTTP while the guard reported success.
    ///
    /// A denylist is the wrong shape for this decision. The set of surfaces that
    /// may read where the human has been is small, closed, and known; the set of
    /// ways a future transport might reach the dispatcher is neither. So the
    /// question is inverted: name the surfaces allowed to answer, and refuse
    /// everything else — including surfaces that do not exist yet, which is
    /// precisely the class that produced this bug.
    var isRemote: Bool { !Self.localSurfaceIDs.contains(id) }

    /// The ONLY surfaces that may answer `activity_query`: the Mac app's own
    /// chat, and the in-process paths that are the same window on the same
    /// machine. Anything else — Telegram, Slack, iOS, iCloud, the HTTP bridges,
    /// and anything added later — is refused by default.
    static let localSurfaceIDs: Set<String> = [
        "chat",           // the Mac app's chat window
        "mac",            // in-process Mac surface
        "observatory",    // local inspector UI
        "workshop",       // local workshop execution
        "",               // unset/in-process default
    ]
}
