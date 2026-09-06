import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / bridge.claude.route.standing_views
//
// The two routes that let Agent retire her own views and answer her own
// proposals from outside the app. The dangerous failure is not a 500 — it is a
// route that mutates her dispositions for an UNAUTHENTICATED peer, or one that
// approves a view that was never proposed / retires one she was never leaning
// on. Both refusals are decided by `ClaudeBridge.standingViewDecision` BEFORE
// any mutation, so that is the seam under test; the auth gate is asserted
// structurally because `route` writes to an `NWConnection`.

@Suite("Claude standing-views route")
struct ClaudeBridgeStandingViewsRouteEvalTests {

    // MARK: - Fixtures

    private func view(
        _ status: CognitiveStandingView.Status,
        body: String = "She reads a silent build as a question, not a verdict.",
        id: UUID = UUID()
    ) -> CognitiveStandingView {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return CognitiveStandingView(
            id: id,
            title: "phrasing",
            body: body,
            status: status,
            moodValenceAtFormation: 0.2,
            createdAt: now,
            updatedAt: now
        )
    }

    private func refusal(
        _ decision: ClaudeBridge.StandingViewRequestDecision
    ) throws -> (status: Int, code: String, reason: String) {
        guard case .refused(let status, let code, let reason) = decision else {
            Issue.record("expected a refusal, got \(decision)")
            throw CancellationError()
        }
        return (status, code, reason)
    }

    // MARK: - Auth

    @Test("both standing-view routes are behind the shared bearer gate")
    func standingViewRoutesRequireBearerAuth() throws {
        let source = try AppSourceScraping.appSource("ClaudeBridge.swift")
        guard let marker = source.range(
            of: "func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data)"
        ),
            let open = source[marker.upperBound...].firstIndex(of: "{"),
            let close = AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
        else {
            Issue.record("could not slice the body of ClaudeBridge.route")
            return
        }
        let routeBody = String(source[open...close])

        // The one auth gate every path shares, and it comes FIRST.
        let gate = try #require(routeBody.range(of: "BridgeCore.authorize(authorizationHeader: headers[\"authorization\"]"))
        for path in ["case \"/standing_views\":", "case \"/standing_views/resolve\":"] {
            let route = try #require(routeBody.range(of: path), "\(path) is not routed")
            #expect(route.lowerBound > gate.upperBound, "\(path) must be routed AFTER the bearer gate")
        }
        // No second, unauthenticated entry point to the same handlers.
        #expect(routeBody.components(separatedBy: "handleStandingViewsList(").count == 2)
        #expect(routeBody.components(separatedBy: "handleStandingViewResolve(").count == 2)

        // And the gate itself refuses a missing / wrong / stale-server bearer.
        #expect(BridgeCore.authorize(authorizationHeader: nil, liveToken: "live") == .unauthorized)
        #expect(BridgeCore.authorize(authorizationHeader: "Bearer nope", liveToken: "live") == .unauthorized)
        #expect(BridgeCore.authorize(authorizationHeader: "Bearer live", liveToken: "live") == .authorized)
        #expect(BridgeCore.authorize(authorizationHeader: "Bearer ", liveToken: "") == .serverStopping)
    }

    // MARK: - Unknown ids and actions

    @Test("an id the runtime does not hold is a 404, never a silent no-op")
    func unknownIdIsRefusedWith404() throws {
        let known = view(.proposed)
        for action in ClaudeBridge.StandingViewBridgeAction.allCases {
            let missing = try refusal(
                ClaudeBridge.standingViewDecision(
                    rawId: UUID().uuidString,
                    rawAction: action.rawValue,
                    views: [known]
                )
            )
            #expect(missing.status == 404)
            #expect(missing.code == "unknown_standing_view")
            #expect(missing.reason.contains("No standing view with id"))

            // A non-UUID id is an id we do not hold — same 404, same prose.
            let garbage = try refusal(
                ClaudeBridge.standingViewDecision(rawId: "not-a-uuid", rawAction: action.rawValue, views: [known])
            )
            #expect(garbage.status == 404)
            #expect(garbage.code == "unknown_standing_view")
        }

        let empty = try refusal(
            ClaudeBridge.standingViewDecision(rawId: "  ", rawAction: "retire", views: [known])
        )
        #expect(empty.status == 400)
        #expect(empty.code == "missing_id")
    }

