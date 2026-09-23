import Darwin
import Foundation

/// HOW A COMMAND-LINE AGENT TAKES A PROMPT AND PRINTS A REPLY — data, like
/// everything else on a known-agent row. One adapter reads this; nothing
/// branches on which agent it came from.
///
/// Flags come from the agent's published documentation. Argument substitution
/// is tested without launching personal agents. Where no resume contract is
/// implemented the entry
/// leaves `continuation` empty and every message is standalone, which is the
/// honest answer rather than a guess at somebody else's session store.
public struct AgentHostCommandLine: Sendable, Equatable {
    /// Placeholders the adapter substitutes, one argument at a time, so a
    /// message is never parsed as a flag or split by a shell.
    public static let messagePlaceholder = "{{message}}"
    public static let sessionPlaceholder = "{{session}}"
    public static let replyFilePlaceholder = "{{reply_file}}"

    /// The executable NAME. Resolved in fixed installation directories, never a path stored
    /// in a row.
    public let executable: String
    /// The argv for a first message, in its non-interactive/print mode. It ends
    /// with the CLI's documented end-of-options marker before the message, so
    /// text beginning with a dash stays text.
    public let arguments: [String]
    /// The argv for a later message in the SAME conversation, or empty when
    /// the CLI documents no resume flag.
    public let continuation: [String]
    /// When the CLI documents writing its final message to a file, the name of
    /// that file inside the run's own working directory. Otherwise stdout is
    /// the reply.
    public let replyFileName: String?
    /// The CLI, rather than this app, assigns the session in protocol output.
    /// Never substitute a locally invented identity.
    public let capturesThreadID: Bool
    /// A complete JSON result envelope supplies response and conversation_id.
    public let jsonResultReply: Bool
    /// Some headless hosts cannot ask for permission to call an MCP tool.
    /// Their command conversation is independent of that optional return path.
    public let automaticMCPProbe: Bool
    /// The wall-clock limit for one run.
    public let timeoutSeconds: Int
    /// The documentation these flags were checked against.
    public let documentation: String

    public var continuesConversations: Bool { !continuation.isEmpty }

    public init(executable: String, arguments: [String], continuation: [String] = [],
                replyFileName: String? = nil, capturesThreadID: Bool = false, jsonResultReply: Bool = false,
                automaticMCPProbe: Bool = true,
                timeoutSeconds: Int, documentation: String) {
        self.executable = executable
        self.arguments = arguments
        self.continuation = continuation
        self.replyFileName = replyFileName
        self.capturesThreadID = capturesThreadID
        self.jsonResultReply = jsonResultReply
        self.automaticMCPProbe = automaticMCPProbe
        self.timeoutSeconds = timeoutSeconds
        self.documentation = documentation
    }

    /// Only the protocol event supplies identity; prose/tool output cannot.
    /// Multiple different identities are ambiguous and must not be resumed.
    public func capturedThreadID(stdout: String, expected: String? = nil) -> String? {
        guard capturesThreadID else { return nil }
        if jsonResultReply {
            guard let object = resultObject(stdout), let raw = object["conversation_id"] as? String,
                  let uuid = UUID(uuidString: raw) else { return nil }
            let value = uuid.uuidString.lowercased()
            guard expected == nil || value == expected?.lowercased() else { return nil }
            return value
        }
        var found: String?
        for line in stdout.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "thread.started" else { continue }
            guard let raw = event["thread_id"] as? String,
                  let uuid = UUID(uuidString: raw) else { return nil }
            let value = uuid.uuidString.lowercased()
            if let found, found != value { return nil }
            if let expected, value != expected.lowercased() { return nil }
            found = value
        }
        return found
    }

    public func resultReply(stdout: String) -> String? {
        guard jsonResultReply, let object = resultObject(stdout),
              object["status"] as? String == "SUCCESS" else { return nil }
        return object["response"] as? String
    }

    private func resultObject(_ stdout: String) -> [String: Any]? {
        guard let data = stdout.data(using: .utf8), data.count <= 16 * 1024 * 1024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One argv, with every placeholder replaced as a WHOLE argument. A first
    /// message opens the conversation; `resuming` continues one the caller
    /// already has an identity for.
    public func argv(message: String, session: String?, resuming: Bool, replyFilePath: String?) -> [String] {
        let template = (resuming && continuesConversations) ? continuation : arguments
        return template.map { argument in
            switch argument {
            case Self.messagePlaceholder: return message
            case Self.sessionPlaceholder: return session ?? ""
            case Self.replyFilePlaceholder: return replyFilePath ?? ""
            default:
                // Bind option values in the same argv element, so a message
                // beginning with '-' can never become an option.
                if argument.hasSuffix("=" + Self.messagePlaceholder) {
                    return String(argument.dropLast(Self.messagePlaceholder.count)) + message
                }
                return argument
            }
        }
    }
}

