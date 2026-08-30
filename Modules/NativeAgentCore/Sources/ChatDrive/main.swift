// Throwaway diagnostic CLI.
//   `chat-drive dispatch [--surface <surface>] <tool> <jsonInput>` — call SwiftToolDispatcher directly
//     so we can verify each tool independent of the LLM tool loop.
//   `chat-drive chat [--surface <surface>] '<message>'` — send a real chat turn through the SwiftNative
//     path and print the full result. `NATIVE_AGENT_CHAT_DRIVE_REPLY` is a
//     guarded hermetic provider fixture for subprocess evaluation only.
//     `NA_CHAT_SESSION` optionally supplies the durable session identity and
//     is normalized before this CLI opens provider or persistence state.
//   `chat-drive stream [--surface <surface>] '<message>'` — send the same turn through the streaming
//     path the Mac UI uses.
//   `chat-drive provider-prefs [surface]` — print checked read-only Swift
//     provider/model picks without recovering pending picker state.
//   `chat-drive doctor [--repair true|false] [--check-llm true|false]` — run Swift Doctor checks.
//   `chat-drive memory-migrate <dataRoot>` — run MemoryV2 migration/repair.
//   `chat-drive memory-recall <dataRoot> '<query>' [k]` — verify SQLite recall.
//   `chat-drive memory-embedding-epoch {status|activate|rollback} <dataRoot>` — atomically manage vector-space identity.
//   `chat-drive memory-eval [--query-mode natural|compact] <dataRoot>` — run the known-answer MemoryV2 probe gate.
//   `chat-drive memory-hygiene [--approve-swap true|false] <dataRoot>` — stage/apply gated MemoryV2 hygiene and KG reconciliation.
//   `chat-drive living-fabric-eval <dataRoot>` — read-only Wave 5/6 evidence report.
//   `chat-drive procedure {status|stage-review|compile|invoke|stage-activation|activate|deactivate} <dataRoot> [<shape-or-artifact-id>] [--approval <id>] [--invocation-key <stable-key>]`
//     — operate the evidence-bound, locally reviewed procedure lifecycle.
//   `chat-drive physiology-soak-report <dataRoot>` — read-only installed-body soak status.
//   `chat-drive provider-transplant-fixture --targets <provider:model,...> --output <path> [--mode smoke|standard|full] [--lifetime-seconds 300...7200]`
//   `chat-drive provider-transplant-eval --fixture <frozen-mind-fixture.json> [--authorization <local-authorization.json>] [--output <report.json>]`
//     — opt-in live configured-provider probe over frozen non-personal fixtures.
// Used by the orchestrator (Claude) to verify end-to-end that Agent's tools
// wired in the W1+W2 + post-review fixes actually fire without clicking the
// Mac GUI.

import Foundation
import ApprovalInbox
import NativeAgentCore
import NativeAgentEvaluation
import ChatOrchestration
import Context
import KnowledgeGraph
import MemoryV2
import PersistenceCore
import PersonaEngine
import ProviderRouting
import DoctorChecks
import TrustCenter
import WorkshopExecution

@main
struct ChatDriveMain {
    /// One canonical command vocabulary for both the visible CLI contract and
    /// the production router. An added help name with no router case, or a
    /// deleted router case with a still-advertised name, is now impossible:
    /// this `CaseIterable` enum drives usage and the exhaustive switch below.
    private enum Command: String, CaseIterable {
        case dispatch
        case chat
        case stream
        case providerPrefs = "provider-prefs"
        case doctor
        case memoryMigrate = "memory-migrate"
        case memoryRecall = "memory-recall"
        case memoryEmbeddingEpoch = "memory-embedding-epoch"
        case memoryEval = "memory-eval"
        case memoryHygiene = "memory-hygiene"
        case livingFabricEval = "living-fabric-eval"
        case procedure
        case physiologySoakReport = "physiology-soak-report"
        case workshopCancel = "workshop-cancel"
        case providerTransplantEval = "provider-transplant-eval"
        case providerTransplantFixture = "provider-transplant-fixture"

        static var usage: String {
            "usage: chat-drive {\(Self.allCases.map(\.rawValue).joined(separator: "|"))} ..."
        }
    }

    /// Fixture-only provider transport for the executable's hermetic stream
    /// evaluation. It is deliberately local to ChatDrive: production routing
    /// never sees it, and callers must opt in through the guarded environment
    /// checked by `streamClientForCurrentProcess()`.
    private final class ChatDriveHermeticStreamingLLM: LLMClient, StreamingLLMClient, MessagesStreamingLLMClient, @unchecked Sendable {
        private let chunks: [String]

        init(chunks: [String]) {
            self.chunks = chunks
        }

        private var reply: String { chunks.joined() }

        func complete(prompt: String, system: String?, model: String?) async throws -> String {
            reply
        }

        func complete(
            prompt: String,
            system: String?,
            model: String?,
            surface: String
        ) async throws -> String {
            reply
        }

        func complete(
            prompt: String,
            system: String?,
            model: String?,
            tools: [LLMToolSchema]?
        ) async throws -> String {
            reply
        }

        func completeMessages(
            messages: [LLMMessage],
            system: String?,
            model: String?,
            surface: String,
            tools: [LLMToolSchema]?
        ) async throws -> String {
            reply
        }

        func stream(
            prompt: String,
            system: String?,
            model: String?
        ) -> AsyncThrowingStream<String, Error> {
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                Task {
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                }
            }
        }

