import CryptoKit
import Darwin
import Foundation
import os
import Security

// Blueprint: | `AgentHostCommandLines.swift` | `AgentHostCommandLines`: CLI contracts and scrubbed launches |

/// One data-driven adapter reads documented CLI contracts without host-specific branches. Without a resume contract, messages remain standalone rather than
/// guessing a session identity.
public struct AgentHostCommandLine: Sendable, Equatable, Codable {
    /// Placeholders the adapter substitutes, one argument at a time, so a message is never parsed as a flag or split by a shell.
    public static let messagePlaceholder = "{{message}}"
    public static let sessionPlaceholder = "{{session}}"
    public static let replyFilePlaceholder = "{{reply_file}}"
    public static let sessionNamePlaceholder = "{{session_name}}"

    public let executable: String
    /// The argv for a first message, in its non-interactive/print mode. It ends with the CLI's documented end-of-options marker before the message, so text
    /// beginning with a dash stays text.
    public let arguments: [String]
    /// The argv for a later message in the SAME conversation, or empty when the CLI documents no resume flag.
    public let continuation: [String]
    /// When the CLI documents writing its final message to a file, the name of that file inside the run's own working directory. Otherwise stdout is the reply.
    public let replyFileName: String?
    /// The CLI, rather than this app, assigns the session in protocol output. Never substitute a locally invented identity.
    public let capturesThreadID: Bool
    public let jsonResultReply: Bool
    /// Envelope keys for reply, session, status and optional error flag; success is the status value that proves a reply.
    public let resultFields: [String: String]?
    /// Some headless hosts cannot ask for permission to call an MCP tool. Their command conversation is independent of that optional return path.
    public let automaticMCPProbe: Bool
    /// The CLI prints one JSON event per line while it answers; the adapter reads those as live progress. nil: its output is read at exit.
    public let stream: Stream?
    /// Which documented permission flags carry NativeAgent's launch decision (`DrivenAgentLaunchPermission`). nil: this CLI is not given one.
    public let permissionFlags: PermissionFlags?
    public let timeoutSeconds: Int
    public let documentation: String
    /// Require the release that supports these flags; Claude Code's --name requires 2.1.76. Nil imposes no version floor.
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

    /// Refuse incompatible or unreadable versions before passing flags the installed CLI may not understand.
    public func versionFailure(program: String, reported: String?) -> String? {
        guard let minimumVersion else { return nil }
        guard let found = reported?.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map({ String(reported![$0]) }) else {
            return """
                \(program)'s version could not be read (\(program) --version), so whether it takes this recipe's flags (from \(minimumVersion)) is unknown. \
                Update \(program), then Agents > Verify. Nothing was sent.
                """
        }
        let have = found.split(separator: ".").compactMap { Int($0) }, need = minimumVersion.split(separator: ".").compactMap { Int($0) }
        guard have.lexicographicallyPrecedes(need) else { return nil }
        return """
            \(program) is \(found); this connection needs \(minimumVersion) or newer (\(documentation)). Update \(program), then Agents > Verify. Nothing was \
            sent.
            """
    }

    /// Read reply and identity together; only protocol evidence confirms identity, independently of reply success. Conflicting identities cannot be resumed.
    public func interpretOutput(stdout: String, expected: String? = nil) -> (reply: String?, failure: String?, threadID: String?) {
        if jsonResultReply {
            guard let fields = resultFields, let object = resultObject(stdout) else { return (nil, nil, nil) }
            let identity = capturesThreadID ? fields["session"].flatMap { object[$0] as? String }
                .flatMap { UUID(uuidString: $0) }?.uuidString.lowercased() : nil
            let confirmed = expected == nil || identity == expected?.lowercased() ? identity : nil
            guard let reply = fields["reply"], let status = fields["status"],
                  let success = fields["success"] else { return (nil, nil, confirmed) }
            let text = object[reply] as? String
            if object[status] as? String != success || fields["error"].map({ object[$0] as? Bool != false }) == true {
                let errors = fields["errors"].flatMap { object[$0] as? [String] } ?? []
                return (nil, ([object[status] as? String, text].compactMap { $0 } + errors).joined(separator: "\n"), confirmed)
            }
            return (text, nil, confirmed)
        }
        guard capturesThreadID else { return (nil, nil, nil) }
        var found: String?
        for line in stdout.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "thread.started" else { continue }
            guard let raw = event["thread_id"] as? String,
                  let uuid = UUID(uuidString: raw) else { return (nil, nil, nil) }
            let value = uuid.uuidString.lowercased()
            if let found, found != value { return (nil, nil, nil) }
            if let expected, value != expected.lowercased() { return (nil, nil, nil) }
            found = value
        }
        return (nil, nil, found)
    }

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

    public enum Stream: String, Sendable, Equatable, Codable, CaseIterable {
        case antigravity
        case codex
    }

    public enum PermissionFlags: String, Sendable, Equatable, Codable, CaseIterable {
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

    /// Retain only reply/identity evidence, so tool chatter cannot crowd out the closing result. Live text is consumed separately as it arrives.
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

    /// Replace each placeholder as one whole argument so message text cannot become shell syntax; resume only an observed conversation identity.
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
                // Bind option values in the same argv element, so a message beginning with '-' can never become an option.
                if argument.hasSuffix("=" + Self.messagePlaceholder) {
                    return String(argument.dropLast(Self.messagePlaceholder.count)) + message
                }
                return argument
            }
        }
    }
}

/// The contact owner's checked message-effect projection. Trust sits below that owner, so assembly installs its reader; absence reports unavailable.
public enum AgentHostLaunches {
    public typealias Launch = (acp: AgentHostACP?, commandLine: AgentHostCommandLine?)
    private static let reader = OSAllocatedUnfairLock<(@Sendable (String, URL) throws -> Bool)?>(initialState: nil)

    public static func install(_ read: @escaping @Sendable (String, URL) throws -> Bool) { reader.withLock { $0 = read } }

    public static func messagesByCommand(agent: String, dataRoot: URL) throws -> Bool {
        guard let read = reader.withLock({ $0 }) else {
            throw ToolFailureError("Contact effect classification is not installed.", effects: .none,
                owner: "Agent contacts", code: "agent_profile_unavailable",
                instruction: "Repair runtime assembly before sending to another agent.")
        }
        return try read(agent, dataRoot)
    }
}

public enum AgentHostCommandLines {
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
        let process = ManagedProcess(), output = Pipe(), exited = DispatchSemaphore(value: 0)
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
                ProcessTreeReaper.quiesceAndKill(process.groupSnapshot)
                return refused(process.terminationError ?? "PATH did not return within three seconds; process-group settlement remains in progress")
            }
            drain.stopAndWait()
            if let failure = process.terminationError { return refused(failure) }
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

    /// Resolve links before comparing executable identities; a missing executable has no identity.
    public static func resolveCommand(_ command: String) -> String? {
        guard command.hasPrefix("/") else { return resolveExecutable(command) }
        let path = URL(fileURLWithPath: command).resolvingSymlinksInPath().path
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0 ? path : nil
    }

    /// What an executable file is: its code directory hash when signed, else the SHA-256 of its bytes. A program that changes has another identity.
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
            if let path = resolveCommand(expanded + "/" + name) { return path }
        }
        return nil
    }

    /// Provider keys and the bridge token must never reach an external agent. Start from only the variables needed for executable lookup, user identity and
    /// locale; add a variable only for a verified CLI requirement.
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
