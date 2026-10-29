import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk

// Blueprint: | `main.swift` | `TaskLedgerCLI`: explicit ledger append/claim/list commands, option parsing and shared or explicitly overridden data-root resolution |

@main
struct TaskLedgerCLI {
    static func main() async {
        do {
            let code = try await run(Array(CommandLine.arguments.dropFirst()))
            exit(Int32(code))
        } catch let conflict as TaskLedgerClaimConflict {
            printJSON(.object([
                "status": .string("conflict"),
                "error": .string(conflict.localizedDescription),
            ]))
            exit(3)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ rawArgs: [String]) async throws -> Int {
        var args = rawArgs
        let dataRoot = resolveDataRoot(extractOption("--data-root", from: &args))
        guard let command = args.first else {
            usage()
            return 64
        }
        let commandArgs = Array(args.dropFirst())
        switch command {
        case "append", "claim":
            return try await write(commandArgs, dataRoot: dataRoot, command: command)
        case "list":
            return try await list(commandArgs, dataRoot: dataRoot)
        case "help", "--help", "-h":
            usage()
            return 0
        default:
            fputs("error: unknown command '\(command)'\n", stderr)
            usage()
            return 64
        }
    }

    static func write(_ args: [String], dataRoot: URL, command: String) async throws -> Int {
        let claiming = command == "claim"
        let parsed = parseOptions(
            args,
            single: claiming ? ["actor", "task-id", "title", "note"] : ["actor", "kind", "task-id", "title", "note"],
            repeated: ["ref"],
            flags: claiming ? ["force"] : []
        )
        guard parsed.positionals.isEmpty else {
            fputs("error: \(command) received unexpected positional argument '\(parsed.positionals[0])'\n", stderr)
            return 64
        }
        let kindRaw = claiming ? "claimed" : parsed.options["kind"] ?? "created"
        guard let kind = TaskLedgerKind(rawValue: kindRaw) else {
            fputs("error: unknown kind '\(kindRaw)' (expected one of \(kindList()))\n", stderr)
            return 64
        }
        guard kind != .deleted else {
            fputs("error: deleted requires task_ledger_post with expected_title\n", stderr)
            return 64
        }
        guard let actor = actor(parsed.options["actor"]) else {
            fputs("error: \(command) requires --actor claude|assistant|codex|user\n", stderr)
            return 64
        }
        let taskId: String
        if let explicit = parsed.options["task-id"], !explicit.isEmpty {
            taskId = explicit
        } else if kind == .created {
            taskId = UUID().uuidString
        } else {
            fputs(claiming ? "error: claim requires --task-id\n" : "error: --task-id is required for kind '\(kind.rawValue)' (only 'created' may omit it)\n", stderr)
            return 64
        }
        let event = TaskLedgerEvent(
            taskId: taskId,
            actor: actor,
            kind: kind,
            title: emptyToNil(parsed.options["title"]),
            note: emptyToNil(parsed.options["note"]),
            refs: (parsed.repeated["ref"] ?? []).filter { !$0.isEmpty }
        )
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        let written = kind == .claimed
            ? try await ledger.claim(event, force: parsed.flags.contains("force"))
            : try await ledger.append(event)
        printJSON(.object([
            "status": .string("ok"),
            "event": written.toJSON(),
            "task_id": .string(taskId),
        ]))
        return 0
    }

    static func list(_ args: [String], dataRoot: URL) async throws -> Int {
        let parsed = parseOptions(
            args,
            single: ["task-id"],
            flags: ["include-done", "pretty"]
        )
        guard parsed.positionals.isEmpty else {
            fputs("error: list received unexpected positional argument '\(parsed.positionals[0])'\n", stderr)
            return 64
        }
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        let pretty = parsed.flags.contains("pretty")
        if let taskId = parsed.options["task-id"], !taskId.isEmpty {
            let snapshot = try await ledger.taskDetail(id: taskId)
            guard let task = snapshot.state else {
                printJSON(.object([
                    "status": .string("not_found"),
                    "task_id": .string(taskId),
                ]), pretty: pretty)
                return 0
            }
            printJSON(.object([
                "status": .string("ok"),
                "task": task.toJSON(),
                "events": .array(snapshot.events.map { $0.toJSON() }),
            ]), pretty: pretty)
            return 0
        }

        var states = try await ledger.listTasks(includeTerminal: parsed.flags.contains("include-done"))
        states.sort { $0.updatedTs > $1.updatedTs }
        printJSON(.object([
            "status": .string("ok"),
            "tasks": .array(states.map { $0.toJSON() }),
        ]), pretty: pretty)
        return 0
    }

    static func actor(_ raw: String?) -> TaskLedgerActor? {
        guard let raw else { return nil }
        return TaskLedgerActor(wire: raw)
    }

    static func kindList() -> String {
        TaskLedgerKind.allCases.filter { $0 != .deleted }.map(\.rawValue).joined(separator: "/")
    }

    static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Explicit `--data-root` overrides the app's shared process-root resolver.
    static func resolveDataRoot(_ explicit: String?) -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
        }
        return PersistenceCore.defaultDataRoot()
    }

    static func extractOption(_ name: String, from args: inout [String]) -> String? {
        var out: String?
        var kept: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == name, i + 1 < args.count {
                out = args[i + 1]
                i += 2
            } else {
                kept.append(args[i])
                i += 1
            }
        }
        args = kept
        return out
    }

    static func parseOptions(
        _ args: [String],
        single: Set<String> = [],
        repeated: Set<String> = [],
        flags: Set<String> = []
    ) -> (options: [String: String], repeated: [String: [String]], flags: Set<String>, positionals: [String]) {
        var options: [String: String] = [:]
        var repeatedValues: [String: [String]] = [:]
        var flagValues: Set<String> = []
        var positionals: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else {
                positionals.append(arg)
                i += 1
                continue
            }
            let key = String(arg.dropFirst(2))
            if flags.contains(key) {
                flagValues.insert(key)
                i += 1
            } else if single.contains(key), i + 1 < args.count {
                options[key] = args[i + 1]
                i += 2
            } else if repeated.contains(key), i + 1 < args.count {
                repeatedValues[key, default: []].append(args[i + 1])
                i += 2
            } else {
                positionals.append(arg)
                i += 1
            }
        }
        return (options, repeatedValues, flagValues, positionals)
    }

    static func printJSON(_ value: JSONValue, pretty: Bool = false) {
        do {
            print(try value.serialize(pretty: pretty))
        } catch {
            fputs("error: failed to serialize JSON output: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func usage() {
        fputs("""
        usage: task-ledger [--data-root <path>] <command> ...

        commands:
          append --actor <actor> [--kind <kind>] [--task-id <id>] [--title <title>] [--note <note>] [--ref <ref>...]
          claim  --actor <actor> --task-id <id> [--title <title>] [--note <note>] [--ref <ref>...] [--force]
          list   [--task-id <id>] [--include-done] [--pretty]

        actors: claude, assistant, codex, user
        kinds:  created, claimed, update, blocked, done, cancelled
        default data root: $NATIVE_AGENT_DATA_ROOT or NativeAgent's application data root
        """, stderr)
    }
}
