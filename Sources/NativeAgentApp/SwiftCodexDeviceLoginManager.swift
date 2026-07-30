import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry

actor SwiftCodexDeviceLoginManager {
    private struct LoginState {
        var running: Bool = false
        var pid: Int?
        var url: String?
        var code: String?
        var expiresInMinutes: Int?
        var openedBrowser: Bool?
        var codexHome: String?
        var loginCommand: String?
        var detail: String?
        var exitCode: Int?
        var startedAt: String?
        var finishedAt: String?
    }

    private var process: Process?
    private var outputHandle: FileHandle?
    private var state = LoginState(detail: "codex device-login idle")

    func status(codexHome: URL) throws -> CodexDeviceLogin {
        if let process, !process.isRunning, state.running {
            finish(exitCode: Int(process.terminationStatus), detail: "codex device-login exited")
        }
        if state.codexHome == nil {
            state.codexHome = codexHome.path
        }
        return snapshot()
    }

    func start(codexHome: URL, openBrowser: Bool) async throws -> CodexDeviceLogin {
        if let process, process.isRunning {
            return snapshot()
        }

        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        clearOutputHandle()

        let environment = Self.loginEnvironment(codexHome: codexHome)
        let executable = try Self.resolveCodexExecutable(environment: environment)
        let started = Self.nowISO()
        let command = "CODEX_HOME=\(codexHome.path) \(executable.path) login --device-auth"

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["login", "--device-auth"]
        proc.environment = environment
        proc.standardOutput = pipe
        proc.standardError = pipe

        state = LoginState(
            running: true,
            pid: nil,
            url: nil,
            code: nil,
            expiresInMinutes: nil,
            openedBrowser: false,
            codexHome: codexHome.path,
            loginCommand: command,
            detail: "starting codex device-login",
            exitCode: nil,
            startedAt: started,
            finishedAt: nil
        )
        process = proc
        outputHandle = pipe.fileHandleForReading

        try proc.run()
        state.pid = Int(proc.processIdentifier)
        state.detail = "codex device-login running"

        let pid = Int(proc.processIdentifier)
        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task { await self?.ingest(text, openBrowser: openBrowser) }
        }
        proc.terminationHandler = { [weak self] finishedProcess in
            Task {
                await self?.processDidExit(
                    pid: pid,
                    exitCode: Int(finishedProcess.terminationStatus)
                )
            }
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if state.url != nil || state.code != nil || state.finishedAt != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return snapshot()
    }

    func cancel(codexHome: URL) async throws -> CodexDeviceLogin {
        if state.codexHome == nil {
            state.codexHome = codexHome.path
        }
        if let process, process.isRunning {
            state.detail = "codex device-login cancel requested"
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        finish(exitCode: state.exitCode, detail: "codex device-login cancelled")
        clearOutputHandle()
        process = nil
        return snapshot()
    }

    func clear(codexHome: URL) async throws -> CodexDeviceLogin {
        if let process, process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 300_000_000)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        clearOutputHandle()
        process = nil
        state = LoginState(
            running: false,
            pid: nil,
            url: nil,
            code: nil,
            expiresInMinutes: nil,
            openedBrowser: false,
            codexHome: codexHome.path,
            loginCommand: nil,
            detail: "codex device-login cleared",
            exitCode: nil,
            startedAt: nil,
            finishedAt: Self.nowISO()
        )
        return snapshot()
    }

    private func ingest(_ text: String, openBrowser: Bool) async {
        let plain = Self.stripTerminalControlSequences(text)
        let cleanedLines = plain
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let last = cleanedLines.last {
            state.detail = last
        }
        if state.url == nil, let parsed = Self.extractURL(from: plain) {
            state.url = parsed
            if openBrowser, state.openedBrowser != true {
                state.openedBrowser = await Self.openURL(parsed)
            }
        }
        if state.code == nil, let parsed = Self.extractCode(from: plain) {
            state.code = parsed
        }
        if state.expiresInMinutes == nil, let minutes = Self.extractExpiryMinutes(from: plain) {
            state.expiresInMinutes = minutes
        }
    }

    private func processDidExit(pid: Int, exitCode: Int) {
        guard state.pid == pid else { return }
        let detail = exitCode == 0
            ? "codex device-login exited successfully"
            : "codex device-login exited with code \(exitCode)"
        finish(exitCode: exitCode, detail: detail)
        clearOutputHandle()
        process = nil
    }

    private func finish(exitCode: Int?, detail: String) {
        state.running = false
        state.exitCode = exitCode
        state.finishedAt = state.finishedAt ?? Self.nowISO()
        state.detail = detail
    }

    private func clearOutputHandle() {
        outputHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        outputHandle = nil
    }

    private func snapshot() -> CodexDeviceLogin {
        CodexDeviceLogin(
            running: state.running,
            pid: state.pid,
            url: state.url,
            code: state.code,
            expiresInMinutes: state.expiresInMinutes,
            openedBrowser: state.openedBrowser,
            codexHome: state.codexHome,
            loginCommand: state.loginCommand,
            detail: state.detail,
            exitCode: state.exitCode,
            startedAt: state.startedAt,
            finishedAt: state.finishedAt
        )
    }

    static func loginEnvironment(codexHome: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["PATH"] = augmentedPath(environment["PATH"])
        return environment
    }

    static func augmentedPath(_ existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var parts = (existing ?? "").split(separator: ":").map(String.init)
        for addition in additions where !parts.contains(addition) {
            parts.append(addition)
        }
        return parts.joined(separator: ":")
    }

    static func resolveCodexExecutable(environment: [String: String]) throws -> URL {
        let fm = FileManager.default
        if let override = environment["NATIVE_AGENT_CODEX_BIN"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let path = environment["PATH"] ?? augmentedPath(nil)
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("codex")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw NSError(domain: "NativeAgentSwiftOnly", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Could not find an executable codex CLI. Install codex or set NATIVE_AGENT_CODEX_BIN."
        ])
    }

    /// True when the Codex CLI can be located using the SAME augmented PATH the
    /// login flow uses. A Finder-launched .app inherits a minimal PATH (no
    /// /opt/homebrew/bin), so resolving against the raw ProcessInfo PATH would
    /// miss a Homebrew/cargo codex install and wrongly report "not installed".
    /// Onboarding's ChatGPT precheck and the chat provider-readiness guard both
    /// use this so detection matches what the actual login path can run
    /// (gpt-5.5 review 2026-07-04).
    static func codexIsResolvable() -> Bool {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(environment["PATH"])
        return (try? resolveCodexExecutable(environment: environment)) != nil
    }

    static func extractURL(from text: String) -> String? {
        firstRegexMatch(#"https?://[^\s<>"']+"#, in: text).map { match in
            match.trimmingCharacters(in: CharacterSet(charactersIn: ".,);]}>'\""))
        }
    }

    static func stripTerminalControlSequences(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]") else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    static func extractCode(from text: String) -> String? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for (index, line) in lines.enumerated() {
            if let inline = firstRegexCapture(
                #"(?i)\b(?:user\s+code|one-time\s+code|code)\b\s*(?:\([^)]*\))?\s*(?:is|:)\s*([A-Z0-9]{4,}-[A-Z0-9-]{3,})\b"#,
                in: line
            ) {
                return inline.uppercased()
            }

            let lower = line.lowercased()
            let announcesDeviceCode = lower.contains("one-time code")
                || lower.contains("user code")
                || (lower.contains("enter") && lower.contains("code"))
            if announcesDeviceCode, index + 1 < lines.count,
               let nextLineCode = deviceCodeFromStandaloneLine(lines[index + 1]) {
                return nextLineCode
            }
        }
        return nil
    }

    static func deviceCodeFromStandaloneLine(_ line: String) -> String? {
        guard let match = firstRegexCapture(
            #"^\s*([A-Z0-9]{4,}-[A-Z0-9-]{3,})\s*$"#,
            in: line
        ) else { return nil }
        return match.uppercased()
    }

    static func extractExpiryMinutes(from text: String) -> Int? {
        guard let value = firstRegexCapture(#"(?i)expires?\s+(?:in\s+)?(\d+)\s+min"#, in: text) else {
            return nil
        }
        return Int(value)
    }

    static func firstRegexMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    static func openURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}


// Notify-don't-hang (2026-06-09): in-turn tool notices (invoke_claude
// start/heartbeat/timeout) hop from the chat stream consumer to the UI
// toast bar through this notification. userInfo: ["kind": String, "text": String].
