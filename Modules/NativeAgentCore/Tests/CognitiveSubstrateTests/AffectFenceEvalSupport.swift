import Foundation
import PersistenceCore
@testable import CognitiveSubstrate

// Shared fixtures for the `core.substrate.affect` coverage-ledger evals
// (docs/evals/ledger.json). One clock + one substrate factory + one node
// builder, so the six suites below do not each grow their own copy.
//
// Everything here is HERMETIC: no data root unless a suite asks for one, and
// the one that does gets a fresh temp directory it owns.

final class AffectFenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) { self.current = current }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

enum AffectFenceFixture {

    static func configuration(
        capsuleInjectionEnabled: Bool = true,
        affectEnabled: Bool = true,
        persistenceEnabled: Bool = false,
        maximumCapsuleCharacters: Int = 1_800
    ) -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: persistenceEnabled,
            workspaceEnabled: true,
            capsuleInjectionEnabled: capsuleInjectionEnabled,
            affectEnabled: affectEnabled,
            maximumCapsuleCharacters: maximumCapsuleCharacters
        )
    }

    static func substrate(
        clock: AffectFenceClock,
        configuration: CognitiveConfiguration? = nil,
        dynamics: PersonalityDynamicsConfiguration = .default,
        store: CognitiveSQLiteStore? = nil
    ) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: configuration ?? Self.configuration(),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                userName: { "User" },
                dynamics: { dynamics }
            ),
            store: store
        )
    }

    /// A temp data root this test owns outright. Never `data/`.
    static func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nativeagent-affect-fence-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func node(
        summary: String,
        kind: CognitiveNodeKind = .conversationFocus,
        subjectType: String = "topic",
        metadata: [String: JSONValue] = [:],
        valence: Double = 0,
        arousal: Double = 0,
        warmth: Double = 0,
        createdAt: Date,
        lastActivatedAt: Date? = nil
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(),
            kind: kind,
            subjectReference: CognitiveSubjectReference(
                type: subjectType,
                id: "affect-fence-\(UUID().uuidString)",
                label: "topic"),
            activation: 0.9,
            salience: 0.9,
            confidence: 0.8,
            sourceClass: .userStated,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt ?? createdAt,
            decayHalfLife: 100_000,
            summary: summary,
            metadata: metadata,
            emotionalValence: valence,
            emotionalArousal: arousal,
            emotionalWarmth: warmth)
    }

    static func capsuleRequest(
        _ message: String = "keep going",
        sessionId: String? = "affect-fence-session",
        mode: CognitiveCapsuleMode = .inject,
        maximumCharacters: Int? = nil
    ) -> CognitiveCapsuleRequest {
        CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: message,
            sessionId: sessionId,
            mode: mode,
            maximumCharacters: maximumCharacters)
    }
}
