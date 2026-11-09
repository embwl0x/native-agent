import ChatToolParsing
import Foundation
import NativeAgentShared
import PersistenceCore
import AuthoredCapabilities
import Experiences
import NativeAgentCore
import TrustCenter
import Privacy
import Transcripts
// Blueprint: | `ApprovalRecord.swift` | Approval substance, checked origin doors and decision faces; the person's resolution provenance owns authority. |

/// Timestamps are ISO-8601; decision fields stay nil until resolution.
public struct ApprovalRecord: Sendable, Equatable, Identifiable {
    public var id: String
    private var recordedTitle: String
    /// The card's title: a tool call's act in words, a peer asker named first; otherwise the filer's own title.
    public var title: String {
        get {
            guard let call else { return recordedTitle }
            let asker = recordedTitle.range(of: Self.askerSeparator, options: .backwards).map { String(recordedTitle[..<$0.upperBound]) } ?? ""
            return asker + call.act
        }
        set { recordedTitle = newValue }
    }
    /// An ask raised for someone else (a peer, a part, a script) names its asker first: "<asker> asked: <act>".
    public static let askerSeparator = " asked: "
    /// A tool call's ask in the person's words, read from the call itself; nil for asks a filer words itself.
    public var call: (act: String, says: String)? {
        guard let fields = payload.objectValue, fields["kind"] == .string("chat_tool_approval"),
              let tool = fields["toolName"]?.stringValue else { return nil }
        return ApprovalWords.call(tool: tool, input: fields["input"])
    }
    public var action: String
    public var risk: String
    public var reason: String
    public var status: String            // "pending" | "resolved" | "denied" | "canceled" | "orphaned"
    public var payload: JSONValue
    private var recordedPayloadPreview: String
    /// Render retained history without rewriting it to add missing-history wording.
    public var payloadPreview: String {
        get {
            if let call { return call.says }
            guard action == "rem.proposal" else { return recordedPayloadPreview }
            let replacement: REMReplacement?
            if case .object(let fields) = payload,
               case .object(let proposal)? = fields["proposal"],
               case .object(let replaced)? = proposal["replaced"],
               case .string(let source)? = replaced["source"],
               case .string(let text)? = replaced["text"] {
                replacement = REMReplacement(source: source, text: text)
            } else { replacement = nil }
            let description = REMReplacement.describe(replacement)
            return recordedPayloadPreview.hasSuffix(description)
                ? recordedPayloadPreview : recordedPayloadPreview + "\n\n" + description
        }
        set { recordedPayloadPreview = newValue }
    }
    public var createdAt: String
    /// When an identical pending request was last re-asked; nil until its first repeat.
    public var lastRequestedAt: String?

