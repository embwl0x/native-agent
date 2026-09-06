import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

private struct BuilderWorktreeTestError: Error, CustomStringConvertible {
    let description: String
}

private func runBuilderWorktreeGit(_ arguments: [String], cwd: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = String(
        data: stdout.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let error = String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    guard process.terminationStatus == 0 else {
        throw BuilderWorktreeTestError(
            description: "git \(arguments.joined(separator: " ")) failed: \(error)"
        )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct BuilderWorktreeFixture {
    enum GitState: Equatable {
        case valid
        case nonGit
        case corruptProbe
        case allocationFailure
    }

    let root: URL
    let repo: URL
    let dataRoot: URL
    let configRoot: URL

    static func make(gitState: GitState = .valid) throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "builder-worktree-dispatch-\(UUID().uuidString)",
            isDirectory: true
        )
        let repo = root.appendingPathComponent("NativeAgent", isDirectory: true)
        let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
        let persona = repo.appendingPathComponent("persona", isDirectory: true)
        let script = repo.appendingPathComponent("script", isDirectory: true)
        let sources = repo.appendingPathComponent("Sources", isDirectory: true)
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        for directory in [dataRoot, persona, script, sources, configRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("fixture\n".utf8).write(
            to: persona.appendingPathComponent("SOUL.template.md")
        )
        try Data("#!/bin/sh\n".utf8).write(
            to: script.appendingPathComponent("init_persona.sh")
        )
        try Data("// swift-tools-version: 6.0\n".utf8).write(
            to: repo.appendingPathComponent("Package.swift")
        )
        try Data("let fixture = true\n".utf8).write(
            to: sources.appendingPathComponent("Fixture.swift")
        )
        switch gitState {
        case .nonGit:
            break
        case .corruptProbe:
            try Data("not a git directory\n".utf8).write(
                to: repo.appendingPathComponent(".git")
            )
        case .valid, .allocationFailure:
            _ = try runBuilderWorktreeGit(["init"], cwd: repo)
            _ = try runBuilderWorktreeGit(["config", "user.name", "NativeAgent Test"], cwd: repo)
            _ = try runBuilderWorktreeGit(["config", "user.email", "nativeagent-test@example.invalid"], cwd: repo)
            _ = try runBuilderWorktreeGit(["config", "commit.gpgsign", "false"], cwd: repo)
            _ = try runBuilderWorktreeGit(["add", "."], cwd: repo)
            _ = try runBuilderWorktreeGit(["commit", "-m", "fixture"], cwd: repo)
            if gitState == .allocationFailure {
                try Data("blocks nativeagent branch namespace\n".utf8).write(
                    to: repo.appendingPathComponent(".git/refs/heads/nativeagent")
                )
            }
        }
        return .init(root: root, repo: repo, dataRoot: dataRoot, configRoot: configRoot)
    }
}

private actor BuilderWakePayloads {
    private var values: [[String: JSONValue]] = []

    func append(_ value: [String: JSONValue]) {
        values.append(value)
    }

    func all() -> [[String: JSONValue]] {
        values
    }
}

private func builderString(_ key: String, in value: JSONValue) -> String? {
    guard case .object(let object) = value,
          case .string(let string)? = object[key] else { return nil }
    return string
}

private func builderDispatcher(
    fixture: BuilderWorktreeFixture,
    wakes: BuilderWakePayloads
) -> SwiftToolDispatcher {
    SwiftToolDispatcher(
        dataRoot: fixture.dataRoot,
        agentBridgeConfigRoot: fixture.configRoot,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakes.append(input)
            let messageId: String
            if case .string(let value)? = input["messageId"] {
                messageId = value
            } else {
                messageId = "missing"
            }
            let threadId: String
            if case .string(let value)? = input["threadId"] {
                threadId = value
            } else {
                threadId = "thread-\(messageId)"
            }
            return .object(["status": .string("sent"), "threadId": .string(threadId)])
        },
        claudeMessageWakeupOverride: { input in
            await wakes.append(input)
            return .object(["status": .string("sent")])
        },
        ompMessageWakeupOverride: { input in
            await wakes.append(input)
            return .object(["status": .string("sent")])
        }
    )
}

private let builderMessageRoutes: [(tool: String, topic: String)] = [
    ("codex_message", "codex-route"),
    ("claude_message", "claude-route"),
    ("omp_message", "omp-route"),
]

@Test("parallel codex_message writers receive distinct worktrees and a follow-up reuses its tree")
func codexMessageDispatchIsolatesParallelWriters() async throws {
    let fixture = try BuilderWorktreeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try runBuilderWorktreeGit(
        ["remote", "add", "origin", "https://github.com/nativeagent-tests/NativeAgent.git"],
        cwd: fixture.repo
    )
    let wakes = BuilderWakePayloads()
    let tools = SwiftToolDispatcher(
        dataRoot: fixture.dataRoot,
        agentBridgeConfigRoot: fixture.configRoot,
        codexMessageNotificationPermissionOverride: false,
        codexMessageWakeupOverride: { input in
            await wakes.append(input)
            let messageId: String
            if case .string(let value)? = input["messageId"] {
                messageId = value
            } else {
                messageId = "missing"
            }
            let threadId: String
            if case .string(let value)? = input["threadId"] {
                threadId = value
            } else {
                threadId = "thread-\(messageId)"
            }
            return .object(["status": .string("sent"), "threadId": .string(threadId)])
        }
    )

    async let first = tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Build lane one."),
            "message_id": .string("lane-one"),
            "working_directory": .string(fixture.repo.path),
        ],
        surface: "chat"
    )
    async let second = tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Build lane two."),
            "message_id": .string("lane-two"),
            "working_directory": .string(fixture.repo.path),
        ],
        surface: "chat"
    )
    let (firstResult, secondResult) = try await (first, second)
    let firstDirectory = try #require(builderString("workingDirectory", in: firstResult))
    let secondDirectory = try #require(builderString("workingDirectory", in: secondResult))
    #expect(firstDirectory != secondDirectory)
    #expect(firstDirectory != fixture.repo.path)
    #expect(secondDirectory != fixture.repo.path)
    #expect(FileManager.default.fileExists(atPath: firstDirectory))
    #expect(FileManager.default.fileExists(atPath: secondDirectory))
    #expect(try runBuilderWorktreeGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: URL(fileURLWithPath: firstDirectory)).hasPrefix("nativeagent/codex-"))
    #expect(try runBuilderWorktreeGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: URL(fileURLWithPath: secondDirectory)).hasPrefix("nativeagent/codex-"))

    try Data("lane one only\n".utf8).write(
        to: URL(fileURLWithPath: firstDirectory).appendingPathComponent("LANE_ONE.txt")
    )
    #expect(!FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: secondDirectory).appendingPathComponent("LANE_ONE.txt").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: fixture.repo.appendingPathComponent("LANE_ONE.txt").path
    ))

    let firstConversation = try #require(builderString("conversationId", in: firstResult))
    let followUp = try await tools.dispatch(
        tool: "codex_message",
        input: [
            "text": .string("Continue lane one."),
            "message_id": .string("lane-one-follow-up"),
            "conversation_id": .string(firstConversation),
            // Tool-calling models may serialize this optional on every call.
            // The saved conversation, not a repeated repo hint, owns resume cwd.
            "repository": .string("nativeagent-tests/NativeAgent"),
        ],
        surface: "chat"
    )
    #expect(builderString("workingDirectory", in: followUp) == firstDirectory)
    let payloads = await wakes.all()
    #expect(payloads.count == 3)
    #expect(payloads.contains { $0["workingDirectory"] == .string(firstDirectory) })
    #expect(payloads.contains { $0["workingDirectory"] == .string(secondDirectory) })
}

