import AuthoredCapabilities
import AgentWorkspace
import Foundation
import TurnTrace
import Experiences
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
import Senses
import ToolRegistry
import ActivityWatch
import ChatTurnContracts
import NativeAgentShared
// Blueprint: | `SwiftToolDispatcher+ActivityQuery.swift` | `SwiftToolDispatcher`: activity-query discovery, argument parsing and named failures; capture policy and actual-origin authority admit bounded local history answers |

extension SwiftToolDispatcher {
    /// Discover activity queries only when capture is on and agent access is
    /// granted directly or by Full Mac. Dispatch rechecks actual-origin authority.
    func activityCaptureEnabled() async -> Bool {
        guard let policy = try? ActivityPolicyStore(dataRoot: dataRoot).loadChecked() else {
            return false
        }
        guard policy.captureEnabled else { return false }
        if policy.allowModelAccess { return true }
        return await fullMacYoloAdmitted(surface: "chat")
    }

    private func activityQueryFailure(_ error: ActivityQueries.QueryError, argumentPath: String = "$") -> ToolFailureError {
        let file = ActivityWatchPaths.policyURL(dataRoot: dataRoot)
        switch error {
        case .captureDisabled:
            return ToolFailureError(error.description, effects: .none, owner: file.path,
                tap: "Trust > Features > Activity capture > Record which apps you use", personDecides: true,
                code: "activity_capture_disabled", status: .refused,
                instruction: "Only the owner can enable activity capture; enabling cannot recover activity from while it was off.")
        case .modelAccessDisabled:
            return ToolFailureError(error.description, effects: .none, owner: file.path,
                tap: "Trust > Features > My access > Let me answer from activity history", personDecides: true,
                code: "activity_model_access_disabled", status: .refused,
                instruction: "Only the owner can enable activity model access.")
        case .remoteSurfaceRefused:
            return ToolFailureError(error.description, effects: .none, owner: "Full Mac authority for this request",
                tap: "NativeAgent > Chat", personDecides: true, code: "activity_surface_denied", status: .refused,
                instruction: "Ask in NativeAgent's Mac chat; activity model access is required there without admitted Full Mac.")
        case .policyUnavailable:
            return ToolFailureError(error.description, effects: .none, owner: file.path,
                tap: "Finder > Go > Go to Folder > \(file.deletingLastPathComponent().path) > activity_policy.json > Open With > TextEdit",
                code: "activity_policy_unavailable",
                instruction: "Ask the owner to preserve the original bytes and repair this policy without changing saved choices.")
        case .badRange:
            return ToolFailureError(error.description + " Correct \(argumentPath).", argumentPath: argumentPath,
                accepted: "A timezone recognized by macOS and a supported range, or finite from/to instants with from < to and at most 366 days between them.",
                effects: .none, code: "activity_range_invalid",
                instruction: "Correct the named argument before asking for activity history.", recovery: .correctArguments)
        }
    }

    /// The read path into the local activity store: authenticated Full Mac or
    /// local model-access opt-in admits bounded answers; capture off, malformed
    /// policies and unparseable ranges refuse. Parsing and SQL make no model
    /// calls, and answers enter neither cognition nor memory promotion.
    func impl_activity_query_tool(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        guard tool == "activity_query" else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' has no Swift activity-query implementation"
            )
        }
        let fullMacAdmitted = await fullMacYoloAdmitted(surface: surface)
        guard fullMacAdmitted || !ActivityQueries.isRefusedSurface(surface) else {
            throw activityQueryFailure(.remoteSurfaceRefused(surface: surface))
        }

        func stringArg(_ key: String) -> String? {
            guard case .string(let value)? = input[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func intArg(_ key: String) -> Int? {
            switch input[key] {
            case .int(let value): return Int(value)
            case .double(let value): return Int(exactly: value.rounded(.towardZero))
            case .string(let value): return Int(value)
            default: return nil
            }
        }

        let timezone: TimeZone
        if let requestedTimezone = stringArg("timezone") {
            guard let resolved = TimeZone(identifier: requestedTimezone) else {
                throw activityQueryFailure(.badRange(
                        "unknown IANA timezone \"\(requestedTimezone)\""
                    ), argumentPath: "$.timezone")
            }
            timezone = resolved
        } else {
            timezone = .current
        }
        let now = Date()

        let range: (from: Double, to: Double)
        if let fromRaw = stringArg("from") ?? intArg("from").map(String.init) {
            guard let from = ActivityQueries.parseInstant(fromRaw, timezone: timezone) else {
                throw activityQueryFailure(.badRange(
                        "could not read `from` = \"\(fromRaw)\". Accepted: epoch seconds, "
                        + "an ISO-8601 instant, or YYYY-MM-DD."
                    ), argumentPath: "$.from")
            }
            let toRaw = stringArg("to") ?? intArg("to").map(String.init)
            let to: Double
            if let toRaw {
                guard let parsed = ActivityQueries.parseInstant(toRaw, timezone: timezone) else {
                    throw activityQueryFailure(.badRange(
                            "could not read `to` = \"\(toRaw)\". Accepted: epoch seconds, "
                            + "an ISO-8601 instant, or YYYY-MM-DD."
                        ), argumentPath: "$.to")
                }
                to = parsed
            } else {
                to = now.timeIntervalSince1970
            }
            range = (from, to)
        } else {
            let name = stringArg("range") ?? "today"
            guard let resolved = ActivityQueries.resolveRange(
                named: name, timezone: timezone, now: now
            ) else {
                throw activityQueryFailure(.badRange(
                        "unknown range \"\(name)\". Accepted: today, yesterday, last_hour, "
                        + "last_24_hours, last_7_days, last_30_days — or pass explicit "
                        + "`from`/`to`."
                    ), argumentPath: "$.range")
            }
            range = resolved
        }

        let service = ActivityQueries(dataRoot: dataRoot)
        do {
            return try await service.run(ActivityQueries.Request(
                from: range.from,
                to: range.to,
                bundleID: stringArg("bundle_id"),
                timezone: timezone,
                rowCap: intArg("limit") ?? ActivityQueries.maxRows
            ), fullMacAdmitted: fullMacAdmitted)
        } catch let error as ActivityQueries.QueryError {
            // Surfaced as a tool denial, not a crash and not an empty answer:
            // "capture is off" must never look like "you did nothing today".
            throw activityQueryFailure(error)
        }
    }
}