    /// Shows the reason or owner-review preview, never serialized payload; surfaces apply redaction.
    public var readableAsk: String {
        let reason = self.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { return reason }
        guard SwiftNativeApprovalInbox.ownerReviewActions.contains(action) else { return "" }
        return payloadPreview.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var resolvedAt: String?
    public var decision: String?
    public var decidedBy: String?
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
            let reply = ToolResult(executedAction)
            return reply.outcome
        }
        if case .string(let raw)? = execution["resultClass"],
           let result = ChatToolOutcome.ExactResultClass(rawValue: raw) { return result }
        guard let status = execution["status"] else { return .unknown }
        let reply = ToolResult(.object(["status": status]))
        return reply.outcome
    }

    public var executionIsStopped: Bool {
        guard case .object(let execution)? = executedAction else { return false }
        return execution["status"] == .string("stopped")
    }

    public var matter: Matter {
        Matter(id: id, form: .ask, from: "approval", title: NativeAppSecretRedactor.redactText(title),
               summary: NativeAppSecretRedactor.redactText(readableAsk), words: NativeAppSecretRedactor.redactText(payloadPreview),
               symbol: "checkmark.shield.fill", badge: "APPROVAL", open: "approval:" + id,
               choices: payloadPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? []
                   : [.init(id: "approve", label: "Approve", role: .primary), .init(id: "reject", label: "Reject", role: .destructive)],
               evidence: [.init(source: Matter.approvals, id: id)])
    }

    public struct PersonOrigin: Sendable {
        public let thread: Door?
        public let session: String?
    }

    /// Only the two live chat filers write this origin; malformed routes remain a named read failure.
    public var personOrigin: PersonOrigin? {
        get throws {
            guard let fields = payload.objectValue,
                  fields["kind"] == .string("chat_tool_approval") || fields["kind"] == .string("agent_acp_live_approval"),
                  let value = fields["origin"] else { return nil }
            guard let origin = value.objectValue, let surface = origin["surface"]?.stringValue else {
                throw ApprovalInboxError.malformedResponse("approval \(id) has an unreadable origin")
            }
            func text(_ key: String) throws -> String? {
                guard let value = origin[key], value != .null else { return nil }
                guard let raw = value.stringValue else {
                    throw ApprovalInboxError.malformedResponse("approval \(id) has an unreadable origin \(key)")
                }
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : clean
            }
            switch surface {
            case "telegram", "slack":
                // A surface without a destination names no thread; the person's known phone and Mac doors still belong to the ask.
                guard let destination = try text("destinationId") else { return PersonOrigin(thread: nil, session: nil) }
                let thread = try text("threadId")
                return PersonOrigin(thread: surface == "telegram" ? .telegram(chat: destination, thread: thread)
                                    : .slack(channel: destination, thread: thread), session: nil)
            case "chat", "ios": return PersonOrigin(thread: nil, session: try text("sessionId"))
            default: return nil
            }
        }
    }

    /// The person's doors for this ask: the phone, the thread it came from and the Mac, and the person's own conversation when the ask was
    /// raised anywhere else (a conversation that raised it already holds its card), the same door an interaction's matter names.
    public func personDoors(dataRoot: URL) throws -> [Door] {
        let origin = try personOrigin
        return try Door.asking(thread: origin?.thread, unless: origin?.session, dataRoot: dataRoot)
    }

    /// Every reader uses the inbox decision independently of execution attribution.
    public var decisionExperience: Experience {
        let ref = Experience.Ref(source: Matter.approvals, id: id)
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
            words = executionDetail ?? decision.map { "\(action): \($0)." } ?? payloadPreview
        }
        // A saved decision is not proof of a successful effect. Lead its receipt with the execution owner's verdict.
        let outcomeLead: String?
        switch decision {
        case "denied": outcomeLead = "Declined"
        case "canceled": outcomeLead = "Not now"
        case "approved":
            switch executionResultClass {
            case .succeeded: outcomeLead = "Done"
            case .failed: outcomeLead = "Failed"
            case .refused: outcomeLead = "Refused"
            case .cancelled: outcomeLead = "Stopped"
            case .timeout: outcomeLead = "Unknown: the approved action timed out; completion is unconfirmed"
            case .unknown: outcomeLead = "Unknown: the approved action's completion is unconfirmed"
            }
        default: outcomeLead = status == "orphaned" ? "Expired: no decision was recorded" : nil
        }
        var receipt: String
        if let outcomeLead {
            let detail = words.trimmingCharacters(in: .whitespacesAndNewlines)
            receipt = outcomeLead + (detail.isEmpty ? ": no result detail was recorded." : ": " + detail)
        } else { receipt = words }
        if let attribution = resolutionProvenance?.messageAttribution { receipt += " " + attribution + "." }
        // Approval is not adoption; only completed application writes this receipt.
        let applied: Bool
        let reply = ToolResult(.object(fields))
        if action == "rem.proposal", decision == "approved",
           fields["op"] == .string("rem_proposal_approve"), case .bool? = fields["growthAppended"],
           !reply.carriesFailureEvidence { applied = true } else { applied = false }
        let tone: PartFace.Tone = executionResultClass.isFailure ? .failed
            : decision == nil || (decision == "approved" && executionResultClass == .unknown) ? .attention : .done
        let rowDetail = [matter.summary, resolutionProvenance?.messageAttribution].compactMap { $0 }.joined(separator: "\n")
        let row = PartFace.Row(id: id, title: matter.title, detail: NativeAppSecretRedactor.redactText(rowDetail), value: matter.badge, at: createdAt,
                               symbol: matter.symbol, tone: tone,
                               open: matter.open, actions: matter.choices)
        return Experience(id: id, kind: .decision, cause: cause.map { [$0] } ?? [], evidence: [ref],
                          outcome: decision.map { .init(domain: "approvals", status: $0, at: resolvedAt) },
                          face: .init(words: NativeAppSecretRedactor.redactText(receipt), artifacts: [], row: row, from: "approval"),
                          addressedTo: [ForPerson.person],
                          owes: ["decide": obligation],
                          claims: applied ? [.init(claim: "applied", evidence: [ref])] : [])
    }
    /// Receipts address the person as "you" and name other deciders by their own labels.
    public var approvedBy: String? {
        guard decision == "approved",
              let provenance = resolutionProvenance ?? decidedBy.map(ApprovalResolutionProvenance.local) else { return nil }
        let who = switch provenance {
        case .telegram: "you, in Telegram"
        case .signedIOS: "you, on your iPhone"
        case .personMessage(let sessionID, let messageID, let door):
            "the agent on your message \(messageID) in conversation \(sessionID), through \(door.messageDoorName)"
        case .local(decidedBy: "mac_ui"), .local(decidedBy: "local_desk_click"): "you, in the Mac app"
        case .local(let label): label
        }
        guard let at = resolvedAt.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) else { return who }
        let clock = DateFormatter()
        clock.dateFormat = Calendar.current.isDateInToday(at) ? "HH:mm" : "MMM d, HH:mm"
        return "\(who), \(clock.string(from: at))"
    }
    public var chatContinuation: JSONValue? = nil
    /// The inline conversation card: `{sessionId, telegramChatId?, at}`. Display binding only; set once, so a request never posts two cards.
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
        self.recordedTitle = title
        self.action = action
        self.risk = risk
        self.reason = reason
        self.status = status
        self.payload = payload
        self.recordedPayloadPreview = payloadPreview
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
    /// Only the chat approval filer supplies an origin; other kinds must not borrow lookalike fields.
    public var chatOriginSessionId: String? {
        guard case .object(let fields) = payload,
              case .string(let kind)? = fields["kind"],
              // ACP questions belong to a live protocol request, not a tool replay. They share chat presentation only, never execution.
              kind == "chat_tool_approval" || kind == "agent_acp_live_approval",
              case .object(let origin)? = fields["origin"],
              case .string(let sessionId)? = origin["sessionId"] else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The canon filer marks agent-owned decisions so person-facing cards cannot decide them.
    public var isAgentsOwnDecision: Bool { action == "studio.canon" }

    public var chatCardSessionId: String? {
        guard case .object(let card)? = chatCard, case .string(let id)? = card["sessionId"],
              !id.isEmpty else { return nil }
        return id
    }

}

