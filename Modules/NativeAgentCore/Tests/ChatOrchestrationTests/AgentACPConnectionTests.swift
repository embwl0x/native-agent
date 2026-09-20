import Foundation
import ApprovalInbox
import Darwin
import NativeAgentCore
import Testing
@testable import ChatOrchestration
@testable import TrustCenter

@Suite struct AgentACPConnectionTests {
    @Test func connectedContactRoundTripsThroughEveryPeerReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPeerStore(dataRoot: root)
        let row = try #require(AgentHostDirectory.row(named: "Cursor CLI"))
        // Seed the existing identity so connect uses no real credential store.
        var contact = AgentPeerContact(name: row.displayName, endpoint: URL(string: "acp://\(row.id)")!, transport: .acp)
        contact.approvedExecutablePath = "/usr/bin/true"
        try store.upsert(contact)
        let proposal = AgentHostConnection.Proposal(row: row, command: "/fixture/link", descriptorPath: "/fixture/bridge.json",
            existing: contact, workingDirectory: root, contactID: contact.id,
            executable: try AgentACPExecutable.capture(path: "/usr/bin/true"))
        var mismatched = proposal
        mismatched.executablePath = "/different/approved/program"
        #expect(throws: AgentHostConnection.Refusal.self) {
            try AgentHostConnection.connect(proposal: mismatched, store: store)
        }
        #expect(try store.list() == [contact])
        let connected = try AgentHostConnection.connect(proposal: proposal, store: store).contact
        let reopened = AgentPeerStore(dataRoot: root)
        #expect(try reopened.list() == [connected])
        #expect(connected.approvedExecutablePath == connected.acpExecutable?.path)
        #expect(connected.canStartTurn)
        #expect(SwiftNativeSecurityCenter.messagesAnAgentHostByCommand(.string("peer:" + contact.id), dataRoot: root))
        #expect(try reopened.insertDiscovered(connected) == connected)
        #expect(try reopened.upsert(connected) == connected)
        #expect(try reopened.setElevation(peerID: contact.id, allowed: true)?.elevationAllowed == true)
        reopened.recordProof(peerID: contact.id, inbound: true, outbound: true)
        #expect(try reopened.list().first?.state == .setUp)
        reopened.recordRoundTrip(peerID: contact.id, executable: connected.approvedExecutablePath, workspace: root.path)
        #expect(try reopened.list().first?.state == .connected)
        var scoped = try #require(try reopened.list().first)
        scoped.endpoint = URL(string: "acp://goose")!
        #expect(!scoped.isReady)
        scoped = try #require(try reopened.list().first)
        scoped.credentialKey = AgentPeerContact.credentialKey(for: UUID().uuidString.lowercased())
        #expect(!scoped.isReady)
        reopened.recordUnavailable(peerID: contact.id)
        #expect(try reopened.list().first?.state == .setUp)
        reopened.recordRoundTrip(peerID: contact.id, executable: connected.approvedExecutablePath, workspace: root.path)
        #expect(try reopened.upsert(connected).state == .connected)
        // Reconnect retires both directions, including a stale proposal whose
        // proof predates the latest store write, without clearing elevation.
        let reconnected = try AgentHostConnection.connect(proposal: proposal, store: reopened).contact
        #expect(reconnected.state == .setUp)
        #expect(reconnected.provenInboundAt == nil && reconnected.provenOutboundAt == nil)
        #expect(reconnected.roundTripProof == nil)
        #expect(reconnected.elevationAllowed)
        #expect(try reopened.list() == [reconnected])
        #expect(try reopened.remove(contact.id))
        #expect(try reopened.list().isEmpty)
    }

    @Test func legacyACPEndpointsResolveToCanonicalRows() throws {
        for (legacy, canonical) in [("gemini", "gemini-cli"), ("cursor-agent", "cursor-cli")] {
            let endpoint = URL(string: "acp://" + legacy)!
            #expect(AgentPeerStore.hostRowID(endpoint) == canonical)
            let contact = AgentPeerContact(name: legacy, endpoint: endpoint, transport: .acp)
            try AgentPeerStore.validate(contact)
            #expect(AgentHostDirectory.rows.filter { $0.id == canonical }.count == 1)
        }
        #expect(AgentPeerStore.hostRowID(URL(string: "acp://cursor-agent/path")!) == nil)
        #expect(AgentPeerStore.hostRowID(URL(string: "mcp://cursor-agent")!) == nil)
    }

    @Test func executableApprovalDetectsReplacementEditsAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let link = root.appendingPathComponent("agent-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        var approved = try AgentACPExecutable.capture(path: link.path)
        var contact = AgentPeerContact(name: "Fixture", endpoint: URL(string: "acp://goose")!, transport: .acp)
        #expect(!contact.canStartTurn)
        contact.acpExecutable = approved
        #expect(!contact.canStartTurn)
        contact.approvedExecutablePath = "/different/approved/program"
        #expect(!contact.canStartTurn)
        contact.approvedExecutablePath = approved.path
        #expect(contact.canStartTurn)
        approved.version = "fixture 1.0"
        #expect(approved.path == binary.resolvingSymlinksInPath().path)
        #expect(approved.isCurrent)
        let data = try JSONEncoder().encode(approved)
        #expect(try JSONDecoder().decode(AgentACPExecutable.self, from: data) == approved)
        // Editing in place retains the inode but must still invalidate consent.
        let handle = try FileHandle(forWritingTo: binary)
        try handle.write(contentsOf: Data("#!/bin/sh\nexit 1\n".utf8))
        try handle.close()
        #expect(!approved.isCurrent)
        #expect(!contact.canStartTurn)
        approved = try AgentACPExecutable.capture(path: binary.path)
        contact.acpExecutable = approved
        #expect(contact.canStartTurn)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: binary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        #expect(!approved.isCurrent)
        #expect(!contact.canStartTurn)
        approved = try AgentACPExecutable.capture(path: binary.path)
        contact.acpExecutable = approved
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        #expect(!contact.canStartTurn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        #expect(contact.canStartTurn)
        try FileManager.default.removeItem(at: binary)
        #expect(!approved.isCurrent)
        #expect(!contact.canStartTurn)
    }

    @Test func cardNamesProgramFolderAndActualAuthority() throws {
        let row = try #require(AgentHostDirectory.row(named: "Cursor CLI"))
        var binary = try AgentACPExecutable.capture(path: "/usr/bin/true")
        binary.version = "different-version"
        let proposal = AgentHostConnection.Proposal(row: row, command: "/fixture/link", descriptorPath: "/fixture/bridge.json",
            existing: nil, workingDirectory: URL(fileURLWithPath: "/fixture/project"), contactID: UUID().uuidString.lowercased(), executable: binary)
        let card = AgentHostConnection.cardText(proposal, appName: "Test App")
        for text in ["run on this Mac as you", "read and change files itself", "only when Cursor CLI asks", "/fixture/project", binary.path, "different-version", "Untested version"] {
            #expect(card.contains(text))
        }
        #expect(!card.contains("still need permission"))
        #expect(card.contains("The program at this path is what will be run"))
        #expect(card.contains("re-checked before every launch"))
    }

    @Test(arguments: [false, true]) func verifiedPathVersionProbeRuns(retainedOutput: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if let raw = try? String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8),
               let pid = Int32(raw) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        let binary = root.appendingPathComponent("agent")
        let source = retainedOutput ? """
            #!/usr/bin/ruby
            child = fork do
              Process.setsid
              STDIN.close
              sleep 10
            end
            File.write(File.join(File.dirname(__FILE__), 'child-pid'), child.to_s)
            exit! 0
            """ : "#!/bin/sh\n[ \"$1\" = --version ] || exit 1\nprintf 'fixture 1.2.3\\n'\n"
        try Data(source.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let approved = try AgentACPExecutable.capture(path: binary.path)
        let start = ContinuousClock.now
        #expect(try await approved.reportedVersion() == (retainedOutput ? nil : "fixture 1.2.3"))
        #expect(start.duration(to: .now) < .seconds(6))
    }

    @Test func changedProgramCannotLaunchAfterApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let approved = try AgentACPExecutable.capture(path: binary.path)
        try Data("#!/bin/sh\necho launched > effect\n".utf8).write(to: binary)
        do {
            _ = try await AgentACPClient().turn(executable: binary.path, arguments: [], directory: root,
                environment: [:], message: "test", approvedExecutable: approved, permission: { _ in false })
            Issue.record("A changed program must not launch")
        } catch { #expect(error as? AgentACPClient.Failure == .executableChanged) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        let store = AgentPeerStore(dataRoot: root)
        var contact = AgentPeerContact(name: "Goose", endpoint: URL(string: "acp://goose")!, transport: .acp)
        contact.acpExecutable = approved
        contact.approvedExecutablePath = approved.path
        contact.acpWorkingDirectory = root.path
        try store.upsert(contact)
        let inbox = SwiftNativeApprovalInbox(root: root)
        let events = await ApprovalLifecycleBus.shared.events()
        let resolver = Task {
            for await event in events where event.phase == .requested && event.record.action == "agent.acp.connect" {
                guard let record = try? await inbox.get(event.record.id) else { continue }
                #expect(record.reason.contains("Digest:"))
                #expect(record.reason.contains(approved.digest))
                return try await inbox.resolve(record.id, decision: .approved, decidedBy: "test person")
            }
            throw CancellationError()
        }
        defer { resolver.cancel() }
        #expect(try await AgentACPApproval.renewExecutable(contact, store: store, inbox: inbox))
        _ = try await resolver.value
        #expect(try store.list().first?.acpExecutable?.isCurrent == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
    }

    @Test(arguments: [false, true], [false, true])
    func pathSwapBeforeLaunchCannotRunReplacement(sandboxed: Bool, script: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agent")
        if script {
            try Data("#!/bin/sh\nprintf 'approved\\n'\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        } else {
            try FileManager.default.copyItem(atPath: "/bin/echo", toPath: binary.path)
        }
        let approved = try AgentACPExecutable.capture(path: binary.path)
        try approved.verify()
        try FileManager.default.moveItem(at: binary, to: root.appendingPathComponent("old"))
        try Data("#!/bin/sh\necho unapproved > effect\nexit 71\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        #expect(!approved.isCurrent)
        let input = Pipe(), output = Pipe()
        let pid: pid_t
        do {
            pid = try AgentACPProcess.spawn(executable: sandboxed ? "/usr/bin/sandbox-exec" : binary.path,
                arguments: sandboxed ? ["-p", "(version 1)(allow default)", binary.path, "approved"] : ["approved"],
                directory: root, environment: [:], input: input, output: output, approvedExecutable: approved)
        } catch {
            #expect(error as? AgentACPClient.Failure == .executableChanged)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
            return
        }
        try input.fileHandleForReading.close()
        try input.fileHandleForWriting.close()
        try output.fileHandleForWriting.close()
        let bytes = try output.fileHandleForReading.readToEnd()
        try output.fileHandleForReading.close()
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        _ = bytes
        Issue.record("A replaced program must be refused before spawning")
    }
}
