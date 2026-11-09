import Foundation
import NativeAgentShared
import ChatTurnRuntime
import AgentWorkspace
import ChatToolParsing
import AgentLinkTransport
import NativeAgentCore
import PersistenceCore
import AgentConversations
import ApprovalInbox
import Darwin
import CoreFoundation
import ProviderRouting
import CryptoKit
import SQLite3
import UniformTypeIdentifiers
// Blueprint: | `AgentContactTaskValues.swift` | Execution and payload debt remain distinct. |
public enum AgentContactTaskState: String, Codable, Sendable {
    case submitted, working, inputRequired = "input-required", completed, failed, canceled, stopped
    public var terminal: Bool { self == .completed || self == .failed || self == .canceled || self == .stopped }
}
public struct AgentContactTask: Codable, Sendable {
    public var lifeID: String?
    public let id: String
    public let context: String
    public let owner: String
    public var state: AgentContactTaskState = .submitted
    public var text = ""
    public var parts: [AgentContactPart] = []
    public var detail: String?
    public var failure: ProviderFailure.Report?
    public var updated = Date()
    public var canonicalSession: String?
    public var canonicalRunID: String?
    /// Builder routing/provenance only; transcript owns its accepted words and files.
    public var bridgeInput: AgentContactBridgeInput?
    public var acceptedOutputModes: [String]?
    /// Set when the contact gave this task as a job rather than a conversation.
    public var job: AgentContactJob?
    public var toolResult: JSONValue?
    public var delegatedCompletions: [String: AgentContactPart]?
    public var approvalIDs: Set<String>?
    public var replyPayloadExpired: Bool?
    /// Execution can be terminal while its saved payload still needs repair.
    public var replyRecovery: AgentContactReplyRecovery?
    public var delegatedCompletionDigests: [String: String]?
    /// Persist registered callbacks before accepting execution.
    public var callbacks: [String: AgentContactCallback]?
    var owesCallbacks: Bool {
        callbacks?.values.contains { $0.delivered != state.rawValue } == true
    }
    var needsReplyRecovery: Bool {
        !state.terminal || replyRecovery != nil
    }
    var hasReplyPayload: Bool {
        !text.isEmpty || !parts.isEmpty || toolResult != nil || failure != nil
            || delegatedCompletions?.isEmpty == false
    }
}
public struct AgentContactReplyRecovery: Codable, Sendable {
    public let source: String
    public let detail: String
}
public enum AgentContactEvent: Sendable {
    case snapshot(AgentContactTask)
    case status(AgentContactTask, final: Bool)
    case artifact(task: AgentContactTask, artifactID: String, parts: [AgentContactPart], append: Bool, last: Bool)
}
struct AgentContactTurn: Sendable {
    let taskID: String
    let context: String
    let requestID: String
    let principal: AgentBridgePrincipal
    let parts: [AgentContactPart]
    var bindRun: @Sendable (String, String) async throws -> Void = { _, _ in }
    /// Restarted queued input is already canonical in the conversation.
    var accepted: EnqueuedUserMessage? = nil
    var bridgeInput: AgentContactBridgeInput? = nil
    var job: AgentContactJob? = nil
}
enum AgentContactProgress: Sendable {
    case working
    case text(String)
    case waiting
    case approval(String)
}
struct AgentContactOutcome: Sendable {
    var state: AgentContactTaskState
    var parts: [AgentContactPart]
    var detail: String? = nil
    var failure: ProviderFailure.Report? = nil
    var replyRecovery: AgentContactReplyRecovery? = nil
    var toolResult: JSONValue? = nil
}

/// A job a contact gave the agent over A2A. The brief is the message text and the input files are its file parts; the task's one folder is derived from its id.
public struct AgentContactJob: Codable, Sendable, Equatable {
    /// What the contact says will be true when the job is done. Peer words: quoted to the agent as data, never an instruction.
    public let done: String?

    static let skill = "job"
    static let maximumDoneBytes = 2000

    /// One folder per task under the agent-runs area; the files the agent makes for the job go here and come back as its artifacts.
    static func folder(taskID: String, dataRoot: URL) -> URL {
        AgentHostConnection.builderWorkspaceRoot(dataRoot: dataRoot).appendingPathComponent("agent-bridge-runs/inbound-jobs/" + taskID)
    }

    /// Save the contact's files under `input/` in the order sent and return their folder-relative names. The folder exists afterwards.
    static func stage(_ parts: [AgentContactPart], taskID: String, dataRoot: URL) throws -> [String] {
        let input = folder(taskID: taskID, dataRoot: dataRoot).appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var names: [String] = []
        for case .file(let name, _, let bytes, _) in parts {
            // The contact names the file, never where it goes: one plain name inside input/.
            let plain = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
            let saved = "\(names.count + 1)-" + (plain.isEmpty || plain.hasPrefix(".") ? "file" : plain)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: input.appendingPathComponent(saved))
            names.append("input/" + saved)
        }
        return names
    }

    /// Retain each readable artifact and name every file whose delivery needs repair.
    static func fileParts(taskID: String, dataRoot: URL) throws -> (parts: [AgentContactPart], failures: [String]) {
        let entries = try FileManager.default.contentsOfDirectory(at: folder(taskID: taskID, dataRoot: dataRoot),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var parts: [AgentContactPart] = []
        var failures: [String] = []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            do {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                guard let regular = values.isRegularFile else {
                    throw AgentContactFailure(code: -32603, message: "Regular-file metadata is unavailable")
                }
                guard regular else { continue }
                let mime = UTType(filenameExtension: entry.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let attachment = ChatTurnRuntime.MultimodalAttachment(type: "file", base64: "", mime: mime, name: entry.lastPathComponent, path: entry.path)
                parts.append(try AgentContactPart.output(attachment, taskID: taskID))
            } catch { failures.append(entry.path + ": " + ((error as? AgentContactFailure)?.message ?? error.localizedDescription)) }
        }
        return (parts, failures)
    }
}

extension AgentContactTask {
    /// A conversation's reply is one artifact. A job's report is one artifact and each file the agent made is another.
    func replyArtifacts(_ parts: [AgentContactPart]) -> [(id: String, parts: [AgentContactPart])] {
        guard !parts.isEmpty else { return [] }
        guard job != nil else { return [(id: id + "-reply", parts: parts)] }
        var artifacts: [(id: String, parts: [AgentContactPart])] = []
        let report = parts.filter { if case .file = $0 { false } else { true } }
        if !report.isEmpty { artifacts.append((id: id + "-reply", parts: report)) }
        let files = parts.filter { if case .file = $0 { true } else { false } }
        for (index, file) in files.enumerated() { artifacts.append((id: id + "-file-\(index + 1)", parts: [file])) }
        return artifacts
    }
}