@Test("claude_message creates one worktree and reuses it for the same conversation")
func claudeMessageDispatchReusesConversationWorktree() async throws {
    let fixture = try BuilderWorktreeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wakes = BuilderWakePayloads()
    let tools = SwiftToolDispatcher(
        dataRoot: fixture.dataRoot,
        agentBridgeConfigRoot: fixture.configRoot,
        claudeMessageWakeupOverride: { input in
            await wakes.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let first = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Build the Claude lane."),
            "topic": .string("claude lane"),
            "message_id": .string("claude-lane-first"),
            "working_directory": .string(fixture.repo.path),
        ],
        surface: "chat"
    )
    let firstDirectory = try #require(builderString("workingDirectory", in: first))
    let conversationId = try #require(builderString("conversationId", in: first))
    #expect(firstDirectory != fixture.repo.path)
    #expect(try runBuilderWorktreeGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: URL(fileURLWithPath: firstDirectory)).hasPrefix("nativeagent/claude-"))

    let followUp = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Continue the same Claude lane."),
            "message_id": .string("claude-lane-follow-up"),
            "conversation_id": .string(conversationId),
        ],
        surface: "chat"
    )
    #expect(builderString("workingDirectory", in: followUp) == firstDirectory)
    let payloads = await wakes.all()
    #expect(payloads.count == 2)
    #expect(payloads.allSatisfy { $0["cwd"] == .string(firstDirectory) })
}

