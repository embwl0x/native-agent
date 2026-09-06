import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

/// Agent's ask (2026-09-01): full-detail `agent_introspect` must let her pin
/// which binary is answering the current turn, from inside the turn.
@Suite("agent_introspect build stamp")
struct AgentIntrospectBuildStampTests {
    @Test("full-detail build stamp carries version, exact revision, dirty flag and pid")
    func cleanBuildStamp() throws {
        let identity = NativeAgentBuildIdentity(
            version: "0.4.5-dev",
            build: "451",
            sourceRevision: "0123456789abcdef0123456789abcdef01234567",
            sourceDirty: false
        )
        guard case .object(let stamp) = SwiftToolDispatcher.buildStamp(identity: identity, pid: 4242) else {
            Issue.record("build stamp is not a JSON object")
            return
        }
        #expect(Set(stamp.keys) == ["version", "exactSourceRevision", "sourceDirty", "pid"])
        #expect(stamp["version"] == .string("0.4.5-dev"))
        #expect(stamp["exactSourceRevision"] == .string("0123456789abcdef0123456789abcdef01234567"))
        #expect(stamp["sourceDirty"] == .bool(false))
        #expect(stamp["pid"] == .int(4242))
    }

    /// A dirty build is never presented as exact proof of the named commit —
    /// the field is present and null, so absence of proof is readable rather
    /// than a missing key that looks like an older binary.
    @Test("dirty build reports a null exact revision, not the bare sha")
    func dirtyBuildStamp() throws {
        let identity = NativeAgentBuildIdentity(
            version: "0.4.5-dev",
            build: "451",
            sourceRevision: "0123456789abcdef0123456789abcdef01234567",
            sourceDirty: true
        )
        guard case .object(let stamp) = SwiftToolDispatcher.buildStamp(identity: identity, pid: 7) else {
            Issue.record("build stamp is not a JSON object")
            return
        }
        #expect(stamp["exactSourceRevision"] == .null)
        #expect(stamp["sourceDirty"] == .bool(true))
    }
}