extension ApprovalRecord {
    /// Decode the current stored record. Invalid evidence never becomes an invented empty field or a changed authority flag.
    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        guard case .string(let savedID)? = obj["id"], !savedID.isEmpty,
              case .string(let title)? = obj["title"], !title.isEmpty,
              case .string(let action)? = obj["action"], !action.isEmpty,
              case .string(let risk)? = obj["risk"],
              case .string(let reason)? = obj["reason"],
              case .object(let payload)? = obj["payload"],
              case .string(let preview)? = obj["payloadPreview"],
              case .string(let created)? = obj["createdAt"],
              NativeTimestampFormat.parseISO8601FractionalFirst(created) != nil,
              case .bool(let remoteResolvable)? = obj["remoteResolvable"],
              case .bool(let localOnly)? = obj["localOnly"],
              case .string(let status)? = obj["status"],
              status == "pending" || SwiftNativeApprovalInbox.terminalApprovalStatuses.contains(status)
        else { return nil }
        for key in ["lastRequestedAt", "decidedBy", "detail", "cause"] {
            if let value = obj[key] {
                guard case .string = value else { return nil }
            }
        }
        if case .string(let last)? = obj["lastRequestedAt"],
           NativeTimestampFormat.parseISO8601FractionalFirst(last) == nil { return nil }
        for key in ["executedAction", "chatContinuation", "chatCard"] {
            if let value = obj[key] {
                guard case .object = value else { return nil }
            }
        }
        if status == "pending" || status == "orphaned" {
            guard obj["decision"] == .null, obj["resolvedAt"] == .null,
                  obj["decidedBy"] == nil, obj["resolutionProvenance"] == nil else { return nil }
        } else {
            guard case .string(let decision)? = obj["decision"], ApprovalDecision(rawValue: decision) != nil,
                  case .string(let resolved)? = obj["resolvedAt"],
                  NativeTimestampFormat.parseISO8601FractionalFirst(resolved) != nil,
                  case .string(let decider)? = obj["decidedBy"], !decider.isEmpty,
                  let provenanceJSON = obj["resolutionProvenance"],
                  let provenance = ApprovalResolutionProvenance(json: provenanceJSON),
                  provenance.decidedBy == decider else { return nil }
            if status == "denied", decision != "denied" { return nil }
            if status == "canceled", decision != "canceled" { return nil }
        }
        self.id = savedID
        self.recordedTitle = title
        self.action = action
        self.risk = risk
        self.reason = reason
        self.status = status
        self.payload = .object(payload)
        self.recordedPayloadPreview = preview
        self.createdAt = created
        self.lastRequestedAt = obj["lastRequestedAt"]?.stringValue
        self.resolvedAt = obj["resolvedAt"]?.stringValue
        self.decision = obj["decision"]?.stringValue
        self.decidedBy = obj["decidedBy"]?.stringValue
        self.resolutionProvenance = obj["resolutionProvenance"].flatMap(ApprovalResolutionProvenance.init(json:))
        self.remoteResolvable = remoteResolvable
        self.localOnly = localOnly
        self.executedAction = obj["executedAction"]
        self.executionDetail = obj["detail"]?.stringValue
        self.cause = obj["cause"]?.stringValue
        self.chatContinuation = obj["chatContinuation"]
        self.chatCard = obj["chatCard"]
    }

    /// Nullable decision fields are explicit null; execution and detail keys are omitted until present.
    public func toJSON(forStorage: Bool = false) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(forStorage ? recordedTitle : title),
            "action": .string(action),
            "risk": .string(risk),
            "reason": .string(reason),
            "status": .string(status),
            "payload": payload,
            "payloadPreview": .string(forStorage ? recordedPayloadPreview : payloadPreview),
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
    public var status: String?
    /// If set, only records whose `action` matches, compared through `ExecutionEventVocabulary`.
    public var action: String?

    public init(status: String? = nil, action: String? = nil) {
        self.status = status
        self.action = action
    }

    public static let all = ApprovalFilter()
    public static let pending = ApprovalFilter(status: "pending")
    public static let resolved = ApprovalFilter(status: "resolved")
}