    @Test("only approve, reject and retire are actions; anything else is a spoken 400")
    func unknownActionIsRefusedWith400() throws {
        let target = view(.proposed)
        for raw in ["", "   ", "delete", "activate", "approve-all", "APPROVEE"] {
            let refused = try refusal(
                ClaudeBridge.standingViewDecision(rawId: target.id.uuidString, rawAction: raw, views: [target])
            )
            #expect(refused.status == 400)
            #expect(refused.code == (raw.trimmingCharacters(in: .whitespaces).isEmpty ? "missing_action" : "unknown_action"))
            #expect(!refused.reason.isEmpty)
            #expect(refused.reason.contains("approve"))
        }
        // Case and surrounding whitespace are the caller's shell, not a refusal.
        #expect(
            ClaudeBridge.standingViewDecision(rawId: target.id.uuidString, rawAction: " Approve ", views: [target])
                == .proceed(.approve, target)
        )
    }

    // MARK: - Which action fits which status

    @Test("approve and reject answer a proposal and nothing else")
    func approveAndRejectOnlyApplyToProposed() throws {
        for action in [ClaudeBridge.StandingViewBridgeAction.approve, .reject] {
            let proposed = view(.proposed)
            #expect(
                ClaudeBridge.standingViewDecision(
                    rawId: proposed.id.uuidString,
                    rawAction: action.rawValue,
                    views: [proposed]
                ) == .proceed(action, proposed)
            )

            for status in [CognitiveStandingView.Status.active, .held, .retired] {
                let other = view(status)
                let refused = try refusal(
                    ClaudeBridge.standingViewDecision(
                        rawId: other.id.uuidString,
                        rawAction: action.rawValue,
                        views: [other]
                    )
                )
                #expect(refused.status == 409)
                #expect(refused.code == "not_awaiting_review")
                #expect(refused.reason.contains(status.rawValue))
            }
        }
    }

    @Test("retire ends a view she is leaning on and nothing else")
    func retireOnlyAppliesToActiveOrHeld() throws {
        for status in [CognitiveStandingView.Status.active, .held] {
            let leaning = view(status)
            #expect(
                ClaudeBridge.standingViewDecision(
                    rawId: leaning.id.uuidString,
                    rawAction: "retire",
                    views: [leaning]
                ) == .proceed(.retire, leaning)
            )
        }
        for status in [CognitiveStandingView.Status.proposed, .retired] {
            let other = view(status)
            let refused = try refusal(
                ClaudeBridge.standingViewDecision(
                    rawId: other.id.uuidString,
                    rawAction: "retire",
                    views: [other]
                )
            )
            #expect(refused.status == 409)
            #expect(refused.code == "not_leaning")
            #expect(refused.reason.contains(status.rawValue))
        }
    }

    // MARK: - Projection

    @Test("the listed projection is id/status/first 80 chars, leaning first, retired absent")
    func listProjectionIsBoundedAndOrdered() throws {
        let long = String(repeating: "z", count: 200)
        let active = view(.active, body: long)
        let held = view(.held)
        let proposed = view(.proposed)
        let retired = view(.retired)
        let rows = ClaudeBridge.standingViewListJSON([proposed, retired, held, active])

        #expect(rows.count == 3)
        #expect(rows.map { $0["status"] as? String } == ["active", "held", "proposed"])
        #expect(rows.map { $0["id"] as? String } == [active.id.uuidString, held.id.uuidString, proposed.id.uuidString])
        #expect(rows.allSatisfy { Set($0.keys) == ["id", "status", "body"] })
        #expect((rows[0]["body"] as? String)?.count == 80)
        #expect(rows[0]["body"] as? String == String(repeating: "z", count: 80))
        #expect(rows[1]["body"] as? String == held.body)
        #expect(rows.allSatisfy { JSONSerialization.isValidJSONObject($0) })
        #expect(!rows.contains { ($0["status"] as? String) == "retired" })

        #expect(ClaudeBridge.standingViewBodyPreview("").isEmpty)
        #expect(ClaudeBridge.standingViewBodyPreview(long).count == ClaudeBridge.standingViewBodyPreviewLimit)
    }
}
