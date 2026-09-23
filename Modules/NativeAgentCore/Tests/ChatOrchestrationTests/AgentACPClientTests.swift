import ApprovalInbox
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

// Subprocess startup must not consume another fixture's phase-specific deadline.
@Suite(.serialized) struct AgentACPClientTests {
    private struct Fixture {
        let root: URL
        let script: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            script = root.appendingPathComponent("agent.rb")
            try Self.source.write(to: script, atomically: true, encoding: .utf8)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func run(_ mode: String, client: AgentACPClient = AgentACPClient(),
                 conversationID: String? = nil,
                 keepAlive: Bool = false, requireVerifiedRestore: Bool = false,
                 mcpServers: [JSONValue] = [], timeout: Duration = .seconds(10),
                 permission: @escaping AgentACPClient.Permission = { _ in false },
                 update: @escaping AgentACPClient.Update = { _ in }) async throws -> AgentACPClient.Reply {
            try await client.turn(executable: "/usr/bin/ruby", arguments: [script.path, mode],
                directory: root, environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                message: "--message $(must_not_run)\nsecond line", mcpServers: mcpServers, permissionMode: "ask",
                conversationID: conversationID,
                approvedExecutable: try AgentACPExecutable.capture(path: "/usr/bin/ruby"),
                keepAlive: keepAlive, requireVerifiedRestore: requireVerifiedRestore, timeout: timeout,
                permission: permission, update: update)
        }
        static let source = #"""
        require 'json'
        STDOUT.sync = true
        mode = ARGV.fetch(0)
        def send_json(value)
          STDOUT.write(JSON.generate(value) + "\n")
        end
        def result(id, value)
          send_json({'jsonrpc'=>'2.0', 'id'=>id, 'result'=>value})
        end
        def update(text)
          send_json({'jsonrpc'=>'2.0', 'method'=>'session/update', 'params'=>{'sessionId'=>'session-one', 'update'=>{'sessionUpdate'=>'agent_message_chunk', 'content'=>{'type'=>'text','text'=>text}}}})
        end
        prompt_id = nil
        permission_pending = false
        mode_set = false
        turns = 0
        STDIN.each_line do |line|
          m = JSON.parse(line)
          File.open('prompt-attempted', 'w') { |f| f.puts('prompt') } if m['method'] == 'session/prompt'
          if mode == 'stall-' + m['method'].to_s
            File.write('stalled-method', m['method'])
            sleep 60
          end
          case m['method']
          when 'initialize'
            raise 'version' unless m['params']['protocolVersion'] == 1
            raise 'capabilities' unless m['params']['clientCapabilities'] == {}
            caps = mode.start_with?('session-') ? {'loadSession'=>true} : {}
            caps['sessionCapabilities'] = {'resume'=>{}} if mode == 'session-resume'
            result(m['id'], {'protocolVersion'=> mode == 'version' ? 2 : 1, 'agentCapabilities'=>caps})
            sleep 10 if mode == 'blocked-input'
          when 'session/new'
            File.open('requests', 'a') { |f| f.puts('new') }
            raise 'cwd' unless m['params']['cwd'] == ENV['HOME']
            raise 'servers' unless m['params']['mcpServers'] == []
            result(m['id'], {'sessionId'=>'session-one','modes'=>{'currentModeId'=>'auto','availableModes'=>[{'id'=>'ask','name'=>'Ask'}]}})
          when 'session/load', 'session/resume'
            raise 'wrong method' unless m['method'] == (mode == 'session-resume' ? 'session/resume' : 'session/load')
            raise 'cwd' unless m['params']['cwd'] == ENV['HOME'] && File.realpath(Dir.pwd) == File.realpath(ENV['HOME'])
            raise 'servers' unless m['params']['mcpServers'] == []
            raise 'session' unless m['params']['sessionId'] == 'session-one'
            File.open('requests', 'a') { |f| f.puts(m['method']) }
            update('old answer must not appear') unless mode == 'session-empty'
            if mode == 'session-failed'
              send_json({'jsonrpc'=>'2.0', 'id'=>m['id'], 'error'=>{'code'=>-32000,'message'=>'Session expired'}})
            else
              result(m['id'], {})
            end
          when 'session/set_mode'
            raise 'unsafe mode' unless m['params']['modeId'] == 'ask'
            mode_set = true
            result(m['id'], {})
          when 'session/prompt'
            raise 'mode was not set' unless mode_set
            raise 'session' unless m['params']['sessionId'] == 'session-one'
            raise 'message' unless m['params']['prompt'][0]['text'] == "--message $(must_not_run)\nsecond line"
            prompt_id = m['id']
            if mode == 'permission' || mode == 'cancel-permission'
              permission_pending = true
              send_json({'jsonrpc'=>'2.0','id'=>'permission-one','method'=>'session/request_permission','params'=>{'sessionId'=>'session-one','toolCall'=>{'toolCallId'=>'tool-one','title'=>'Write a note','rawInput'=>{'path'=>'note.txt'}},'options'=>[{'optionId'=>'once','name'=>'Allow once','kind'=>'allow_once'},{'optionId'=>'never','name'=>'Deny','kind'=>'reject_once'},{'optionId'=>'always','name'=>'Always','kind'=>'allow_always'}]}})
            else
              turns += 1
              if mode == 'retained'
                update(turns == 1 ? 'model selected' : 'selected model retained')
                result(prompt_id, {'stopReason'=>'end_turn'})
                next
              end
              update('first ')
              exit 7 if mode == 'crash'
              next if mode == 'cancel'
              if mode == 'malformed'
                STDOUT.puts('not json')
                next
              end
              update('answer')
              if mode == 'orphan'
                child = fork do
                  STDIN.close
                  STDOUT.close
                  trap('TERM', 'IGNORE')
                  sleep 30
                  File.write('orphan-effect', 'survived')
                end
                File.write('child-pid', child.to_s)
              end
              result(prompt_id, {'stopReason'=> mode == 'limit' ? 'max_tokens' : 'end_turn'})
              exit! 0 if mode == 'orphan'
            end
          when 'session/cancel'
            File.write('cancelled', 'yes')
            result(prompt_id, {'stopReason'=>'cancelled'}) unless permission_pending
          else
            if m['id'] == 'permission-one'
              outcome = m.fetch('result').fetch('outcome')
              File.write('permission', JSON.generate(outcome))
              if outcome['outcome'] == 'cancelled'
                result(prompt_id, {'stopReason'=>'cancelled'})
              else
                File.write('note.txt', 'approved effect') if outcome['optionId'] == 'once'
                update(outcome['optionId'])
                result(prompt_id, {'stopReason'=>'end_turn'})
              end
            end
          end
        end
        File.write('closed', 'yes')
        """#
    }

    @Test func normalTurnStreamsAndCloses() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let updates = Updates()
        let reply = try await fixture.run("normal", update: { await updates.add($0) })
        #expect(reply.completed)
        #expect(reply.text == "first answer")
        #expect(await updates.count == 2)
        // Bounded final process cleanup check; the fixture writes only under HOME.
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("closed").path))
    }

    @Test(arguments: ["session-load", "session-resume"])
    func secondMessageContinuesWithoutHistory(_ mode: String) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let first = try await fixture.run(mode)
        let updates = Updates()
        let second = try await fixture.run(mode, conversationID: first.sessionID, update: { await updates.add($0) })
        #expect(first.sessionID == second.sessionID)
        #expect(!first.continued && second.continued)
        #expect(second.detail == nil)
        #expect(second.text == "first answer")
        #expect(await updates.count == 2)
        let requests = try String(contentsOf: fixture.root.appendingPathComponent("requests"), encoding: .utf8)
        #expect(requests == "new\n" + (mode == "session-resume" ? "session/resume\n" : "session/load\n"))
    }

    @Test(arguments: ["session-failed", "normal"])
    func unavailableSessionNeverSilentlyStartsFresh(_ mode: String) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let first = try await fixture.run(mode)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("prompt-attempted"))
        do {
            _ = try await fixture.run(mode, conversationID: first.sessionID)
            Issue.record("An unsupported or rejected restore must never start another conversation")
        } catch { #expect(error as? AgentACPClient.Failure == .sessionUnavailable) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("prompt-attempted").path))
        let requests = try String(contentsOf: fixture.root.appendingPathComponent("requests"), encoding: .utf8)
        #expect(requests == (mode == "session-failed" ? "new\nsession/load\n" : "new\n"))
    }

    @Test func commandOnlyConversationStaysInTheSameProcess() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let client = AgentACPClient()
        let first = try await fixture.run("retained", client: client, keepAlive: true)
        let second = try await fixture.run("retained", client: client, conversationID: first.sessionID, keepAlive: true)
        #expect(first.text == "model selected")
        #expect(second.text == "selected model retained")
        #expect(second.continued && second.sessionID == first.sessionID)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("requests"), encoding: .utf8) == "new\n")
        await client.close()
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("closed").path))
    }

    @Test func ambiguousColdResumeNeverPromptsOrStartsFresh() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        do {
            _ = try await fixture.run("session-empty", conversationID: "session-one", requireVerifiedRestore: true)
            Issue.record("An empty restore response cannot prove the old session exists")
        } catch { #expect(error as? AgentACPClient.Failure == .sessionUnavailable) }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("requests"), encoding: .utf8) == "session/load\n")
    }

    @Test func poolRejectsOverlappingTurnsAndRevokesOwnedChild() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let pool = AgentACPConnections()
        let lease = try await pool.acquire(peer: "fixture", conversation: nil, configuration: "approved")
        let reply = try await fixture.run("retained", client: lease.client, keepAlive: true)
        await pool.finish(lease, peer: "fixture", conversation: reply.sessionID)
        let resumed = try await pool.acquire(peer: "fixture", conversation: reply.sessionID, configuration: "approved")
        do {
            _ = try await pool.acquire(peer: "fixture", conversation: reply.sessionID, configuration: "approved")
            Issue.record("Overlapping conversation must not run twice")
        } catch { #expect(error as? AgentACPClient.Failure == .busy) }
        await pool.finish(resumed, peer: "fixture", conversation: reply.sessionID)
        await pool.revoke(peer: "fixture")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("closed").path))
    }

    @Test func stoppedReaderCannotBlockTheTurnDeadline() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let start = ContinuousClock.now
        do {
            _ = try await fixture.run("blocked-input", mcpServers: [.string(String(repeating: "x", count: 512 * 1024))])
            Issue.record("A peer that stops reading must fail")
        } catch {
            #expect(error as? AgentACPClient.Failure == .sessionStartupTimedOut)
        }
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test(arguments: ["initialize", "session/new", "session/set_mode", "session/prompt"])
    func timeoutIdentifiesStartupWithoutClaimingPromptWasUnsent(_ method: String) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let expected: AgentACPClient.Failure
        let phase: String?
        switch method {
        case "initialize": expected = .initializationTimedOut; phase = "initialization"
        case "session/new": expected = .sessionStartupTimedOut; phase = "session_startup"
        case "session/set_mode": expected = .modeSetupTimedOut; phase = "mode_setup"
        default: expected = .timedOut; phase = nil
        }
        do {
            _ = try await fixture.run("stall-" + method, timeout: .seconds(10))
            Issue.record("The stalled peer must time out")
        } catch {
            #expect(error as? AgentACPClient.Failure == expected)
            let receipt = AgentACPClient.startupTimeoutReceipt(error)
            if let phase {
                #expect(receipt?["phase"] == .string(phase))
                #expect(receipt?["sent"] == .bool(false))
                #expect(receipt?["completed"] == .bool(false))
                #expect(receipt?["status"] == .string("unavailable"))
            } else {
                #expect(receipt == nil)
            }
        }
        // Prove the fixture reached the intended stall before checking its receipt.
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("stalled-method"), encoding: .utf8) == method)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("prompt-attempted").path) == (method == "session/prompt"))
    }

    @Test(arguments: [ApprovalDecision.approved, .denied])
    func permissionUsesCanonicalCard(_ decision: ApprovalDecision) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let inbox = SwiftNativeApprovalInbox(root: fixture.root)
        let events = await ApprovalLifecycleBus.shared.events()
        let resolver = Task {
            for await event in events where event.phase == .requested && event.record.action == "agent.acp.permission" {
                guard (try? await inbox.get(event.record.id)) != nil else { continue }
                return try await inbox.resolve(event.record.id, decision: decision, decidedBy: "test person")
            }
            throw CancellationError()
        }
        defer { resolver.cancel() }
        let peer = AgentPeerContact(name: "Test agent", endpoint: URL(string: "acp://goose")!, transport: .acp)
        let reply = try await fixture.run("permission", permission: {
            try await AgentACPApproval.request($0, peer: peer, inbox: inbox)
        })
        let record = try await resolver.value
        #expect(record.decision == decision.rawValue)
        #expect(reply.text == (decision == .approved ? "once" : "never"))
        #expect(reply.completed == (decision == .approved))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("note.txt").path)
            == (decision == .approved))
    }

    @Test func permissionPersistsOnlyBoundedRedactedLocalPreview() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let inbox = SwiftNativeApprovalInbox(root: fixture.root)
        let events = await ApprovalLifecycleBus.shared.events()
        let secret = "sk-proj-" + String(repeating: "a", count: 40)
        let resolver = Task {
            for await event in events where event.phase == .requested && event.record.action == "agent.acp.permission" {
                guard let record = try? await inbox.get(event.record.id) else { continue }
                #expect(record.localOnly && !record.remoteResolvable)
                let persisted = try record.payload.serialize(pretty: false)
                #expect(!persisted.contains(secret))
                #expect(!record.payloadPreview.contains(secret))
                #expect(persisted.count < 4500)
                #expect(record.payloadPreview.count <= 4000)
                for remote: ApprovalResolutionProvenance in [.telegram(chatID: "fixture", userID: "fixture"), .signedIOS(clientID: "fixture", decidedBy: "fixture")] {
                    await #expect(throws: (any Error).self) {
                        _ = try await inbox.resolve(record.id, decision: .approved, provenance: remote)
                    }
                }
                return try await inbox.resolve(record.id, decision: .denied, decidedBy: "local fixture")
            }
            throw CancellationError()
        }
        defer { resolver.cancel() }
        let peer = AgentPeerContact(name: "Fixture", endpoint: URL(string: "acp://goose")!, transport: .acp)
        let allowed = try await AgentACPApproval.request(.object(["toolCall": .object([
            "rawInput": .string("echo " + secret + String(repeating: "x", count: 8000))])]), peer: peer, inbox: inbox)
        #expect(!allowed)
        _ = try await resolver.value
    }

    @Test(arguments: ["crash", "malformed", "version"])
    func brokenTurnNeverCompletes(_ mode: String) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        do {
            _ = try await fixture.run(mode)
            Issue.record("A broken turn must throw, even after partial output")
        } catch { #expect(!(error is CancellationError)) }
        try await Task.sleep(for: .seconds(1))
    }

    @Test func tokenLimitIsNotCompletion() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let reply = try await fixture.run("limit")
        #expect(!reply.completed)
        #expect(reply.stopReason == "max_tokens")
        try await Task.sleep(for: .seconds(1))
    }

    @Test func exitedParentCannotLeaveAnOrphan() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let reply = try await fixture.run("orphan")
        #expect(reply.completed)
        let pid = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("child-pid"), encoding: .utf8)))
        // A reparented zombie may briefly retain its PID, but cannot run.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        #expect(count != size || info.pbi_status == UInt32(SZOMB))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("orphan-effect").path))
    }

    @Test(arguments: ["cancel", "cancel-permission"])
    func cancellationReachesAgentAndPendingPermission(_ mode: String) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let signal = AsyncStream<Void>.makeStream()
        let task = Task {
            try await fixture.run(mode, permission: { _ in
                signal.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
                return true
            }, update: { _ in signal.continuation.yield(()) })
        }
        for await _ in signal.stream { break }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled turn completed") }
        catch { #expect(error is CancellationError) }
        try await Task.sleep(for: .seconds(1))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cancelled").path))
        if mode == "cancel-permission" {
            let outcome = try JSONValue.parse(Data(contentsOf: fixture.root.appendingPathComponent("permission")))
            #expect(outcome == .object(["outcome": .string("cancelled")]))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("closed").path))
    }

    @Test func knownRoutesAndProofStayHonest() throws {
        #expect(AgentHostDirectory.row(named: "Gemini CLI")?.acp?.arguments == ["--acp", "--approval-mode=plan", "--sandbox"])
        #expect(AgentHostDirectory.row(named: "Goose")?.acp?.arguments == ["acp"])
        #expect(AgentHostDirectory.row(named: "Goose")?.acp?.environment == ["GOOSE_MODE": "chat"])
        #expect(AgentHostDirectory.row(named: "Cursor CLI")?.acp?.arguments == ["acp", "--mode=ask", "--sandbox=enabled"])
        #expect(AgentHostDirectory.row(named: "Cursor")?.acp == nil)
        #expect(Set(AgentHostDirectory.rows.map(\.id)).count == AgentHostDirectory.rows.count)
        #expect(AgentHostDirectory.row(named: "gemini")?.id == "antigravity-cli")
        #expect(AgentHostDirectory.row(named: "Gemini CLI")?.id == "gemini-cli")
        #expect(AgentHostDirectory.row(named: "gemini-cli")?.displayName == "Gemini CLI (Legacy)")
        #expect(AgentHostDirectory.row(named: "cursor-agent")?.id == "cursor-cli")
        for (id, version) in [("gemini-cli", "0.60.0"), ("goose", "1.51.0"), ("cursor-cli", "2026.09.15")] {
            let route = try #require(AgentHostACP.byHostID[id])
            let row = try #require(AgentHostDirectory.row(named: id))
            #expect(AgentHostDirectory.rows.filter { $0.matches(id) }.count == 1)
            #expect(row.acpLaunch?.arguments == route.arguments)
            #expect(!row.settingsSupported)
            #expect(row.configPath.isEmpty)
            #expect(route.referenceVersion == version)
            #expect(!route.versionNote("\(id) \(version)").contains("Untested"))
            #expect(route.versionNote("99.0.0").contains("Untested version"))
            #expect(route.versionNote(nil).contains("Untested version"))
            #expect(!route.arguments.contains { $0.contains("yolo") || $0.contains("force") || $0.contains("approve-mcps") })
        }
        #expect(AgentHostDirectory.row(named: "Codex")?.route == .commandLine)
        #expect(AgentHostDirectory.row(named: "Claude Code")?.route == .commandLine)
        let peer = AgentPeerContact(name: "Test", endpoint: URL(string: "acp://goose")!, transport: .acp)
        try AgentPeerStore.validate(peer)
        #expect(!peer.canStartTurn && peer.canAnswerBack)
        #expect(peer.state == .setUp)
        var invalid = peer
        invalid.endpoint = URL(string: "acp://arbitrary-command")!
        #expect(throws: (any Error).self) { try AgentPeerStore.validate(invalid) }
    }

    private actor Updates {
        var count = 0
        func add(_ value: JSONValue) { count += 1 }
    }
}
