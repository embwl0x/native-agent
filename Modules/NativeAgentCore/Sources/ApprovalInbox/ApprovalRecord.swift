import ChatToolParsing
import Foundation
import NativeAgentShared
import PersistenceCore
import AuthoredCapabilities
import Experiences
import NativeAgentCore
import TrustCenter
// Blueprint: | `ApprovalRecord.swift` | `ApprovalRecord`, `ApprovalFilter`, `ApprovalDecision` and `ApprovalResolutionProvenance`; approval presentation, tolerant saved JSON reads and nullable-versus-omitted wire fields; typed decision origin without queue authority |

/// One record in the autonomy approval queue. Preserves the stable
/// `create_approval_request` shape plus NativeAgent's durable typed resolution
/// provenance.
///
/// Timestamps are ISO-8601 strings. The `decision`, `resolvedAt`, `decidedBy`,
/// and `resolutionProvenance` fields stay nil until the request is resolved.
///
/// `executedAction` preserves the domain's outcome. `detail` is its shared
/// decision face. Unlike the nullable decision, both are omitted when nil.
public struct ApprovalRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var action: String
    public var risk: String
    public var reason: String
    public var status: String            // "pending" | "resolved" | "denied" | "canceled" | "orphaned"
    public var payload: JSONValue        // arbitrary JSON dict
    public var payloadPreview: String
    public var createdAt: String         // ISO-8601
    /// When an identical pending request was last re-asked; nil until its first repeat.
    public var lastRequestedAt: String?  // ISO-8601 or nil

    /// Shows the reason or owner-review preview, never serialized payload; surfaces apply redaction.
    public var readableAsk: String {
        let reason = self.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { return reason }
        guard SwiftNativeApprovalInbox.ownerReviewActions.contains(action) else { return "" }
        return payloadPreview.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var resolvedAt: String?       // ISO-8601 or nil
    public var decision: String?         // "approved" | "denied" | "canceled" | nil
    public var decidedBy: String?        // durable human/system decision attribution
    public var resolutionProvenance: ApprovalResolutionProvenance?
    public var remoteResolvable: Bool
    public var localOnly: Bool
    public var executedAction: JSONValue?
    private var executionDetail: String?
    public var cause: String? = nil
    public var detail: String? {
        get { executedAction == nil ? executionDetail : decisionExperience.face?.words }
        set { executionDetail = newValue }
    }

    public var executionResultClass: ChatToolOutcome.ExactResultClass {
        guard let executedAction else { return .unknown }
        guard case .object(let execution) = executedAction,
              execution["op"] == .string("chat_tool_approval_replay") else {
            return ChatToolOutcome.exactResultClass(executedAction)
        }
        if case .string(let raw)? = execution["resultClass"],
           let result = ChatToolOutcome.ExactResultClass(rawValue: raw) { return result }
        guard let status = execution["status"] else { return .unknown }
        return ChatToolOutcome.exactResultClass(.object(["status": status]))
    }

    public var executionIsStopped: Bool {
        guard case .object(let execution)? = executedAction else { return false }
        return execution["status"] == .string("stopped")
    }

    /// The inbox owns the decision. Every reader gets this same expression,
    /// including old rows whose execution sentence contradicted their receipt.
    public var decisionExperience: Experience {
        let ref = Experience.Ref(source: "workflows/approvals/requests.json", id: id)
        var obligation = Experience.Obligation(to: "person")
        if decision != nil {
            obligation.phase = .accepted
            obligation.evidence = ref
        } else if status != "pending" {
            obligation.phase = .letGo
            obligation.reason = .expired
        }
        var fields: [String: JSONValue] = if case .object(let fields)? = executedAction { fields } else { [:] }
        if fields["detail"] == nil, let executionDetail { fields["detail"] = .string(executionDetail) }
        let words: String
        if case .object(let execution)? = executedAction,
           execution["op"] == .string("chat_tool_approval_replay") {
            let outcome = executionResultClass.receipt.label
            if let preview = execution["resultPreview"] { fields["detail"] = preview }
            let preview = ChatToolOutcome.explanation(.object(fields)).map { " Result: \($0)" } ?? ""
            // Execution attribution and approval authority are distinct.
            let ranBy = preview.contains("decided_by") ? " Its decided_by names who carried it out, not who approved it." : ""
            words = (decision == "approved" ? "\(action): \(outcome) after approval by \(approvedBy ?? "an unrecorded decider")."
                : "\(action): \(decision ?? status). The tool did not run.") + preview + ranBy
        } else if executedAction != nil {
            let value = JSONValue.object(fields)
            words = [ChatToolOutcome.explanation(value), ChatToolOutcome.remedy(value)]
                .compactMap { $0 }.joined(separator: " ")
        } else {
            words = executionDetail ?? decision.map { "\(action): \($0)." } ?? readableAsk
        }
        // Permission is not adoption. This receipt is written only after the
        // application completes; false means the lesson was already present.
        let applied: Bool
        if action == "rem.proposal", decision == "approved",
           fields["op"] == .string("rem_proposal_approve"), case .bool? = fields["growthAppended"],
           !ChatToolOutcome.carriesFailureEvidence(.object(fields)) { applied = true } else { applied = false }
        return Experience(id: id, kind: .decision, cause: cause.map { [$0] } ?? [], evidence: [ref],
                          outcome: decision.map { .init(domain: "approvals", status: $0, at: resolvedAt) },
                          face: .init(words: words, artifacts: []), addressedTo: ["person"],
                          owes: ["decide": obligation],
                          claims: applied ? [.init(claim: "applied", evidence: [ref])] : [])
    }
    /// Who approved, in words, with the time: "you, in the Mac app, 18:22".
    /// A person's channel says "you" (her receipts address the person); any
    /// other decider is named by its own label.
    public var approvedBy: String? {
        guard decision == "approved",
              let provenance = resolutionProvenance ?? decidedBy.map(ApprovalResolutionProvenance.local) else { return nil }
        let who = switch provenance {
        case .telegram: "you, in Telegram"
        case .signedIOS: "you, on your iPhone"
        case .local(decidedBy: "mac_ui"), .local(decidedBy: "local_desk_click"): "you, in the Mac app"
        case .local(let label): label
        }
        guard let at = resolvedAt.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) else { return who }
        let clock = DateFormatter()
        clock.dateFormat = Calendar.current.isDateInToday(at) ? "HH:mm" : "MMM d, HH:mm"
        return "\(who), \(clock.string(from: at))"
    }
    public var chatContinuation: JSONValue? = nil
    /// The inline conversation card: `{sessionId, telegramChatId?, at}`.
    /// Display binding only; set once, so a request never posts two cards.
    public var chatCard: JSONValue? = nil

    public init(
        id: String,
        title: String,
        action: String,
        risk: String,
        reason: String,
        status: String,
        payload: JSONValue,
        payloadPreview: String,
        createdAt: String,
        lastRequestedAt: String? = nil,
        resolvedAt: String? = nil,
        decision: String? = nil,
        decidedBy: String? = nil,
        resolutionProvenance: ApprovalResolutionProvenance? = nil,
        remoteResolvable: Bool,
        localOnly: Bool,
        executedAction: JSONValue? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.risk = risk
        self.reason = reason
        self.status = status
        self.payload = payload
        self.payloadPreview = payloadPreview
        self.createdAt = createdAt
        self.lastRequestedAt = lastRequestedAt
        self.resolvedAt = resolvedAt
        self.decision = decision
        self.decidedBy = decidedBy
        self.resolutionProvenance = resolutionProvenance
        self.remoteResolvable = remoteResolvable
        self.localOnly = localOnly
        self.executedAction = executedAction
        self.executionDetail = detail
    }
}

