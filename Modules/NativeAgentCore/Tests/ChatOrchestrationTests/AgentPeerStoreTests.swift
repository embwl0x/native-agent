import Darwin
import Foundation
import Testing
@testable import ChatOrchestration

@Suite struct AgentPeerStoreTests {
    private func fixture() -> AgentPeerStore {
        AgentPeerStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("agent-peers-\(UUID())"))
    }
    private func clean(_ store: AgentPeerStore) {
        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent().deletingLastPathComponent())
    }
    private func contact(_ name: String = "Other agent", endpoint: String = "https://agent.example/.well-known/agent-card.json") -> AgentPeerContact {
        AgentPeerContact(name: name, endpoint: URL(string: endpoint)!, transport: .a2a)
    }

    @Test func missingCRUDStableIdentityAndPrivatePermissions() throws {
        let store = fixture()
        defer { clean(store) }
        #expect(try store.list().isEmpty)
        var first = contact()
        first.credentialKey = AgentPeerContact.credentialKey(for: first.id)
        #expect(try store.upsert(first) == first)
        let second = contact("Same Mac", endpoint: "http://127.0.0.1:8765")
        try store.upsert(second)
        first.name = "Renamed agent"
        try AgentPeerStore(dataRoot: store.fileURL.deletingLastPathComponent().deletingLastPathComponent()).upsert(first)
        #expect(try store.list() == [first, second])
        #expect(try store.remove(first.id))
        #expect(try !store.remove(first.id))
        #expect(try store.list() == [second])
        for (url, expected) in [(store.fileURL, 0o600), (store.fileURL.deletingLastPathComponent(), 0o700)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == expected)
        }
    }

    @Test(arguments: ["broken", "{}", "null", "[null]", "[{\"id\":\"bad\"}]", "[] trailing"])
    func malformedConfigurationNeverBecomesEmptyOrOverwritten(bytes: String) throws {
        let store = fixture()
        defer { clean(store) }
        _ = try store.list()
        let original = Data(bytes.utf8)
        try original.write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.list() }
        #expect(throws: (any Error).self) { try store.upsert(contact()) }
        #expect(throws: (any Error).self) { try store.remove(UUID().uuidString.lowercased()) }
        #expect(try Data(contentsOf: store.fileURL) == original)
    }

    @Test func invalidRowsDuplicatesAndUnknownSecretFieldsArePreserved() throws {
        let store = fixture()
        defer { clean(store) }
        _ = try store.list()
        let good = contact()
        var bad = good
        bad.credentialKey = "provider:openai"
        var unknown = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
        unknown["token"] = "synthetic-do-not-persist"
        let cases = [try JSONEncoder().encode([good, good]), try JSONEncoder().encode([bad]),
                     try JSONSerialization.data(withJSONObject: [unknown])]
        for bytes in cases {
            try bytes.write(to: store.fileURL)
            #expect(throws: (any Error).self) { try store.upsert(contact("New")) }
            #expect(try Data(contentsOf: store.fileURL) == bytes)
        }
    }

    @Test(arguments: ["http://agent.example", "https://user:pass@agent.example", "https://agent.example/?token=synthetic", "https://agent.example/#secret", "file:///tmp/peer", "http://127.0.0.2", "http://localhost.evil.example", "https://agent.example:0"])
    func unsafeEndpointRejected(endpoint: String) throws {
        #expect(throws: AgentPeerStoreError.invalidEndpoint) { try AgentPeerStore.validate(contact(endpoint: endpoint)) }
    }

    @Test(arguments: ["https://agent.example/card.json", "http://localhost:8765", "http://127.0.0.1:8765", "http://[::1]:8765"])
    func explicitLocalOrEncryptedEndpointAccepted(endpoint: String) throws {
        try AgentPeerStore.validate(contact(endpoint: endpoint))
    }

    @Test func fieldAndCountBounds() throws {
        let store = fixture()
        defer { clean(store) }
        for name in ["", " leading", "line\nbreak", String(repeating: "a", count: 121)] {
            #expect(throws: AgentPeerStoreError.invalidContact) { try store.upsert(contact(name)) }
        }
        var badID = contact()
        badID.id = "peer/not-a-uuid"
        #expect(throws: AgentPeerStoreError.invalidContact) { try store.upsert(badID) }
        var badKey = contact()
        badKey.credentialKey = AgentPeerContact.credentialKey(for: UUID().uuidString.lowercased())
        #expect(throws: AgentPeerStoreError.invalidCredentialReference) { try store.upsert(badKey) }
        #expect(throws: AgentPeerStoreError.invalidEndpoint) {
            try store.upsert(contact(endpoint: "https://agent.example/" + String(repeating: "a", count: 2048)))
        }
        _ = try store.list()
        var peers = (0..<AgentPeerStore.maximumContacts).map { contact("Peer \($0)") }
        try JSONEncoder().encode(peers).write(to: store.fileURL)
        #expect(throws: AgentPeerStoreError.tooManyContacts) { try store.upsert(contact("Overflow")) }
        peers[0].name = "Updated at capacity"
        try store.upsert(peers[0])
        #expect(try store.list() == peers)
    }

    @Test func unreadableAndNonregularConfigurationsCannotBeReplaced() throws {
        let store = fixture()
        defer { clean(store) }
        _ = try store.list()
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.upsert(contact()) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        try FileManager.default.removeItem(at: store.fileURL)
        #expect(mkfifo(store.fileURL.path, 0o600) == 0)
        #expect(throws: AgentPeerStoreError.unreadableConfiguration) { try store.list() }
        #expect(throws: AgentPeerStoreError.unreadableConfiguration) { try store.upsert(contact()) }
    }

    @Test func oversizedDocumentAndSymlinkAreNotFollowedOrReplaced() throws {
        let store = fixture()
        defer { clean(store) }
        _ = try store.list()
        let data = Data(repeating: 0x20, count: AgentPeerStore.maximumConfigurationBytes + 1)
        try data.write(to: store.fileURL)
        #expect(throws: AgentPeerStoreError.configurationTooLarge) { try store.upsert(contact()) }
        #expect(try Data(contentsOf: store.fileURL) == data)
        try FileManager.default.removeItem(at: store.fileURL)
        let target = store.fileURL.deletingLastPathComponent().appendingPathComponent("target.json")
        try Data("[]".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        #expect(throws: AgentPeerStoreError.unreadableConfiguration) { try store.upsert(contact()) }
        #expect(try Data(contentsOf: target) == Data("[]".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.fileURL.path) == target.path)
    }

    @Test func independentInstancesDoNotLoseConcurrentMutations() async throws {
        let store = fixture()
        defer { clean(store) }
        let peers = (0..<16).map { contact("Peer \($0)") }
        let root = store.fileURL.deletingLastPathComponent().deletingLastPathComponent()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for peer in peers {
                group.addTask { _ = try AgentPeerStore(dataRoot: root).upsert(peer) }
            }
            try await group.waitForAll()
        }
        #expect(Set(try store.list().map(\.id)) == Set(peers.map(\.id)))
    }
}
