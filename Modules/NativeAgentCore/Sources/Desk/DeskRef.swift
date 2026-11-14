import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `DeskRef.swift` | Stable Desk references and their persisted tagged-union identity |

// MARK: - Ref (tagged union by `kind`, each carries a stable refId)

public enum DeskRefKind: Sendable, Equatable {
    case file(path: String, line: Int?, label: String?)
    case commit(sha: String, repo: String?, label: String?, status: String?)
    case ghIssue(repo: String, number: Int, title: String?, status: String?)
    case ghPr(repo: String, number: Int, title: String?, status: String?, checks: String?)
    case url(url: String, title: String?)
    case agent(name: String, handoffId: String?, sessionId: String?)
    case approval(id: String, status: String?)
    case trace(id: String, kind: String?)
    case note(text: String)
    case step(DeskStep)

    public var token: String {
        switch self {
        case .file: return "file"
        case .commit: return "commit"
        case .ghIssue: return "gh_issue"
        case .ghPr: return "gh_pr"
        case .url: return "url"
        case .agent: return "agent"
        case .approval: return "approval"
        case .trace: return "trace"
        case .note: return "note"
        case .step: return "step"
        }
    }

    public var priority: Int {
        switch self {
        case .ghPr: return 0
        case .ghIssue: return 1
        case .file: return 2
        case .commit: return 3
        case .url: return 4
        case .agent: return 5
        case .approval: return 6
        case .trace: return 7
        case .note: return 8
        case .step: return 9
        }
    }
}

/// A piece is a made thing laid on an item: a url reference addressed `make:<Make ref>`, so every build reads it as a url reference.
public enum DeskPiece {
    public static let scheme = "make:"

    /// The Make ref an address lays, or nil when the address is not a piece's.
    public static func makeRef(address: String) -> String? {
        guard address.hasPrefix(scheme) else { return nil }
        let ref = String(address.dropFirst(scheme.count))
        return ref.isEmpty ? nil : ref
    }

    /// The Make ref a reference lays, or nil when it is not a piece.
    public static func makeRef(_ ref: DeskRef) -> String? {
        guard case .url(let url, _) = ref.kind else { return nil }
        return makeRef(address: url)
    }

    /// What is on the table: each piece laid on a board item that is not finished, with its item, as the Desk page draws **On the table**.
    public static func onTable(_ state: DeskState) -> [(item: DeskItem, ref: DeskRef)] {
        state.board.items.filter { !$0.status.isTerminal }.flatMap { item in item.refs.filter { makeRef($0) != nil }.map { (item: item, ref: $0) } }
    }
}

public struct DeskRef: Sendable, Equatable {
    public var refId: String
    public var kind: DeskRefKind

    public init(refId: String = DeskClock.newRefId(), kind: DeskRefKind) {
        self.refId = refId
        self.kind = kind
    }

    public var priority: Int { kind.priority }

    /// Omit nil fields instead of emitting null so the wire form matches the shared event writer.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "kind": .string(kind.token),
            "refId": .string(refId),
        ]
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { obj[k] = .string(v) } }
        func putInt(_ k: String, _ v: Int?) { if let v { obj[k] = .int(Int64(v)) } }
        switch kind {
        case let .file(path, line, label):
            obj["path"] = .string(path); putInt("line", line); put("label", label)
        case let .commit(sha, repo, label, status):
            obj["sha"] = .string(sha); put("repo", repo); put("label", label); put("status", status)
        case let .ghIssue(repo, number, title, status):
            obj["repo"] = .string(repo); obj["number"] = .int(Int64(number)); put("title", title); put("status", status)
        case let .ghPr(repo, number, title, status, checks):
            obj["repo"] = .string(repo); obj["number"] = .int(Int64(number)); put("title", title); put("status", status); put("checks", checks)
        case let .url(url, title):
            obj["url"] = .string(url); put("title", title)
        case let .agent(name, handoffId, sessionId):
            obj["name"] = .string(name); put("handoffId", handoffId); put("sessionId", sessionId)
        case let .approval(id, status):
            obj["id"] = .string(id); put("status", status)
        case let .trace(id, kind):
            // traceKind prevents the payload from overwriting the union discriminator.
            obj["id"] = .string(id); put("traceKind", kind)
        case let .note(text):
            obj["text"] = .string(text)
        case let .step(step):
            obj.merge(step.fields) { _, new in new }
        }
        return .object(obj)
    }

    /// Decode every current field so stored references retain their full identity.
    public static func fromJSON(_ value: JSONValue) -> DeskRef? {
        guard case .object(let obj) = value,
              let token = obj["kind"]?.stringValue,
              let refId = obj["refId"]?.stringValue, !refId.isEmpty else { return nil }
        let kind: DeskRefKind
        switch token {
        case "file":
            guard let path = obj["path"]?.stringValue else { return nil }
            kind = .file(path: path, line: jsonInt(obj, "line"), label: obj["label"]?.stringValue)
        case "commit":
            guard let sha = obj["sha"]?.stringValue else { return nil }
            kind = .commit(sha: sha, repo: obj["repo"]?.stringValue, label: obj["label"]?.stringValue, status: obj["status"]?.stringValue)
        case "gh_issue":
            guard let repo = obj["repo"]?.stringValue, let number = jsonInt(obj, "number") else { return nil }
            kind = .ghIssue(repo: repo, number: number, title: obj["title"]?.stringValue, status: obj["status"]?.stringValue)
        case "gh_pr":
            guard let repo = obj["repo"]?.stringValue, let number = jsonInt(obj, "number") else { return nil }
            kind = .ghPr(repo: repo, number: number, title: obj["title"]?.stringValue, status: obj["status"]?.stringValue, checks: obj["checks"]?.stringValue)
        case "url":
            guard let url = obj["url"]?.stringValue else { return nil }
            kind = .url(url: url, title: obj["title"]?.stringValue)
        case "agent":
            guard let name = obj["name"]?.stringValue else { return nil }
            kind = .agent(name: name, handoffId: obj["handoffId"]?.stringValue, sessionId: obj["sessionId"]?.stringValue)
        case "approval":
            guard let id = obj["id"]?.stringValue else { return nil }
            kind = .approval(id: id, status: obj["status"]?.stringValue)
        case "trace":
            guard let id = obj["id"]?.stringValue else { return nil }
            kind = .trace(id: id, kind: obj["traceKind"]?.stringValue)
        case "note":
            guard let text = obj["text"]?.stringValue else { return nil }
            kind = .note(text: text)
        case "step":
            guard let step = DeskStep(fields: obj) else { return nil }
            kind = .step(step)
        default:
            return nil
        }
        let ref = DeskRef(refId: refId, kind: kind)
        guard ref.toJSON() == value else { return nil }
        return ref
    }
}
