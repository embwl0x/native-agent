import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `MacToolsView.swift` | Shared forms and receipt rows over policy-gated signed Mac controls |

struct MacToolsView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var ledger = RemoteActionLedger.shared
    @State private var hasLoadedPolicy = false
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page("phone-mac-tools") }
    private var policy: MacControlPolicyWireSnapshot? { sync.trustPolicy?.macControlPolicy }

    var body: some View {
        AlivePage(title: "Mac Tools", line: "Things I can do on your Mac from here.") {
            if !pairingStore.isPaired { AliveUnpairedReason() }
            if !hasLoadedPolicy && pairingStore.isPaired { ProgressView("Checking Mac Control…") }
            FaceView(face: face, door: door, session: session)
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .macSyncErrorBanner()
    }

    private func restriction(_ privilege: PhoneMacControlAction) -> String? {
        guard pairingStore.isPaired else { return "Pair with your Mac before using Mac Tools." }
        guard hasLoadedPolicy else { return "Waiting on the Mac's control policy." }
        guard MacToolsPolicyGatePresentation.state(for: policy) == .enabled else {
            return MacToolsPolicyGatePresentation.disabledDescription(for: policy)
        }
        guard MacToolsPrivilegePresentation.isAllowed(privilege, policy: policy) else {
            return MacToolsPrivilegePresentation.disabledDescription(for: privilege) + " Enable in the Mac app's Trust tab."
        }
        return nil
    }

    private func form(_ privilege: PhoneMacControlAction, title: String, fields: [PartFace.FormField], label: String,
                      footer: String? = nil) -> PartFace.Section {
        .init(id: privilege.rawValue, title: title, footer: footer, rows: [], block: .init(kind: "form", key: privilege.rawValue,
            fields: fields, submit: [.init(id: "run", label: label, call: .init(privilege.rawValue), unavailable: restriction(privilege))]))
    }

    private var face: PartFace {
        var sections = [
            form(.notification, title: "Send a notification", fields: [
                .init(id: "title", label: "Title", value: .string(""), placeholder: sync.agentDisplayName),
                .init(id: "message", label: "Message", kind: "lines", value: .string(""), required: true)
            ], label: "Send"),
            form(.volume, title: "The Mac", fields: [
                .init(id: "percent", label: "Volume target (%)", kind: "number", required: true, min: 0, max: 100, step: 5)
            ], label: "Set", footer: MacVolumeControlPresentation.currentVolumeDisclosure),
            form(.spotlight, title: "Search the Mac", fields: [
                .init(id: "query", label: "Spotlight", value: .string(""), required: true)
            ], label: "Search")
        ]
        if !ledger.actions.isEmpty {
            sections.append(.init(id: "receipts", title: "Recent on the Mac", footer: "Kept while this app stays open.", rows: ledger.actions.map { card in
                var actions: [PartFace.Action] = []
                if card.state == .failed {
                    actions.append(.init(id: "retry", label: "Retry", call: .init(card.kind.privilege.rawValue,
                        ["receipt": .string(card.id.uuidString)]), unavailable: restriction(card.kind.privilege)))
                }
                if card.state == .waitingApproval {
                    actions.append(.init(id: "approval", label: "Review Approval", call: .init("phone.reviewApproval")))
                }
                return .init(id: card.id.uuidString, title: card.title,
                    value: card.subtitle + " · " + card.state.rawValue, at: card.updatedAt.ISO8601Format(), actions: actions)
            }))
            sections += ledger.actions.map { card in
                .init(id: "receipt-body-" + card.id.uuidString, title: card.title, rows: [], block: .init(kind: "document",
                    key: "receipt-body-" + card.id.uuidString, text: card.detail, format: "plain", copy: true))
            }
        }
        return PartFace(sections: sections)
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, cancellationLabel: "Cancel waiting", waitingOn: "your Mac", perform: perform)
    }

    private func perform(_ submission: FaceActSubmission) async -> FaceActOutcome {
        if submission.checking {
            return await ledger.read(operation: submission.id)
        }
        if submission.expectedCall.action == "phone.reviewApproval" {
            NativeAgentNotificationLaunchIntent.stage(screen: "approvals")
            NotificationCenter.default.post(name: .nativeagentOpenActivity, object: nil, userInfo: ["screen": "approvals"])
            return .init(effects: .none, accepted: true)
        }
        guard let privilege = PhoneMacControlAction(rawValue: submission.expectedCall.action) else {
            return refused("This Mac control is unavailable.")
        }
        if let why = restriction(privilege) { return refused(why) }
        guard !session.operations.values.contains(where: {
            $0.submission.id != submission.id && $0.submission.expectedCall.action == privilege.rawValue
                && ($0.outcome == nil || $0.outcome?.unresolved == true)
        }) else { return refused("Already waiting on your Mac for this control. Check its outcome before submitting again.") }
        let kind: RemoteActionKind
        let cardID: UUID
        if let receipt = submission.expectedCall.args["receipt"]?.stringValue {
            guard let card = ledger.actions.first(where: { $0.id.uuidString == receipt }), card.state == .failed else {
                return refused("Read the receipt again before retrying its original request.")
            }
            kind = card.kind; cardID = card.id
            ledger.bind(cardID, to: submission.id)
        } else {
            let values = submission.values ?? [:]
            switch privilege {
            case .notification:
                guard let message = values["message"]?.stringValue, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let title = values["title"]?.stringValue else { return refused("The notification needs its title and message fields.") }
                kind = .notify(title: title.isEmpty ? sync.agentDisplayName : title, message: message)
            case .volume:
                let percent: Double?
                switch values["percent"] {
                case .int(let value): percent = Double(value)
                case .double(let value): percent = value
                default: percent = nil
                }
                guard let percent, percent.isFinite, (0...100).contains(percent), percent.rounded() == percent else {
                    return refused("Choose a whole volume target between 0% and 100%.")
                }
                kind = .volume(Int(percent))
            case .spotlight:
                guard let query = values["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return refused("Enter a Spotlight query.")
                }
                kind = .spotlight(query)
            default: return refused("This page does not offer that Mac control.")
            }
            let title: String
            let subtitle: String
            switch kind {
            case .notify(let name, _): title = "Send notification"; subtitle = name
            case .volume(let percent): title = "Set volume"; subtitle = "\(percent)%"
            case .spotlight(let query): title = "Spotlight search"; subtitle = query
            }
            cardID = ledger.start(kind, title: title, subtitle: subtitle, operation: submission.id)
        }
        ledger.update(cardID, state: .running, detail: RemoteActionRetryPresentation.dispatchDetail(for: kind,
            isRetry: submission.expectedCall.args["receipt"] != nil))
        do {
            let words: String
            var committed: [FaceCommittedField] = []
            switch kind {
            case .notify(let title, let message):
                words = try await sync.macNotify(title: title, message: message)
                committed = [.init(id: "title", value: .string("")), .init(id: "message", value: .string(""))]
            case .volume(let percent):
                _ = try await sync.macSetVolume(percent: percent)
                words = MacVolumeControlPresentation.acknowledgement(percent: percent)
                committed = [.init(id: "percent", value: .int(Int64(percent)))]
            case .spotlight(let query):
                let raw = try await sync.macSpotlight(query: query)
                let result = try await MacToolsSpotlightPresentation.outcome(from: raw)
                words = ([result.statusText] + result.rows).joined(separator: "\n")
                committed = [.init(id: "query", value: .string(query))]
            }
            ledger.update(cardID, state: .ranOnMac, detail: words)
            return .init(words: words, effects: .known, accepted: true, committed: committed)
        } catch {
            let cause: any Error = error is CancellationError
                ? SyncError.responseUnconfirmed("Stopped waiting. Check the action's Mac outcome before submitting new work.") : error
            let outcome: FaceActOutcome
            if privilege == .spotlight, cause is DecodingError || cause is PartCallError {
                outcome = .init(failure: .init(code: "spotlight_response_unreadable", message: cause.localizedDescription,
                    cause: nil, effects: .none), effects: .none)
            } else { outcome = .phoneFailure(cause) }
            let state: RemoteActionState
            if case SyncError.approvalRequired = cause { state = .waitingApproval }
            else { state = outcome.effects == .unknown ? .unconfirmed : .failed }
            ledger.update(cardID, state: state, detail: cause.localizedDescription, approvalID: (cause as? SyncError)?.approvalID)
            return outcome
        }
    }

    private func refused(_ words: String) -> FaceActOutcome {
        .init(failure: .init(code: "mac_control_unavailable", message: words, cause: nil, effects: .none), effects: .none)
    }

    private func refresh() async {
        _ = await sync.refreshTrustSnapshot()
        hasLoadedPolicy = true
    }
}
