import Darwin
import Foundation
import Testing
import MemoryV2

@Suite("Memory policy saved authority")
struct MemoryPolicyGateTests {
    private func withPolicyPath(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryPolicyGateTests-\(UUID().uuidString)")
        let trust = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, trust.appendingPathComponent("policy.json"))
    }

    @Test func absentPolicyUsesDefaultsWithoutCreatingAuthority() throws {
        try withPolicyPath { root, policy in
            #expect(MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root))
            #expect(!MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: root))
            #expect(!FileManager.default.fileExists(atPath: policy.path))
        }
    }

    @Test func danglingPolicyLinkDeniesEveryDefaultEnabledFeatureAndPreservesLink() throws {
        try withPolicyPath { root, policy in
            let destination = root.appendingPathComponent("missing-policy.json").path
            try FileManager.default.createSymbolicLink(atPath: policy.path, withDestinationPath: destination)
            #expect(!MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root))
            #expect(!MemoryPolicyGate.consolidationEnabled(dataRoot: root))
            #expect(!MemoryPolicyGate.adaptivePromotionEnabled(dataRoot: root))
            #expect(!MemoryPolicyGate.autoPromoteConsolidatedEnabled(dataRoot: root))
            #expect(!MemoryPolicyGate.hygieneEnabled(dataRoot: root))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: policy.path) == destination)
            #expect(!FileManager.default.fileExists(atPath: destination))
        }
    }

    @Test func unreadablePolicyDeniesWithoutRewritingBytes() throws {
        try withPolicyPath { root, policy in
            let bytes = Data(#"{"memoryPolicy":{"cross_session_recall":true}}"#.utf8)
            try bytes.write(to: policy)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: policy.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policy.path) }
            // Root can read mode-000 files; use a directory for that environment.
            if geteuid() == 0 {
                try FileManager.default.removeItem(at: policy)
                try FileManager.default.createDirectory(at: policy, withIntermediateDirectories: false)
                #expect(!MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root))
            } else {
                #expect(!MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policy.path)
                #expect(try Data(contentsOf: policy) == bytes)
            }
        }
    }

    @Test func inspectionFailureDeniesInsteadOfDefaulting() throws {
        try withPolicyPath { root, policy in
            let trust = policy.deletingLastPathComponent()
            try FileManager.default.removeItem(at: trust)
            try Data("not a directory".utf8).write(to: trust)
            #expect(!MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root))
        }
    }

    @Test func validPolicyLinkReadsFreshValuesAndPreservesBytes() throws {
        try withPolicyPath { root, policy in
            let destination = root.appendingPathComponent("saved-policy.json")
            try FileManager.default.createSymbolicLink(at: policy, withDestinationURL: destination)
            for enabled in [false, true] {
                let bytes = Data("{\"memoryPolicy\":{\"cross_session_recall\":\(enabled)}}".utf8)
                try bytes.write(to: destination, options: .atomic)
                #expect(MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root) == enabled)
                #expect(try Data(contentsOf: destination) == bytes)
            }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: policy.path) == destination.path)
        }
    }

    @Test func absentFieldsKeepDefaultsAndMalformedFieldsDeny() throws {
        try withPolicyPath { root, policy in
            for json in ["{}", #"{"memoryPolicy":{}}"#] {
                try Data(json.utf8).write(to: policy)
                #expect(MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root))
                #expect(!MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: root))
            }
            for json in ["invalid JSON", #"{"memoryPolicy":false}"#,
                         #"{"memoryPolicy":{"cross_session_recall":"true"}}"#] {
                try Data(json.utf8).write(to: policy)
                #expect(!MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: root))
            }
        }
    }
}
