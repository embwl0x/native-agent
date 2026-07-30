import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore

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
        case "append":
            return try await append(commandArgs, dataRoot: dataRoot)
        case "claim":
            return try await claim(commandArgs, dataRoot: dataRoot)
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

    static func append(_ args: [String], dataRoot: URL) async throws -> Int {
        let parsed = parseOptions(
            args,
            single: ["actor", "kind", "task-id", "title", "note"],
            repeated: ["ref"]
        )
        guard parsed.positionals.isEmpty else {
            fputs("error: append received unexpected positional argument '\(parsed.positionals[0])'\n", stderr)
            return 64
        }
        guard let actor = actor(parsed.options["actor"]) else {
            fputs("error: append requires --actor claude|assistant|codex|user\n", stderr)
            return 64
        }
        let kindRaw = parsed.options["kind"] ?? "created"
        guard let kind = TaskLedgerKind(rawValue: kindRaw) else {
            fputs("error: unknown kind '\(kindRaw)' (expected one of \(kindList()))\n", stderr)
            return 64
        }
        let taskId: String
        if let explicit = parsed.options["task-id"], !explicit.isEmpty {
            taskId = explicit
        } else if kind == .created {
            taskId = UUID().uuidString
        } else {
            fputs("error: --task-id is required for kind '\(kind.rawValue)' (only 'created' may omit it)\n", stderr)
            return 64
        }
        let event = makeEvent(
            actor: actor,
            kind: kind,
            taskId: taskId,
            title: parsed.options["title"],
            note: parsed.options["note"],
            refs: parsed.repeated["ref"] ?? []
        )
        let written = try await SwiftNativeTaskLedger(dataRoot: dataRoot).append(event)
        printJSON(.object([
            "status": .string("ok"),
            "event": written.toJSON(),
            "task_id": .string(taskId),
        ]))
        return 0
    }

    static func claim(_ args: [String], dataRoot: URL) async throws -> Int {
        let parsed = parseOptions(
            args,
            single: ["actor", "task-id", "title", "note"],
            repeated: ["ref"],
            flags: ["force"]
        )
        guard parsed.positionals.isEmpty else {
            fputs("error: claim received unexpected positional argument '\(parsed.positionals[0])'\n", stderr)
            return 64
        }
        guard let actor = actor(parsed.options["actor"]) else {
            fputs("error: claim requires --actor claude|assistant|codex|user\n", stderr)
            return 64
        }
        guard let taskId = parsed.options["task-id"], !taskId.isEmpty else {
            fputs("error: claim requires --task-id\n", stderr)
            return 64
        }
        let event = makeEvent(
            actor: actor,
            kind: .claimed,
            taskId: taskId,
            title: parsed.options["title"],
            note: parsed.options["note"],
            refs: parsed.repeated["ref"] ?? []
        )
        let written = try await SwiftNativeTaskLedger(dataRoot: dataRoot)
            .claim(event, force: parsed.flags.contains("force"))
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
            let events = try await ledger.readEventsUnlocked().filter { $0.taskId == taskId }
            guard !events.isEmpty else {
                printJSON(.object([
                    "status": .string("not_found"),
                    "task_id": .string(taskId),
                ]), pretty: pretty)
                return 0
            }
            let state = SwiftNativeTaskLedger.compact(events).first?.toJSON() ?? .null
            printJSON(.object([
                "status": .string("ok"),
                "task": state,
                "events": .array(events.map { $0.toJSON() }),
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

    static func makeEvent(
        actor: TaskLedgerActor,
        kind: TaskLedgerKind,
        taskId: String,
        title: String?,
        note: String?,
        refs: [String]
    ) -> TaskLedgerEvent {
        TaskLedgerEvent(
            taskId: taskId,
            actor: actor,
            kind: kind,
            title: emptyToNil(title),
            note: emptyToNil(note),
            refs: refs.filter { !$0.isEmpty }
        )
    }

    static func actor(_ raw: String?) -> TaskLedgerActor? {
        guard let raw else { return nil }
        return TaskLedgerActor(rawValue: raw)
    }

    static func kindList() -> String {
        TaskLedgerKind.allCases.map(\.rawValue).joined(separator: "/")
    }

    static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Precedence: explicit `--data-root` > `NATIVE_AGENT_DATA_ROOT` env > a
    /// cwd-relative `./data` LAST-RESORT. The retired Python `task_ledger.py`
    /// anchored its default to the REPO (`__file__.parent.parent / data`), not
    /// the cwd — so the canonical invocation `script/task_ledger.sh` exports
    /// `NATIVE_AGENT_DATA_ROOT=<repo>/data` to preserve that. Do NOT rely on the
    /// cwd fallback as the repo default: a non-repo cwd would split the
    /// cross-agent ledger onto a stray `<cwd>/data` + a different flock sidecar.
    static func resolveDataRoot(_ explicit: String?) -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: expandTilde(explicit), isDirectory: true)
        }
        if let env = ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
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
        default data root: $NATIVE_AGENT_DATA_ROOT or ./data
        """, stderr)
    }
}