/// The command-line half of the known-agent table, keyed by the row's id. It
/// lives here, below the chat module, because the Trust boundary has to price a
/// message to such a contact as what it is — running a command — and there must
/// be ONE table to read rather than a second copy of the same facts.
public enum AgentHostCommandLines {
    public static let byHostID: [String: AgentHostCommandLine] = [
        "antigravity-cli": AgentHostCommandLine(
            executable: "agy",
            arguments: ["--mode", "plan", "--sandbox", "--disable-slash-commands", "--output-format", "json",
                        "--print=" + AgentHostCommandLine.messagePlaceholder],
            continuation: ["--mode", "plan", "--sandbox", "--disable-slash-commands", "--output-format", "json",
                           "--conversation", AgentHostCommandLine.sessionPlaceholder,
                           "--print=" + AgentHostCommandLine.messagePlaceholder],
            capturesThreadID: true, jsonResultReply: true, automaticMCPProbe: false, timeoutSeconds: 300,
            documentation: "https://www.antigravity.google/docs/cli/headless/"),
        // Verified on this Mac: `claude -p --session-id <uuid> -- "<text>"`
        // printed the reply on stdout, `claude -p --resume <uuid>` answered
        // from the same conversation, and a message beginning with `--` stayed
        // the prompt rather than becoming a flag.
        "claude-code": AgentHostCommandLine(
            executable: "claude",
            arguments: ["-p", "--session-id", AgentHostCommandLine.sessionPlaceholder,
                        "--", AgentHostCommandLine.messagePlaceholder],
            continuation: ["-p", "--resume", AgentHostCommandLine.sessionPlaceholder,
                           "--", AgentHostCommandLine.messagePlaceholder],
            timeoutSeconds: 300,
            documentation: "https://code.claude.com/docs/en/cli-reference"),
        // JSONL thread.started carries the CLI-minted identity. Resume uses
        // that exact UUID, never --last or a guessed private rollout path.
        "codex": AgentHostCommandLine(
            executable: "codex",
            arguments: ["exec", "--json", "--skip-git-repo-check", "-o", AgentHostCommandLine.replyFilePlaceholder,
                        "--", AgentHostCommandLine.messagePlaceholder],
            continuation: ["exec", "resume", "--json", "--skip-git-repo-check",
                           "-o", AgentHostCommandLine.replyFilePlaceholder,
                           "--", AgentHostCommandLine.sessionPlaceholder, AgentHostCommandLine.messagePlaceholder],
            replyFileName: "reply.txt",
            capturesThreadID: true,
            timeoutSeconds: 300,
            documentation: "https://learn.chatgpt.com/docs/non-interactive-mode"),
    ]

    /// Fixed, ordered installation locations. Discovery never reads shell PATH or runs code.
    // The person's own install folders first, as in a normal shell path: on the 09-19 drive the
    // Homebrew copy of Codex (0.131, from May) won over the one in ~/.local/bin the person uses.
    public static let searchPaths = ["~/.local/bin", "~/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "~/.npm-global/bin", "~/.npm/bin", "~/Library/pnpm", "~/.local/share/pnpm",
        "~/.bun/bin", "~/.local/share/mise/shims", "~/.asdf/shims", "~/.lmstudio/bin"]

    public static func resolveExecutable(_ name: String) -> String? {
        resolveExecutable(name, directories: searchPaths,
                          home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func resolveExecutable(_ name: String, directories: [String], home: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in directories {
            let expanded = directory.hasPrefix("~/") ? home + String(directory.dropFirst()) : directory
            guard expanded.hasPrefix("/") else { continue }
            // Standalone installations use links, sometimes through another
            // linked version directory. Inspect the resolved file consistently.
            let candidate = URL(fileURLWithPath: expanded + "/" + name).resolvingSymlinksInPath().path
            var info = stat()
            if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               access(candidate, X_OK) == 0 { return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path }
        }
        return nil
    }

    /// THE ENVIRONMENT ANOTHER AGENT'S COMMAND GETS, and nothing else.
    ///
    /// This app's own environment carries provider keys and the bridge token.
    /// Handing that to an external program would give it, silently, everything
    /// this app can reach — so the run starts from a scrubbed set instead: the
    /// few variables a command needs to find itself, its user and its locale,
    /// and no others. Each of the two rows above was run under exactly this set
    /// and answered normally; a variable is added here only when a verified CLI
    /// provably needs it.
    public static func scrubbedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var scrubbed: [String: String] = [:]
        for name in ["PATH", "HOME", "USER", "LANG", "TMPDIR", "TERM"] {
            if let value = source[name] { scrubbed[name] = value }
        }
        for (name, value) in source where name.hasPrefix("LC_") { scrubbed[name] = value }
        // PATH is how the executable was found in the first place, so it must
        // not be empty even when this app inherited none.
        if scrubbed["PATH"]?.isEmpty ?? true { scrubbed["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return scrubbed
    }
}
