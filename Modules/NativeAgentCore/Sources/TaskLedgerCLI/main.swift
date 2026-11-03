import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk

// Blueprint: | `main.swift` | `TaskLedgerCLI`: explicit ledger append/claim/list commands, one strict option parser before ledger access and shared or explicitly overridden data-root resolution |

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
        if rawArgs == ["--help"] || rawArgs == ["-h"] { usage(); return 0 }
        let parsed: ParsedOptions
        do { parsed = try parseOptions(rawArgs) }
        catch { fputs("error: \(error.localizedDescription)\n", stderr); return 64 }
        guard let command = parsed.positionals.first else {
            usage()
            return 64
        }
        guard parsed.positionals.count == 1 else {
            fputs("error: unexpected positional argument '\(parsed.positionals[1])'\n", stderr)
            return 64
        }
        let allowed: Set<String>
        switch command {
        case "append": allowed = ["data-root", "actor", "kind", "task-id", "title", "note", "ref"]
        case "claim": allowed = ["data-root", "actor", "task-id", "title", "note", "ref", "force"]
        case "list": allowed = ["data-root", "task-id", "include-done", "pretty"]
        case "help": usage(); return 0
        default:
            fputs("error: unknown command '\(command)'\n", stderr)
            usage()
            return 64
        }
        let supplied = Set(parsed.options.keys).union(parsed.repeated.keys).union(parsed.flags)
        guard supplied.isSubset(of: allowed) else {
            fputs("error: \(command) does not accept \(supplied.subtracting(allowed).sorted().map { "--" + $0 }.joined(separator: ", "))\n", stderr)
            return 64
        }
        if let root = parsed.options["data-root"], root.isEmpty {
            fputs("error: --data-root requires a non-empty path\n", stderr)
            return 64
        }
        let dataRoot = resolveDataRoot(parsed.options["data-root"])
        switch command {
        case "append", "claim":
            return try await write(parsed, dataRoot: dataRoot, command: command)
        case "list":
            return try await list(parsed, dataRoot: dataRoot)
        default: preconditionFailure("Command validated above")
        }
    }

    static func write(_ parsed: ParsedOptions, dataRoot: URL, command: String) async throws -> Int {
        let claiming = command == "claim"
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

    static func list(_ parsed: ParsedOptions, dataRoot: URL) async throws -> Int {
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

    struct OptionError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct ParsedOptions {
        var options: [String: String] = [:]
        var repeated: [String: [String]] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
    }

    static func parseOptions(_ args: [String]) throws -> ParsedOptions {
        let single: Set<String> = ["data-root", "actor", "kind", "task-id", "title", "note"]
        let repeated: Set<String> = ["ref"]
        let flags: Set<String> = ["force", "include-done", "pretty"]
        var parsed = ParsedOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else {
                parsed.positionals.append(arg)
                i += 1
                continue
            }
            let pieces = arg.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces[0])
            if flags.contains(key) {
                guard pieces.count == 1 else { throw OptionError(message: "--\(key) does not take a value") }
                parsed.flags.insert(key)
                i += 1
            } else {
                guard single.contains(key) || repeated.contains(key) else {
                    throw OptionError(message: "unknown option --\(key)")
                }
                let value: String
                if pieces.count == 2 {
                    value = String(pieces[1])
                    i += 1
                } else {
                    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                        throw OptionError(message: "--\(key) requires a value; for literal text beginning with -- use --\(key)='--text'")
                    }
                    value = args[i + 1]
                    i += 2
                }
                if repeated.contains(key) { parsed.repeated[key, default: []].append(value) }
                else {
                    guard parsed.options[key] == nil else { throw OptionError(message: "--\(key) may be supplied only once") }
                    parsed.options[key] = value
                }
            }
        }
        return parsed
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
        option values beginning with -- require equals, e.g. --note='--literal text'
        default data root: $NATIVE_AGENT_DATA_ROOT or NativeAgent's application data root
        """, stderr)
    }
}