extension ApprovalRecord {
    /// The conversation that asked, for a chat tool approval: the filer
    /// (`NativeAgentChatApprovalFiler`) records it as `payload.origin.sessionId`.
    /// Only chat approvals carry a chat origin — every other kind is nil rather
    /// than borrowing a lookalike field.
    public var chatOriginSessionId: String? {
        guard case .object(let fields) = payload,
              case .string(let kind)? = fields["kind"],
              // ACP questions belong to a live protocol request, not a tool
              // replay. They share chat presentation only, never execution.
              kind == "chat_tool_approval" || kind == "agent_acp_live_approval",
              case .object(let origin)? = fields["origin"],
              case .string(let sessionId)? = origin["sessionId"] else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Her own decision, filed here only so she can resolve it with her own
    /// tool (`studio_canon_resolve`): never a card, note or button for the
    /// person. The canon filer's action is the marker.
    public var isAgentsOwnDecision: Bool { action == "studio.canon" }

    /// The conversation this approval's chat card was posted into, if any.
    public var chatCardSessionId: String? {
        guard case .object(let card)? = chatCard, case .string(let id)? = card["sessionId"],
              !id.isEmpty else { return nil }
        return id
    }

    public var chatCardDelivered: Bool {
        guard case .object(let card)? = chatCard else { return false }
        return card["delivered"] == .bool(true)
    }
}

extension ApprovalRecord {
    /// Build a record from its saved JSON object, tolerating missing keys.
    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        let idStr = obj["id"]?.stringValue ?? ""
        if idStr.isEmpty { return nil }
        self.id = idStr
        self.title = obj["title"]?.stringValue ?? ""
        self.action = obj["action"]?.stringValue ?? ""
        self.risk = obj["risk"]?.stringValue ?? ""
        self.reason = obj["reason"]?.stringValue ?? ""
        self.status = obj["status"]?.stringValue ?? ""
        self.payload = obj["payload"] ?? .object([:])
        self.payloadPreview = obj["payloadPreview"]?.stringValue ?? ""
        self.createdAt = obj["createdAt"]?.stringValue ?? ""
        self.lastRequestedAt = obj["lastRequestedAt"]?.stringValue
        self.resolvedAt = obj["resolvedAt"]?.stringValue
        self.decision = obj["decision"]?.stringValue
        self.decidedBy = obj["decidedBy"]?.stringValue
        if let value = obj["resolutionProvenance"], case .null = value {
            self.resolutionProvenance = nil
        } else if let value = obj["resolutionProvenance"] {
            self.resolutionProvenance = ApprovalResolutionProvenance(json: value)
        } else {
            self.resolutionProvenance = nil
        }
        // Pending owner-review cards allow phone replies; terminal rows keep their saved flags.
        if self.status == "pending",
           SwiftNativeApprovalInbox.ownerReviewActions.contains(self.action) {
            self.remoteResolvable = true
            self.localOnly = false
        } else {
            self.remoteResolvable = obj["remoteResolvable"]?.boolValue ?? false
            self.localOnly = obj["localOnly"]?.boolValue ?? false
        }
        // Preserve the saved execution outcome's shape.
        if let v = obj["executedAction"], case .null = v {
            self.executedAction = nil
        } else if let v = obj["executedAction"] {
            self.executedAction = v
        } else {
            self.executedAction = nil
        }
        self.executionDetail = obj["detail"]?.stringValue
        self.cause = obj["cause"]?.stringValue
        self.chatContinuation = obj["chatContinuation"]
        self.chatCard = obj["chatCard"]
    }