@Test("parallel omp_message writers receive distinct worktrees and a follow-up reuses its tree")
func ompMessageDispatchIsolatesParallelWriters() async throws {
    let fixture = try BuilderWorktreeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wakes = BuilderWakePayloads()
    let tools = SwiftToolDispatcher(
        dataRoot: fixture.dataRoot,
        agentBridgeConfigRoot: fixture.configRoot,
        ompMessageWakeupOverride: { input in
            await wakes.append(input)
            return .object(["status": .string("sent")])
        }
    )

    async let first = tools.dispatch(
        tool: "omp_message",
        input: [
            "text": .string("Build OMP lane one."),
            "topic": .string("omp lane one"),
            "message_id": .string("omp-lane-one"),
            "working_directory": .string(fixture.repo.path),
        ],
        surface: "chat"
    )
    async let second = tools.dispatch(
        tool: "omp_message",
        input: [
            "text": .string("Build OMP lane two."),
            "topic": .string("omp lane two"),
            "message_id": .string("omp-lane-two"),
            "working_directory": .string(fixture.repo.path),
        ],
        surface: "chat"
    )
    let (firstResult, secondResult) = try await (first, second)
    let firstDirectory = try #require(builderString("workingDirectory", in: firstResult))
    let secondDirectory = try #require(builderString("workingDirectory", in: secondResult))
    #expect(firstDirectory != secondDirectory)
    #expect(firstDirectory != fixture.repo.path)
    #expect(secondDirectory != fixture.repo.path)
    #expect(try runBuilderWorktreeGit(
        ["rev-parse", "--abbrev-ref", "HEAD"],
        cwd: URL(fileURLWithPath: firstDirectory)
    ).hasPrefix("nativeagent/omp-"))
    #expect(try runBuilderWorktreeGit(
        ["rev-parse", "--abbrev-ref", "HEAD"],
        cwd: URL(fileURLWithPath: secondDirectory)
    ).hasPrefix("nativeagent/omp-"))

    let conversationId = try #require(builderString("conversationId", in: firstResult))
    let followUp = try await tools.dispatch(
        tool: "omp_message",
        input: [
            "text": .string("Continue OMP lane one."),
            "message_id": .string("omp-lane-one-follow-up"),
            "conversation_id": .string(conversationId),
        ],
        surface: "chat"
    )
    #expect(builderString("workingDirectory", in: followUp) == firstDirectory)
    let payloads = await wakes.all()
    #expect(payloads.count == 3)
    #expect(payloads.contains { $0["cwd"] == .string(firstDirectory) })
    #expect(payloads.contains { $0["cwd"] == .string(secondDirectory) })
}

@Test("a saved builder worktree rejects a conflicting follow-up working_directory")
func builderFollowUpRejectsConflictingWorkingDirectory() async throws {
    let fixture = try BuilderWorktreeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wakes = BuilderWakePayloads()
    let tools = SwiftToolDispatcher(
        dataRoot: fixture.dataRoot,
        agentBridgeConfigRoot: fixture.configRoot,
        claudeMessageWakeupOverride: { input in
            await wakes.append(input)
            return .object(["status": .string("sent")])
        }
    )

    let first = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Build in an isolated Claude lane."),
            "topic": .string("conflicting-cwd"),
            "message_id": .string("conflicting-cwd-first"),
            "working_directory": .string(fixture.repo.path),
        ],
        surface: "chat"
    )
    let assignedDirectory = try #require(builderString("workingDirectory", in: first))
    let conversationId = try #require(builderString("conversationId", in: first))
    #expect(assignedDirectory != fixture.repo.path)

    let conflicting = try await tools.dispatch(
        tool: "claude_message",
        input: [
            "text": .string("Do not leave the private lane."),
            "message_id": .string("conflicting-cwd-follow-up"),
            "conversation_id": .string(conversationId),
            "working_directory": .string(fixture.repo.path),
        ],
        surface: "chat"
    )
    #expect(builderString("status", in: conflicting) == "failed")
    #expect(builderString("reason", in: conflicting)
        == "builder_worktree_follow_up_directory_conflict")
    let payloads = await wakes.all()
    #expect(payloads.count == 1)
}

