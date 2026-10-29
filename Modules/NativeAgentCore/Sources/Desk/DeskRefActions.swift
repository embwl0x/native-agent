import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskRefActions.swift` | `DeskRefAction`, `DeskRefAffordance`: reference open destinations and copy text |

public enum DeskRefAction: Equatable, Sendable {
    case open(url: String, label: String)
    case copy(text: String, label: String)

    public var label: String {
        switch self {
        case .open(_, let label): return label
        case .copy(_, let label): return label
        }
    }

    public var opensExternally: Bool {
        if case .open = self { return true }
        return false
    }
}

public enum DeskRefAffordance {
    public static func action(for ref: DeskRef) -> DeskRefAction {
        switch ref.kind {
        case let .ghPr(repo, number, title, _, _):
            return .open(
                url: "https://github.com/\(repo)/pull/\(number)",
                label: title?.isEmpty == false ? title! : "\(repo) #\(number)")
        case let .ghIssue(repo, number, title, _):
            return .open(
                url: "https://github.com/\(repo)/issues/\(number)",
                label: title?.isEmpty == false ? title! : "\(repo) #\(number)")
        case let .url(url, title):
            return .open(url: url, label: title?.isEmpty == false ? title! : url)
        case let .commit(sha, repo, label, _):
            if let repo, !repo.isEmpty {
                return .open(
                    url: "https://github.com/\(repo)/commit/\(sha)",
                    label: label?.isEmpty == false ? label! : String(sha.prefix(8)))
            }
            return .copy(text: sha, label: label?.isEmpty == false ? label! : String(sha.prefix(8)))
        case let .file(path, line, label):
            let text = line.map { "\(path):\($0)" } ?? path
            return .copy(text: text, label: label?.isEmpty == false ? label! : text)
        case let .agent(name, handoffId, sessionId):
            return .copy(text: handoffId ?? sessionId ?? name, label: name)
        case let .approval(id, _):
            return .copy(text: id, label: "approval \(id.prefix(8))")
        case let .trace(id, kind):
            return .copy(text: id, label: kind.map { "\($0) \(id.prefix(8))" } ?? "trace \(id.prefix(8))")
        case let .note(text):
            return .copy(text: text, label: text)
        case let .step(step):
            return .copy(text: step.words, label: "queued " + step.when)
        }
    }
}
