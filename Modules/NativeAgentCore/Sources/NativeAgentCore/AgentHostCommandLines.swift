import CryptoKit
import Darwin
import Foundation
import os
import Security

// Blueprint: | `AgentHostCommandLines.swift` | `AgentHostCommandLines`: data-driven CLI launch/stream contracts, executable resolution and scrubbed environment; no host-specific adapter branches |

/// HOW A COMMAND-LINE AGENT TAKES A PROMPT AND PRINTS A REPLY — data, like
/// everything else on a known-agent row. One adapter reads this; nothing
/// branches on which agent it came from.
///
/// Flags come from the agent's published documentation. Argument substitution
/// is tested without launching personal agents. Where no resume contract is
/// implemented the entry
/// leaves `continuation` empty and every message is standalone, which is the
/// honest answer rather than a guess at somebody else's session store.
public struct AgentHostCommandLine: Sendable, Equatable, Codable {
    /// Placeholders the adapter substitutes, one argument at a time, so a
    /// message is never parsed as a flag or split by a shell.
    public static let messagePlaceholder = "{{message}}"
    public static let sessionPlaceholder = "{{session}}"
    public static let replyFilePlaceholder = "{{reply_file}}"
    /// What the conversation is called on the agent's side, where its CLI
    /// lets a session be named: "NativeAgent · <her name> · <label>".
    public static let sessionNamePlaceholder = "{{session_name}}"

    /// The executable name, resolved through the recipe and the login PATH.
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
    /// A complete JSON result envelope supplies the reply and session.
    public let jsonResultReply: Bool
    /// Envelope keys for reply, session, status and optional error flag;
    /// success is the status value that proves a reply.
    public let resultFields: [String: String]?
    /// Some headless hosts cannot ask for permission to call an MCP tool.
    /// Their command conversation is independent of that optional return path.
    public let automaticMCPProbe: Bool
    /// The CLI prints one JSON event per line while it answers; the
    /// adapter reads those as live progress. nil: its output is read at exit.
    public let stream: Stream?
    /// Which documented permission flags carry NativeAgent's launch decision
    /// (`DrivenAgentLaunchPermission`). nil: this CLI is not given one.
    public let permissionFlags: PermissionFlags?
    /// The wall-clock limit for one run.
    public let timeoutSeconds: Int
    /// The documentation these flags were checked against.
    public let documentation: String
    /// The oldest release that takes these flags (Claude Code's --name came
    /// in 2.1.76). nil: any release.
    public let minimumVersion: String?

    public var continuesConversations: Bool { !continuation.isEmpty }

    public init(executable: String, arguments: [String], continuation: [String] = [],
                replyFileName: String? = nil, capturesThreadID: Bool = false, jsonResultReply: Bool = false,
                resultFields: [String: String]? = nil,
                automaticMCPProbe: Bool = true, stream: Stream? = nil, permissionFlags: PermissionFlags? = nil,
                timeoutSeconds: Int, documentation: String, minimumVersion: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.continuation = continuation
        self.replyFileName = replyFileName
        self.capturesThreadID = capturesThreadID
        self.jsonResultReply = jsonResultReply
        self.resultFields = resultFields
        self.automaticMCPProbe = automaticMCPProbe
        self.stream = stream
        self.permissionFlags = permissionFlags
        self.timeoutSeconds = timeoutSeconds
        self.documentation = documentation
        self.minimumVersion = minimumVersion
    }

    /// Why a program that reported `reported` (its `--version` text) cannot
    /// run these flags: older than `minimumVersion`, or no version to read.
    /// Nil when it is new enough.
    public func versionFailure(program: String, reported: String?) -> String? {
        guard let minimumVersion else { return nil }
        guard let found = reported?.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map({ String(reported![$0]) }) else {
            return "\(program)'s version could not be read (\(program) --version), so whether it takes this recipe's flags (from \(minimumVersion)) is unknown. Update \(program), then Agents > Verify. Nothing was sent."
        }
        let have = found.split(separator: ".").compactMap { Int($0) }, need = minimumVersion.split(separator: ".").compactMap { Int($0) }
        guard have.lexicographicallyPrecedes(need) else { return nil }
        return "\(program) is \(found); this connection needs \(minimumVersion) or newer (\(documentation)). Update \(program), then Agents > Verify. Nothing was sent."
    }

