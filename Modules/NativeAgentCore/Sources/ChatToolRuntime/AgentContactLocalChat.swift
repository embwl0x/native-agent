import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `AgentContactLocalChat.swift` | A host's local chat server: its loaded model answers the conversation's history, streamed live. |
extension SwiftToolDispatcher {
    /// One message to a host's local chat server (`host.localChat`). The server keeps no conversation, so the request carries this conversation's
    /// answered exchanges before the new message. It answers with a model the host already has loaded; a server that is off, or has nothing
    /// loaded, is said so and nothing is sent: the server is never started, nor a model loaded, on the agent's behalf. The conversation is
    /// resumable by its own history, so every receipt names it: the id it was sent under, else its record's.
    func hostLocalChatRun(invocation: ChatToolInvocation, row: AgentHostRow, contact: AgentPeerContact, message: String, conversationID: String?,
                          store: AgentPeerStore, surface: String) async throws -> JSONValue {
        guard let chat = row.localChat else { throw AgentCommunicationError.invalid("\(row.displayName) has no local chat server") }
        // The recipe this send is made under; a later edit does not restamp its proof.
        let recipe = AgentRecipeStore.recipe(row.id).flatMap { $0.host == row ? $0 : nil }
        let began = Date()
        var receipt: [String: JSONValue] = ["agent": .string("peer:" + contact.id), "transport": .string("mcpHost"), "host": .string(row.id),
            "route": .string("local-chat"), "completed": .bool(false)]
        if invocation.dryRun {
            receipt["dry_run"] = .bool(true)
            receipt["checked"] = .array([.string("localChat.server"), .string("localChat.models")])
        } else {
            receipt["conversation_id"] = .string(conversationID ?? invocation.liveTarget?.recordID ?? UUID().uuidString.lowercased())
        }
        func notSent(_ reason: String, _ detail: String) -> JSONValue {
            var result = receipt
            result["status"] = .string(invocation.dryRun ? "failed" : "unavailable")
            result["reason"] = .string(reason)
            result["sent"] = .bool(false)
            result["detail"] = .string(detail + " Nothing was sent.")
            return .object(result)
        }
        guard let server = URL(string: chat.server), ["http", "https"].contains(server.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(server.host?.lowercased() ?? ""),
              let models = URL(string: chat.server + chat.models), let endpoint = URL(string: chat.server + chat.chat) else {
            return notSent("local_chat_misconfigured", """
                agents/recipes/\(row.id).json host.localChat must name a loopback http server and its paths (server is \(chat.server)); \
                correct it with agent.recipe_write.
                """)
        }

        // This conversation so far, read first so the model read below is the last thing before the send: each exchange that has both its
        // message and its answer, oldest first, then the new message.
        var messages: [LLMMessage] = []
        if let target = invocation.liveTarget, let record = target.recordID {
            let exchanges = try AgentConversationStore(dataRoot: dataRoot).records().first { $0.id == record }?.exchanges ?? []
            for exchange in exchanges where exchange.id != target.operationID {
                guard let prompt = exchange.prompt, let reply = exchange.reply else { continue }
                messages += [.user(prompt), .assistantText(reply)]
            }
        }
        messages.append(.user(message))

        // The loaded model, read without loading one, right before the send: a chat request that names an unloaded model would make the host
        // load it (LM Studio's chat completions take no "only if loaded" option and report no load), so only a model that unloads in the gap
        // between these two local requests could be loaded again by the send.
        let loaded: [String]
        do {
            // No clock ends the read: a server that is off refuses at once, and Stop cancels it.
            var request = URLRequest(url: models)
            request.timeoutInterval = .infinity
            let (data, response) = try await ProviderHTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let said = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return notSent("local_chat_refused", "\(row.displayName)'s server at \(chat.server) answered HTTP \(status) to \(chat.models)"
                    + (said.isEmpty ? "." : ": " + said))
            }
            guard let found = Self.loadedChatModels(data) else {
                return notSent("local_chat_models_unreadable", """
                    \(row.displayName)'s server at \(chat.server) answered \(chat.models), but not as a model list with loaded instances.
                    """)
            }
            loaded = found
        } catch {
            if Task.isCancelled {
                return .object(receipt.merging(["status": .string("cancelled"), "sent": .bool(false), "terminal": .bool(true),
                    "detail": .string("The message was stopped before it went out. Nothing was sent.")]) { $1 })
            }
            store.recordUnavailable(peerID: contact.id, step: "Its server is off. " + chat.start)
            return notSent("local_chat_server_off", """
                \(row.displayName)'s server is not on at \(chat.server) (\(error.localizedDescription)), so nothing can answer. \(chat.start)
                """)
        }
        guard let model = loaded.first else {
            return notSent("no_model_loaded", """
                \(row.displayName)'s server is on, but it has no model loaded, so nothing can answer. Load a model in \(row.displayName), then send \
                again.
                """)
        }
        receipt["model"] = .string(model)
        if loaded.count > 1 { receipt["loaded_models"] = .array(loaded.map(JSONValue.string)) }
        if invocation.dryRun {
            receipt["status"] = .string("passed")
            receipt["sent"] = .bool(false)
            receipt["detail"] = .string("\(row.displayName)'s server is on at \(chat.server) with \(model) loaded; no prompt was sent.")
            return .object(receipt)
        }

        let transport = OpenAITransport(endpoint: endpoint, apiKeyOverride: row.id, dataRootOverride: dataRoot,
                                        providerId: row.id, providerLabel: row.displayName)
        var call = LLMCall(turn: nil, surface: surface, purpose: "contact message: " + row.displayName)
        call.traceDataRoot = dataRoot
        let live = invocation.liveTarget
        let hub = AgentConversationLiveHub.shared
        var said = ""
        var cut: LLMToolBoundaryReason?
        do {
            for try await event in transport.streamMessages(messages: messages, system: nil, model: model, tools: nil, call: call) {
                switch event {
                case .textDelta(let text):
                    said += text
                    if let live { await hub.text(live, delta: text) }
                case .keepAlive, .callInput:
                    if let live { await hub.activity(live) }
                case .toolBoundary(let reason): cut = reason
                default: break
                }
            }
        } catch {
            var result = receipt
            result["sent"] = .null
            if Task.isCancelled || error is CancellationError {
                result["status"] = .string("cancelled")
                result["terminal"] = .bool(true)
                result["detail"] = .string("The conversation was stopped.")
            } else if let failure = ProviderFailure.report(error, work: .outcomeUnknown) {
                Self.peerFailure(failure, into: &result)
            } else {
                result["status"] = .string("outcome_unknown")
                result["terminal"] = .bool(true)
                result["detail"] = .string("\(row.displayName)'s answer did not finish: \(ProviderFailure.diagnosticDescription(error))")
            }
            if !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result["reply"] = .string(said)
                result["untrusted_remote_data"] = .bool(true)
            }
            return .object(result)
        }
        store.recordProof(peerID: contact.id, outbound: true)
        // Its server answered: an earlier unavailable mark (server off) clears with its step.
        store.clearUnavailable(peerID: contact.id, before: began)
        let answered = !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        receipt["sent"] = .bool(true)
        receipt["reply"] = .string(said)
        receipt["untrusted_remote_data"] = .bool(answered)
        // An answer the model did not finish is what it said so far, never a completed reply.
        if let cut {
            receipt["status"] = .string("incomplete")
            receipt["reply_truncated"] = .bool(true)
            receipt["stop_reason"] = .string(cut.rawValue)
            receipt["detail"] = .string(cut == .outputLimit
                ? "\(model)'s answer was cut at its output limit; this is what it said before the cut."
                : "\(model)'s answer was cut (\(cut.rawValue)); this is what it said before the cut.")
            return .object(receipt)
        }
        if answered { store.recordRoundTrip(peerID: contact.id, workspace: chat.server, recipe: recipe) }
        receipt["status"] = .string("replied")
        receipt["completed"] = .bool(true)
        return .object(receipt)
    }

    /// The ids of the loaded chat models in a model list shaped `{"models": [{"type": "llm", "loaded_instances": [{"id": …}]}]}`; nil for any
    /// other shape.
    static func loadedChatModels(_ data: Data) -> [String]? {
        guard case .object(let root)? = try? JSONValue.parse(data), case .array(let models)? = root["models"] else { return nil }
        return models.flatMap { model -> [String] in
            guard case .object(let fields) = model, fields["type"] == .string("llm"),
                  case .array(let instances)? = fields["loaded_instances"] else { return [] }
            return instances.compactMap { if case .object(let instance) = $0, case .string(let id)? = instance["id"] { id } else { nil } }
        }
    }
}
