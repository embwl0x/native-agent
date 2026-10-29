import Foundation
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
import WorkshopExecution
import DreamREMCycle
// Blueprint: | `SwiftToolDispatcher+PersonaTools.swift` | `SwiftToolDispatcher`: persona read/write tools; introspection separates durable bundle/build/data-root identity from launch ids and names the surface/model/effort route and context-budget owners; get-persona-document truncates at a valid UTF-8 scalar boundary within its 64 KiB source cap |

// MARK: - Persona and runtime introspection tools

extension SwiftToolDispatcher {
    private static let personaDocMaxBytes = 64 * 1024

    func impl_get_persona_doc(input: [String: JSONValue]) async throws -> JSONValue {
        let doc = try requireString(input, input["doc"] == nil && input["kind"] != nil ? "kind" : "doc")
        // Reject path-traversal characters.
        if doc.contains("/") || doc.contains("..") || doc.hasPrefix(".") {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: invalid persona doc name '\(doc)'"
            )
        }
        let docName = doc.hasSuffix(".md") ? doc : "\(doc).md"
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let result = PersonaSystemActions.personaRead([:],
            ConnectorActionContext(repoRoot: rootForRead, dataRoot: dataRoot, personaRoot: personaRoot),
            selectedDocument: personaRoot.appendingPathComponent(docName))
        guard case .object(let fields) = result else {
            throw ToolFailureError("Persona reader returned an invalid response.", effects: .none)
        }
        guard case .string(let text)? = fields["content"] else {
            throw AutonomyGateError.toolDenied(reason: "SwiftToolDispatcher: " + (fields["error"]?.stringValue ?? "Persona document read failed."))
        }
        let bytes = Data(text.utf8)
        if bytes.count > Self.personaDocMaxBytes {
            var head = bytes.prefix(Self.personaDocMaxBytes)
            // The whole document is valid UTF-8; only the final scalar may
            // straddle this cap. Remove its incomplete bytes, never the cap.
            while !head.isEmpty, String(data: head, encoding: .utf8) == nil { head.removeLast() }
            let headText = String(decoding: head, as: UTF8.self)
            return .string(headText + "\n... [truncated, \(bytes.count) bytes total]")
        }
        return .string(text)
    }

    func impl_persona_read(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try requireString(input, "kind")
        let result = PersonaSystemActions.personaRead(["kind": .string(kind)],
            ConnectorActionContext(repoRoot: rootForRead, dataRoot: dataRoot,
                                   personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)))
        if case .object(let fields) = result, fields["ok"] == .bool(false) {
            let error = fields["error"]?.stringValue ?? ""
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
        // GROWTH keeps the lines REM approved, graduated standing lessons among
        // them (a 10-09 rewrite silently dropped some). One goes only when
        // `retire` names it with a reason; it is then tombstoned, as a REM deny
        // is, and the pins follow.
        var retire: [String: String] = [:]
        if case .object(let named)? = input["retire"] {
            for case let (line, .string(why)) in named where !why.trimmingCharacters(in: .whitespaces).isEmpty {
                retire[line.trimmingCharacters(in: .whitespacesAndNewlines)] = why
            }
        }
        // Read under GROWTH's own lock, the one REM's writer appends under, so
        // a lesson published mid-rewrite is in this read or lands after this
        // write. Strict: an unreadable history refuses rather than reading as
        // "nothing to protect".
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

    /// The REM lessons standing in a GROWTH body: approved, or appended by an
    /// approval whose flip has not landed yet. A denied one never stands.
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

    func impl_agent_introspect(input: [String: JSONValue]) async throws -> JSONValue {
        let sessionId = ChatToolSessionInjection.explicitSessionId(in: input)
        let fullDetail = (input["detail"]?.stringValue ?? "compact")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "full"
        let pid = ProcessInfo.processInfo.processIdentifier
        let provider = await Self.providerStamp(dataRoot: dataRoot)
        let runtimeInstanceID = "swift-native-\(pid)"
        var response: [String: JSONValue] = [
            "status": .string("ok"),
            "detail": .string(fullDetail ? "full" : "compact"),
            "invoked_as": .string("agent_introspect"),
            "runtime": .string("swift-native"),
            "python_daemon": .string("retired"),
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
            "tool_state": .string("app is your one tool; app {find} finds an action by what you want done. Request detail=full for diagnostic roots and outcome population health"),
        ]
        if case .object(let stamp) = provider, case .string(let model)? = stamp["model"] {
            var window = ChatSessionAutocompactionConfig.productionDefault().contextWindowReadout(
                forModel: model, providerID: stamp["name"]?.stringValue, dataRoot: dataRoot)
            window["route"] = .object(stamp.filter { ["name", "model", "surface", "reasoning_effort", "source"].contains($0.key) })
            window["owner"] = .string("The surface's provider/model/effort route selects the model. ProviderRouting's verified model catalog supplies its native window; Settings > Context window and ChatSessionAutocompactionConfig set the effective history budget. Effort is reported as routing context, not a separate window multiplier.")
            response["context_window"] = .object(window)
        }
        if !sessionId.isEmpty {
            // session_id stays as a compatibility alias, but now names the
            // same authoritative conversation scope used by traces,
            // scratchpads, and lazy tool activation. The process-scoped
            // identity is separate above and must never masquerade as chat.
            response["conversation_session_id"] = .string(sessionId)
            response["session_id"] = .string(sessionId)
        }
        guard fullDetail else { return .object(response) }

        let catalog = await catalogSnapshot(includeSchemas: false)
        let availableTools = Set(catalog.names.filter { !Self.isModelHidden($0) })
        let modelVisibleAvailableTools = Self.modelVisibleCatalogToolNames(availableTools)
        let activeTools = Self.alwaysOnCoreNames
            .union(LLMCallContext.turnActiveTools ?? [])
            .intersection(modelVisibleAvailableTools)
            .sorted()
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let trustedRoots = await trustedWorkspaceRoots()
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
            "available_tool_count": .string("Every model-visible tool in the catalog, loaded or not."),
        ])
        response["discovery"] = .string("every capability is an app action: app {} is home and the pages, app {find} finds an action")
        response["compatibility"] = .object([
            "recall_search": .string("alias_for_recall_memory"),
        ])
        response["build"] = Self.buildStamp(identity: .current)
        return .object(response)
    }

    /// Which binary is answering this turn, independent of this launch's ids.
    ///
    /// Reads `NativeAgentBuildIdentity`, the SAME type the local bridge's
    /// `buildIdentity` payload reports, so an in-turn answer and an
    /// out-of-band bridge read can never name different binaries.
    /// `exactSourceRevision` is null on a dirty or unstamped build: absence is
    /// the honest answer, never a bare `sourceRevision` promoted to proof.
    static func buildStamp(identity: NativeAgentBuildIdentity) -> JSONValue {
        .object([
            "version": .string(identity.version),
            "build": .string(identity.build),
            "exactSourceRevision": identity.exactSourceRevision.map(JSONValue.string) ?? .null,
            "sourceDirty": .bool(identity.sourceDirty),
            "sourceContentID": identity.sourceContentID.map(JSONValue.string) ?? .null,
        ])
    }

    /// The provider+model actually generating the current turn (live), or the
    /// surface's configured model when introspect runs outside a turn. Answers
    /// Agent's "which model is running me right now" — the live turn model can
    /// differ from the configured one on a per-turn override. `source` tells the
    /// agent which it got: live_turn / configured / unresolved.
    static func providerStamp(dataRoot: URL) async -> JSONValue {
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        if let turn = ChatTurnRuntimeContext.current,
           !turn.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Report the exact transport admitted with this turn. Model-family
            // inference cannot distinguish API-key, OAuth-direct, Codex, or an
            // OpenRouter route serving the same upstream model.
            let snapshot = try? await router.checkedRoutingSnapshot()
            let surfaceActiveProvider = snapshot.flatMap {
                ProviderRoutingSurfaceLookup.value($0.activeProviders, turn.surface)
            }
            return .object([
                "name": .string(
                    turn.providerID
                        ?? router.inferProviderForModel(turn.model)
                        ?? surfaceActiveProvider
                        ?? "unknown"
                ),
                "model": .string(turn.model),
                "surface": .string(turn.surface),
                "reasoning_effort": LLMCallContext.reasoningEffort.map(JSONValue.string) ?? .null,
                "surface_active_provider": surfaceActiveProvider.map { JSONValue.string($0) } ?? .null,
                "source": .string("live_turn"),
            ])
        }
        // Outside a turn there is no turn model in play; report the chat-surface
        // configured model as the best available answer.
        if let snapshot = try? await router.checkedRoutingSnapshot(),
           let pref = ProviderRoutingSurfaceLookup.value(snapshot.preferences, "chat")
                ?? snapshot.preferences["chat"],
           !pref.model.isEmpty {
            let surfaceActiveProvider = ProviderRoutingSurfaceLookup.value(
                snapshot.activeProviders,
                "chat"
            )
            return .object([
                "name": .string(surfaceActiveProvider ?? router.inferProviderForModel(pref.model) ?? "unknown"),
                "model": .string(pref.model),
                "surface": .string("chat"),
                "reasoning_effort": .string(pref.reasoningEffort),
                "surface_active_provider": surfaceActiveProvider.map { JSONValue.string($0) } ?? .null,
                "source": .string("configured"),
            ])
        }
        return .object([
            "name": .string("unknown"),
            "model": .null,
            "source": .string("unresolved"),
        ])
    }
}