public enum ApprovalDecision: String, Sendable, Equatable {
    case approved
    case denied
    case canceled
}

/// Distinct remote origins let the inbox bind transport authority under its decision-write lock; labels cannot confer it.
public enum ApprovalResolutionProvenance: Sendable, Equatable {
    case local(decidedBy: String)
    case telegram(chatID: String, userID: String)
    case signedIOS(clientID: String, decidedBy: String)
    indirect case personMessage(sessionID: String, messageID: String, door: ApprovalResolutionProvenance)

    public static let schema = "approval-resolution-provenance.v1"

    public var decidedBy: String {
        switch self {
        case .local(let decidedBy), .signedIOS(_, let decidedBy):
            return decidedBy
        case .telegram:
            return "telegram_verified_user"
        case .personMessage:
            return "agent_on_person_message"
        }
    }

    /// Chat decisions retain the verifying transport without claiming the person tapped.
    public var transport: ApprovalResolutionProvenance {
        if case .personMessage(_, _, let door) = self { return door }
        return self
    }

    fileprivate var messageDoorName: String {
        switch self {
        case .local: "Mac chat"
        case .signedIOS: "your paired iPhone"
        case .telegram: "Telegram"
        case .personMessage: "a person-message decision"
        }
    }

    public var messageAttribution: String? {
        guard case .personMessage(let sessionID, let messageID, let door) = self else { return nil }
        return "Decided by the agent on your message \(messageID) in conversation \(sessionID), through \(door.messageDoorName)"
    }

