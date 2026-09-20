import ApprovalInbox
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite struct AgentACPClientTests {
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
                 mcpServers: [JSONValue] = [],
                 permission: @escaping AgentACPClient.Permission = { _ in false },
                 update: @escaping AgentACPClient.Update = { _ in }) async throws -> AgentACPClient.Reply {
            try await client.turn(executable: "/usr/bin/ruby", arguments: [script.path, mode],
                directory: root, environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                message: "--message $(must_not_run)\nsecond line", mcpServers: mcpServers, permissionMode: "ask",
                approvedExecutable: try AgentACPExecutable.capture(path: "/usr/bin/ruby"),
                timeout: .seconds(10),
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
        STDIN.each_line do |line|
          m = JSON.parse(line)
          case m['method']
          when 'initialize'
            raise 'version' unless m['params']['protocolVersion'] == 1
            raise 'capabilities' unless m['params']['clientCapabilities'] == {}
            result(m['id'], {'protocolVersion'=> mode == 'version' ? 2 : 1, 'agentCapabilities'=>{}})
            sleep 10 if mode == 'blocked-input'
          when 'session/new'
            raise 'cwd' unless m['params']['cwd'] == ENV['HOME']
            raise 'servers' unless m['params']['mcpServers'] == []
            result(m['id'], {'sessionId'=>'session-one','modes'=>{'currentModeId'=>'auto','availableModes'=>[{'id'=>'ask','name'=>'Ask'}]}})
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

    @Test func stoppedReaderCannotBlockTheTurnDeadline() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let start = ContinuousClock.now
        do {
            _ = try await fixture.run("blocked-input", mcpServers: [.string(String(repeating: "x", count: 512 * 1024))])
            Issue.record("A peer that stops reading must fail")
        } catch {
            #expect(error as? AgentACPClient.Failure == .timedOut)
        }
        #expect(start.duration(to: .now) < .seconds(5))
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
        #expect(AgentHostDirectory.row(named: "gemini")?.id == "gemini-cli")
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