    /// Only the protocol event supplies identity; prose/tool output cannot.
    /// Multiple different identities are ambiguous and must not be resumed.
    public func capturedThreadID(stdout: String, expected: String? = nil) -> String? {
        guard capturesThreadID else { return nil }
        if jsonResultReply {
            guard let fields = resultFields, let key = fields["session"],
                  let object = resultObject(stdout), let raw = object[key] as? String,
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

    public func resultReply(stdout: String) -> (reply: String?, failure: String?) {
        guard jsonResultReply, let fields = resultFields, let reply = fields["reply"],
              let status = fields["status"], let success = fields["success"],
              let object = resultObject(stdout) else { return (nil, nil) }
        let text = object[reply] as? String
        if object[status] as? String != success || fields["error"].map({ object[$0] as? Bool != false }) == true {
            let errors = fields["errors"].flatMap { object[$0] as? [String] } ?? []
            return (nil, ([object[status] as? String, text].compactMap { $0 } + errors).joined(separator: "\n"))
        }
        return (text, nil)
    }

    /// The whole-output envelope, or in stream form the one `result` event's.
    private func resultObject(_ stdout: String) -> [String: Any]? {
        guard let data = stdout.data(using: .utf8), data.count <= 16 * 1024 * 1024 else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if stream == .antigravity, object["event"] as? String == "result" {
                return object["result"] as? [String: Any]
            }
            return object
        }
        guard stream != nil else { return nil }
        let results = Self.events(stdout).filter { $0["event"] as? String == "result" }
        return results.count == 1 ? results[0]["result"] as? [String: Any] : nil
    }

    private static func events(_ stdout: String) -> [[String: Any]] {
        stdout.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    /// Stream shapes, by protocol rather than by agent.
    public enum Stream: String, Sendable, Equatable, Codable {
        /// `agy --output-format stream-json`: step_update text_delta, then one result.
        case antigravity
        /// `codex exec --json`: whole items as they complete.
        case codex
    }

    public enum PermissionFlags: String, Sendable, Equatable, Codable {
        /// `codex -c sandbox_mode=… -c approval_policy=…`.
        case codex
        case claude
    }

    /// One line of live output, for display only; the reply is still read at exit.
    public enum StreamEvent: Sendable, Equatable {
        /// `whole`: the complete message so far, replacing what was shown.
        case text(String, whole: Bool)
        case note(String)
        case activity
    }

    /// Retain only reply/identity evidence, so tool chatter cannot crowd out
    /// the closing result. Live text is consumed separately as it arrives.
    public func streamEvent(line: String) -> (retain: Bool, event: StreamEvent?) {
        guard let stream else { return (jsonResultReply, nil) }
        guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return (false, nil) }
        switch stream {
        case .antigravity:
            let retain = event["event"] as? String == "result"
            if event["event"] as? String == "step_update",
               let step = event["step_update"] as? [String: Any], step["step_type"] as? String == "agent_response",
               let text = step["text_delta"] as? String { return (retain, .text(text, whole: false)) }
            return (retain, .activity)
        case .codex:
            let retain = event["type"] as? String == "thread.started"
            guard let item = event["item"] as? [String: Any] else { return (retain, .activity) }
            if event["type"] as? String == "item.completed", item["type"] as? String == "agent_message",
               let text = item["text"] as? String { return (retain, .text(text, whole: true)) }
            if event["type"] as? String == "item.started", let command = item["command"] as? String { return (retain, .note(command)) }
            return (retain, .activity)
        }
    }

    /// One argv, with every placeholder replaced as a WHOLE argument. A first
    /// message opens the conversation; `resuming` continues one the caller
    /// already has an identity for.
    /// `sessionName` is read only when the template names the session.
    public func argv(message: String, session: String?, resuming: Bool, replyFilePath: String?,
                     sessionName: () -> String) -> [String] {
        let template = (resuming && continuesConversations) ? continuation : arguments
        let name = template.contains(Self.sessionNamePlaceholder) ? sessionName() : ""
        return template.map { argument in
            switch argument {
            case Self.messagePlaceholder: return message
            case Self.sessionPlaceholder: return session ?? ""
            case Self.replyFilePlaceholder: return replyFilePath ?? ""
            case Self.sessionNamePlaceholder: return name
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

/// What a host's recipe launches now, read through `AgentRecipeStore.launch`.
/// The Trust boundary prices a message by it but sits below the store's
/// module, so the engine installs that reader here at assembly; until then
/// no host launches anything, and the run itself is gated again at dispatch.
public enum AgentHostLaunches {
    public typealias Launch = (acp: AgentHostACP?, commandLine: AgentHostCommandLine?)
    private static let reader = OSAllocatedUnfairLock<(@Sendable (String) -> Launch)?>(initialState: nil)

    public static func install(_ read: @escaping @Sendable (String) -> Launch) { reader.withLock { $0 = read } }

    public static func launch(host: String) -> Launch { reader.withLock { $0 }?(host) ?? (nil, nil) }
}

/// The command-line half of the known-agent table, keyed by the row's id: the
/// recipes' seed (`AgentHostDirectory.seed`). What runs is the recipe.
public enum AgentHostCommandLines {
    public static let seed: [String: AgentHostCommandLine] = [
        "antigravity-cli": AgentHostCommandLine(
            executable: "agy",
            arguments: ["--mode", "plan", "--sandbox", "--disable-slash-commands", "--output-format", "stream-json",
                        "--print=" + AgentHostCommandLine.messagePlaceholder],
            continuation: ["--mode", "plan", "--sandbox", "--disable-slash-commands", "--output-format", "stream-json",
                           "--conversation", AgentHostCommandLine.sessionPlaceholder,
                           "--print=" + AgentHostCommandLine.messagePlaceholder],
            capturesThreadID: true, jsonResultReply: true,
            resultFields: ["reply": "response", "session": "conversation_id", "status": "status", "success": "SUCCESS"],
            automaticMCPProbe: false, stream: .antigravity, timeoutSeconds: 300,
            documentation: "https://www.antigravity.google/docs/cli/headless/"),
        "claude-code": AgentHostCommandLine(
            executable: "claude",
            arguments: ["-p", "--output-format", "json", "--name", AgentHostCommandLine.sessionNamePlaceholder,
                        "--", AgentHostCommandLine.messagePlaceholder],
            continuation: ["-p", "--output-format", "json", "--resume", AgentHostCommandLine.sessionPlaceholder,
                           "--", AgentHostCommandLine.messagePlaceholder],
            capturesThreadID: true, jsonResultReply: true,
            resultFields: ["reply": "result", "session": "session_id", "status": "subtype", "success": "success", "error": "is_error", "errors": "errors"],
            automaticMCPProbe: false, permissionFlags: .claude, timeoutSeconds: 300,
            documentation: "https://code.claude.com/docs/en/headless", minimumVersion: "2.1.76"),
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
            capturesThreadID: true, stream: .codex, permissionFlags: .codex,
            timeoutSeconds: 300,
            documentation: "https://learn.chatgpt.com/docs/non-interactive-mode"),
    ]

    /// Read once per app launch, with the same startup files as a login terminal.
    public static let loginEnvironment: Result<[String: String], ToolFailureError> = {
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? ""
        func refused(_ reason: String) -> Result<[String: String], ToolFailureError> {
            let files = shell.hasSuffix("/zsh") ? "~/.zshenv, ~/.zprofile, ~/.zshrc, ~/.zlogin" : "\(shell)'s login startup files"
            return .failure(ToolFailureError("Login shell \(shell): \(reason). Repair its startup files, then restart the app to read PATH again.",
                effects: .none, owner: "login shell \(shell) startup files",
                tap: "Repair \(files); the app reads PATH again at its next launch", personDecides: true))
        }
        guard shell.hasPrefix("/"), access(shell, X_OK) == 0 else { return refused("the account's shell is not executable") }
        let process = Process(), output = Pipe(), exited = DispatchSemaphore(value: 0)
        let bytes = OSAllocatedUnfairLock(initialState: Data())
        process.executableURL = URL(fileURLWithPath: shell)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.arguments = ["-ilc", "printf '\\0%s\\0' \"$PATH\""]
        process.environment = baseEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do {
            let drain = try ProcessPipeDrain(handle: output.fileHandleForReading) { chunk in
                bytes.withLock { if $0.count < 1024 * 1024 { $0.append(chunk) } }
            }
            defer { drain.stopAndWait() }
            try process.run()
            try? output.fileHandleForWriting.close()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                ProcessTreeReaper.quiesceAndKill(ProcessTreeReaper.snapshot(rootPID: process.processIdentifier))
                return refused("PATH did not return within three seconds")
            }
            drain.stopAndWait()
            let fields = bytes.withLock { $0.split(separator: 0, omittingEmptySubsequences: false) }
            guard process.terminationStatus == 0, fields.count >= 3,
                  let path = String(data: Data(fields[1]), encoding: .utf8), !path.isEmpty else { return refused("no readable PATH returned") }
            var environment = baseEnvironment()
            environment["PATH"] = path
            return .success(environment)
        } catch { return refused(error.localizedDescription) }
    }()

    public static func resolveExecutable(_ name: String) -> String? {
        resolveExecutable(name, directories: [],
                          home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// A command as the file that runs: an absolute path, or a name on the
    /// login PATH, with its links resolved; nil when no executable file.
    public static func resolveCommand(_ command: String) -> String? {
        guard command.hasPrefix("/") else { return resolveExecutable(command) }
        let path = URL(fileURLWithPath: command).resolvingSymlinksInPath().path
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0 ? path : nil
    }

    /// What an executable file is: its code directory hash when signed, else
    /// the SHA-256 of its bytes. A program that changes has another identity.
    public static func identity(ofExecutable path: String) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
           SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
           let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            return "cdhash:" + unique.map { String(format: "%02x", $0) }.joined()
        }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func resolveExecutable(_ name: String, directories: [String], home: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        guard case .success(let environment) = loginEnvironment else { return nil }
        for directory in directories + (environment["PATH"] ?? "").components(separatedBy: ":") {
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
        switch loginEnvironment {
        case .success(let environment): return environment
        case .failure: return baseEnvironment()
        }
    }

    private static func baseEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var scrubbed: [String: String] = [:]
        for name in ["PATH", "HOME", "USER", "LANG", "TMPDIR", "TERM"] {
            if let value = source[name] { scrubbed[name] = value }
        }
        for (name, value) in source where name.hasPrefix("LC_") { scrubbed[name] = value }
        return scrubbed
    }
}
