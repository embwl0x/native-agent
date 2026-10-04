import Foundation
import ChatOrchestration
import PersistenceCore

extension ClaudeBridgeMessageRuntime {
    /// OMP: `omp-bridge/wake-jobs/<safe id>.json` not yet settled (a
    /// `finished` may race the settlement write, so it needs the job only).
    /// Codex: a reply job still in `reply-jobs/` naming the message.
    static func agentLiveJobActive(agent: String, messageID: String, finishing: Bool) -> Bool {
        let root = InstallPaths.current.bridgeConfigRoot(dataRoot: PersistenceCore.defaultDataRoot())
        func json(_ url: URL) -> [String: Any]? {
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
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
            guard let job = json(root.appendingPathComponent("omp-bridge/wake-jobs/\(safe(160)).json")),
                  job["messageId"] as? String == messageID else { return false }
            return finishing || job["state"] as? String != "settled"
        case "codex":
            let dir = root.appendingPathComponent("codex-nativeagent-bridge/reply-jobs")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.contains { file in
                guard file.pathExtension == "json", let entries = json(file)?["entries"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["payload"] as? [String: Any])?["messageId"] as? String == messageID }
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
        guard Self.agentLiveJobActive(agent: agent, messageID: message, finishing: event == "finished") else {
            response(409, ["error": "no_active_job"])
            return
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