    /// Serialize nullable decision fields as explicit `null`, not absent.
    ///
    /// `executedAction` and `detail` are OMITTED when nil (not written as
    /// null) — these keys are added after action execution.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "action": .string(action),
            "risk": .string(risk),
            "reason": .string(reason),
            "status": .string(status),
            "payload": payload,
            "payloadPreview": .string(payloadPreview),
            "createdAt": .string(createdAt),
            "remoteResolvable": .bool(remoteResolvable),
            "localOnly": .bool(localOnly),
        ]
        if let lastRequestedAt {
            obj["lastRequestedAt"] = .string(lastRequestedAt)
        }
        obj["resolvedAt"] = resolvedAt.map(JSONValue.string) ?? .null
        obj["decision"] = decision.map(JSONValue.string) ?? .null
        if let decidedBy {
            obj["decidedBy"] = .string(decidedBy)
        }
        if let resolutionProvenance {
            obj["resolutionProvenance"] = resolutionProvenance.toJSON()
        }
        if let ea = executedAction {
            obj["executedAction"] = ea
        }
        if let cause { obj["cause"] = .string(cause) }
        if let d = detail {
            obj["detail"] = .string(d)
        }
        if let chatContinuation { obj["chatContinuation"] = chatContinuation }
        if let chatCard { obj["chatCard"] = chatCard }
        return .object(obj)
    }
}