@Test("non-Git async builder dispatch preserves an omitted cwd for new and pre-pointer follow-ups")
func nonGitBuilderDispatchPreservesNilWorkingDirectory() async throws {
    let fixture = try BuilderWorktreeFixture.make(gitState: .nonGit)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wakes = BuilderWakePayloads()
    let tools = builderDispatcher(fixture: fixture, wakes: wakes)

    for route in builderMessageRoutes {
        let first = try await tools.dispatch(
            tool: route.tool,
            input: [
                "text": .string("Ordinary non-Git dispatch without a cwd."),
                "topic": .string(route.topic),
                "message_id": .string("\(route.topic)-nil-first"),
            ],
            surface: "chat"
        )
        #expect(builderString("status", in: first) == (route.tool == "claude_message" ? "accepted" : "queued"))
        #expect(builderString("workingDirectory", in: first) == nil)
        let conversationId = try #require(builderString("conversationId", in: first))

        let followUp = try await tools.dispatch(
            tool: route.tool,
            input: [
                "text": .string("Continue without inventing a cwd."),
                "message_id": .string("\(route.topic)-nil-follow-up"),
                "conversation_id": .string(conversationId),
            ],
            surface: "chat"
        )
        #expect(builderString("status", in: followUp) == (route.tool == "claude_message" ? "accepted" : "queued"))
        #expect(builderString("workingDirectory", in: followUp) == nil)
    }

    let payloads = await wakes.all()
    #expect(payloads.count == 6)
    #expect(payloads.allSatisfy { payload in
        payload["cwd"] == nil && payload["workingDirectory"] == nil
    })
}

@Test("an explicit ordinary non-Git cwd is forwarded unchanged by all async builder routes")
func nonGitBuilderDispatchPreservesRequestedWorkingDirectory() async throws {
    let fixture = try BuilderWorktreeFixture.make(gitState: .nonGit)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wakes = BuilderWakePayloads()
    let tools = builderDispatcher(fixture: fixture, wakes: wakes)

    for route in builderMessageRoutes {
        let result = try await tools.dispatch(
            tool: route.tool,
            input: [
                "text": .string("Use this ordinary non-Git directory."),
                "topic": .string("\(route.topic)-explicit"),
                "message_id": .string("\(route.topic)-explicit"),
                "working_directory": .string(fixture.repo.path),
            ],
            surface: "chat"
        )
        #expect(builderString("status", in: result) == (route.tool == "claude_message" ? "accepted" : "queued"))
        #expect(builderString("workingDirectory", in: result) == fixture.repo.path)
    }

    let payloads = await wakes.all()
    #expect(payloads.count == 3)
    #expect(payloads.allSatisfy { payload in
        payload["cwd"] == .string(fixture.repo.path)
            || payload["workingDirectory"] == .string(fixture.repo.path)
    })
}

@Test("Git evidence with a failed isolation probe is refused by every async builder route")
func builderDispatchRejectsFailedGitProbe() async throws {
    let fixture = try BuilderWorktreeFixture.make(gitState: .corruptProbe)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wakes = BuilderWakePayloads()
    let tools = builderDispatcher(fixture: fixture, wakes: wakes)

    for route in builderMessageRoutes {
        let result = try await tools.dispatch(
            tool: route.tool,
            input: [
                "text": .string("Do not dispatch into a corrupt Git checkout."),
                "topic": .string("\(route.topic)-probe-failure"),
                "message_id": .string("\(route.topic)-probe-failure"),
                "working_directory": .string(fixture.repo.path),
            ],
            surface: "chat"
        )
        #expect(builderString("status", in: result) == "failed")
        #expect(builderString("reason", in: result) == "builder_worktree_git_probe_failed")
    }
    let payloads = await wakes.all()
    #expect(payloads.isEmpty)
}

@Test("Git worktree allocation failure is refused by every async builder route")
func builderDispatchRejectsFailedWorktreeAllocation() async throws {
    let fixture = try BuilderWorktreeFixture.make(gitState: .allocationFailure)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wakes = BuilderWakePayloads()
    let tools = builderDispatcher(fixture: fixture, wakes: wakes)

    for route in builderMessageRoutes {
        let result = try await tools.dispatch(
            tool: route.tool,
            input: [
                "text": .string("Do not dispatch after worktree allocation fails."),
                "topic": .string("\(route.topic)-allocation-failure"),
                "message_id": .string("\(route.topic)-allocation-failure"),
                "working_directory": .string(fixture.repo.path),
            ],
            surface: "chat"
        )
        #expect(builderString("status", in: result) == "failed")
        #expect(builderString("reason", in: result) == "builder_worktree_create_failed")
    }
    let payloads = await wakes.all()
    #expect(payloads.isEmpty)
}