        func streamMessages(
            messages: [LLMMessage],
            system: String?,
            model: String?,
            surface: String,
            tools: [LLMToolSchema]?
        ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
            let chunks = self.chunks
            return AsyncThrowingStream { continuation in
                Task {
                    for chunk in chunks { continuation.yield(.textDelta(chunk)) }
                    continuation.finish()
                }
            }
        }
    }

    private struct ChatDriveHermeticNoTools: ToolDispatchClient {
        func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue { .null }
        func listAvailableTools() async throws -> [String] { [] }
    }

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let rawMode = args.first else {
            FileHandle.standardError.write(Data((Command.usage + "\n").utf8))
            exit(64)
        }
        if ["help", "--help", "-h"].contains(rawMode) {
            print(Command.usage)
            return
        }
        guard let mode = Command(rawValue: rawMode) else {
            FileHandle.standardError.write(Data("unknown mode: \(rawMode)\n".utf8))
            exit(64)
        }
        // This is intentionally a router-level acknowledgement, not a
        // command implementation shortcut: it lets automation probe every
        // declared command without triggering a writer or provider call.
        if args.dropFirst().elementsEqual(["--help"]) {
            print("usage: chat-drive \(mode.rawValue) ...")
            return
        }

        switch mode {
        case .dispatch:
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: ["surface"])
            guard parsed.positionals.count >= 1 else {
                FileHandle.standardError.write(Data("usage: chat-drive dispatch [--surface <surface>] <tool> [<jsonInput>]\n".utf8))
                exit(64)
            }
            let tool = parsed.positionals[0]
            let jsonInput = parsed.positionals.count >= 2 ? parsed.positionals[1] : "{}"
            try await runDispatch(
                tool: tool,
                jsonInput: jsonInput,
                surface: parsed.options["surface"] ?? "chat"
            )

        case .chat:
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: ["surface", "model", "effort"])
            let prompt = parsed.positionals.joined(separator: " ")
            guard !prompt.isEmpty else {
                FileHandle.standardError.write(Data("usage: chat-drive chat [--surface <surface>] [--model <model>] [--effort <effort>] '<message>'\n".utf8))
                exit(64)
            }
            try await runChat(
                prompt: prompt,
                surface: parsed.options["surface"] ?? "chat",
                modelOverride: parsed.options["model"],
                effortOverride: parsed.options["effort"]
            )

        case .stream:
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: ["surface", "model", "effort"])
            let prompt = parsed.positionals.joined(separator: " ")
            guard !prompt.isEmpty else {
                FileHandle.standardError.write(Data("usage: chat-drive stream [--surface <surface>] [--model <model>] [--effort <effort>] '<message>'\n".utf8))
                exit(64)
            }
            try await runStream(
                prompt: prompt,
                surface: parsed.options["surface"] ?? "chat",
                modelOverride: parsed.options["model"],
                effortOverride: parsed.options["effort"]
            )

        case .providerPrefs:
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: [])
            guard parsed.positionals.count <= 1 else {
                commandLineUsageError("usage: chat-drive provider-prefs [surface]")
            }
            try await runProviderPrefs(surface: parsed.positionals.first)

        case .doctor:
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: ["repair", "check-llm"])
            try await runDoctor(
                repair: boolOption(parsed.options["repair"], defaultValue: false),
                checkLLM: boolOption(parsed.options["check-llm"], defaultValue: false)
            )

        case .memoryMigrate:
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: chat-drive memory-migrate <dataRoot>\n".utf8))
                exit(64)
            }
            try await runMemoryMigrate(dataRootPath: args[1])

        case .memoryRecall:
            guard args.count >= 3 else {
                FileHandle.standardError.write(Data("usage: chat-drive memory-recall <dataRoot> '<query>' [k]\n".utf8))
                exit(64)
            }
            let k = args.count >= 4 ? Int(args[3]) ?? 5 : 5
            try await runMemoryRecall(dataRootPath: args[1], query: args[2], k: k)

        case .memoryEmbeddingEpoch:
            guard args.count >= 3 else {
                FileHandle.standardError.write(Data(
                    "usage: chat-drive memory-embedding-epoch {status|activate|rollback} <dataRoot>\n".utf8
                ))
                exit(64)
            }
            try await runMemoryEmbeddingEpoch(action: args[1], dataRootPath: args[2])

        case .memoryEval:
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: ["query-mode"])
            guard parsed.positionals.count >= 1 else {
                FileHandle.standardError.write(Data("usage: chat-drive memory-eval [--query-mode natural|compact] <dataRoot>\n".utf8))
                exit(64)
            }
            try await runMemoryEval(
                dataRootPath: parsed.positionals[0],
                queryMode: parsed.options["query-mode"] ?? "natural"
            )

        case .memoryHygiene:
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: ["approve-swap", "max-passes"])
            guard parsed.positionals.count >= 1 else {
                FileHandle.standardError.write(Data("usage: chat-drive memory-hygiene [--approve-swap true|false] [--max-passes n] <dataRoot>\n".utf8))
                exit(64)
            }
            try await runMemoryHygiene(
                dataRootPath: parsed.positionals[0],
                approveSwap: strictBoolOption(
                    parsed.options["approve-swap"],
                    defaultValue: false,
                    optionName: "approve-swap"
                ),
                maxPasses: strictPositiveIntOption(
                    parsed.options["max-passes"],
                    defaultValue: 2,
                    optionName: "max-passes"
                )
            )

        case .livingFabricEval:
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: chat-drive living-fabric-eval <dataRoot>\n".utf8))
                exit(64)
            }
            try await runLivingFabricEval(dataRootPath: args[1])

        case .procedure:
            let parsed = parseOptions(
                Array(args.dropFirst()),
                allowedOptions: [
                    "approval", "scope", "source", "destination", "invocation-key",
                ]
            )
            guard parsed.positionals.count >= 2 else {
                FileHandle.standardError.write(Data(
                    "usage: chat-drive procedure {status|stage-review|compile|invoke|stage-activation|activate|deactivate} <dataRoot> [<shape-or-artifact-id>] [--approval <id>] [--scope manual|canary] [--source <workspace-relative>] [--destination <workspace-relative>] [--invocation-key <stable-key>]\n".utf8
                ))
                exit(64)
            }
            let action = parsed.positionals[0]
            guard [
                "status", "stage-review", "compile", "invoke", "stage-activation", "activate", "deactivate",
            ].contains(action) else {
                commandLineUsageError(
                    "procedure action must be status, stage-review, compile, invoke, stage-activation, activate, or deactivate"
                )
            }
            if let scope = parsed.options["scope"], !["manual", "canary"].contains(scope) {
                commandLineUsageError("procedure scope must be manual or canary")
            }
            if action == "activate",
               (parsed.options["approval"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                commandLineUsageError("procedure activate requires --approval <resolved-local-id>")
            }
            do {
                try await runProcedureOperator(
                    action: action,
                    dataRootPath: parsed.positionals[1],
                    shapeID: parsed.positionals.count >= 3 ? parsed.positionals[2] : nil,
                    approvalID: parsed.options["approval"],
                    scope: parsed.options["scope"],
                    sourceRelativePath: parsed.options["source"],
                    destinationRelativePath: parsed.options["destination"],
                    invocationKey: parsed.options["invocation-key"]
                )
            } catch {
                FileHandle.standardError.write(Data("procedure failed: \(error)\n".utf8))
                exit(1)
            }

        case .physiologySoakReport:
            guard args.count >= 2 else {
                FileHandle.standardError.write(Data("usage: chat-drive physiology-soak-report <dataRoot>\n".utf8))
                exit(64)
            }
            try await runPhysiologySoakReport(dataRootPath: args[1])

        case .workshopCancel:
            guard args.count == 3,
                  !args[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !args[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                FileHandle.standardError.write(Data(
                    "usage: chat-drive workshop-cancel <dataRoot> <executionId>\n".utf8
                ))
                exit(64)
            }
            do {
                try await runWorkshopCancel(dataRootPath: args[1], executionID: args[2])
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                FileHandle.standardError.write(Data("workshop-cancel failed: \(message)\n".utf8))
                exit(1)
            }

        case .providerTransplantEval:
            let parsed = parseOptions(
                Array(args.dropFirst()),
                allowedOptions: ["fixture", "authorization", "public-safe", "output"]
            )
            guard let fixturePath = parsed.options["fixture"],
                  !fixturePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                FileHandle.standardError.write(Data(
                    "usage: chat-drive provider-transplant-eval --fixture <frozen-mind-fixture.json> [--authorization <local-authorization.json>] [--public-safe true|false] [--output <report.json>]\n".utf8
                ))
                exit(64)
            }
            let environmentPublicSafe = boolOption(
                ProcessInfo.processInfo.environment["NATIVEAGENT_PUBLIC_SAFE_MODE"],
                defaultValue: false
            )
            let effectivePublicSafe = environmentPublicSafe
                || boolOption(parsed.options["public-safe"], defaultValue: false)
            FileHandle.standardError.write(Data(
                "[provider-transplant-eval] publicSafeMode=\(effectivePublicSafe) envForced=\(environmentPublicSafe)\n".utf8
            ))
            try await runProviderTransplantEvalV2(
                fixturePath: fixturePath,
                authorizationPath: parsed.options["authorization"],
                outputPath: parsed.options["output"],
                publicSafeMode: effectivePublicSafe
            )

        case .providerTransplantFixture:
            let parsed = parseOptions(
                Array(args.dropFirst()),
                allowedOptions: ["targets", "output", "mode", "lifetime-seconds"]
            )
            guard let rawTargets = parsed.options["targets"],
                  let outputPath = parsed.options["output"] else {
                FileHandle.standardError.write(Data(
                    "usage: chat-drive provider-transplant-fixture --targets <provider:model,...> --output <path> [--mode smoke|standard|full] [--lifetime-seconds 300...7200]\n".utf8
                ))
                exit(64)
            }
            try makeProviderTransplantFixture(
                rawTargets: rawTargets,
                outputPath: outputPath,
                mode: parsed.options["mode"] ?? "smoke",
                lifetimeSeconds: parsed.options["lifetime-seconds"]
            )

        }
    }

    static func parseOptions(_ args: [String], allowedOptions: Set<String>) -> (options: [String: String], positionals: [String]) {
        var options: [String: String] = [:]
        var positionals: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                guard allowedOptions.contains(key) else {
                    commandLineUsageError("unknown option: \(arg)")
                }
                guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                    commandLineUsageError("option \(arg) requires a value")
                }
                options[key] = args[i + 1]
                i += 2
            } else {
                positionals.append(arg)
                i += 1
            }
        }
        return (options, positionals)
    }

    static func boolOption(_ raw: String?, defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: return defaultValue
        }
    }

    /// Options that control a persistent mutation must not silently turn an
    /// unparseable value into a benign-looking default. The doctor command
    /// deliberately retains its fail-closed default; memory hygiene instead
    /// rejects malformed write controls before it opens a store.
    static func strictBoolOption(_ raw: String?, defaultValue: Bool, optionName: String) -> Bool {
        guard let raw else { return defaultValue }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: commandLineUsageError("option --\(optionName) must be true or false")
        }
    }

    static func strictPositiveIntOption(_ raw: String?, defaultValue: Int, optionName: String) -> Int {
        guard let raw else { return defaultValue }
        guard let value = Int(raw), value > 0 else {
            commandLineUsageError("option --\(optionName) must be a positive integer")
        }
        return value
    }

    static func commandLineUsageError(_ message: String) -> Never {
        FileHandle.standardError.write(Data("chat-drive: \(message)\n".utf8))
        exit(64)
    }

    static func runDispatch(tool: String, jsonInput: String, surface: String) async throws {
        FileHandle.standardError.write(Data("[dispatch] surface=\(surface) tool=\(tool) input=\(jsonInput)\n".utf8))
        // Parse input JSON
        guard let data = jsonInput.data(using: .utf8),
              let parsed = try? JSONValue.parse(data),
              case .object(let input) = parsed else {
            commandLineUsageError("dispatch input must be a JSON object")
        }
        // Input validation is deliberately before dispatcher construction.
        // `SwiftToolDispatcher` resolves the active data root and owner-backed
        // services; a malformed diagnostic argv must not even open that seam.
        let d = SwiftToolDispatcher(enforceLazyToolLoading: false)
        do {
            let result = try await d.dispatch(tool: tool, input: input, surface: surface)
            print("=== \(tool) returned ===")
            if let s = try? result.serialize(pretty: true) {
                print(s)
            } else {
                print(String(describing: result))
            }
        } catch {
            print("=== ERROR ===")
            print("\(error)")
            exit(1)
        }
    }

    static func runChat(
        prompt: String,
        surface: String,
        modelOverride: String?,
        effortOverride: String?
    ) async throws {
        let sessionId = chatDriveSessionID(fallbackPrefix: "drive")
        // Validate the guarded subprocess transport before asking the router
        // for defaults. `computeModelPreferences()` opens (and may create)
        // root-backed provider state, so an invalid fixture invocation must be
        // refused before any data-root byte can exist — mirroring runStream.
        let client = try chatClientForCurrentProcess()
        let prefs = try await SwiftNativeProviderRouting().computeModelPreferences()
        let pick = prefs[canonicalRoutingSurface(surface)] ?? prefs["chat"]
        guard let pick else { throw ProviderRoutingError.unavailable }
        let model = modelOverride ?? pick.model
        let effort = effortOverride ?? pick.reasoningEffort
        FileHandle.standardError.write(
            Data("[chat] sessionId=\(sessionId)\n[chat] surface=\(surface) model=\(model) effort=\(effort)\n[chat] prompt=\(prompt)\n".utf8)
        )
        let started = Date()
        do {
            let resp = try await client.chat(
                message: prompt,
                sessionId: sessionId,
                model: model,
                reasoningEffort: effort,
                fileAccess: "workspace",
                attachments: [],
                persona: nil,
                surface: surface,
                suppressUserAppend: false
            )
            guard !resp.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "ChatDrive",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "chat completed without assistant text"]
                )
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            // The app process outlives its detached trace writes; this CLI
            // exits right here. Await the trace lanes so the turn's durable
            // receipts (turn.terminal included) cannot lose the race with exit.
            await drainTurnTracePersistence()
            print("--- ASSISTANT REPLY ---")
            print(resp.output)
            print("--- META ---")
            print("model:", resp.model)
            print("runId:", resp.runId)
            print("session:", resp.sessionId ?? "(nil)")
            print("elapsed_ms:", elapsed)
        } catch {
            // Error turns emit traces too — drain before the failure exit so
            // a failed turn's receipts are as durable as a successful one's.
            await drainTurnTracePersistence()
            print("--- ERROR ---")
            print("\(error)")
            exit(1)
        }
    }

    /// The ordinary CLI builds the production client. This fixture seam is
    /// intentionally narrower than a provider setting: it replaces only the
    /// transport after an explicit hermetic opt-in, while retaining the real
    /// ChatDrive command, session persistence, routing admission, orchestration,
    /// and terminal-trace path used by the non-streaming CLI.
    static func chatClientForCurrentProcess() throws -> any ChatOrchestrationClient {
        let environment = ProcessInfo.processInfo.environment
        guard let reply = environment["NATIVE_AGENT_CHAT_DRIVE_REPLY"] else {
            return makeChatOrchestrationClient()
        }
        guard environment["NATIVE_AGENT_CHAT_DRIVE_HERMETIC"] == "1" else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_REPLY requires NATIVE_AGENT_CHAT_DRIVE_HERMETIC=1")
        }
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_REPLY must be non-empty")
        }
        return hermeticClient(chunks: [reply])
    }

    static func runStream(
        prompt: String,
        surface: String,
        modelOverride: String?,
        effortOverride: String?
    ) async throws {
        let sessionId = chatDriveSessionID(fallbackPrefix: "drive-stream")
        // Validate the guarded subprocess transport before asking the router
        // for defaults. Invalid fixture input must not open a root-backed
        // routing seam as a side effect of a command-line usage error.
        let client = try streamClientForCurrentProcess()
        let prefs = try await SwiftNativeProviderRouting().computeModelPreferences()
        let pick = prefs[canonicalRoutingSurface(surface)] ?? prefs["chat"]
        guard let pick else { throw ProviderRoutingError.unavailable }
        let model = modelOverride ?? pick.model
        let effort = effortOverride ?? pick.reasoningEffort
        FileHandle.standardError.write(
            Data("[stream] sessionId=\(sessionId)\n[stream] surface=\(surface) model=\(model) effort=\(effort)\n[stream] prompt=\(prompt)\n".utf8)
        )

        let started = Date()
        var accumulated = ""
        var finalReply: String?
        var deltaCount = 0
        do {
            for try await event in client.chatStream(
                message: prompt,
                sessionId: sessionId,
                model: model,
                reasoningEffort: effort,
                fileAccess: "workspace",
                attachments: [],
                persona: nil,
                surface: surface,
                suppressUserAppend: false
            ) {
                switch event {
                case .delta(let text):
                    accumulated += text
                    deltaCount += 1
                    print(text, terminator: "")
                    fflush(stdout)
                case .toolUse(let name, _):
                    FileHandle.standardError.write(Data("\n[stream] tool_use \(name)\n".utf8))
                case .toolResult(let name, _):
                    FileHandle.standardError.write(Data("[stream] tool_result \(name)\n".utf8))
                case .notice(let kind, let text):
                    FileHandle.standardError.write(Data("[stream] notice \(kind): \(text)\n".utf8))
                case .final(let result):
                    finalReply = result.reply
                case .error(let message):
                    throw NSError(
                        domain: "ChatDriveStream",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            }
            guard deltaCount > 0 else {
                throw NSError(
                    domain: "ChatDriveStream",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "stream ended without an assistant delta"]
                )
            }
            guard let finalReply else {
                throw NSError(
                    domain: "ChatDriveStream",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "stream ended without a terminal event"]
                )
            }
            guard finalReply == accumulated else {
                throw NSError(
                    domain: "ChatDriveStream",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "stream deltas did not equal terminal reply"]
                )
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            // Same process-exit drain as runChat: the stream's terminal trace
            // is fired before the event stream finishes, but its disk append
            // is detached and must be awaited before this short-lived process
            // exits.
            await drainTurnTracePersistence()
            print("\n--- STREAM META ---")
            print("reply:", finalReply)
            print("delta_count:", deltaCount)
            print("session:", sessionId)
            print("elapsed_ms:", elapsed)
        } catch {
            await drainTurnTracePersistence()
            print("\n--- STREAM ERROR ---")
            print("\(error)")
            exit(1)
        }
    }

    /// The CLI's new-conversation owner. A missing environment value creates
    /// one fresh owned session; a supplied value is normalized through the
    /// same path-safe identity owner persistence rechecks later. Invalid
    /// input must not turn into a fresh UUID, because that silently splits a
    /// headless multi-turn conversation into an orphan session.
    static func chatDriveSessionID(fallbackPrefix: String) -> String {
        if let raw = ProcessInfo.processInfo.environment["NA_CHAT_SESSION"] {
            guard let normalized = NativeAgentChatSessionID.normalizedPathComponent(raw) else {
                commandLineUsageError(
                    "NA_CHAT_SESSION must be a non-empty filesystem-safe chat session id"
                )
            }
            return normalized
        }
        return "\(fallbackPrefix)-\(UUID().uuidString.prefix(8))"
    }

    /// Turn-trace persistence is fire-and-forget off the turn path: the plan
    /// row rides `TurnPlanTraceWriter`'s chained writer and every bus event
    /// (terminal receipt included) rides the emission→deliver→persist pumps.
    /// The app stays alive so those detached writes always land; this CLI
    /// exits immediately after one turn, so it must await the same drains the
    /// app runs at termination. Event-driven waits only — no sleeps.
    static func drainTurnTracePersistence() async {
        await TurnPlanTraceWriter.shared.drain()
        await TurnTraceBus.shared.drainForProcessExit()
    }

    /// The ordinary CLI always builds the production client.  The environment
    /// fixture exists solely for a subprocess evaluation of this executable:
    /// it still exercises the real chat-stream façade, persistence, and trace
    /// writer, but replaces only the provider transport with declared chunks.
    /// An accidentally-present chunk variable is rejected unless the explicit
    /// hermetic opt-in accompanies it, so diagnostics cannot silently pretend
    /// to be a live provider turn.
    static func streamClientForCurrentProcess() throws -> any ChatOrchestrationClient {
        let environment = ProcessInfo.processInfo.environment
        guard let rawChunks = environment["NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS"] else {
            return makeChatOrchestrationClient()
        }
        guard environment["NATIVE_AGENT_CHAT_DRIVE_HERMETIC"] == "1" else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS requires NATIVE_AGENT_CHAT_DRIVE_HERMETIC=1")
        }
        guard let data = rawChunks.data(using: .utf8),
              let chunks = try? JSONDecoder().decode([String].self, from: data),
              !chunks.isEmpty,
              chunks.allSatisfy({ !$0.isEmpty }) else {
            commandLineUsageError("NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS must be a non-empty JSON string array")
        }

        return hermeticClient(chunks: chunks)
    }

    /// Shared assembly for the two explicitly opt-in subprocess fixtures.
    /// The fixture only supplies deterministic provider output; all stateful
    /// chat owners are still bound to the caller's exact data root.
    private static func hermeticClient(chunks: [String]) -> any ChatOrchestrationClient {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let llm = ChatDriveHermeticStreamingLLM(chunks: chunks)
        let tools = ChatDriveHermeticNoTools()
        let engine = SwiftNativeTurnEngine(
            persona: SwiftNativePersonaEngine.isolated(dataRoot: dataRoot),
            memory: nil,
            router: SwiftNativeProviderRouting(dataRoot: dataRoot),
            trust: SwiftNativeTrustCenter(dataRoot: dataRoot),
            llm: llm,
            tools: tools,
            remPinsDataRoot: dataRoot,
            memoryPromoter: nil
        )
        return makeChatOrchestrationClient(
            engine: engine,
            llm: llm,
            tools: tools,
            dataRoot: dataRoot,
            streamingLLM: llm
        )
    }

    static func runProviderPrefs(surface: String?) async throws {
        let routing = SwiftNativeProviderRouting()
        // This is deliberately the no-recovery read: an operator's probe must
        // never repair a partial provider-selection transaction as a side
        // effect. Pending/corrupt authority is an explicit failed probe.
        let snapshot = try await routing.checkedRoutingSnapshotReadOnly()
        let prefs = snapshot.preferences
        func object(_ pref: SurfacePreference) -> JSONValue {
            let activeProvider = ProviderRoutingSurfaceLookup.value(
                snapshot.activeProviders,
                pref.surface
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let inferredProvider = routing.inferProviderForModel(pref.model)
            // This mirrors the LLM adapter's no-active-provider fallback: a
            // model family chooses its provider; an unknown but valid model
            // reaches the Codex adapter. Never emit an empty provider and
            // never hide which branch produced the receipt.
            let provider = (activeProvider?.isEmpty == false ? activeProvider : nil)
                ?? inferredProvider
                ?? "codex"
            let providerSource = activeProvider?.isEmpty == false
                ? "active_provider"
                : inferredProvider == nil ? "codex_fallback" : "model_family"
            return .object([
                "surface": .string(pref.surface),
                "provider": .string(provider),
                "providerSource": .string(providerSource),
                "model": .string(pref.model),
                "reasoningEffort": .string(pref.reasoningEffort),
                "serviceTier": .string(pref.serviceTier),
                "modelKnown": pref.modelKnown.map { .bool($0) } ?? .null,
            ])
        }
        let out: JSONValue
        if let surface, !surface.isEmpty {
            let canonicalSurface = canonicalRoutingSurface(surface)
            guard let pref = prefs[canonicalSurface] else {
                FileHandle.standardError.write(Data("unknown surface: \(surface)\n".utf8))
                exit(64)
            }
            out = object(pref)
        } else {
            let entries = prefs.keys.sorted().compactMap { prefs[$0].map(object) }
            out = .array(entries)
        }
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runProviderTransplantEvalV2(
        fixturePath: String,
        authorizationPath: String?,
        outputPath: String?,
        publicSafeMode: Bool
    ) async throws {
        // Public-safe mode is a process boundary, not merely a provider-runner
        // option. Refuse before opening artifacts, registries, or output paths
        // so the env override is both no-egress and byte-preserving.
        guard !publicSafeMode else { throw FrozenMindEvaluationError.publicSafeMode }
        // V2 intentionally constructs only the configured provider router and
        // LLM adapters. It never constructs ChatOrchestration, persona, memory,
        // cognition, tools, feedback, or an action dispatcher.
        let fixtureData = try readBoundedFrozenMindArtifact(path: fixturePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(FrozenMindEvaluationFixtureArtifact.self, from: fixtureData)
        let inputs: [String: FrozenMindScenarioInput]
        switch fixture.contentClass {
        case .generatedNonPersonal:
            // Generated egress is authorized only for the exact factory-owned
            // closed fixture. A caller-controlled, merely self-consistent JSON
            // artifact must not be able to relabel personal bytes as generated.
            inputs = try FrozenMindGeneratedFixtureFactory.validatedGeneratedInputs(fixture)
        case .personal:
            inputs = try fixture.validatedInputs()
        }

        let authorization: FrozenMindEvaluationAuthorization
        let authorizer: any FrozenMindEvaluationEgressAuthorizing
        switch fixture.contentClass {
        case .generatedNonPersonal:
            guard authorizationPath == nil else {
                throw FrozenMindEvaluationError.authorizationRejected
            }
            let now = Date()
            let expiresAt = min(fixture.epochManifest.expiresAt, fixture.evaluationManifest.expiresAt)
            authorization = FrozenMindEvaluationAuthorization(
                manifest: fixture.evaluationManifest,
                epochManifest: fixture.epochManifest,
                approvedTargets: Set(fixture.evaluationManifest.targets),
                approvedAt: now.addingTimeInterval(-1),
                expiresAt: expiresAt,
                retentionExpiresAt: expiresAt,
                localApprovalReceiptID: "generated-nonpersonal:\(fixture.evaluationManifest.manifestDigest)"
            )
            authorizer = GeneratedNonPersonalFrozenMindEvaluationEgressAuthorizer()

        case .personal:
            guard let authorizationPath else {
                throw FrozenMindEvaluationError.authorizationRejected
            }
            let authorizationData = try readBoundedFrozenMindArtifact(
                path: authorizationPath,
                maximumBytes: 256 * 1_024
            )
            let artifact = try decoder.decode(
                FrozenMindEvaluationLocalAuthorizationArtifact.self,
                from: authorizationData
            )
            authorization = try artifact.validatedAuthorization(
                manifest: fixture.evaluationManifest,
                epochManifest: fixture.epochManifest
            )
            authorizer = ExactLocalFrozenMindEvaluationEgressAuthorizer(expected: authorization)
        }

        let lifecycleAudit = FrozenMindProviderLifecycleAudit()
        let router = SwiftNativeProviderRouting()
        let llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(),
            openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            xaiOAuthDirect: XAIOAuthDirectAdapter(),
            moonshot: MoonshotAdapter(),
            kimiCode: AnthropicAdapter.kimiCode(),
            openRouter: OpenRouterAdapter(),
            lifecycleObserver: lifecycleAudit
        )
        let providers = (try? await router.listProviders()) ?? []
        let providersByID = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pairs: [(FrozenMindProviderTarget, any FrozenMindEvaluationProviderCalling)] =
            fixture.evaluationManifest.targets.map { target in
                let provider = providersByID[target.providerID]
                let configured = provider?.configured == true
                let lastError = provider?.lastError?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    target,
                    LLMFrozenMindEvaluationProviderCaller(
                        target: target,
                        client: llm,
                        lifecycleAudit: lifecycleAudit,
                        configured: configured,
                        liveHealth: configured && (lastError?.isEmpty ?? true)
                            ? .healthy : .unavailable,
                        maximumInputBytes: fixture.evaluationManifest.budget.maximumInputBytesPerCall,
                        maximumOutputBytes: fixture.evaluationManifest.budget.maximumOutputBytesPerCall
                    )
                )
            }
        let callers = Dictionary(uniqueKeysWithValues: pairs)
        let revisions = frozenMindArtifactRevisions(fixture.epochManifest)
        let report = try await FrozenMindEvaluationRunner.run(
            epochManifest: fixture.epochManifest,
            manifest: fixture.evaluationManifest,
            inputs: inputs,
            callers: callers,
            authorization: authorization,
            authorizer: authorizer,
            publicSafeMode: publicSafeMode,
            beforeRevisions: { revisions },
            afterRevisions: { revisions }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let reportData = try encoder.encode(report)
        guard reportData.count <= 32 * 1_024 * 1_024 else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        if let outputPath {
            let url = URL(fileURLWithPath: outputPath).standardizedFileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try reportData.write(to: url, options: .atomic)
            _ = chmod(url.path, 0o600)
            print([
                "wrote frozen-mind report: \(url.path)",
                "reportDigest=\(report.reportDigest)",
                "functionalContractPassed=\(report.functionalContractPassed)",
            ].joined(separator: " "))
        } else {
            print(String(decoding: reportData, as: UTF8.self))
        }
    }

    static func makeProviderTransplantFixture(
        rawTargets: String,
        outputPath: String,
        mode rawMode: String,
        lifetimeSeconds rawLifetimeSeconds: String?
    ) throws {
        guard let mode = FrozenMindEvaluationMode(rawValue: rawMode.lowercased()) else {
            throw FrozenMindEvaluationError.invalidManifest
        }
        let defaultLifetime = mode == .full ? 7_200 : 1_800
        let lifetimeSeconds = rawLifetimeSeconds.flatMap(Int.init) ?? defaultLifetime
        guard (300...7_200).contains(lifetimeSeconds) else {
            throw FrozenMindEvaluationError.invalidManifest
        }
        let targets = rawTargets.split(separator: ",").compactMap { raw -> FrozenMindProviderTarget? in
            let value = String(raw)
            guard let separator = value.firstIndex(of: ":") else { return nil }
            let provider = String(value[..<separator])
            let routeTail = String(value[value.index(after: separator)...])
            let model: String
            let effort: String?
            if let effortSeparator = routeTail.lastIndex(of: "@") {
                model = String(routeTail[..<effortSeparator])
                effort = String(routeTail[routeTail.index(after: effortSeparator)...])
            } else {
                model = routeTail
                effort = nil
            }
            guard !provider.isEmpty, !model.isEmpty else { return nil }
            guard effort?.isEmpty != true else { return nil }
            return FrozenMindProviderTarget(
                providerID: provider,
                modelID: model,
                reasoningEffort: effort
            )
        }
        guard targets.count == rawTargets.split(separator: ",").count else {
            throw FrozenMindEvaluationError.invalidManifest
        }
        let fixture = try FrozenMindGeneratedFixtureFactory.make(
            mode: mode,
            targets: targets,
            lifetime: TimeInterval(lifetimeSeconds)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(fixture)
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        let url = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: Data.WritingOptions.atomic)
        _ = chmod(url.path, 0o600)
        print("wrote generated nonpersonal frozen-mind fixture: \(url.path)")
    }

    static func readBoundedFrozenMindArtifact(
        path: String,
        maximumBytes: Int = 32 * 1_024 * 1_024
    ) throws -> Data {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == size, data.count <= maximumBytes else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        return data
    }

    static func frozenMindArtifactRevisions(
        _ manifest: FrozenMindEpochManifest
    ) -> [FrozenMindOwnerRevision] {
        [
            FrozenMindOwnerRevision(
                owner: "context",
                revision: [
                    String(manifest.contextRevision.generationID),
                    manifest.contextRevision.sourceFingerprint,
                    String(manifest.contextRevision.arenaGenerationID),
                ].joined(separator: ":")
            ),
            manifest.cognitionRevision,
            manifest.organismRevision,
            FrozenMindOwnerRevision(owner: "persona", revision: manifest.personaDigest),
            FrozenMindOwnerRevision(owner: "trust", revision: manifest.trustPolicyDigest),
        ]
    }

    static func runDoctor(repair: Bool, checkLLM: Bool) async throws {
        FileHandle.standardError.write(Data("[doctor] repair=\(repair) checkLLM=\(checkLLM)\n".utf8))
        let results = try await makeDoctorChecks().runAll(repair: repair, checkLLM: checkLLM)
        let status: String = {
            if results.contains(where: { $0.status == "fail" }) { return "fail" }
            if results.contains(where: { $0.status == "warn" }) { return "warn" }
            return "ok"
        }()
        let checks = results.map { result -> JSONValue in
            var obj: [String: JSONValue] = [
                "id": .string(result.id),
                "title": .string(result.title),
                "status": .string(result.status),
                "detail": .string(result.detail),
            ]
            obj["repair"] = result.repair.map { .string($0) } ?? .null
            return .object(obj)
        }
        let payload: JSONValue = .object([
            "status": .string(status),
            "repair": .bool(repair),
            "checkLLM": .bool(checkLLM),
            "checks": .array(checks),
        ])
        print((try? payload.serialize(pretty: true)) ?? "\(payload)")
    }

    static func runMemoryMigrate(dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let report = await MemoryV2Migrator(dataRoot: dataRoot).migrate()
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "memoriesImported": .int(Int64(report.memoriesImported)),
            "proposalsImported": .int(Int64(report.proposalsImported)),
            "tombstonesImported": .int(Int64(report.tombstonesImported)),
            "skippedAlreadyMigrated": .bool(report.skippedAlreadyMigrated),
            "errors": .array(report.errors.map { .string($0) }),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runMemoryRecall(dataRootPath: String, query: String, k: Int) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let bridge = MemoryStorageBridge(storage: storage)
        // Fail-closed: don't silently swap in random vectors when CoreML is
        // unavailable. Memory recall against a mock embedder returns noise
        // (random L2-normalized vectors), which looks like a working system
        // and quietly ships the wrong answer. `NATIVE_AGENT_EMBEDDING_MOCK=1`
        // is the explicit developer test opt-in.
        let embedder: any EmbeddingProvider = {
            if let coreML = try? CoreMLEmbeddingProvider.bundled() { return coreML }
            if ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1" {
                return MockEmbeddingProvider(dimensions: 384)
            }
            return FailClosedEmbeddingProvider(dimensions: 384)
        }()
        let memory = SwiftNativeMemoryV2(embedder: embedder, storage: bridge)
        let response = try await memory.recall(
            MemoryV2RecallRequest(text: query, topK: max(1, k), persona: nil)
        )
        let hits: [JSONValue] = response.hits.map { hit in
            var obj: [String: JSONValue] = [
                "preview": .string(hit.preview),
                "score": .double(hit.score),
            ]
            if let source = hit.source { obj["source"] = .string(source) }
            if let ts = hit.ts { obj["ts"] = .string(ts) }
            return .object(obj)
        }
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "query": .string(query),
            "total": .int(Int64(response.total)),
            "hits": .array(hits),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runMemoryEmbeddingEpoch(action: String, dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let bridge = MemoryStorageBridge(storage: storage)
        let embedder = ManagedEmbeddingProvider(dataRoot: dataRoot)
        let memory = SwiftNativeMemoryV2(embedder: embedder, storage: bridge)

        var activation: MemoryEmbeddingEpochActivationReport?
        switch action {
        case "status":
            break
        case "activate":
            activation = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
        case "rollback":
            _ = try await memory.rollbackMemoryEmbeddingEpochActivation()
        default:
            throw NSError(domain: "ChatDriveMemoryEpoch", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "unknown memory-embedding-epoch action: \(action)"
            ])
        }
        let state = try await storage.embeddingEpochState()
        let providerEpoch = await memory.embeddingEpoch()?.rawValue
        let out: JSONValue = .object([
            "schema": .string("nativeagent.memory-embedding-epoch.v1"),
            "action": .string(action),
            "dataRoot": .string(dataRoot.path),
            "protected": .bool(state.protected),
            "activeEpoch": state.activeEpoch.map(JSONValue.string) ?? .null,
            "providerEpoch": providerEpoch.map(JSONValue.string) ?? .null,
            "providerMatchesActive": .bool(
                state.activeEpoch != nil && state.activeEpoch == providerEpoch
            ),
            "previousEpoch": state.previousEpoch.map(JSONValue.string) ?? .null,
            "rollbackAvailable": .bool(state.rollbackAvailable),
            "activatedAt": state.activatedAt.map(JSONValue.string) ?? .null,
            "activation": activation.map { report in
                .object([
                    "memories": .int(Int64(report.memories)),
                    "proposals": .int(Int64(report.proposals)),
                    "tombstones": .int(Int64(report.tombstones)),
                    "total": .int(Int64(report.total)),
                ])
            } ?? .null,
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runMemoryEval(dataRootPath: String, queryMode: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let embeddingMock = ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1"
        if embeddingMock,
           ProcessInfo.processInfo.environment["NATIVEAGENT_RELEASE_GATE"] == "1" {
            throw NSError(domain: "ChatDriveMemoryEval", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "memory-eval refuses NATIVE_AGENT_EMBEDDING_MOCK=1 in release-gate mode",
            ])
        }
        let loadedProbeSet = try MemoryProbeSet.loadForEvaluation(dataRoot: dataRoot)
        let probeSet = probeSetForEval(loadedProbeSet, queryMode: queryMode)
        guard !probeSet.probes.isEmpty else {
            throw MemoryProbeRunner.ProbeRunnerError.emptyProbeSet
        }
        let embedder: any EmbeddingProvider
        if embeddingMock {
            embedder = MockEmbeddingProvider(dimensions: 384)
        } else if let coreML = try? CoreMLEmbeddingProvider.bundled() {
            embedder = coreML
        } else {
            let out: JSONValue = .object([
                "dataRoot": .string(dataRoot.path),
                "embeddingMock": .bool(false),
                "queryMode": .string(normalizedEvalQueryMode(queryMode)),
                "total": .int(0),
                "frozenCopy": .bool(false),
                "liveStoreMutated": .bool(false),
                "verdict": .object([
                    "status": .string("unavailable"),
                    "reason": .string(
                        "CoreML embedding provider is unavailable; memory-eval did not execute probes"
                    ),
                    "probesExecuted": .int(0),
                ]),
            ])
            print((try? out.serialize(pretty: true)) ?? "\(out)")
            throw NSError(domain: "ChatDriveMemoryEval", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "memory-eval cannot score without the CoreML embedding provider",
            ])
        }
        // Never open the caller's store: even a "read" open of the SQLite pool
        // rewrites WAL/SHM sidecars and runs migrations, mutating a root this
        // evaluation promises to leave byte-identical (liveStoreMutated=false
        // must be a fact, not a claim). Freeze by byte-copying the memory
        // directory into a private temp root and open ONLY the copy.
        let frozenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-memory-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: frozenRoot) }
        try FileManager.default.createDirectory(at: frozenRoot, withIntermediateDirectories: true)
        let sourceMemoryDirectory = dataRoot.appendingPathComponent("memory", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceMemoryDirectory.path) {
            try FileManager.default.copyItem(
                at: sourceMemoryDirectory,
                to: frozenRoot.appendingPathComponent("memory", isDirectory: true)
            )
        }
        let storage = try MemoryStorage(dataRoot: frozenRoot)
        let started = Date()
        let queryBatch: MemoryEmbeddingBatch
        do {
            queryBatch = try await MemoryProbeRunner.embedQuestionsWithEpoch(
                probeSet.probes,
                embedder: embedder
            )
        } catch {
            let out: JSONValue = .object([
                "dataRoot": .string(dataRoot.path),
                "modelId": .string(embedder.modelId),
                "embeddingMock": .bool(embeddingMock),
                "queryMode": .string(normalizedEvalQueryMode(queryMode)),
                "total": .int(0),
                "frozenCopy": .bool(true),
                "liveStoreMutated": .bool(false),
                "verdict": .object([
                    "status": .string("failed"),
                    "reason": .string("embedding batch failed: \(error)"),
                    "probesExecuted": .int(0),
                ]),
            ])
            print((try? out.serialize(pretty: true)) ?? "\(out)")
            throw error
        }
        let score = try await MemoryProbeRunner.evaluate(
            storage: storage,
            probes: probeSet.probes,
            vectors: queryBatch.vectors,
            topK: probeSet.topK,
            embeddingEpoch: queryBatch.epoch
        )
        let contextScore = try await runFrozenContextMemoryEvaluation(
            storage: storage,
            probeSet: probeSet,
            queryBatch: queryBatch
        )
        let epochState = try await storage.embeddingEpochState()
        let disclosure = frozenDisclosureEvaluation()
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let missValues: [JSONValue] = score.misses.map { miss in
            .object([
                "probeId": .string(miss.probeId),
                "question": .string(miss.question),
                "topSummaries": .array(miss.topSummaries.map { .string($0) }),
            ])
        }
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "modelId": .string(embedder.modelId),
            "embeddingMock": .bool(embeddingMock),
            "version": .int(Int64(probeSet.version)),
            "topK": .int(Int64(probeSet.topK)),
            "queryMode": .string(normalizedEvalQueryMode(queryMode)),
            "total": .int(Int64(score.total)),
            "hits": .int(Int64(score.hits)),
            "fraction": .double(score.fraction),
            "summary": .string(score.summary),
            "verdict": .object([
                "status": .string("scored"),
                "summary": .string(score.summary),
                "probesExecuted": .int(Int64(score.total)),
                "allConfiguredProbesExecuted": .bool(score.total == probeSet.probes.count),
            ]),
            "hitProbeIds": .array(score.hitProbeIds.map { .string($0) }),
            "misses": .array(missValues),
            "frozenCopy": .bool(true),
            "liveStoreMutated": .bool(false),
            "embeddingEpoch": .object([
                "protected": .bool(epochState.protected),
                "active": epochState.activeEpoch.map(JSONValue.string) ?? .null,
                "query": .string(queryBatch.epoch.rawValue),
                "matches": .bool(epochState.activeEpoch == nil || epochState.activeEpoch == queryBatch.epoch.rawValue),
            ]),
            "contextSelector": contextScore,
            "disclosure": disclosure,
            "rankingChangeEligible": .bool(false),
            "rankingDecision": .string(
                "baseline-only: no semantic/temporal/rank-fusion candidate is activated by this evaluation"
            ),
            "durationMs": .int(Int64(elapsedMs)),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runFrozenContextMemoryEvaluation(
        storage: MemoryStorage,
        probeSet: MemoryProbeSet,
        queryBatch: MemoryEmbeddingBatch
    ) async throws -> JSONValue {
        let memories = try await storage.listMemories(persona: nil, status: "active", limit: nil)
            .filter { MemoryLifecycle.isRecallEligible($0.lifecycle) }
        var sources: [ContextStoredSource] = []
        var atoms: [ContextStoredAtom] = []
        var recordByAtom: [ContextAtomID: StoredMemory] = [:]
        for memory in memories {
            guard let vector = memory.embedding,
                  memory.embeddingEpoch == nil || memory.embeddingEpoch == queryBatch.epoch.rawValue,
                  let disclosure = MemoryRecordDisclosurePolicy.classify(
                      personaID: memory.personaId,
                      status: memory.status,
                      lifecycle: memory.lifecycle,
                      tags: memoryTags(memory.metadata),
                      metadata: memory.metadata
                  ) else { continue }
            let sourceID = ContextSourceID(rawValue: "memory-eval-source:\(memory.id)")
            let atomID = ContextAtomID(rawValue: "memory-eval-atom:\(memory.id)")
            let privacy: ContextPrivacy
            switch disclosure.privacy {
            case .localPrivate: privacy = .localPrivate
            case .trustedRemote: privacy = .trustedRemote
            case .publicSafe: privacy = .publicSafe
            }
            let surfaces = Set(disclosure.permittedSurfaces.map(ContextSurface.init(rawValue:)))
            let pinned: Bool = {
                guard case .object(let object)? = memory.metadata,
                      case .bool(true)? = object["pinned"] else { return false }
                return true
            }()
            let authority: ContextAuthority = pinned ? .canonical : .inferred
            let updatedAt = MemoryRecallScoring.parseTimestamp(memory.updatedAt) ?? Date(timeIntervalSince1970: 0)
            let sourceHash = ContextStableID.digest(parts: [
                memory.id, memory.content, memory.updatedAt, queryBatch.epoch.rawValue,
            ])
            let descriptor = ContextSourceDescriptor(
                id: sourceID,
                owner: "nativeagent.memory-eval",
                kind: .memory,
                canonicalLocator: "memory-v2/records/\(memory.id)",
                authority: authority,
                privacy: privacy,
                permittedSurfaces: surfaces,
                injectionPolicy: .adaptive
            )
            let draft = ContextAtomDraft(
                id: atomID,
                sourceID: sourceID,
                kind: .memory,
                headingPath: [],
                sourceRange: ContextSourceRange(utf8Start: 0, utf8End: memory.content.utf8.count),
                sourceHash: sourceHash,
                body: memory.content,
                authority: authority,
                confidence: memory.confidence,
                freshness: ContextFreshness(updatedAt: updatedAt),
                privacy: privacy,
                permittedSurfaces: surfaces,
                injectionPolicy: .adaptive,
                contentRole: .memory,
                entities: [ContextEntity(kind: "memory_record", id: memory.id, label: memory.id)],
                triggers: memoryTags(memory.metadata),
                activation: 0,
                recentUsefulness: 0,
                decayState: 1,
                embedding: ContextEmbedding(
                    modelFingerprint: queryBatch.epoch.rawValue,
                    values: vector
                )
            )
            sources.append(ContextStoredSource(
                descriptor: descriptor,
                sourceHash: sourceHash,
                health: .healthy,
                lastError: nil,
                validFromGeneration: 1,
                validToGeneration: nil
            ))
            atoms.append(ContextStoredAtom(
                versionKey: "\(atomID.rawValue)@1",
                draft: draft,
                validFromGeneration: 1,
                validToGeneration: nil
            ))
            recordByAtom[atomID] = memory
        }
        let generation = ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: 1,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                reason: "frozen memory evaluation",
                sourceFingerprint: ContextStableID.digest(parts: sources.map(\.sourceHash).sorted()),
                atomCount: atoms.count,
                sourceCount: sources.count
            ),
            sources: sources,
            atoms: atoms,
            relationships: []
        )
        let selector = ContextSelector()
        var hits = 0
        var hitIDs: [String] = []
        var misses: [JSONValue] = []
        for (index, probe) in probeSet.probes.enumerated() {
            let need = NeedSignal(
                message: probe.question,
                surface: .chat,
                origin: .localAuthenticated,
                authorization: ContextSelectionAuthorization(
                    allowedOrigins: [.localAuthenticated],
                    allowedPrivacy: [.localPrivate, .trustedRemote, .publicSafe],
                    allowedSourceIDs: Set(sources.map(\.descriptor.id))
                ),
                queryEmbedding: queryBatch.vectors[index],
                queryEmbeddingModelFingerprint: queryBatch.epoch.rawValue,
                availableGenerationID: 1,
                characterBudget: 6_000,
                now: Date(timeIntervalSince1970: 60),
                cacheState: .hit
            )
            let packet = try selector.select(need, from: generation)
            let selected = packet.selectedItems.compactMap { recordByAtom[$0.pointer.atomID] }
            let matched = packet.selectedItems.contains { item in
                guard let memory = recordByAtom[item.pointer.atomID] else { return false }
                if let expectedID = probe.expectMemoryId, memory.id == expectedID,
                   item.representation == .body, !item.text.isEmpty { return true }
                return probe.expectAnySubstring.contains { expected in
                    !expected.isEmpty && item.text.range(
                        of: expected,
                        options: [.caseInsensitive]
                    ) != nil
                }
            }
            if matched {
                hits += 1
                hitIDs.append(probe.id)
            } else {
                misses.append(.object([
                    "probeId": .string(probe.id),
                    "selected": .array(selected.prefix(5).map { .string($0.id) }),
                    "rankingEvidence": .array(packet.receipt.candidateScores
                        .sorted { $0.features.total > $1.features.total }
                        .compactMap { candidate -> JSONValue? in
                            guard let memory = recordByAtom[candidate.atomID] else { return nil }
                            return .object([
                                "recordID": .string(memory.id),
                                "expected": .bool(memory.id == probe.expectMemoryId),
                                "semantic": .double(candidate.features.semanticCosine),
                                "overlap": .double(candidate.features.tokenOverlap),
                                "coverage": .double(candidate.features.messageCoverage),
                                "total": .double(candidate.features.total),
                            ])
                        }),
                ]))
            }
        }
        return .object([
            "productionSelector": .bool(true),
            "productionAssembly": .bool(false),
            "scope": .string("memory-only component; full app assembly is covered by the app context integration eval"),
            "renderedEvidence": .bool(true),
            "total": .int(Int64(probeSet.probes.count)),
            "hits": .int(Int64(hits)),
            "summary": .string("\(hits)/\(probeSet.probes.count)"),
            "hitProbeIds": .array(hitIDs.map(JSONValue.string)),
            "misses": .array(misses),
            "candidateAtoms": .int(Int64(atoms.count)),
        ])
    }

    static func frozenDisclosureEvaluation() -> JSONValue {
        func decision(tags: [String], surface: String, persona: String) -> Bool {
            MemoryRecordDisclosurePolicy.classify(
                personaID: "CustomAgent",
                status: "active",
                lifecycle: MemoryLifecycle.confirmed,
                tags: tags,
                metadata: nil
            )?.permits(surface: surface, personaID: persona) == true
        }
        let checks: [(String, Bool)] = [
            ("private_chat", decision(tags: [], surface: "chat", persona: "CustomAgent")),
            // Telegram is User's authenticated personal surface (2026-07-20);
            // slack is the prompt-injectable no-human surface the local_private
            // fence actually protects against.
            ("private_telegram", decision(tags: [], surface: "telegram", persona: "CustomAgent")),
            ("private_slack_denied", !decision(tags: [], surface: "slack", persona: "CustomAgent")),
            ("public_telegram", decision(tags: ["privacy:public_safe"], surface: "telegram", persona: "CustomAgent")),
            ("persona_mismatch_denied", !decision(tags: [], surface: "chat", persona: "Other")),
            ("workshop_alias", decision(tags: [], surface: "workshop", persona: "CustomAgent")),
            ("claude_bridge_alias", decision(tags: [], surface: "claude-bridge", persona: "CustomAgent")),
        ]
        return .object([
            "passed": .bool(checks.allSatisfy(\.1)),
            "checks": .object(Dictionary(uniqueKeysWithValues: checks.map { ($0.0, .bool($0.1)) })),
        ])
    }

    static func memoryTags(_ metadata: JSONValue?) -> [String] {
        guard case .object(let object)? = metadata,
              case .array(let values)? = object["tags"] else { return [] }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    static func runMemoryHygiene(dataRootPath: String, approveSwap: Bool, maxPasses: Int) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let consolidator = MemoryConsolidator(storage: storage)
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        var passValues: [JSONValue] = []
        var appliedSwap = false

        for pass in 1...maxPasses {
            let outcome = try await consolidator.consolidateGated()
            var passObject: [String: JSONValue] = [
                "pass": .int(Int64(pass)),
            ]
            let stagedApproval: String?
            switch outcome {
            case .alreadyStaged(let approvalId):
                stagedApproval = approvalId
                passObject["outcome"] = .string("already_staged")
                passObject["approval_id"] = .string(approvalId)
            case .noChanges(let plan):
                stagedApproval = nil
                passObject["outcome"] = .string("no_changes")
                passObject["plan"] = consolidationPlanJSON(plan)
            case .refusedRegression(let scores, let plan):
                stagedApproval = nil
                passObject["outcome"] = .string("refused_regression")
                passObject["plan"] = consolidationPlanJSON(plan)
                passObject["probe_live"] = .string(scores.live.summary)
                passObject["probe_candidate"] = .string(scores.candidate.summary)
                passObject["lost_probe_ids"] = .array(scores.lostProbeIds.map { .string($0) })
            case .staged(let approvalId, let scores, let diff, let plan):
                stagedApproval = approvalId
                passObject["outcome"] = .string("staged")
                passObject["approval_id"] = .string(approvalId)
                passObject["probe_live"] = .string(scores.live.summary)
                passObject["probe_candidate"] = .string(scores.candidate.summary)
                passObject["diff"] = .string(diff.summary)
                passObject["plan"] = consolidationPlanJSON(plan)
            }

            if approveSwap, let approvalId = stagedApproval {
                do {
                    _ = try await inbox.resolve(
                        approvalId,
                        decision: .approved,
                        decidedBy: "chat-drive-memory-hygiene"
                    )
                    passObject["approval_resolution"] = .string("approved")
                } catch let error as ApprovalInboxError {
                    switch error {
                    case .alreadyResolved:
                        passObject["approval_resolution"] = .string("already_resolved")
                    default:
                        throw error
                    }
                }
                let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: dataRoot)
                passObject["reconcile"] = .array(outcomes.map { .string(describeSwapOutcome($0)) })
                if outcomes.contains(where: isAppliedSwapOutcome) {
                    appliedSwap = true
                }
                passValues.append(.object(passObject))
                if outcomes.contains(where: isStaleSwapOutcome) {
                    continue
                }
                break
            } else {
                passValues.append(.object(passObject))
                break
            }
        }

        let activeFragments = try await storage.listMemories(persona: nil, status: "active", limit: nil)
            .filter { memory in
                memory.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "user likes app interfaces to feel"
            }
        let kgSweep: JSONValue? = approveSwap && !appliedSwap
            ? try await runExplicitKnowledgeGraphSweep(dataRoot: dataRoot)
            : nil
        let out: JSONValue = .object([
            "dataRoot": .string(dataRoot.path),
            "approveSwap": .bool(approveSwap),
            "passes": .array(passValues),
            "kgSweep": kgSweep ?? .null,
            "activeKnownBadFragments": .int(Int64(activeFragments.count)),
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    static func runPhysiologySoakReport(dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath, isDirectory: true).standardizedFileURL
        let loaded = await InstalledPhysiologySoakStore(dataRoot: dataRoot).loadReportWithEvidenceSource()
        let output = PhysiologySoakReportOutput(
            evidenceSourceState: loaded.evidenceSourceState,
            retainedDayFileCount: loaded.retainedDayFileCount,
            unreadableDayFileCount: loaded.unreadableDayFileCount,
            report: loaded.report
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    /// CLI envelope for the real store load: keep the analyzer report intact,
    /// while saying whether zero records came from a readable empty directory
    /// or from an absent/unreadable evidence source.
    private struct PhysiologySoakReportOutput: Encodable {
        let schema = "chat-drive-physiology-soak-report.v1"
        let evidenceSourceState: InstalledPhysiologySoakEvidenceSourceState
        let retainedDayFileCount: Int
        let unreadableDayFileCount: Int
        let report: InstalledPhysiologySoakReport
    }

    /// Every Living Fabric projection carries the actual source-read result
    /// alongside its bounded count. A zero projection has meaning only after
    /// a source read; missing and unreadable sources must remain distinct.
    private enum LivingFabricEvidenceSourceState: String {
        case read
        case sourceAbsent = "source absent"
        case sourceUnreadable = "source unreadable"
    }

    private static func livingFabricDirectoryRead(
        _ url: URL
    ) -> (state: LivingFabricEvidenceSourceState, urls: [URL]) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
                return (.sourceUnreadable, [])
            }
            return (
                .read,
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            )
        } catch {
            // Foundation reports a missing path as NSFileReadNoSuchFileError
            // (260) from attributesOfItem/contentsOfDirectory; the legacy
            // NSFileNoSuchFileError (4) is kept for completeness. Anything
            // else (ENOTDIR, EACCES, ...) is a real read failure and must
            // stay "source unreadable" — absence and unreadability are
            // distinct receipt facts.
            let nsError = error as NSError
            let absent = nsError.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code)
            return (absent ? .sourceAbsent : .sourceUnreadable, [])
        }
    }

    private struct OperationalProcedureEvidence {
        let transitions: [CausalTransitionEvidence]
        let authoritativeOutcomes: [AuthoritativeTerminalOutcomeEvidence]
        let githubCommandSourceState: LivingFabricEvidenceSourceState
        let workshopExecutionSourceState: LivingFabricEvidenceSourceState
        let workshopExecutionDirectoriesRead: Int
        let workshopTimelineSourceState: LivingFabricEvidenceSourceState
        let workshopTimelineFilesRead: Int
    }

    /// One bounded evidence reader shared by the Living Fabric report and the
    /// local procedure operator. Review staging must evaluate the exact same
    /// canonical GitHub/Workshop rows as the read-only status report; a second
    /// looser collector would let an approval bind to evidence the report did
    /// not actually admit.
    private static func collectOperationalProcedureEvidence(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol,
        tolerateUnreadableSources: Bool = false
    ) async throws -> OperationalProcedureEvidence {
        let fileManager = FileManager.default
        let githubRoot = dataRoot.appendingPathComponent("workshop/github_command", isDirectory: true)
        let githubOps = githubRoot.appendingPathComponent("ops.jsonl")
        let githubBase = githubRoot.appendingPathComponent("ops_base.json")
        let githubDirectoryRead = livingFabricDirectoryRead(githubRoot)
        let githubSourceState: LivingFabricEvidenceSourceState
        var transitions: [CausalTransitionEvidence]
        if githubDirectoryRead.state != .read {
            githubSourceState = githubDirectoryRead.state
            transitions = []
        } else if !fileManager.fileExists(atPath: githubOps.path),
           !fileManager.fileExists(atPath: githubBase.path) {
            githubSourceState = .sourceAbsent
            transitions = []
        } else {
            do {
                transitions = try await GitHubCommandStore(dataRoot: dataRoot)
                    .causalTransitionEvidence(limit: 2_048)
                githubSourceState = .read
            } catch {
                guard tolerateUnreadableSources else { throw error }
                // This report is diagnostic. A bad canonical feed must not
                // crash it into silence or become an empty transition count.
                transitions = []
                githubSourceState = .sourceUnreadable
            }
        }
        var authoritativeOutcomes: [AuthoritativeTerminalOutcomeEvidence] = []
        let workshopRunner = SwiftNativeWorkshopRunner(
            executorAvailable: false,
            root: dataRoot,
            enableAutonomy: false
        )
        let executionsRoot = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        let executionRead = livingFabricDirectoryRead(executionsRoot)
        let executionDirectories = executionRead.urls.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.lastPathComponent < $1.lastPathComponent
        }
        var workshopTimelineFilesRead = 0
        var workshopTimelineReadFailed = false

        // Builder evidence remains bounded before the final suffix so a
        // malformed/custom root cannot turn review staging into an archival
        // scan or an authority denial into a memory-pressure failure.
        for directory in executionDirectories.suffix(128) {
            let executionRecord = await workshopRunner.getWorkshopExecution(
                directory.lastPathComponent
            )
            let timelineURL = directory.appendingPathComponent("timeline.jsonl")
            let timeline: [JSONValue]
            if !fileManager.fileExists(atPath: timelineURL.path) {
                timeline = []
            } else {
                do {
                    timeline = try await persistence.tailJSONL(
                        timelineURL,
                        limit: 256,
                        maxBytes: 512 * 1_024
                    )
                    workshopTimelineFilesRead += 1
                } catch {
                    guard tolerateUnreadableSources else { throw error }
                    timeline = []
                    workshopTimelineReadFailed = true
                }
            }
            transitions.append(contentsOf: SwiftNativeWorkshopRunner.causalTransitionEvidence(
                executionId: directory.lastPathComponent,
                timeline: timeline,
                record: executionRecord,
                limit: 256
            ))
            if transitions.count > 20_000 {
                transitions.sort {
                    let lhs = parseLivingFabricDate($0.occurredAt) ?? .distantPast
                    let rhs = parseLivingFabricDate($1.occurredAt) ?? .distantPast
                    if lhs != rhs { return lhs < rhs }
                    return $0.operationId < $1.operationId
                }
                transitions = Array(transitions.suffix(20_000))
            }
            let action: MotorActionReadModel?
            do {
                action = try await workshopRunner.motorActionReadModel(
                    actionId: directory.lastPathComponent
                )
            } catch {
                guard tolerateUnreadableSources else { throw error }
                workshopTimelineReadFailed = true
                action = nil
            }
            if let action, let occurredAt = action.updatedAt {
                let kind: AuthoritativeTerminalOutcomeEvidence.Kind?
                switch (action.phase, action.verification) {
                case (.succeeded, .satisfied): kind = .verifiedSuccess
                case (.failed, .failed): kind = .verifiedFailure
                case (.cancelled, .notRequired): kind = .cancelled
                default: kind = nil
                }
                if let kind {
                    authoritativeOutcomes.append(AuthoritativeTerminalOutcomeEvidence(
                        domain: action.domain,
                        itemIdentity: action.actionIdentity,
                        occurredAt: occurredAt,
                        kind: kind
                    ))
                }
            }
        }
        transitions.sort {
            let lhs = parseLivingFabricDate($0.occurredAt) ?? .distantPast
            let rhs = parseLivingFabricDate($1.occurredAt) ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.operationId < $1.operationId
        }
        let workshopTimelineSourceState: LivingFabricEvidenceSourceState
        if workshopTimelineReadFailed {
            workshopTimelineSourceState = .sourceUnreadable
        } else if executionRead.state != .read {
            workshopTimelineSourceState = executionRead.state
        } else if !executionDirectories.isEmpty, workshopTimelineFilesRead == 0 {
            workshopTimelineSourceState = .sourceAbsent
        } else {
            workshopTimelineSourceState = .read
        }
        return OperationalProcedureEvidence(
            transitions: Array(transitions.suffix(20_000)),
            authoritativeOutcomes: authoritativeOutcomes,
            githubCommandSourceState: githubSourceState,
            workshopExecutionSourceState: executionRead.state,
            workshopExecutionDirectoriesRead: executionDirectories.count,
            workshopTimelineSourceState: workshopTimelineSourceState,
            workshopTimelineFilesRead: workshopTimelineFilesRead
        )
    }

    static func runProcedureOperator(
        action: String,
        dataRootPath: String,
        shapeID: String?,
        approvalID: String?,
        scope: String?,
        sourceRelativePath: String?,
        destinationRelativePath: String?,
        invocationKey: String?
    ) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath, isDirectory: true)
            .standardizedFileURL
        let store = ProcedureArtifactStore(dataRoot: dataRoot)
        if action == "status" {
            let status = await store.statusSnapshot()
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.status.v1"),
                "artifactCount": .int(Int64(status.artifactCount)),
                "corruptArtifactCount": .int(Int64(status.corruptArtifactCount)),
                "corruptInvocationCount": .int(Int64(status.corruptInvocationCount)),
                "invocationCount": .int(Int64(status.invocationCount)),
                "manualInvocationCount": .int(Int64(status.manualInvocationCount)),
                "automaticInvocationCount": .int(Int64(status.automaticInvocationCount)),
                "verifiedInvocationCount": .int(Int64(status.verifiedInvocationCount)),
                "activationArtifactCount": .int(Int64(status.activationArtifactCount)),
                "corruptActivationArtifactCount": .int(
                    Int64(status.corruptActivationArtifactCount)
                ),
                "activeAutomaticProcedureCount": .int(
                    Int64(status.activeAutomaticProcedureCount)
                ),
                "automaticSelectionEnabled": .bool(status.automaticSelectionEnabled),
                "payloadFree": .bool(true),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")
            return
        }

        if ["stage-activation", "activate", "deactivate"].contains(action) {
            guard let artifactID = shapeID,
                  artifactID.count == 64,
                  artifactID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw procedureOperatorError(
                    "\(action) requires a lowercase 64-character artifact ID"
                )
            }
            let artifact = try await store.load(artifactID)
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            if action == "deactivate" {
                let active = try await store.loadActiveExactProcedure(
                    procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
                    implementationIdentity:
                        WorkshopCompiledLocalFileCopyPlanner.implementationIdentity
                )
                guard active.artifact.id == artifact.id else {
                    throw procedureOperatorError("active procedure artifact does not match")
                }
                try await store.deactivateExact(
                    procedureID: WorkshopCompiledLocalFileCopyPlanner.procedureID,
                    expectedActivationID: active.manifest.id
                )
                let output: JSONValue = .object([
                    "schema": .string("procedure.operator.deactivate.v1"),
                    "procedureID": .string(active.manifest.proposal.procedureID),
                    "activationID": .string(active.manifest.id),
                    "automaticSelectionEnabled": .bool(false),
                    "artifactRetained": .bool(true),
                    "rollbackDataMigration": .bool(false),
                ])
                print((try? output.serialize(pretty: true)) ?? "\(output)")
                return
            }
            if action == "stage-activation" {
                guard let proposal = try await WorkshopProcedureExactActivationQualifier
                    .localFileCopyProposal(dataRoot: dataRoot, artifact: artifact) else {
                    throw procedureOperatorError(
                        "artifact does not yet have 12 distinct verified zero-provider canonical executions"
                    )
                }
                let pending = try await inbox.list(filter: ApprovalFilter(
                    status: "pending",
                    action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction
                ))
                let existing = pending.first(where: {
                    SwiftNativeApprovalInbox.procedureExactActivationProposal(from: $0)?
                        .artifactID == proposal.artifactID
                })
                let approval: ApprovalRecord
                if let existing {
                    approval = existing
                } else {
                    approval = try await inbox.stageProcedureExactActivationApproval(proposal)
                }
                let output: JSONValue = .object([
                    "schema": .string("procedure.operator.activation-review.v1"),
                    "approvalID": .string(approval.id),
                    "approvalStatus": .string(approval.status),
                    "artifactID": .string(artifact.id),
                    "proposalDigest": .string(proposal.bindingDigest),
                    "verifiedExecutions": .int(Int64(proposal.verifiedExecutionCount)),
                    "distinctInputs": .int(Int64(proposal.distinctInputCount)),
                    "zeroProviderExecutions": .int(
                        Int64(proposal.zeroProviderExecutionCount)
                    ),
                    "p95ExecutionLatencyMilliseconds": .int(
                        Int64(proposal.p95ExecutionLatencyMilliseconds)
                    ),
                    "localOnly": .bool(true),
                    "remoteResolvable": .bool(false),
                ])
                print((try? output.serialize(pretty: true)) ?? "\(output)")
                return
            }
            guard let approvalID, !approvalID.isEmpty else {
                throw procedureOperatorError("activate requires --approval <resolved-local-id>")
            }
            let approval = try await inbox.get(approvalID)
            guard let proposal = SwiftNativeApprovalInbox
                .procedureExactActivationProposal(from: approval),
                  proposal.artifactID == artifact.id,
                  await WorkshopProcedureExactActivationQualifier
                    .proposalStillMatchesCanonicalEvidence(
                        proposal,
                        dataRoot: dataRoot,
                        artifact: artifact
                    ) else {
                throw procedureOperatorError(
                    "approved activation evidence no longer matches canonical Workshop truth"
                )
            }
            let decision = try await inbox.approvedProcedureExactActivationDecision(
                approvalID: approvalID,
                proposal: proposal
            )
            let activation = try await store.installAndActivateExact(
                proposal: proposal,
                reviewerDecision: decision
            )
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.activate.v1"),
                "activationID": .string(activation.id),
                "artifactID": .string(activation.proposal.artifactID),
                "procedureID": .string(activation.proposal.procedureID),
                "selectionMode": .string(activation.selectionMode),
                "automaticSelectionEnabled": .bool(true),
                "permissionAuthority": .bool(false),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")
            return
        }

        if action == "invoke" {
            guard let artifactID = shapeID,
                  artifactID.count == 64,
                  artifactID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let sourceRelativePath,
                  let destinationRelativePath,
                  let invocationKey,
                  validProcedureInvocationKey(invocationKey) else {
                throw procedureOperatorError(
                    "invoke requires a lowercase 64-character artifact ID, --source and --destination workspace-relative paths, and a stable --invocation-key (1-128 letters, numbers, dot, dash, or underscore)"
                )
            }
            try await invokeCompiledWorkshopProcedure(
                store: store,
                artifactID: artifactID,
                dataRoot: dataRoot,
                sourceRelativePath: sourceRelativePath,
                destinationRelativePath: destinationRelativePath,
                invocationKey: invocationKey
            )
            return
        }

        guard let shapeID,
              shapeID.count == 64,
              shapeID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw procedureOperatorError("a lowercase 64-character shape identity is required")
        }
        let evidence = try await collectOperationalProcedureEvidence(
            dataRoot: dataRoot,
            persistence: SwiftNativePersistenceCore()
        )
        let trajectories = ProcedureTrajectoryExtractor.extract(evidence.transitions).trajectories
        guard let candidate = ProcedureCandidateCompiler.evaluate(
            trajectories: trajectories
        ).first(where: { $0.id == shapeID }) else {
            throw procedureOperatorError("procedure candidate not found in canonical evidence")
        }
        let reviewScope: ProcedureReviewScope
        switch scope ?? "manual" {
        case "manual": reviewScope = .manualOnly
        case "canary": reviewScope = .manualAndCanary
        default: throw procedureOperatorError("scope must be manual or canary")
        }
        let proposal = ProcedureReviewProposal(candidate: candidate, scope: reviewScope)
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)

        switch action {
        case "stage-review":
            guard candidate.manualBlockingReasons == [.reviewerDecisionMissing] else {
                throw procedureOperatorError(
                    "candidate has non-review blockers: "
                        + candidate.manualBlockingReasons.map(\.rawValue).joined(separator: ",")
                )
            }
            if reviewScope == .manualAndCanary {
                let nonReviewCanaryBlockers = candidate.canaryBlockingReasons.filter {
                    $0 != .reviewerDecisionMissing && $0 != .reviewerCanaryScopeMissing
                }
                guard nonReviewCanaryBlockers.isEmpty else {
                    throw procedureOperatorError(
                        "candidate is not canary-ready: "
                            + nonReviewCanaryBlockers.map(\.rawValue).joined(separator: ",")
                    )
                }
            }
            let pending = try await inbox.list(filter: ApprovalFilter(
                status: "pending",
                action: SwiftNativeApprovalInbox.procedureReviewApprovalAction
            ))
            let existingApproval = pending.first(where: {
                guard case .object(let payload) = $0.payload,
                      case .string(let pendingShape)? = payload["candidateShapeIdentity"],
                      case .string(let pendingDigest)? = payload["candidateEvidenceDigest"] else {
                    return false
                }
                return pendingShape == proposal.candidateShapeIdentity
                    && pendingDigest == proposal.candidateEvidenceDigest
            })
            let approval = if let existingApproval {
                existingApproval
            } else {
                try await inbox.stageProcedureReviewApproval(proposal)
            }
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.review.v1"),
                "approvalID": .string(approval.id),
                "approvalStatus": .string(approval.status),
                "shapeIdentity": .string(candidate.id),
                "trajectoryCount": .int(Int64(candidate.trajectoryCount)),
                "distinctInputs": .int(Int64(candidate.distinctInputInstanceCount)),
                "verifiedSuccesses": .int(Int64(candidate.verifiedSuccessCount)),
                "verifiedSuccessRate": .double(candidate.verifiedSuccessRate),
                "removableProviderCalls": candidate.measurableRemovableProviderCalls
                    .map { .int(Int64($0)) } ?? .null,
                "scope": .string(reviewScope.rawValue),
                "localOnly": .bool(true),
                "remoteResolvable": .bool(false),
                "payloadFree": .bool(true),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")

        case "compile":
            guard let approvalID, !approvalID.isEmpty else {
                throw procedureOperatorError("compile requires --approval <resolved-local-id>")
            }
            let decision = try await inbox.approvedProcedureReviewerDecision(
                approvalID: approvalID,
                proposal: proposal
            )
            guard let reviewed = ProcedureCandidateCompiler.evaluate(
                trajectories: trajectories,
                reviewerDecisions: [decision]
            ).first(where: { $0.id == shapeID }), reviewed.manualInvocationEligible else {
                throw procedureOperatorError("reviewed candidate is not eligible for manual invocation")
            }
            let artifact = try DeclarativeProcedureCompiler.compile(reviewed)
            let replay = reviewed.sourceTrajectories.map {
                ProcedureReplayEngine.replay(artifact, against: $0, mode: .historicalExact)
            }
            guard replay.allSatisfy({
                $0.status == .matched
                    && $0.matchedStepCount == artifact.transitionTable.count
            }) else {
                throw procedureOperatorError("historical exact replay diverged; artifact not installed")
            }
            _ = try await store.install(artifact)
            let output: JSONValue = .object([
                "schema": .string("procedure.operator.compile.v1"),
                "artifactID": .string(artifact.id),
                "shapeIdentity": .string(artifact.procedureShapeIdentity),
                "sourceTrajectoryCount": .int(Int64(artifact.sourceTrajectoryIdentities.count)),
                "replayedTrajectoryCount": .int(Int64(replay.count)),
                "manualInvocationEligible": .bool(artifact.manualInvocationEligible),
                "canaryEligible": .bool(artifact.canaryEligible),
                "automaticSelectionEligible": .bool(false),
                "permissionAuthority": .bool(false),
                "payloadFree": .bool(true),
            ])
            print((try? output.serialize(pretty: true)) ?? "\(output)")

        default:
            throw procedureOperatorError(
                "action must be status, stage-review, compile, invoke, stage-activation, activate, or deactivate"
            )
        }
    }

    /// Manual proof seam for the first provider-free procedure target. The
    /// procedure store remains the artifact/invocation owner; Workshop remains
    /// the canonical executor; Desk remains the task identity; Trust Center is
    /// re-read at admission and before every tool action. This command adds no
    /// automatic selector and cannot invoke external-send or process-global
    /// tools.
    private static func invokeCompiledWorkshopProcedure(
        store: ProcedureArtifactStore,
        artifactID: String,
        dataRoot: URL,
        sourceRelativePath: String,
        destinationRelativePath: String,
        invocationKey: String
    ) async throws {
        let artifact = try await store.load(artifactID)
        let invocation = try WorkshopCompiledLocalFileCopyInvocation(
            artifact: artifact,
            dataRoot: dataRoot,
            sourceRelativePath: sourceRelativePath,
            destinationRelativePath: destinationRelativePath,
            invocationKey: invocationKey,
            store: store
        )
        let startedAt = Date()
        let dispatcher = SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: false,
            enforceLazyToolLoading: false
        )
        let outcome = try await invocation.invokeManual(
            policyAllowed: {
                await workshopProcedurePolicyAllows(dataRoot: dataRoot)
            },
            toolDispatch: { tool, arguments in
                return try await dispatcher.dispatch(
                    tool: tool,
                    input: arguments,
                    surface: "procedure"
                )
            }
        )
        let receipt = outcome.receipt
        let finalRecord = outcome.execution
        let providerAccounting = exactWorkshopProviderAccounting(finalRecord)
        let verificationStatus: JSONValue = finalRecord.verification
            .map { .string($0.status.rawValue) } ?? .null
        let planningCalls: JSONValue = finalRecord.planningProviderCallCount
            .map { .int(Int64($0)) } ?? .null
        let totalCalls: JSONValue = providerAccounting
            .map { .int(Int64($0.providerCalls)) } ?? .null
        let removableCalls: JSONValue = providerAccounting
            .map { .int(Int64($0.removableCalls)) } ?? .null
        let elapsed = Int64(Date().timeIntervalSince(startedAt) * 1_000)
        var fields: [String: JSONValue] = [
            "schema": .string("procedure.operator.invoke.v1"),
            "artifactID": .string(artifact.id),
            "invocationID": .string(receipt.invocationID),
            "opaqueExecutionIdentity": .string(outcome.opaqueExecutionIdentity),
            "deskAlias": outcome.deskAlias.map(JSONValue.string) ?? .null,
            "workshopStatus": .string(finalRecord.status),
            "verificationStatus": verificationStatus,
            "planningProviderCalls": planningCalls,
            "totalProviderCalls": totalCalls,
            "removableOrchestrationProviderCalls": removableCalls,
            "procedureVerified": .bool(receipt.verified),
            "authorityRechecked": .bool(receipt.authorityRechecked),
            "canonicalEvidenceMatched": .bool(receipt.canonicalEvidenceMatched),
            "automaticSelection": .bool(false),
            "permissionAuthority": .bool(false),
            "retrySafe": .bool(true),
            "elapsedMilliseconds": .int(elapsed),
            "payloadFree": .bool(true),
        ]
        fields["verificationMethods"] = .array(
            (finalRecord.verification?.methods ?? []).map(JSONValue.string)
        )
        let output: JSONValue = .object(fields)
        print((try? output.serialize(pretty: true)) ?? "\(output)")
    }

    private static func validProcedureInvocationKey(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._")
        )
        return raw.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func workshopProcedurePolicyAllows(dataRoot: URL) async -> Bool {
        do {
            // The checked canonical owner distinguishes missing state (merge
            // defaults) from damaged saved authority (throw/fail closed).
            let policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot)
                .loadTrustPolicyChecked()
            return SwiftNativeWorkshopRunner.workshopPolicyAllows(policy)
        } catch {
            return false
        }
    }

    private static func exactWorkshopProviderAccounting(
        _ record: WorkshopExecutionRecord
    ) -> (providerCalls: Int, removableCalls: Int)? {
        guard let planning = record.planningProviderCallCount,
              let planningRemovable = record.planningRemovableOrchestrationProviderCallCount,
              planning >= 0, planningRemovable >= 0, planningRemovable <= planning else {
            return nil
        }
        var providers = planning
        var removable = planningRemovable
        for row in record.stepsCompleted {
            guard case .object(let object) = row,
                  case .int(let provider)? = object["provider_call_count"],
                  case .int(let removed)? = object["removable_orchestration_provider_call_count"],
                  provider >= 0, removed >= 0, removed <= provider else { return nil }
            let (nextProviders, providerOverflow) = providers.addingReportingOverflow(Int(provider))
            let (nextRemovable, removableOverflow) = removable.addingReportingOverflow(Int(removed))
            guard !providerOverflow, !removableOverflow else { return nil }
            providers = nextProviders
            removable = nextRemovable
        }
        guard removable <= providers else { return nil }
        return (providers, removable)
    }

    private static func procedureOperatorError(_ message: String) -> NSError {
        NSError(
            domain: "NativeAgentProcedureOperator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Read-only evidence report for the Living Fabric pilot. This is builder
    /// instrumentation, not another runtime owner: it reads bounded persisted
    /// traces through the existing projections, writes nothing, creates no
    /// training corpus, and grants no control or learning approval.
    static func runLivingFabricEval(dataRootPath: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let evaluatedAt = Date()
        let persistence = SwiftNativePersistenceCore()
        let traceDirectory = dataRoot.appendingPathComponent("turn_traces", isDirectory: true)
        let traceDirectoryRead = livingFabricDirectoryRead(traceDirectory)
        let traceURLs = traceDirectoryRead.urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Turn trace retention is already bounded by the app. Keep this CLI
        // defensive as well so a malformed/custom root cannot turn a review
        // command into an unbounded memory load. The receipt is part of the
        // report: an empty or imperfect input window must not look like an
        // authoritative zero-recommendation result.
        let maximumTraceFiles = 21
        let perFileRowLimit = 20_000
        let perFileByteLimit = 16 * 1_024 * 1_024
        let maximumTraceEvents = 100_000
        let selectedTraceURLs = Array(traceURLs.suffix(maximumTraceFiles))
        var traceEvents: [TurnTraceEvent] = []
        traceEvents.reserveCapacity(min(50_000, traceURLs.count * 2_000))
        var physicalTraceRowsScanned = 0
        var malformedJSONTraceRows = 0
        var rejectedTraceEventRows = 0
        var byteWindowTruncatedFileCount = 0
        var globallyDiscardedTraceEventCount = 0
        var traceSourceState = traceDirectoryRead.state
        var traceFilesRead = 0
        for url in selectedTraceURLs {
            do {
                let receipt = try await persistence.tailJSONLReadReceipt(
                    url,
                    limit: perFileRowLimit,
                    maxBytes: perFileByteLimit
                )
                traceFilesRead += 1
                physicalTraceRowsScanned += receipt.physicalRowsScanned
                malformedJSONTraceRows += receipt.malformedJSONRowCount
                if receipt.truncatedToByteWindow {
                    byteWindowTruncatedFileCount += 1
                }
                let decoded = receipt.rows.compactMap(TurnTraceEvent.init(jsonRow:))
                rejectedTraceEventRows += receipt.rows.count - decoded.count
                traceEvents.append(contentsOf: decoded)
                if traceEvents.count > maximumTraceEvents {
                    let discarded = traceEvents.count - maximumTraceEvents
                    traceEvents.removeFirst(discarded)
                    globallyDiscardedTraceEventCount += discarded
                }
            } catch {
                traceSourceState = .sourceUnreadable
                continue
            }
        }
        let shadow = MetacognitiveShadowEvaluation.evaluate(events: traceEvents)
        let outcomeCalibration = MetacognitiveOutcomeCalibrationReport.evaluate(events: traceEvents)

        let operationalEvidence = try await collectOperationalProcedureEvidence(
            dataRoot: dataRoot,
            persistence: persistence,
            tolerateUnreadableSources: true
        )
        let transitions = operationalEvidence.transitions
        let authoritativeOutcomes = operationalEvidence.authoritativeOutcomes

        let transitionDates = transitions.compactMap { parseLivingFabricDate($0.occurredAt) }
        let transitionDomainCounts = Dictionary(grouping: transitions, by: \.domain)
            .mapValues(\.count)
        let procedureExtraction = ProcedureTrajectoryExtractor.extract(transitions)
        let procedureCandidates = ProcedureCandidateCompiler.evaluate(
            trajectories: procedureExtraction.trajectories
        )
        let procedureRoot = dataRoot
            .appendingPathComponent("living_fabric", isDirectory: true)
            .appendingPathComponent("procedures", isDirectory: true)
        let procedureSourceRead = livingFabricDirectoryRead(procedureRoot)
        let procedureArtifacts = await ProcedureArtifactStore(dataRoot: dataRoot).statusSnapshot()
        let outcomeReport = CausalTerminalOutcomeClassifier.classify(
            transitions: transitions,
            authoritative: authoritativeOutcomes
        )
        let holdout = AdaptiveCausalTimeHoldoutPolicy.split(transitions)
        let drift = AdaptiveCausalDriftEvaluator.evaluate(
            training: holdout.training,
            holdout: holdout.holdout
        )
        let transitionSchemaVersion = "causal-transition-evidence.v2"
        let privacyArtifactURL = dataRoot
            .appendingPathComponent("living_fabric", isDirectory: true)
            .appendingPathComponent("review", isDirectory: true)
            .appendingPathComponent("privacy-classification.json")
        let privacyLoad: (artifact: AdaptiveCausalPrivacyReviewArtifact?, status: String) = {
            do {
                return (try AdaptiveCausalPrivacyReviewLoader.load(
                    from: privacyArtifactURL,
                    requiredDomains: Set(transitions.map(\.domain)),
                    transitionSchemaVersion: transitionSchemaVersion
                ), "valid")
            } catch let error as AdaptiveCausalArtifactError {
                return (nil, error.rawValue)
            } catch {
                return (nil, "malformed")
            }
        }()
        let shadowRoot = dataRoot
            .appendingPathComponent("living_fabric", isDirectory: true)
            .appendingPathComponent("shadow", isDirectory: true)
        let rollbackLoad: (artifact: AdaptiveCausalRollbackManifest?, status: String) = {
            do {
                return (try AdaptiveCausalRollbackManifestLoader.load(
                    from: shadowRoot.appendingPathComponent("rollback-manifest.json"),
                    modelArtifactDirectory: shadowRoot.appendingPathComponent("models", isDirectory: true)
                ), "valid")
            } catch let error as AdaptiveCausalArtifactError {
                return (nil, error.rawValue)
            } catch {
                return (nil, "malformed")
            }
        }()
        func artifactSourceState(_ status: String) -> LivingFabricEvidenceSourceState {
            switch status {
            case "valid": return .read
            case AdaptiveCausalArtifactError.missing.rawValue: return .sourceAbsent
            default: return .sourceUnreadable
            }
        }
        let gate = AdaptiveCausalLearningGate.evaluate(AdaptiveCausalLearningEvidence(
            firstTransitionAt: transitionDates.min(),
            lastTransitionAt: transitionDates.max(),
            evaluatedAt: evaluatedAt,
            transitionCount: transitions.count,
            outcomeCompleteCount: outcomeReport.outcomeCompleteTransitionCount,
            invalidTransitionTimestampCount: holdout.invalidTimestampCount,
            // These names classify this bounded projection, not the underlying
            // raw stores. Approval/drift/rollback remain explicit blockers.
            transitionSchemaVersion: transitionSchemaVersion,
            // These can become non-nil/true only through strict read-only
            // validation of explicit offline artifacts. The evaluator never
            // creates or repairs either artifact.
            privacyClassificationVersion: privacyLoad.artifact?.classificationVersion,
            holdoutDays: holdout.elapsedHoldoutDays,
            driftDetectionReady: drift.detectorReady,
            distributionDriftWithinLimit: drift.withinLimit,
            rollbackArtifactReady: rollbackLoad.artifact != nil,
            personalTraceLearningApproved: false,
            purpose: .personalShadowEvaluation,
            holdoutTransitionCount: holdout.holdout.count,
            controlledProductionTransitionCount: transitions.count {
                $0.evidenceClass == .controlledProduction
            }
        ))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let shadowValue: JSONValue = .object([
            "schema": .string("metacognition.shadow-evaluation.v1"),
            "recommendationEmission": .string(
                shadow.turns.isEmpty ? "no recommendations emitted" : "recommendations emitted"
            ),
            "recommendations": .int(Int64(shadow.turns.count)),
            "legacyExcludedRecommendations": .int(Int64(shadow.legacyExcludedRecommendationCount)),
            "correlatedTurns": .int(Int64(shadow.correlatedTurnCount)),
            "incompleteCorrelation": .int(Int64(shadow.incompleteCorrelationCount)),
            "correlationCoverage": .double(shadow.correlationCoverageRate),
            "completeObservedMeasurements": .int(Int64(shadow.completeObservedMeasurementCount)),
            "observedMeasurementCoverage": .double(shadow.observedMeasurementCoverageRate),
            "toolLaneAgreement": .double(shadow.toolLaneAgreementRate),
            // Tool use is the only recommendation dimension with an exact
            // terminal observation today. Compute/context quality require a
            // later authoritative outcome and are deliberately not inferred
            // from latency, model choice, or packet size.
            "scoredRecommendationDimensions": .array([.string("tool_use")]),
            "unscoredRecommendationDimensions": .object([
                "compute": .string("no_authoritative_quality_outcome"),
                "context": .string("no_authoritative_usefulness_outcome"),
                "model": .string("recommendation_does_not_choose_a_model"),
                "correction_rate": .string("explicit_regenerate_only; not_a_causal_quality_label"),
                "unnecessary_model_calls": .string("no_counterfactual_no_call_baseline"),
                "tool_usefulness": .string("terminal_receipt_proves_use_not_value"),
            ]),
            // Closed-schema v1 terminal receipts plus explicit regenerate
            // edges. This supersedes inference from silence/prose while
            // remaining payload-free and observational.
            "authoritativeOutcomeCalibration": outcomeCalibration.traceValue,
            "recommendationObservations": .object([
                "compute": computeLaneObservationJSON(shadow.turns),
                "context": contextLaneObservationJSON(shadow.turns),
                "tool": toolLaneObservationJSON(shadow.turns),
            ]),
            "recommendedAffordances": .object(shadow.affordanceCounts.mapValues { .int(Int64($0)) }),
            "observedProviders": .object(shadow.providerCounts.mapValues { .int(Int64($0)) }),
            "observedProviderModels": .object(shadow.providerModelCounts.mapValues { .int(Int64($0)) }),
            "observedEngineModels": .object(shadow.modelCounts.mapValues { .int(Int64($0)) }),
            "observedReasoningEffort": .object(shadow.reasoningEffortCounts.mapValues { .int(Int64($0)) }),
            "observedContextSources": .object(shadow.contextSourceCounts.mapValues { .int(Int64($0)) }),
            "turnLatencyMs": integerMetricSummaryJSON(shadow.turnLatency),
            "providerLatencyMs": integerMetricSummaryJSON(shadow.providerLatency),
            "contextPacketCharacters": integerMetricSummaryJSON(shadow.contextPacketCharacters),
            "contextSelectedAtoms": integerMetricSummaryJSON(shadow.contextSelectedAtoms),
            "evidenceStatus": .string(shadow.evidenceStatus.rawValue),
            "firstRecommendationAt": shadow.firstRecommendationAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "lastRecommendationAt": shadow.lastRecommendationAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "surfaces": .object(shadow.surfaceCounts.mapValues { .int(Int64($0)) }),
            "controlAuthority": .bool(false),
        ])
        let readinessValue: JSONValue = .object([
            "readyForShadowTraining": .bool(gate.readyForShadowTraining),
            "blockers": .array(gate.blockers.map { .string($0.rawValue) }),
            "observationDays": .double(gate.observationDays),
            "observationDaysRemaining": .double(gate.observationDaysRemaining),
            "transitionCount": .int(Int64(gate.transitionCount)),
            "transitionDomains": .object(transitionDomainCounts.mapValues { .int(Int64($0)) }),
            "transitionsRemaining": .int(Int64(gate.transitionsRemaining)),
            "outcomeCompleteCount": .int(Int64(gate.outcomeCompleteCount)),
            "outcomeCoverage": .double(gate.outcomeCoverage),
            "outcomeClassification": .string("terminal_trajectory.v1"),
            "terminalTrajectoryCount": .int(Int64(outcomeReport.terminalTrajectoryCount)),
            "incompleteTrajectoryCount": .int(Int64(outcomeReport.incompleteTrajectoryCount)),
            "terminalKinds": .object(Dictionary(
                uniqueKeysWithValues: outcomeReport.terminalKindCounts.map {
                    ($0.key.rawValue, JSONValue.int(Int64($0.value)))
                }
            )),
            "privacyReviewLoaded": .bool(privacyLoad.artifact != nil),
            "privacyReviewStatus": .string(privacyLoad.status),
            "privacyClassificationVersion": privacyLoad.artifact.map { .string($0.classificationVersion) } ?? .null,
            "holdoutCutoffAt": holdout.cutoffAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "holdoutTrainingCount": .int(Int64(holdout.training.count)),
            "holdoutEvaluationCount": .int(Int64(holdout.holdout.count)),
            "sampleSufficiencyUsed": .bool(gate.sampleSufficiencyUsed),
            "readinessPurpose": .string(gate.purpose.rawValue),
            "controlledProductionTransitionCount": .int(
                Int64(gate.controlledProductionTransitionCount)
            ),
            "holdoutInvalidTimestampCount": .int(Int64(holdout.invalidTimestampCount)),
            "holdoutDays": .int(Int64(holdout.elapsedHoldoutDays)),
            "holdoutDaysRemaining": .int(Int64(gate.holdoutDaysRemaining)),
            "lastEvidenceAgeDays": gate.lastEvidenceAgeDays.map(JSONValue.double) ?? .null,
            "driftSchema": .string(drift.schema),
            "driftStatus": .string(drift.status.rawValue),
            "driftJensenShannon": drift.jensenShannonDivergence.map(JSONValue.double) ?? .null,
            "driftMaximumAllowed": .double(drift.maximumAllowedDivergence),
            "rollbackManifestLoaded": .bool(rollbackLoad.artifact != nil),
            "rollbackManifestStatus": .string(rollbackLoad.status),
            "rollbackModelVersion": rollbackLoad.artifact.map { .string($0.modelVersion) } ?? .null,
            "controlAuthority": .bool(false),
            "personalTraceLearningApproved": .bool(false),
        ])
        let procedureValue: JSONValue = .object([
            "schema": .string("compiled.procedure.evidence.v1"),
            "acceptedTrajectories": .int(Int64(procedureExtraction.trajectories.count)),
            "rejectedTrajectories": .int(Int64(procedureExtraction.rejections.count)),
            "rowsWithoutTrajectoryIdentity": .int(Int64(
                procedureExtraction.rowsWithoutTrajectoryIdentity
            )),
            "rejectionReasons": .object(Dictionary(
                grouping: procedureExtraction.rejections.flatMap(\.reasons),
                by: \.rawValue
            ).mapValues { .int(Int64($0.count)) }),
            "candidates": .array(procedureCandidates.map { candidate in
                .object([
                    "shapeIdentity": .string(candidate.id),
                    "productRole": .string(candidate.productRole.rawValue),
                    "trajectories": .int(Int64(candidate.trajectoryCount)),
                    "verifiedSuccesses": .int(Int64(candidate.verifiedSuccessCount)),
                    "verifiedSuccessRate": .double(candidate.verifiedSuccessRate),
                    "manualEligible": .bool(candidate.manualInvocationEligible),
                    "canaryEligible": .bool(candidate.canaryEligible),
                    "automaticSelectionEligible": .bool(false),
                    "manualBlockers": .array(candidate.manualBlockingReasons.map {
                        .string($0.rawValue)
                    }),
                    "canaryBlockers": .array(candidate.canaryBlockingReasons.map {
                        .string($0.rawValue)
                    }),
                ])
            }),
            "installedArtifacts": .int(Int64(procedureArtifacts.artifactCount)),
            "corruptArtifacts": .int(Int64(procedureArtifacts.corruptArtifactCount)),
            "invocations": .int(Int64(procedureArtifacts.invocationCount)),
            "manualInvocations": .int(Int64(procedureArtifacts.manualInvocationCount)),
            "automaticInvocations": .int(Int64(procedureArtifacts.automaticInvocationCount)),
            "verifiedInvocations": .int(Int64(procedureArtifacts.verifiedInvocationCount)),
            "activationArtifacts": .int(Int64(procedureArtifacts.activationArtifactCount)),
            "activeAutomaticProcedures": .int(
                Int64(procedureArtifacts.activeAutomaticProcedureCount)
            ),
            "automaticSelectionEnabled": .bool(
                procedureArtifacts.automaticSelectionEnabled
            ),
            "generatedEvidenceCanQualify": .bool(false),
            "payloadFree": .bool(true),
        ])
        let evidenceSourcesValue: JSONValue = .object([
            "turnTraces": .object([
                "source": .string("turn_traces/*.jsonl"),
                "state": .string(traceSourceState.rawValue),
                "filesDiscovered": .int(Int64(traceURLs.count)),
                "filesRead": .int(Int64(traceFilesRead)),
            ]),
            "githubCommand": .object([
                "source": .string("workshop/github_command/{ops.jsonl,ops_base.json}"),
                "state": .string(operationalEvidence.githubCommandSourceState.rawValue),
                "transitionsRead": .int(Int64(transitions.count)),
            ]),
            "workshopExecutions": .object([
                "source": .string("workshop/executions/*/{execution.json,timeline.jsonl}"),
                "state": .string(operationalEvidence.workshopExecutionSourceState.rawValue),
                "executionDirectoriesRead": .int(
                    Int64(operationalEvidence.workshopExecutionDirectoriesRead)
                ),
                "timelineState": .string(operationalEvidence.workshopTimelineSourceState.rawValue),
                "timelineFilesRead": .int(Int64(operationalEvidence.workshopTimelineFilesRead)),
            ]),
            "procedureArtifacts": .object([
                "source": .string("living_fabric/procedures/"),
                "state": .string(procedureSourceRead.state.rawValue),
                "artifactsRead": .int(Int64(procedureArtifacts.artifactCount)),
                "invocationsRead": .int(Int64(procedureArtifacts.invocationCount)),
            ]),
            "privacyClassification": .object([
                "source": .string("living_fabric/review/privacy-classification.json"),
                "state": .string(artifactSourceState(privacyLoad.status).rawValue),
                "validationStatus": .string(privacyLoad.status),
            ]),
            "rollbackManifest": .object([
                "source": .string("living_fabric/shadow/{rollback-manifest.json,models/}"),
                "state": .string(artifactSourceState(rollbackLoad.status).rawValue),
                "validationStatus": .string(rollbackLoad.status),
            ]),
        ])
        let out: JSONValue = .object([
            "schema": .string("living-fabric-evidence.v1"),
            "generatedAt": .string(formatter.string(from: evaluatedAt)),
            // The actual selected window is evidence too. It makes the 21-file
            // and 100k-event safety bounds visible to operators, and separates
            // malformed input from an honest no-recommendations finding.
            "traceWindow": .object([
                "schema": .string("living-fabric.trace-window.v1"),
                "inputStatus": .string(
                    traceSourceState == .sourceUnreadable ? "source unreadable"
                        : (traceURLs.isEmpty ? "no trace files found" : "trace files evaluated")
                ),
                "filesDiscovered": .int(Int64(traceURLs.count)),
                "filesScanned": .int(Int64(selectedTraceURLs.count)),
                "filesOmittedBy21DayWindow": .int(
                    Int64(max(0, traceURLs.count - selectedTraceURLs.count))
                ),
                "physicalRowsScanned": .int(Int64(physicalTraceRowsScanned)),
                "malformedJSONRows": .int(Int64(malformedJSONTraceRows)),
                "rejectedEventRows": .int(Int64(rejectedTraceEventRows)),
                "eventsRetained": .int(Int64(traceEvents.count)),
                "eventsDiscardedByGlobalCap": .int(Int64(globallyDiscardedTraceEventCount)),
                "filesTruncatedByByteWindow": .int(Int64(byteWindowTruncatedFileCount)),
                "perFileRowLimit": .int(Int64(perFileRowLimit)),
                "perFileByteLimit": .int(Int64(perFileByteLimit)),
                "globalEventLimit": .int(Int64(maximumTraceEvents)),
            ]),
            "evidenceSources": evidenceSourcesValue,
            "metacognition": .object([
                "shadowEvaluation": shadowValue,
                "outcomeCalibration": outcomeCalibration.traceValue,
            ]),
            "wave5": shadowValue,
            "wave6": readinessValue,
            "procedureCompilation": procedureValue,
        ])
        print((try? out.serialize(pretty: true)) ?? "\(out)")
    }

    /// Exact builder/operator cancellation for a named Workshop execution.
    /// It delegates to the canonical Workshop store owner and prints only the
    /// bounded lifecycle projection; no objective, plan arguments, or output
    /// payload crosses this proof seam.
    static func runWorkshopCancel(dataRootPath: String, executionID: String) async throws {
        let dataRoot = URL(fileURLWithPath: dataRootPath).standardizedFileURL
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: false,
            root: dataRoot,
            enableAutonomy: false
        )
        let record = try await runner.cancel(executionId: executionID)
        let action = try await runner.motorActionReadModel(actionId: executionID)
        let output: JSONValue = .object([
            "schema": .string("workshop.cancel.receipt.v1"),
            "executionIdentity": .string(CausalTransitionEvidence.opaqueIdentity(record.id)),
            "status": .string(record.status),
            "phase": action.map { .string($0.phase.rawValue) } ?? .null,
            "verification": action.map { .string($0.verification.rawValue) } ?? .null,
            "payloadFree": .bool(true),
        ])
        print((try? output.serialize(pretty: true)) ?? "\(output)")
    }

    static func integerMetricSummaryJSON(
        _ summary: MetacognitiveShadowEvaluation.IntegerMetricSummary
    ) -> JSONValue {
        .object([
            "count": .int(Int64(summary.count)),
            "minimum": summary.minimum.map { .int(Int64($0)) } ?? .null,
            "maximum": summary.maximum.map { .int(Int64($0)) } ?? .null,
            "mean": summary.mean.map(JSONValue.double) ?? .null,
        ])
    }

    static func computeLaneObservationJSON(
        _ turns: [MetacognitiveShadowEvaluation.Turn]
    ) -> JSONValue {
        .object(Dictionary(grouping: turns, by: \.recommendedComputeLane).mapValues { group in
            let correlated = group.filter(\.hasCorrelatedProviderOutcome)
            return .object([
                "recommendations": .int(Int64(group.count)),
                "correlatedTurns": .int(Int64(correlated.count)),
                "providerCalls": integerMetricSummaryJSON(.init(correlated.map(\.providerCallCount))),
                "turnLatencyMs": integerMetricSummaryJSON(.init(correlated.compactMap(\.turnElapsedMs))),
            ])
        })
    }

    static func contextLaneObservationJSON(
        _ turns: [MetacognitiveShadowEvaluation.Turn]
    ) -> JSONValue {
        .object(Dictionary(grouping: turns, by: \.recommendedContextLane).mapValues { group in
            let complete = group.filter(\.hasCompleteObservedMeasurements)
            return .object([
                "recommendations": .int(Int64(group.count)),
                "completeObservedMeasurements": .int(Int64(complete.count)),
                "packetCharacters": integerMetricSummaryJSON(.init(complete.compactMap(\.contextPacketCharacters))),
                "selectedAtoms": integerMetricSummaryJSON(.init(complete.compactMap(\.contextSelectedAtomCount))),
                "expansions": integerMetricSummaryJSON(.init(complete.map(\.contextExpansionCount))),
            ])
        })
    }

    static func toolLaneObservationJSON(
        _ turns: [MetacognitiveShadowEvaluation.Turn]
    ) -> JSONValue {
        .object(Dictionary(grouping: turns, by: \.recommendedToolLane).mapValues { group in
            let correlated = group.filter(\.hasCorrelatedProviderOutcome)
            let agreement = correlated.isEmpty
                ? nil
                : Double(correlated.filter(\.toolLaneMatchedObservedUse).count) / Double(correlated.count)
            return .object([
                "recommendations": .int(Int64(group.count)),
                "correlatedTurns": .int(Int64(correlated.count)),
                "useAgreement": agreement.map(JSONValue.double) ?? .null,
                "dispatches": integerMetricSummaryJSON(.init(correlated.map(\.toolDispatchCount))),
                "failedDispatches": integerMetricSummaryJSON(.init(correlated.map(\.failedToolDispatchCount))),
            ])
        })
    }

    static func parseLivingFabricDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func consolidationPlanJSON(_ plan: ConsolidationReport) -> JSONValue {
        .object([
            "processed": .int(Int64(plan.processed)),
            "autoAccepted": .int(Int64(plan.autoAccepted)),
            "duplicatesMerged": .int(Int64(plan.duplicatesMerged)),
            "pendingForReview": .int(Int64(plan.pendingForReview)),
            "staleArchived": .int(Int64(plan.staleArchived)),
            "errors": .array(plan.errors.map { .string($0) }),
        ])
    }

    static func describeSwapOutcome(_ outcome: MemoryConsolidationSwapOutcome) -> String {
        switch outcome {
        case .applied(let runId, let backupPath):
            return "applied run=\(runId) backup=\(backupPath)"
        case .alreadyApplied(let runId):
            return "already_applied run=\(runId)"
        case .staleRefused(let runId):
            return "stale_refused run=\(runId)"
        case .cleanedUpDenied(let runId):
            return "cleaned_up_denied run=\(runId)"
        case .pendingApproval(let runId):
            return "pending_approval run=\(runId)"
        case .failed(let runId, let reason):
            return "failed run=\(runId) reason=\(reason)"
        }
    }

    static func isStaleSwapOutcome(_ outcome: MemoryConsolidationSwapOutcome) -> Bool {
        if case .staleRefused = outcome { return true }
        return false
    }

    static func isAppliedSwapOutcome(_ outcome: MemoryConsolidationSwapOutcome) -> Bool {
        if case .applied = outcome { return true }
        if case .alreadyApplied = outcome { return true }
        return false
    }

    static func runExplicitKnowledgeGraphSweep(dataRoot: URL) async throws -> JSONValue {
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let memories = try await storage.listMemories(persona: nil, status: nil, limit: nil)
        let facts = memories.map { memory in
            KnowledgeGraphMemoryFact(
                id: memory.id,
                content: memory.content,
                source: memory.source,
                status: memory.status,
                createdAt: memory.createdAt,
                updatedAt: memory.updatedAt,
                metadata: memory.metadata
            )
        }
        let sqlitePath = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
        let report = try await indexer.collectGarbage(
            liveFacts: facts,
            apply: true,
            approvedOverThreshold: true
        )
        return .object([
            "applied": .bool(report.applied),
            "requiresApproval": .bool(report.requiresApproval),
            "candidates": .int(Int64(report.candidates.count)),
            "entitiesDeleted": .int(Int64(report.entitiesDeleted)),
            "edgesDeleted": .int(Int64(report.edgesDeleted)),
            "staleIndexRowsDeleted": .int(Int64(report.staleIndexRowsDeleted)),
            "legacyUntrackedEntities": .int(Int64(report.legacyUntrackedEntities)),
        ])
    }

    static func probeSetForEval(_ probeSet: MemoryProbeSet, queryMode: String) -> MemoryProbeSet {
        let mode = normalizedEvalQueryMode(queryMode)
        guard mode == "compact" else { return probeSet }
        return MemoryProbeSet(
            version: probeSet.version,
            topK: probeSet.topK,
            probes: probeSet.probes.map { probe in
                MemoryProbe(
                    id: probe.id,
                    question: compactMemoryEvalQuery(probe.question),
                    expectMemoryId: probe.expectMemoryId,
                    expectAnySubstring: probe.expectAnySubstring
                )
            }
        )
    }

    static func normalizedEvalQueryMode(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered == "compact" ? "compact" : "natural"
    }

    static func compactMemoryEvalQuery(_ question: String) -> String {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "can", "did", "do", "does",
            "for", "from", "how", "in", "is", "it", "kind", "of", "on", "or",
            "should", "the", "to", "want", "what", "when", "where", "which", "who",
            "why", "with"
        ]
        let tokens = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
        let compact = Array(tokens.prefix(12)).joined(separator: " ")
        return compact.isEmpty ? question : compact
    }
}
