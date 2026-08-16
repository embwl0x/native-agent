import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Pairing secret authority", .serialized)
struct PairingSecretManagerTests {
    private func tempSecretURL() throws -> (root: URL, secret: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingSecret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("icloud_pairing_secret.bin"))
    }

    @Test func missingSecretBootstrapsDurablyWithStrictMode() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let secret = try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret)

        #expect(secret.count == 32)
        #expect(try Data(contentsOf: fixture.secret) == secret)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.secret.path)
        #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func validExistingSecretIsReusedExactly() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = Data(repeating: 0x7a, count: 32)
        try expected.write(to: fixture.secret)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.secret.path
        )

        #expect(try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret) == expected)
    }

    @Test func shortExistingSecretFailsAndRemainsBytePreserved() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = Data("too-short".utf8)
        try invalid.write(to: fixture.secret)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.secret.path
        )

        #expect(throws: (any Error).self) {
            _ = try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret)
        }
        #expect(try Data(contentsOf: fixture.secret) == invalid)
    }

    @Test func oversizedExistingSecretFailsAndRemainsBytePreserved() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = Data(repeating: 0xaa, count: 33)
        try invalid.write(to: fixture.secret)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.secret.path
        )

        #expect(throws: (any Error).self) {
            _ = try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret)
        }
        #expect(try Data(contentsOf: fixture.secret) == invalid)
    }

    @Test func explicitDeletionRefusesInvalidStateAndPreservesItsBytes() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = Data("damaged-authority".utf8)
        try invalid.write(to: fixture.secret)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.secret.path
        )

        #expect(throws: (any Error).self) {
            try PairingSecretManager.deleteSecret(at: fixture.secret)
        }
        #expect(try Data(contentsOf: fixture.secret) == invalid)
    }

    @Test func unsafeModeFailsWithoutSilentPermissionRepair() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = Data(repeating: 0x5b, count: 32)
        try expected.write(to: fixture.secret)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.secret.path
        )

        #expect(throws: (any Error).self) {
            _ = try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret)
        }
        #expect(try Data(contentsOf: fixture.secret) == expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.secret.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
    }

    @Test func symlinkSecretFailsWithoutReadingOrReplacingTarget() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.root.appendingPathComponent("external-secret")
        let expected = Data(repeating: 0x33, count: 32)
        try expected.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: fixture.secret, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            _ = try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.secret.path) == target.path)
        #expect(try Data(contentsOf: target) == expected)
    }

    @Test func nonregularSecretFailsWithoutDeletingContents() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.secret, withIntermediateDirectories: true)
        let marker = fixture.secret.appendingPathComponent("preserve-me")
        let bytes = Data("preserve".utf8)
        try bytes.write(to: marker)

        #expect(throws: (any Error).self) {
            _ = try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret)
        }
        #expect(try Data(contentsOf: marker) == bytes)
    }

    @Test func missingSecretNeverReturnsEphemeralBytesWhenDirectoryIsNotWritable() throws {
        let fixture = try tempSecretURL()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.root.path
            )
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.root.path
        )

        #expect(throws: (any Error).self) {
            _ = try PairingSecretManager.loadOrGenerateSecret(at: fixture.secret)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.secret.path))
    }

    @Test func explicitRotationAtomicallyReplacesAndReturnsCanonicalBytes() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSecret = Data(repeating: 0x19, count: 32)
        try oldSecret.write(to: fixture.secret)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.secret.path
        )

        let rotated = try PairingSecretManager.rotateSecret(at: fixture.secret)

        #expect(rotated.count == 32)
        #expect(rotated != oldSecret)
        #expect(try Data(contentsOf: fixture.secret) == rotated)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.secret.path)
        #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.contains(".rotate.") }
        #expect(leftovers.isEmpty)
    }

    @Test func explicitRotationRefusesInvalidAuthorityWithoutRepairingIt() throws {
        let fixture = try tempSecretURL()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = Data("preserve-invalid-authority".utf8)
        try invalid.write(to: fixture.secret)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.secret.path
        )

        #expect(throws: (any Error).self) {
            _ = try PairingSecretManager.rotateSecret(at: fixture.secret)
        }
        #expect(try Data(contentsOf: fixture.secret) == invalid)
    }
}
