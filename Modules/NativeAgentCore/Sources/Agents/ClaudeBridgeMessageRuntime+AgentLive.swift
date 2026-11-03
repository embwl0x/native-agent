import Foundation
import AgentConversations
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ClaudeBridgeMessageRuntime+AgentLive.swift` | `ClaudeBridgeMessageRuntime`: `agentLiveJobActive`, `handleAgentLive` |

extension ClaudeBridgeMessageRuntime {
    /// OMP: `omp-bridge/wake-jobs/<safe id>.json` not yet settled (a
    /// `finished` may race the settlement write, so it needs the job only).
    /// Codex: a reply job still in `reply-jobs/` naming the message.
    static func agentLiveJobActive(agent: String, messageID: String, finishing: Bool) throws -> Bool {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let root = InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        func json(_ url: URL) throws -> [String: Any]? {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            guard let job = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentConversationStore.Failure(message: "The live job file is malformed: " + url.path)
            }
            guard try DataRootLife.isCurrent(job["lifeID"] as? String, in: dataRoot) else { return nil }
            return job
        }
        // The helpers' safeFilePart: anything outside [A-Za-z0-9._-] becomes "_".
        func safe(_ limit: Int) -> String {
            String(String(messageID.unicodeScalars.map { scalar -> Character in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
                    ? Character(scalar) : "_"
            }).prefix(limit))
        }
        switch agent {
        case "omp":
            let file = root.appendingPathComponent("omp-bridge/wake-jobs/\(safe(160)).json")
            guard let job = try json(file) else { return false }
            guard job["messageId"] as? String == messageID, let state = job["state"] as? String else {
                throw AgentConversationStore.Failure(message: "The live job identity or state is malformed: " + file.path)
            }
            return finishing || state != "settled"
        case "codex":
            let dir = root.appendingPathComponent("codex-nativeagent-bridge/reply-jobs")
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
            return try files.contains { file in
                guard file.pathExtension == "json" else { return false }
                guard let job = try json(file) else { return false }
                guard let entries = job["entries"] as? [[String: Any]] else {
                    throw AgentConversationStore.Failure(message: "The live job entries are malformed: " + file.path)
                }
                return try entries.contains { entry in
                    guard let payload = entry["payload"] as? [String: Any], let id = payload["messageId"] as? String else {
                        throw AgentConversationStore.Failure(message: "The live job message identity is malformed: " + file.path)
                    }
                    return id == messageID
                }
            }
        default: return false
        }
    }

    /// Body: `{message_id, event: started|partial|note|activity|finished,
    /// text?, delta?, note?, streams?}`. `text` is the whole reply so far.
    public func handleAgentLive(response: @escaping Response, body: Data, agent: String) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = (json["message_id"] ?? json["messageId"]) as? String,
              !message.isEmpty, message.utf8.count <= 128,
              let event = json["event"] as? String,
              ["started", "partial", "note", "activity", "finished"].contains(event) else {
            response(400, ["error": "invalid_live_event"])
            return
        }
        func field(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty else { return nil }
            return String(value.prefix(64 * 1024))
        }
        // The bridge bearer is shared by every lane; only the lane's own
        // unsettled wake job for this exact message may speak for it.
        do {
            guard try Self.agentLiveJobActive(agent: agent, messageID: message, finishing: event == "finished") else {
                response(409, ["error": "no_active_job"]); return
            }
        } catch {
            response(503, ["error": "live_job_unavailable", "detail": "The accepted job could not be read: \(error.localizedDescription). Repair its saved job evidence; do not resend the message."]); return
        }
        let target = AgentConversationLiveTarget.message(agent: agent, messageID: message, dataRoot: PersistenceCore.defaultDataRoot())
        let streams = json["streams"] as? Bool ?? false
        Task { [weak self] in
            let hub = AgentConversationLiveHub.shared
            switch event {
            case "started": await hub.begin(target, lane: agent, streams: streams, note: field("note"))
            case "partial": await hub.text(target, delta: field("delta"), replace: field("text"))
            case "note": if let note = field("note") ?? field("text") { await hub.note(target, note) }
            case "activity": await hub.activity(target)
            default: await hub.settle(target, state: "finished", note: field("note"))
            }
            self?.writeLiveResponse(response, status: 200, obj: ["status": "ok"])
        }
    }

    private func writeLiveResponse(_ response: Response, status: Int, obj: [String: Any]) {
        response(status, obj)
    }
}
