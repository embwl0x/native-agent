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
    /// Carried work: when it is ready and where it came from.
    case step(DeskStep)

    /// Wire token written as the ref's `kind` field.
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

    /// Live-render priority: gh_pr > gh_issue > file > commit > url > agent > approval > trace > note. LOWER number = higher priority (renders first).
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

    /// Merge a sparse `cachedFields` patch (from an `update_ref` op) into the in-place-updatable fields of this ref. Unknown / inapplicable keys are ignored; the immutable identity fields (path, sha, repo, number, url, name, id) are NOT
    /// overwritten.
    public func applyingCachedFields(_ fields: [String: JSONValue]) -> DeskRefKind {
        func num(_ k: String) -> Int? { jsonInt(fields, k) }
        switch self {
        case let .file(path, line, label):
            return .file(path: path, line: num("line") ?? line, label: fields["label"]?.stringValue ?? label)
        case let .commit(sha, repo, label, status):
            // repo is part of identity (like sha) — NOT overwritten by a patch.
            return .commit(sha: sha, repo: repo, label: fields["label"]?.stringValue ?? label, status: fields["status"]?.stringValue ?? status)
        case let .ghIssue(repo, number, title, status):
            return .ghIssue(repo: repo, number: number, title: fields["title"]?.stringValue ?? title, status: fields["status"]?.stringValue ?? status)
        case let .ghPr(repo, number, title, status, checks):
            return .ghPr(repo: repo, number: number, title: fields["title"]?.stringValue ?? title, status: fields["status"]?.stringValue ?? status, checks: fields["checks"]?.stringValue ?? checks)
        case let .url(url, title):
            return .url(url: url, title: fields["title"]?.stringValue ?? title)
        case let .agent(name, handoffId, sessionId):
            return .agent(name: name, handoffId: fields["handoffId"]?.stringValue ?? handoffId, sessionId: fields["sessionId"]?.stringValue ?? sessionId)
        case let .approval(id, status):
            return .approval(id: id, status: fields["status"]?.stringValue ?? status)
        case let .trace(id, kind):
            // `traceKind` mirrors the wire key (the discriminator owns `kind`).
            return .trace(id: id, kind: fields["traceKind"]?.stringValue ?? kind)
        case let .note(text):
            return .note(text: fields["text"]?.stringValue ?? text)
        case .step(var step):
            if step.replyRoute == nil { step.replyRoute = fields["replyRoute"] }
            return .step(step)
        }
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

    /// Serialize to the wire form `{kind, refId, ...fields}`. Optional fields omitted when nil (NOT emitted as null), exactly like TaskLedgerEvent.
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
            // The trace payload's own "kind" is written under `traceKind` so it never clobbers the union discriminator (`kind` == "trace").
            obj["id"] = .string(id); put("traceKind", kind)
        case let .note(text):
            obj["text"] = .string(text)
        case let .step(step):
            obj.merge(step.fields) { _, new in new }
        }
        return .object(obj)
    }

    /// Tolerant decode. An unknown `kind` token → nil (skipped by the caller).
    public static func fromJSON(_ value: JSONValue) -> DeskRef? {
        guard case .object(let obj) = value,
              let token = obj["kind"]?.stringValue else { return nil }
        // Deterministic fallback when `refId` is absent (legacy / hand-authored line): an empty id, NEVER a fresh random UUID — a random one would make each rebuild produce a different DeskState and drift state.json.
        let refId = obj["refId"]?.stringValue ?? ""
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
            return nil // tolerant: unknown ref kinds skipped
        }
        return DeskRef(refId: refId, kind: kind)
    }
}
