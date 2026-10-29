import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import MapKit
import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import ToolRegistry
import Desk
import ToolExecution
import Studio
import Senses
import Research
import TurnTrace
// Blueprint: | `SwiftToolDispatcher+MacIntegration.swift` | `SwiftToolDispatcher`: one Mac integration invocation selected by `MacIntegrationGates.byTool`, with Mail binding before admission, backend execution after admission and result observations afterward; due-reminders carries the dispatcher's data root; read-only MapKit routes with every step, segment-distance meaning and explicit no-traffic timing; radius-bounded place search splits inline near/in/around locations and reports the split; distance-fraction lookup shares place/describe |

extension SwiftToolDispatcher {
    @MainActor
    private func place(_ text: String) async throws -> sending MKMapItem {
        try Task.checkCancellation()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
            throw AutonomyGateError.toolDenied(reason: "No map location matched '\(text)'. Use a more specific address or place name.")
        }
        return item
    }

    @MainActor
    private func describe(_ item: MKMapItem) -> [String: JSONValue] {
        ["name": item.name.map(JSONValue.string) ?? .null,
            "address": item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true).map(JSONValue.string) ?? .null,
            "latitude": .double(item.location.coordinate.latitude), "longitude": .double(item.location.coordinate.longitude),
            // Arrival times can cross time zones.
            "time_zone": item.timeZone.map { .string($0.identifier) } ?? .null]
    }

    @MainActor
    func impl_maps_search(input: [String: JSONValue]) async throws -> JSONValue {
        let originalQuery = try requireString(input, "query").trimmingCharacters(in: .whitespacesAndNewlines)
        var query = originalQuery
        var near: String
        switch input["near"] {
        case nil, .null?: near = ""
        case .string(let value)?: near = value.trimmingCharacters(in: .whitespacesAndNewlines)
        default: throw AutonomyGateError.toolDenied(reason: "near must be a place name or address.")
        }
        var querySplit: JSONValue = .null
        if near.isEmpty, let separator = query.range(of: #"\s+(near|in|around)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let separatorWord = String(query[separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            near = String(query[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            query = String(query[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            querySplit = .object(["original_query": .string(originalQuery), "query": .string(query), "near": .string(near),
                "separator": .string(separatorWord),
                "note": .string("Split the query at its first near/in/around because no separate near was supplied.")])
        }
        guard !query.isEmpty, !near.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "Place search needs search terms and a place: supply near or include it in query, for example 'coffee near Tampa airport'. Include city/region to disambiguate.")
        }
        let radius: Double
        switch input["radius_miles"] {
        case nil, .null?: radius = 25
        case .double(let value)?: radius = value
        case .int(let value)?: radius = Double(value)
        default: throw AutonomyGateError.toolDenied(reason: "radius_miles must be a positive number; capped at 100 miles.")
        }
        guard radius.isFinite, radius > 0 else {
            throw AutonomyGateError.toolDenied(reason: "radius_miles must be a positive number; capped at 100 miles.")
        }
        let limit: Int64
        switch input["limit"] {
        case nil, .null?: limit = 8
        case .int(let value)? where value > 0: limit = min(value, 20)
        case .double(let value)? where value.isFinite && value > 0 && value.rounded() == value: limit = Int64(min(value, 20))
        default: throw AutonomyGateError.toolDenied(reason: "limit must be a positive integer; capped at 20 places.")
        }
        let center = try await place(near), radiusMiles = min(radius, 100), radiusMeters = radiusMiles * 1609.344
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center.location.coordinate,
            latitudinalMeters: radiusMeters * 2, longitudinalMeters: radiusMeters * 2)
        request.regionPriority = .required
        try Task.checkCancellation()
        let items: [MKMapItem]
        do { items = try await MKLocalSearch(request: request).start().mapItems }
        catch let error as MKError where error.code == .placemarkNotFound { items = [] }
        let matches = items.map { ($0, $0.location.distance(from: center.location)) }
            .filter { $0.1 <= radiusMeters }.sorted { $0.1 < $1.1 }
        let miles = Locale.autoupdatingCurrent.measurementSystem != .metric
        let rows: [JSONValue] = matches.prefix(Int(limit)).map { item, distance in
            var row = describe(item)
            row["phone"] = item.phoneNumber.map(JSONValue.string) ?? .null
            row["url"] = item.url.map { .string($0.absoluteString) } ?? .null
            row["category"] = item.pointOfInterestCategory.map { .string($0.rawValue) } ?? .null
            row["distance"] = .double(distance / (miles ? 1609.344 : 1000))
            return .object(row)
        }
        try Task.checkCancellation()
        return .object(["status": .string("completed"), "source": .string("MapKit"),
            "query": .string(query), "query_split": querySplit, "near": .object(describe(center)), "radius_miles": .double(radiusMiles),
            "distance_unit": .string(miles ? "miles" : "km"), "distance_basis": .string("Straight-line distance from the resolved near location, not route distance."),
            "places": .array(rows), "returned_count": .int(Int64(rows.count)),
            "message": .string(rows.isEmpty ? "MapKit returned no matching places within \(radiusMiles) miles of the resolved near location." : "Matching places within the radius, sorted by straight-line distance; MapKit results may not include every place.")])
    }

    @MainActor
    func impl_maps_route(input: [String: JSONValue]) async throws -> JSONValue {
        let origin = try requireString(input, "origin").trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = try requireString(input, "destination").trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = optionalString(input, "transport") ?? "automobile"
        guard !origin.isEmpty, !destination.isEmpty, ["automobile", "walking"].contains(transport) else {
            throw AutonomyGateError.toolDenied(reason: "Route needs origin and destination text, and transport automobile or walking.")
        }
        let fraction: Double?
        switch input["fraction"] {
        case nil, .null?: fraction = nil
        case .double(let value)?: fraction = value
        case .int(let value)?: fraction = Double(value)
        default: throw AutonomyGateError.toolDenied(reason: "fraction must be a number from 0 through 1, measured along the route distance.")
        }
        if let fraction, !fraction.isFinite || !(0...1).contains(fraction) {
            throw AutonomyGateError.toolDenied(reason: "fraction must be a number from 0 through 1, measured along the route distance.")
        }
        async let originPlace = place(origin)
        async let destinationPlace = place(destination)
        let source = try await originPlace
        let target = try await destinationPlace
        let request = MKDirections.Request()
        request.source = source; request.destination = target
        request.transportType = transport == "walking" ? .walking : .automobile
        try Task.checkCancellation()
        let response: MKDirections.Response
        do { response = try await MKDirections(request: request).calculate() }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw ToolFailureError("MapKit returned no route: \(error.localizedDescription)", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("maps.route"), "args": .object(input)]))
        }
        guard let route = response.routes.first else {
            throw ToolFailureError("MapKit returned no route for these locations and transport.", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("maps.route"), "args": .object(input)]))
        }
        let steps = route.steps.enumerated()
        var result: [String: JSONValue] = ["status": .string("completed"), "source": .string("MapKit"),
            "origin": .object(describe(source)), "destination": .object(describe(target)), "transport": .string(transport),
            "route_name": .string(route.name), "distance_meters": .double(route.distance),
            "expected_travel_time_seconds": .double(route.expectedTravelTime),
            "traffic": .string("not_included"),
            "travel_time_basis": .string("MKRoute.expectedTravelTime estimates travel under ideal conditions, without live traffic. No traffic-aware ETA was requested."),
            "step_distance_basis": .string("Each distance_meters is the route segment associated with that step, not the length of the turn or exit manoeuvre itself."),
            "steps": .array(steps.map { .object(["index": .int(Int64($0.offset)), "instruction": .string($0.element.instructions), "distance_meters": .double($0.element.distance)]) }),
            "total_steps": .int(Int64(route.steps.count)), "steps_total": .int(Int64(route.steps.count)), "has_more": .bool(false)]
        if let fraction {
            let points = route.polyline.points(), count = route.polyline.pointCount
            guard count > 1 else { throw AutonomyGateError.toolDenied(reason: "The route has no usable geometry for a fractional point.") }
            let lengths = (1..<count).map { points[$0 - 1].distance(to: points[$0]) }
            var remaining = lengths.reduce(0, +) * fraction
            var point = points[count - 1]
            for index in 1..<count {
                let length = lengths[index - 1]
                if remaining <= length, length > 0 {
                    let ratio = remaining / length
                    point = MKMapPoint(x: points[index - 1].x + (points[index].x - points[index - 1].x) * ratio,
                        y: points[index - 1].y + (points[index].y - points[index - 1].y) * ratio)
                    break
                }
                remaining -= length
            }
            try Task.checkCancellation()
            guard let geocoder = MKReverseGeocodingRequest(location: CLLocation(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)),
                  let place = try await geocoder.mapItems.first else {
                throw AutonomyGateError.toolDenied(reason: "MapKit could not name the requested point along this route.")
            }
            result["point"] = .object(["fraction": .double(fraction), "latitude": .double(point.coordinate.latitude),
                "longitude": .double(point.coordinate.longitude), "place": .object(describe(place)),
                "basis": .string("Fraction of route distance, not travel time; reverse-geocoded place is near the route point.")])
        }
        try Task.checkCancellation()
        return .object(result)
    }

    // MARK: - Mac integration dispatch

    /// The refusal a switch User turned off gives this tool, whatever the
    /// posture: asked here at dispatch, and by the approval gate before any
    /// card, so a card never asks for what the switch would refuse.
    package static func switchRefusal(integration: String, mode: MacIntegrationPermissionMode,
                                      store: MacIntegrationPermissionStore) async throws -> JSONValue? {
        guard let refusal = try await store.readinessChecked().refusal(integration: integration, mode: mode) else { return nil }
        return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("denied"), "reason": .string("operator_permission_off"),
            "integration": .string(integration), "mode": .string(mode.rawValue), "message": .string(refusal),
            "remedy": Repair.why(owner: "security/mac_integration_permissions.json \(integration).\(mode.rawValue)",
                tap: "Trust > Mac > Apps and features > \(MacIntegrationID.displayName(for: integration)) > \(mode.rawValue.capitalized)",
                instruction: "Only the owner can enable this switch.")]))
    }

    package static func macIntegrationDeniedEnvelope(
        integration: String, mode: MacIntegrationPermissionMode, store: MacIntegrationPermissionStore
    ) async throws -> JSONValue {
        if let refusal = try await switchRefusal(integration: integration, mode: mode, store: store) {
            return refusal
        }
        let fixHint = "Open Trust → Mac → \(MacIntegrationID.displayName(for: integration)) and enable \(mode.rawValue.capitalized)."
        // Ask only for the axis the blocked call needs.
        if let need = InlineInteractionRegistry.permission(
            [integration], why: fixHint, mode: mode == .read ? .read : .write
        ) {
            return InlineInteractionNeed.envelope(need)
        }
        return ChatToolOutcome.refusedBeforeRunning(.object([
            "status": .string("denied"),
            "reason": .string("integration_permission_denied"),
            "integration": .string(integration),
            "mode": .string(mode.rawValue),
            "fix": .string(fixHint),
            "remedy": Repair.why(owner: "security/mac_integration_permissions.json \(integration).\(mode.rawValue)",
                tap: "Trust > Mac > Apps and features > \(MacIntegrationID.displayName(for: integration)) > \(mode.rawValue.capitalized)",
                instruction: "Ask the owner to enable this integration's \(mode.rawValue.capitalized) switch."),
        ]))
    }

    func dispatchMacIntegrationTool(
        tool: String,
        surface: String,
        input: [String: JSONValue]
    ) async throws -> JSONValue {
        // Bind observed Mail identities before admission, without executing a backend.
        let input = ["mail_save_attachment", "mail_read_batch", "mail_triage_batch"].contains(tool)
            ? AgentWorkspace.bindMail(input, dataRoot: dataRoot) : input
        guard let (integration, mode) = MacIntegrationGates.byTool[tool] else {
            throw ToolFailureError("Mac integration tool has no permission declaration: \(tool)", effects: .none)
        }
        let admitted = await fullMacYoloAdmitted(surface: surface)
        let allowed = await macIntegrationPermissionStore.allows(integration, mode: mode, fullMacAdmitted: admitted)
        guard allowed else {
            return try await Self.macIntegrationDeniedEnvelope(integration: integration, mode: mode, store: macIntegrationPermissionStore)
        }
        guard let bridge = macIntegrationBridge else {
            return ChatToolOutcome.refusedBeforeRunning(.object([
                "status": .string("failed"),
                "reason": .string("bridge_not_wired"),
                "integration": .string(integration),
                "message": .string("Mac integration is unavailable in this caller. Call app from the installed app's chat tool chain; supplying a session id cannot attach it."),
                "remedy": .object(["kind": .string("correct_arguments"),
                    "instruction": .string("Call app from the installed app's chat tool chain."), "next_call": .null]),
            ]))
        }
        let result: JSONValue
        switch tool {
        case "mac_calendar_list_upcoming":
            result = HerScreen.notedLifeRead("calendar", try await bridge.calendarListUpcoming(input: input), dataRoot: dataRoot)
        case "mac_calendar_calendars": result = try await bridge.calendarCalendars(input: input)
        case "mac_calendar_free_busy": result = try await bridge.calendarFreeBusy(input: input)
        case "mac_calendar_create_event": result = try await bridge.calendarCreateEvent(input: input)
        case "mac_calendar_modify_event": result = try await bridge.calendarModifyEvent(input: input)
        case "mac_calendar_delete_event": result = try await bridge.calendarDeleteEvent(input: input)
        case "mac_reminders_lists": result = try await bridge.remindersLists(input: input)
        case "mac_reminders_query": result = try await bridge.remindersQuery(input: input)
        case "mac_reminders_read": result = try await bridge.remindersRead(input: input)
        case "mac_reminders_update": result = try await bridge.remindersUpdate(input: input)
        case "mac_reminders_list_due_today":
            result = HerScreen.notedLifeRead("reminders", try await bridge.remindersListDueToday(input: input, dataRoot: dataRoot), dataRoot: dataRoot)
        case "mac_reminders_create": result = try await bridge.remindersCreate(input: input)
        case "mac_reminders_list_rename": result = try await bridge.remindersListRename(input: input)
        case "mac_reminders_list_create": result = try await bridge.remindersListCreate(input: input)
        case "mac_reminders_complete": result = try await bridge.remindersComplete(input: input)
        case "mac_reminders_delete": result = try await bridge.remindersDelete(input: input)
        case "mac_notify": result = try await bridge.macNotify(input: input)
        case "phone_request": result = try await bridge.phoneRequest(input: input)
        case "mobile_notify": result = try await bridge.mobileNotify(input: input, surface: surface)
        case "mac_spotlight_search": result = try await bridge.spotlightSearch(input: input)
        case "contacts_search": result = try await bridge.contactsSearch(input: input)
        case "contacts_create_or_update": result = try await bridge.contactsCreateOrUpdate(input: input)
        case "contacts_delete": result = try await bridge.contactsDelete(input: input)
        case "mail_save_attachment":
            if let error = input["binding_error"] { return .object(["status": .string("failed"), "message": error]) }
            let attachment = try await bridge.mailAttachment(input: input)
            var fileInput = input
            fileInput["path"] = input["destination"] ?? .string("~/Downloads")
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return try await impl_local_connector_tool(tool: tool, input: fileInput, surface: surface, attachment: attachment)
            }
            return try await impl_trusted_file_mutation(tool: tool, input: fileInput, attachment: attachment)
        case "mail_list_recent": result = try await bridge.mailListRecent(input: input)
        case "mail_read_batch": result = try await bridge.mailReadBatch(input: input)
        case "mail_triage_batch": result = try await bridge.mailTriageBatch(input: input)
        case "mail_search": result = try await bridge.mailSearch(input: input)
        case "mail_senders": result = try await bridge.mailSenders(input: input)
        case "mail_send": result = try await bridge.mailSend(input: input)
        case "mail_mark_read": result = try await bridge.mailMarkRead(input: input)
        case "mail_archive": result = try await bridge.mailArchive(input: input)
        case "mail_delete": result = try await bridge.mailDelete(input: input)
        case "mail_reply": result = try await bridge.mailReply(input: input)
        case "mail_draft": result = try await bridge.mailDraft(input: input)
        case "messages_recent_threads": result = try await bridge.messagesRecentThreads(input: input)
        case "messages_send": result = try await bridge.messagesSend(input: input)
        case "notes_search": result = try await bridge.notesSearch(input: input)
        case "notes_create": result = try await bridge.notesCreate(input: input)
        case "notes_update", "notes_delete": result = try await bridge.notesModify(input: input, deleting: tool == "notes_delete")
        case "music_now_playing": result = try await bridge.musicNowPlaying(input: input)
        case "music_control": result = try await bridge.musicControl(input: input)
        case "music_search_library": result = try await bridge.musicSearchLibrary(input: input)
        case "music_list_library": result = try await bridge.musicListLibrary(input: input)
        case "music_list_playlists": result = try await bridge.musicListPlaylists(input: input)
        // Scheduler has no read axis; every scheduler action gates on write.
        case "scheduler_list_jobs": result = try await bridge.schedulerListJobs(input: input)
        case "scheduler_create_job": result = try await bridge.schedulerCreateJob(input: input)
        case "scheduler_cancel_job": result = try await bridge.schedulerCancelJob(input: input)
        case "scheduler_pause_job", "scheduler_resume_job":
            result = try await bridge.schedulerSetJobEnabled(input: input, enabled: tool == "scheduler_resume_job")
        case "scheduler_update_job": result = try await bridge.schedulerUpdateJob(input: input)
        default: throw ToolFailureError("Mac integration tool has no backend: \(tool)", effects: .none)
        }
        if ["mail_list_recent", "mail_search", "mail_senders"].contains(tool) {
            HerReadBadges.shared.note(result, dataRoot: dataRoot)
            return AgentWorkspace.attachReadReferences(tool: tool, input: input, result: result, dataRoot: dataRoot)
        }
        if integration == MacIntegrationID.messages, case .object(var fields) = result,
           fields["reason"] == .string("database_unavailable") || fields["history_reason"] == .string("database_unavailable") {
            fields["remedy"] = SystemPermissionPreflight.remedy("full_disk_access")
            return .object(fields)
        }
        return result
    }
}
