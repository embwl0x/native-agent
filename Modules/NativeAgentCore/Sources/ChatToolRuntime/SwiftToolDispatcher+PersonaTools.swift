import Foundation
import ChatToolParsing
import ChatSessionWork
import ToolRegistry
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import DreamREMCycle
// Blueprint: | `SwiftToolDispatcher+PersonaTools.swift` | `SwiftToolDispatcher`; persona writes; build and route owners |

// MARK: - Persona and runtime introspection tools

extension SwiftToolDispatcher {
    private static let personaDocMaxBytes = 64 * 1024

    func impl_get_persona_doc(turn: Turn, input: [String: JSONValue]) async throws -> JSONValue {
        let doc = try requireString(input, input["doc"] == nil && input["kind"] != nil ? "kind" : "doc")
        // Reject traversal so a document name cannot escape the persona root.
        if doc.contains("/") || doc.contains("..") || doc.hasPrefix(".") {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: invalid persona doc name '\(doc)'"
            )
        }
        let docName = doc.hasSuffix(".md") ? doc : "\(doc).md"
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let result = PersonaSystemActions.personaRead([:],
            ConnectorActionContext(repoRoot: rootForRead, dataRoot: dataRoot, personaRoot: personaRoot, turn: turn),
            selectedDocument: personaRoot.appendingPathComponent(docName))
        let reply = ToolResult(result)
        guard case .object(let fields) = result else {
            throw ToolFailureError("Persona reader returned an invalid response.", effects: .none)
        }
        guard case .string(let text)? = fields["content"] else {
            let error = if case .string? = fields["error"] { reply.failure ?? "" } else { "Persona document read failed." }
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: " + error)
        }
        let bytes = Data(text.utf8)
        if bytes.count > Self.personaDocMaxBytes {
            var head = bytes.prefix(Self.personaDocMaxBytes)
            // The whole document is valid UTF-8; only the final scalar may straddle this cap. Remove its incomplete bytes, never the cap.
            while !head.isEmpty, String(data: head, encoding: .utf8) == nil { head.removeLast() }
            let headText = String(decoding: head, as: UTF8.self)
            return .string(headText + "\n... [truncated, \(bytes.count) bytes total]")
        }
        return .string(text)
    }

    func impl_persona_read(turn: Turn, input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try requireString(input, "kind")
        let result = PersonaSystemActions.personaRead(["kind": .string(kind)],
            ConnectorActionContext(repoRoot: rootForRead, dataRoot: dataRoot,
                                   personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot), turn: turn))
        let reply = ToolResult(result)
        if case .object(let fields) = result, fields["ok"] == .bool(false) {
            let error = if case .string? = fields["error"] { reply.failure ?? "" } else { "" }
            if fields["error_code"] == .string("bad_input") {
                throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher persona_read " + error)
            }
            if fields["error_code"] == .string("persona_not_found"),
               let target = SwiftNativePersonaEngine.personaDocumentPath(kind: kind, root: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)) {
                throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher persona_read doc not found at '\(target.path)'")
            }
            throw AutonomyGateError.toolDenied(reason: error)
        }
        return result
    }

    func impl_persona_write(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try requireString(input, "kind")
        let content = try requireString(input, "content")
        let engine = SwiftNativePersonaEngine(root: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot), dataRoot: dataRoot)
        // Approved GROWTH lessons leave only through explicit retirement with a reason, tombstone and pin update.
        var retire: [String: String] = [:]
        if case .object(let named)? = input["retire"] {
            for case let (line, .string(why)) in named where !why.trimmingCharacters(in: .whitespaces).isEmpty {
                retire[line.trimmingCharacters(in: .whitespacesAndNewlines)] = why
            }
        }
        // Hold the REM writer’s GROWTH lock across read/write so concurrent lessons cannot be dropped; unreadable history refuses.
        let store = REMProposalStore(dataRoot: dataRoot)
        let keeping: @Sendable (String) throws -> Void = { [retire] current in
            let rows: [REMProposalRow]
            do { rows = try store.loadAllStrictly() } catch {
                throw PersonaWriteError.ioFailure("the REM approval history could not be read "
                    + "(\(error.localizedDescription)), so GROWTH's approved lines can't be checked. Nothing was written.")
            }
            let dropped = Self.remLines(rows, in: current).filter {
                !REMGrowthWriter.containsEntryParagraph(content, $0) && retire[$0] == nil
            }
            guard dropped.isEmpty else {
                throw PersonaWriteError.invalidInput(
                    "this GROWTH rewrite drops \(dropped.count) line(s) REM approved:\n"
                    + dropped.map { "- \"\($0)\"" }.joined(separator: "\n")
                    + "\nKeep each one, or retire it with a reason: retire: {\"<the line, exactly>\": \"<why it goes>\"}. "
                    + "Nothing was written.")
            }
        }
        do {
            let result = try await engine.personaWrite(
                kind: kind,
                content: content,
                keeping: canonicalPersonaKind(kind) == "growth" ? keeping : nil
            )
            var fields: [String: JSONValue] = [:]
            if case .object(let saved) = personaWriteResultJSON(result) { fields = saved }
            if !retire.isEmpty, canonicalPersonaKind(kind) == "growth" {
                do {
                    let retired = try store.loadAllStrictly().filter { row in
                        let line = row.proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        return row.status != "denied" && retire[line] != nil && !REMGrowthWriter.containsEntryParagraph(content, line)
                    }
                    for row in retired {
                        try await REMTombstoneStore(dataRoot: dataRoot).record(
                            row, reason: retire[row.proposalText.trimmingCharacters(in: .whitespacesAndNewlines)] ?? "")
                    }
                    try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
                    fields["retired"] = .array(retired.map { .string($0.proposalText) })
                } catch {
                    fields["retire_failed"] = .string("GROWTH was written, but retiring its lines failed "
                        + "(\(error.localizedDescription)); REM may offer them again.")
                }
            }
            return .object(fields)
        } catch {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_write failed: \(error.localizedDescription)"
            )
        }
    }

    /// The REM lessons standing in a GROWTH body: approved, or appended by an approval whose flip has not landed yet. A denied one never stands.
    static func remLines(_ rows: [REMProposalRow], in body: String) -> [String] {
        rows.filter { $0.status != "denied" && REMProposalStore.supportsProposalTarget($0.targetDoc) }
            .map { $0.proposalText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { REMGrowthWriter.containsEntryParagraph(body, $0) }
    }

    func impl_persona_append_section(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try requireString(input, "kind")
        let title = try requireString(input, "title")
        let content = try requireString(input, "content")
        let engine = SwiftNativePersonaEngine(root: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot), dataRoot: dataRoot)
        do {
            let result = try await engine.personaAppendSection(
                kind: kind,
                title: title,
                content: content
            )
            return personaWriteResultJSON(result)
        } catch {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher persona_append_section failed: \(error.localizedDescription)"
            )
        }
    }

    func impl_agent_introspect(turn: Turn, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let sessionId = ChatToolSessionInjection.explicitSessionId(in: input)
        let fullDetail = (input["detail"]?.stringValue ?? "compact")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "full"
        let pid = ProcessInfo.processInfo.processIdentifier
        let provider = await Self.providerStamp(turn: turn, dataRoot: dataRoot)
        let runtimeInstanceID = "swift-native-\(pid)"
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "detail": .string(fullDetail ? "full" : "compact"),
            "invoked_as": .string("agent_introspect"),
            "runtime": .string("swift-native"),
            "provider": provider,
            "dispatch": .object([
                "provider_tools_field": .bool(true),
                "tool_loop": .string("SwiftNativeTurnEngine.executeTurnWithStreamingToolLoop"),
                "dispatcher": .string("SwiftToolDispatcher"),
            ]),
            "identity": .object([
                "bundle_id": Bundle.main.bundleIdentifier.map(JSONValue.string) ?? .null,
                "data_root": .string(dataRoot.path),
                "build": Self.buildStamp(identity: .current),
            ]),
            "launch": .object([
                "runtime_instance_id": .string(runtimeInstanceID), "process_id": .int(Int64(pid)),
                "note": .string("These ids identify this running process only and change on relaunch; they are not your durable identity."),
            ]),
            "tool_state": .string("""
                app is your one tool; app {find} finds an action by what you want done. Request detail=full for diagnostic roots and outcome \
                population health
                """),
        ]
        if case .object(let stamp) = provider, case .string(let model)? = stamp["model"] {
            var window = try await ContextWindowPolicy.readout(
                forModel: model, providerID: stamp["name"]?.stringValue, dataRoot: dataRoot,
                call: LLMCall(turn: turn, surface: turn.runtime?.surface ?? "chat", purpose: "agent.introspect"))
            window["route"] = .object(stamp.filter { ["name", "model", "surface", "reasoning_effort", "source"].contains($0.key) })
            window["owner"] = .string("""
                The surface's provider/model/effort route selects the model. ProviderRouting's verified model catalog supplies its native \
                default window. Effort is routing context, not a separate window multiplier.
                """)
            response["context_window"] = .object(window)
        }
        if !sessionId.isEmpty {
            response["conversation_session_id"] = .string(sessionId)
        }
        guard fullDetail else { return .object(response) }

        let catalog = try await catalogSnapshot(turn: turn, includeSchemas: false, surface: surface)
        let availableTools = Set(catalog.names.filter { !Self.isModelHidden($0) })
        let modelVisibleAvailableTools = Self.modelVisibleCatalogToolNames(availableTools)
        let activeTools = Self.alwaysOnCoreNames
            .union(turn.offeredTools ?? [])
            .intersection(modelVisibleAvailableTools)
            .sorted()
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let trustedRoots = try await trustedWorkspaceRoots()
        let outcomeDimensionHealth: JSONValue
        do {
            let audit = try await OutcomeDimensionStatePopulationReader(
                dataRoot: dataRoot,
                since: Calendar.current.date(byAdding: .day, value: -7, to: Date())
            ).read()
            outcomeDimensionHealth = audit.jsonValue
        } catch {
            outcomeDimensionHealth = .object([
                "status": .string("unavailable"),
                "absent_is_zero": .bool(false),
                "error_class": .string(String(describing: type(of: error))),
            ])
        }
        response["outcome_dimension_health"] = outcomeDimensionHealth
        response["data_root"] = .string(dataRoot.path)
        response["persona_root"] = .string(personaRoot.path)
        response["read_root"] = .string(rootForRead.path)
        response["trusted_workspace_roots"] = .array(trustedRoots.map { .string($0.path) })
        response["active_tools"] = .array(activeTools.map { .string($0) })
        response["active_tool_count"] = .int(Int64(activeTools.count))
        response["available_tool_count"] = .int(Int64(modelVisibleAvailableTools.count))
        response["tool_count_semantics"] = .object([
            "active_tool_count": .string("Tools advertised to the model this turn: always-on core + turn-scoped, intersected with the model-visible catalog."),
            "available_tool_count": .string("Every model-visible tool in the catalog."),
        ])
        response["discovery"] = .string("every capability is an app action: app {} is home and the pages, app {find} finds an action")
        response["build"] = Self.buildStamp(identity: .current)
        return .object(response)
    }

    /// Share NativeAgentBuildIdentity with the bridge so both reads identify the same binary. A dirty or unstamped build has no exactSourceRevision;
    /// sourceRevision alone cannot prove it.
    static func buildStamp(identity: NativeAgentBuildIdentity) -> JSONValue {
        .object([
            "version": identity.unavailableReason == nil ? .string(identity.version) : .null,
            "build": identity.unavailableReason == nil ? .string(identity.build) : .null,
            "exactSourceRevision": identity.exactSourceRevision.map(JSONValue.string) ?? .null,
            "sourceDirty": identity.sourceDirty.map(JSONValue.bool) ?? .null,
            "sourceContentID": identity.sourceContentID.map(JSONValue.string) ?? .null,
            "unavailableReason": identity.unavailableReason.map(JSONValue.string) ?? .null,
        ])
    }

    /// A per-turn override can differ from configured routing; source distinguishes live_turn, configured and unresolved.
    static func providerStamp(turn: Turn?, dataRoot: URL) async -> JSONValue {
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        if let runtime = turn?.runtime,
           !runtime.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Report admitted transport directly; the same model can arrive through API-key, OAuth, bridge or router paths.
            return .object([
                "name": runtime.providerID.map(JSONValue.string) ?? .null,
                "model": .string(runtime.model),
                "surface": .string(runtime.surface),
                "reasoning_effort": (turn?.admission?.reasoningEffort).map(JSONValue.string) ?? .null,
                "source": .string(runtime.providerID == nil ? "unavailable" : "live_turn"),
                "error": runtime.providerID == nil ? .string("The admitted turn provider identity is unavailable; repair the turn context producer.") : .null,
            ])
        }
        // Without a live turn, only the chat surface’s configured model can be reported.
        do {
            let snapshot = try await router.checkedRoutingSnapshot()
            guard let pref = ProviderRoutingSurfaceLookup.value(snapshot.preferences, "chat"), !pref.model.isEmpty else {
                return .object(["name": .null, "model": .null, "source": .string("unconfigured")])
            }
            let surfaceActiveProvider = ProviderRoutingSurfaceLookup.value(
                snapshot.activeProviders,
                "chat"
            )
            return .object([
                "name": surfaceActiveProvider.map(JSONValue.string) ?? .null,
                "model": .string(pref.model),
                "surface": .string("chat"),
                "reasoning_effort": .string(pref.reasoningEffort),
                "surface_active_provider": surfaceActiveProvider.map { JSONValue.string($0) } ?? .null,
                "source": .string("configured"),
            ])
        } catch { return .object([
            "name": .null,
            "model": .null,
            "source": .string("unavailable"),
            "error": .string(error.localizedDescription),
        ]) }
    }
}
