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
//   `chat-drive doctor [--repair true|false]` — run Swift Doctor checks.
//     FIX-5b (2026-09-01): `--check-llm` is GONE. It was documented here and
//     threaded all the way into `runAll`, which has never read it — this
//     Doctor makes no provider call by design, so the flag promised a probe
//     that does not exist. Passing it now fails loudly instead of lying.
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

try await ChatDriveMain.main()

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

    @MainActor
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
            let parsed = parseOptions(Array(args.dropFirst()), allowedOptions: ["repair"])
            try await runDoctor(repair: boolOption(parsed.options["repair"], defaultValue: false))

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
}
