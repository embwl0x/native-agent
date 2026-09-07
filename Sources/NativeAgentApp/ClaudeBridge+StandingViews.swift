import Foundation
import Network
import CognitiveSubstrate

extension ClaudeBridge {
    // MARK: - /standing_views
    //
    // The Observatory (Activity › Cognition Proposals) was the ONLY way to
    // approve, reject or retire one of Agent's standing views; the bridge could
    // read `standingViewProposals` and nothing more. These two routes reach the
    // same two functions the buttons call — `CognitionProposalActions
    // .resolveWithOutcome` and `.retireWithOutcome` — so the boundary recheck,
    // the runtime microcycle, and the durable receipts are exactly the UI's.
    // Nothing here touches the substrate or the standing-view table directly.

    /// The three decisions the bridge accepts. They map onto exactly the two
    /// Observatory actions: `approve`/`reject` resolve a `.proposed` view,
    /// `retire` ends one she is already leaning on (`.active` or `.held`).
    enum StandingViewBridgeAction: String, Sendable, CaseIterable {
        case approve, reject, retire

        var approved: Bool { self == .approve }
    }

    /// What one `/standing_views/resolve` request turns into, decided against
    /// the live view list BEFORE any mutation. A refusal carries the spoken
    /// reason the caller reads back; the applied path speaks with the outcome
    /// prose `CognitionProposalActions` already returns.
    enum StandingViewRequestDecision: Sendable, Equatable {
        case proceed(StandingViewBridgeAction, CognitiveStandingView)
        case refused(status: Int, code: String, reason: String)
    }

    static let standingViewBodyPreviewLimit = 80

    /// First 80 characters of the body — enough to say WHICH view was acted on
    /// without shipping her whole disposition over the socket.
    static func standingViewBodyPreview(_ body: String) -> String {
        String(body.prefix(standingViewBodyPreviewLimit))
    }

    static func standingViewJSON(_ view: CognitiveStandingView) -> [String: Any] {
        [
            "id": view.id.uuidString,
            "status": view.status.rawValue,
            "body": standingViewBodyPreview(view.body),
        ]
    }

    /// The three statuses the list route reports, in the order a reviewer wants
    /// them: what she is leaning on hardest first, the queue last. `.retired` is
    /// deliberately absent — this route exists to act, and nothing acts on a
    /// retired view.
    static let standingViewListedStatuses: [CognitiveStandingView.Status] = [.active, .held, .proposed]

    static func standingViewListJSON(_ views: [CognitiveStandingView]) -> [[String: Any]] {
        standingViewListedStatuses.flatMap { status in
            views.filter { $0.status == status }.map(standingViewJSON)
        }
    }

    static func standingViewDecision(
        rawId: String,
        rawAction: String,
        views: [CognitiveStandingView]
    ) -> StandingViewRequestDecision {
        let actionText = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !actionText.isEmpty else {
            return .refused(
                status: 400,
                code: "missing_action",
                reason: "Say which action you want: approve, reject, or retire."
            )
        }
        guard let action = StandingViewBridgeAction(rawValue: actionText) else {
            return .refused(
                status: 400,
                code: "unknown_action",
                reason: "\"\(actionText)\" is not a standing-view action. Use approve, reject, or retire."
            )
        }
        let idText = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idText.isEmpty else {
            return .refused(
                status: 400,
                code: "missing_id",
                reason: "Say which standing view to \(actionText), by id."
            )
        }
        guard let uuid = UUID(uuidString: idText),
              let view = views.first(where: { $0.id == uuid })
        else {
            return .refused(
                status: 404,
                code: "unknown_standing_view",
                reason: "No standing view with id \(idText)."
            )
        }
        switch action {
        case .approve, .reject:
            guard view.status == .proposed else {
                return .refused(
                    status: 409,
                    code: "not_awaiting_review",
                    reason: "That standing view is \(view.status.rawValue), not proposed — approve and reject only answer a proposal. Retire ends one the agent is already leaning on."
                )
            }
        case .retire:
            guard view.isLeaning else {
                return .refused(
                    status: 409,
                    code: "not_leaning",
                    reason: "That standing view is \(view.status.rawValue), not one the agent is leaning on — retire only ends an active or held view."
                )
            }
        }
        return .proceed(action, view)
    }

    func handleStandingViewsList(conn: NWConnection) {
        let workLatch = WorkLatch()
        let workTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let detail = await CognitionObservatoryActions.refresh()
            guard workLatch.claim() else { return }
            let views = detail.standingViews
            self.writeJSON(conn, status: 200, obj: [
                "standingViews": Self.standingViewListJSON(views),
                "counts": Dictionary(
                    uniqueKeysWithValues: Self.standingViewListedStatuses.map { status in
                        (status.rawValue, views.filter { $0.status == status }.count)
                    }
                ),
            ])
        }
        workLatch.arm(afterSeconds: Self.readWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": "/standing_views",
                "seconds": Self.readWorkDeadlineSeconds,
            ])
        }
    }

    func handleStandingViewResolve(conn: NWConnection, body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        let rawId = (json["id"] as? String) ?? ""
        let rawAction = (json["action"] as? String) ?? ""

        // Same WorkLatch + asyncAfter bound as handleState/handleOrganismDebug:
        // exactly one of the work Task and the deadline writes the response.
        let workLatch = WorkLatch()
        let workTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            func respond(_ status: Int, _ obj: [String: Any]) {
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: status, obj: obj)
            }
            let before = await CognitionObservatoryActions.refresh()
            switch Self.standingViewDecision(rawId: rawId, rawAction: rawAction, views: before.standingViews) {
            case .refused(let status, let code, let reason):
                respond(status, ["error": code, "reason": reason])
            case .proceed(let action, let view):
                // THROUGH the Observatory actions, never around them: same
                // recheck, same runtime mutation, same receipts as a click.
                let result = action == .retire
                    ? await CognitionProposalActions.retireWithOutcome(id: view.id)
                    : await CognitionProposalActions.resolveWithOutcome(id: view.id, approved: action.approved)
                let after = result.detail.standingViews.first(where: { $0.id == view.id }) ?? view
                switch result.status {
                case .applied(let applied):
                    respond(200, [
                        "status": "applied",
                        "action": action.rawValue,
                        "id": view.id.uuidString,
                        "viewStatus": applied.rawValue,
                        "body": Self.standingViewBodyPreview(after.body),
                    ])
                case .unavailable(let reason):
                    respond(409, [
                        "error": "not_applied",
                        "reason": reason,
                        "action": action.rawValue,
                        "id": view.id.uuidString,
                        "viewStatus": after.status.rawValue,
                        "body": Self.standingViewBodyPreview(after.body),
                    ])
                case .notSaved(let reason):
                    // Changed in memory, never written (2026-09-06). Reported as
                    // a failure, not an application: it reverts on restart.
                    respond(500, [
                        "error": "not_saved",
                        "reason": reason,
                        "action": action.rawValue,
                        "id": view.id.uuidString,
                        "viewStatus": after.status.rawValue,
                        "body": Self.standingViewBodyPreview(after.body),
                    ])
                }
            }
        }
        workLatch.arm(afterSeconds: Self.readWorkDeadlineSeconds) { [weak self] in
            guard let self, workLatch.claim() else { return }
            workTask.cancel()
            self.writeJSON(conn, status: 504, obj: [
                "error": "work_timeout",
                "path": "/standing_views/resolve",
                "seconds": Self.readWorkDeadlineSeconds,
            ])
        }
    }

}