    var isRemote: Bool {
        switch self {
        case .telegram, .signedIOS: true
        case .local: false
        case .personMessage(_, _, let door): door.isRemote
        }
    }

    var channel: String {
        switch self {
        case .local: "local"
        case .telegram: "telegram"
        case .signedIOS: "ios_signed"
        case .personMessage: "person_message"
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
        case "person_message":
            guard decidedBy == "agent_on_person_message",
                  case .string(let sessionID)? = object["sessionID"],
                  NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID,
                  case .string(let messageID)? = object["messageID"], !messageID.isEmpty,
                  case .object(let doorFields)? = object["door"], doorFields["channel"] != .string("person_message"),
                  let door = Self(json: .object(doorFields)) else { return nil }
            self = .personMessage(sessionID: sessionID, messageID: messageID, door: door)
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
        if case .personMessage(let sessionID, let messageID, let door) = self {
            object["sessionID"] = .string(sessionID)
            object["messageID"] = .string(messageID)
            object["door"] = door.toJSON()
        }
        return .object(object)
    }
}

extension ApprovalResolutionProvenance {
    /// Who decided, read from the person's own act at the door the person tapped: the Mac, the paired phone its router verified, or Telegram's
    /// verified sender in its chat. Nil when that door verified no one (a phone tap with no device, a Telegram tap with no sender or chat)
    /// or the act was no tap: nothing is invented, so no approval is answered.
    public init?(personAct: PersonAct) {
        func named(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        switch personAct.door {
        case "mac": self = .local(decidedBy: "mac_ui")
        case "phone":
            guard let device = named(personAct.device) else { return nil }
            self = .signedIOS(clientID: device, decidedBy: "ios_signed_operator")
        case "telegram":
            guard let chat = named(personAct.chat), let sender = named(personAct.device) else { return nil }
            self = .telegram(chatID: chat, userID: sender)
        default: return nil
        }
    }
}

extension Door {
    /// Every door an ask (an approval, a request) reaches the person by, whoever raised it: the phone, the Mac, the thread it came from, the
    /// person's own Telegram chat while Telegram has its one owner, and the person's own conversation unless it was raised there.
    public static func asking(thread: Door?, unless origin: String?, dataRoot: URL) throws -> [Door] {
        let telegram = thread.map { if case .telegram = $0 { true } else { false } } == true ? nil : try PersonsTelegram.door(dataRoot)
        return person(thread: thread) + [telegram, try personsConversation(unless: origin, dataRoot: dataRoot)].compactMap { $0 }
    }

    /// The person's own conversation as a matter's door: the anchored direct conversation, unless the matter was raised there (its own row
    /// already holds the card). One rule for every ask that reaches the person, approvals and interactions alike.
    public static func personsConversation(unless origin: String?, dataRoot: URL) throws -> Door? {
        guard let anchor = try ConversationAnchor.checkedCurrent(dataRoot: dataRoot)?.sessionId,
              NativeAgentChatSessionID.normalizedPathComponent(anchor) == anchor,
              origin != anchor else { return nil }
        return .conversation(anchor)
    }
}

/// The person's Telegram chat as an ask's door: Telegram's owner sets how it is read while Telegram runs (the one owner's private chat), and
/// clears it when Telegram stops; with no owner, or Telegram off, an ask has no Telegram door.
public enum PersonsTelegram {
    public typealias Read = @Sendable (URL) throws -> Door?
    private final class Box: @unchecked Sendable { let lock = NSLock(); var read: Read? }
    private static let box = Box()
    public static func use(_ read: Read?) { box.lock.withLock { box.read = read } }
    static func door(_ dataRoot: URL) throws -> Door? { try box.lock.withLock { box.read }?(dataRoot) }
}