public struct ApprovalFilter: Sendable, Equatable {
    /// "pending", "resolved", "denied", "canceled", "orphaned", or nil for all.
    public var status: String?
    /// If set, only records whose `action` matches — compared through
    /// `ExecutionEventVocabulary`, so `mission.step` and `execution.step`
    /// are the same filter.
    public var action: String?

    public init(status: String? = nil, action: String? = nil) {
        self.status = status
        self.action = action
    }

    public static let all = ApprovalFilter()
    public static let pending = ApprovalFilter(status: "pending")
    public static let resolved = ApprovalFilter(status: "resolved")
}

/// Accepted approval decision values.
public enum ApprovalDecision: String, Sendable, Equatable {
    case approved
    case denied
    case canceled
}

/// Typed, durable origin for an approval decision.
///
/// Remote cases are deliberately distinct from local decisions so
/// the inbox can enforce `remoteResolvable` and bind transport identity while
/// holding the same lock that commits the terminal decision. A caller cannot
/// safely turn a Telegram or signed-iOS decision into a local string label.
public enum ApprovalResolutionProvenance: Sendable, Equatable {
    case local(decidedBy: String)
    case telegram(chatID: String, userID: String)
    case signedIOS(clientID: String, decidedBy: String)

    public static let schema = "approval-resolution-provenance.v1"

    public var decidedBy: String {
        switch self {
        case .local(let decidedBy), .signedIOS(_, let decidedBy):
            return decidedBy
        case .telegram:
            return "telegram_verified_user"
        }
    }

    var isRemote: Bool {
        switch self {
        case .telegram, .signedIOS: true
        case .local: false
        }
    }

    var channel: String {
        switch self {
        case .local: "local"
        case .telegram: "telegram"
        case .signedIOS: "ios_signed"
        }
    }

    init?(json: JSONValue) {
        guard case .object(let object) = json,
              object["schema"] == .string(Self.schema),
              case .string(let channel)? = object["channel"],
              case .string(let decidedBy)? = object["decidedBy"],
              !decidedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        switch channel {
        case "local":
            self = .local(decidedBy: decidedBy)
        case "ios_signed":
            guard case .string(let clientID)? = object["clientID"],
                  !clientID.isEmpty else { return nil }
            self = .signedIOS(clientID: clientID, decidedBy: decidedBy)
        case "telegram":
            guard case .string(let chatID)? = object["chatID"],
                  case .string(let userID)? = object["userID"],
                  !chatID.isEmpty, !userID.isEmpty else { return nil }
            self = .telegram(chatID: chatID, userID: userID)
        default:
            return nil
        }
        guard object["remote"] == .bool(isRemote) else { return nil }
    }

    func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "schema": .string(Self.schema),
            "channel": .string(channel),
            "decidedBy": .string(decidedBy),
            "remote": .bool(isRemote),
        ]
        if case .telegram(let chatID, let userID) = self {
            object["chatID"] = .string(chatID)
            object["userID"] = .string(userID)
        }
        if case .signedIOS(let clientID, _) = self {
            object["clientID"] = .string(clientID)
            // Preserve verified public-key fingerprints as explicit device identity.
            if clientID.count == 64 {
                object["deviceID"] = .string(clientID)
            }
        }
        return .object(object)
    }
}
