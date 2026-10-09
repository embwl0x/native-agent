import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import MapKit

extension SwiftToolDispatcher {
    @MainActor
    private func place(_ text: String) async throws -> MKMapItem {
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
            // Arrival times cross zones (10-08: Eastern departure, Central arrival).
            "time_zone": item.timeZone.map { .string($0.identifier) } ?? .null]
    }

    @MainActor
    func impl_maps_search(input: [String: JSONValue]) async throws -> JSONValue {
        let query = try requireString(input, "query").trimmingCharacters(in: .whitespacesAndNewlines)
        let near = try requireString(input, "near").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !near.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "Place search needs query and near text; include city/region to disambiguate.")
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
            "query": .string(query), "near": .object(describe(center)), "radius_miles": .double(radiusMiles),
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
        let source = try await place(origin), target = try await place(destination)
        let request = MKDirections.Request()
        request.source = source; request.destination = target
        request.transportType = transport == "walking" ? .walking : .automobile
        try Task.checkCancellation()
        // Server, throttling and "Directions Not Available" (seen to clear on an identical second request) get one retry; the first cause is reported.
        func calculate() async throws -> MKDirections.Response { try await MKDirections(request: request).calculate() }
        let response: MKDirections.Response
        do { response = try await calculate() } catch is CancellationError { throw CancellationError() } catch {
            let first = "MapKit returned no route: \(error.localizedDescription)"
            guard let code = (error as? MKError)?.code, [.serverFailure, .loadingThrottled, .directionsNotFound].contains(code) else {
                throw AutonomyGateError.toolDenied(reason: first)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            do { response = try await calculate() } catch {
                throw AutonomyGateError.toolDenied(reason: first + " (one retry also failed)")
            }
        }
        guard let route = response.routes.first else {
            throw AutonomyGateError.toolDenied(reason: "MapKit returned no route for these locations and transport.")
        }
        let steps = route.steps.enumerated().filter { !$0.element.instructions.isEmpty }
            .sorted { $0.element.distance > $1.element.distance }.prefix(5).sorted { $0.offset < $1.offset }
        var result: [String: JSONValue] = ["status": .string("completed"), "source": .string("MapKit"),
            "origin": .object(describe(source)), "destination": .object(describe(target)), "transport": .string(transport),
            "route_name": .string(route.name), "distance_meters": .double(route.distance),
            "expected_travel_time_seconds": .double(route.expectedTravelTime),
            "steps": .array(steps.map { .object(["index": .int(Int64($0.offset)), "instruction": .string($0.element.instructions), "distance_meters": .double($0.element.distance)]) }),
            "total_steps": .int(Int64(route.steps.count))]
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

    func sendInstructionRefusal(tool: String, input: [String: JSONValue]) -> JSONValue? {
        guard let text = ChatToolSessionContext.userText, ChatToolSessionContext.forbidsSending(text),
              SwiftNativeSecurityCenter.sendsExternally(tool: tool, input: input, dataRoot: dataRoot) else { return nil }
        let mail = ["mail_send", "mail_reply"].contains(tool)
        let args = mail ? input.filter { ["to", "subject", "body", "cc", "bcc", "message_id", "expected_message_id", "expected_account", "position", "sender", "reply_all"].contains($0.key) }
            : ["value": input["body"] ?? input["message"] ?? input["text"] ?? input["value"] ?? .string("")]
        let call = JSONValue.object(["action": .string(mail ? "mail.draft" : "chat.draft"), "args": .object(args)])
        do {
            return .object(["status": .string("refused"), "effects": .string("none"), "reason": .string("user_requested_no_send"),
                "message": .string("You were asked not to send. Save it as a draft instead: \(try call.serialize(pretty: false))."),
                "draft_call": call])
        } catch {
            return .object(["status": .string("refused"), "effects": .string("none"),
                "message": .string("You were asked not to send. Draft arguments could not be encoded: \(error.localizedDescription)")])
        }
    }

    // MARK: - Mac integration dispatch helper
    //
    // Shared shape for Mac integration tools:
    //   1. Check saved authority and actual-origin Full Mac admission. Admitted
    //      Full Mac covers supported integrations without changing preferences;
    //      lower modes retain the ordinary per-integration permission request.
    //   2. If the bridge isn't wired (headless / app forgot to inject),
    //      return a `bridge_not_wired` envelope — same rationale: don't tear
    //      down the turn, let the LLM explain it.
    //   3. Otherwise forward to the bridge.
    func dispatchMacIntegrationTool(
        tool: String,
        surface: String,
        integration: String,
        mode: MacIntegrationPermissionMode,
        fixHint: String,
        /// Capabilities this same request is KNOWN to need alongside
        /// `integration`. Supplying them folds a predictable chain into one
        /// grant instead of walking the person through two prompts.
        alsoNeeded: [String] = [],
        input: [String: JSONValue],
        run: (any MacIntegrationToolBridge, [String: JSONValue]) async throws -> JSONValue
    ) async throws -> JSONValue {
        let admitted = await fullMacYoloAdmitted(tool: tool, surface: surface)
        let allowed = await macIntegrationPermissionStore.allows(integration, mode: mode, fullMacAdmitted: admitted)
        guard allowed else {
            if let refusal = try await macIntegrationPermissionStore.readinessChecked().refusal(integration: integration, mode: mode) {
                return .object(["status": .string("denied"), "reason": .string("operator_permission_off"),
                    "integration": .string(integration), "mode": .string(mode.rawValue), "message": .string(refusal)])
            }
            // The permission is not granted. That is not a refusal to be
            // relayed as prose with a "fix" hint — it is the person's
            // decision, not yet made, and it gets asked where the work is.
            //
            // ASK ONCE (Agent): the checker knows here exactly which
            // capabilities this tool needs, so it raises ONE need listing all
            // of them and the person grants once. `alsoNeeded` is the rest of
            // a chain the caller could know in advance; step-by-step
            // escalation is reserved for the needs that genuinely cannot be
            // predicted.
            let chain = [integration] + alsoNeeded.filter { $0 != integration }
            var missing: [String] = []
            for capability in chain
            where await !macIntegrationPermissionStore.allows(capability, mode: mode) {
                missing.append(capability)
            }
            if let need = InlineInteractionRegistry.permission(
                missing.isEmpty ? [integration] : missing,
                why: fixHint,
                // The axis the blocked call wanted, so the grant covers that
                // and says so rather than handing over both.
                mode: mode == .read ? .read : .write
            ) {
                return InlineInteractionNeed.envelope(need)
            }
            return .object([
                "status": .string("denied"),
                "reason": .string("integration_permission_denied"),
                "integration": .string(integration),
                "mode": .string(mode.rawValue),
                "fix": .string(fixHint),
            ])
        }
        guard let bridge = macIntegrationBridge else {
            return .object([
                "status": .string("failed"),
                "reason": .string("bridge_not_wired"),
                "integration": .string(integration),
                "fix": .string("App-side MacIntegrationToolBridge not injected; restart the app."),
            ])
        }
        return try await run(bridge, input)
    }
}
