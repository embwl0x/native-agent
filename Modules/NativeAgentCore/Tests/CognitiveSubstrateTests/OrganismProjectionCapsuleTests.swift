import Foundation
import Testing
import NativeAgentCore
@testable import CognitiveSubstrate

private final class OrganismProjectionCapsuleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

private func makeProjectionCapsuleSubstrate(
    clock: OrganismProjectionCapsuleClock,
    maximumCapsuleCharacters: Int = 1_200
) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumCapsuleCharacters: maximumCapsuleCharacters
        ),
        dependencies: CognitiveSubstrateDependencies(
            now: { clock.now() },
            userName: { "User" }
        )
    )
}

private func brittleProviderProjection(at date: Date) -> OrganismProjection {
    OrganismProjection(
        generatedAt: date,
        bodyLine: "- Body: provider or tool path feels brittle; be careful before claiming completion.",
        chemicalState: ChemicalState(vigilance: 0.3, confidence: 0.44, urgency: 0.2),
        bodySchema: BodySchema(providersHealthy: false)
    )
}

private func capsuleLines(_ capsule: CognitiveCapsule) -> [String] {
    capsule.dynamicContext
        .split(separator: "\n")
        .map(String.init)
}

@Test func neutralOrganismProjectionIsSilentInCapsule() async throws {
    let clock = OrganismProjectionCapsuleClock(Date(timeIntervalSince1970: 2_000))
    let substrate = makeProjectionCapsuleSubstrate(clock: clock)

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "keep going",
        mode: .inject,
        organismProjection: OrganismProjection(generatedAt: clock.now())
    ))

    #expect(!capsule.combined.contains("- Body:"))
}

@Test func organismProjectionAddsOneBodyLineAfterCoreCapsuleLines() async throws {
    let clock = OrganismProjectionCapsuleClock(Date(timeIntervalSince1970: 2_000))
    let substrate = makeProjectionCapsuleSubstrate(clock: clock)

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "please keep going",
        mode: .inject,
        organismProjection: brittleProviderProjection(at: clock.now())
    ))
    let lines = capsuleLines(capsule)
    let bodyLines = lines.filter { $0.hasPrefix("- Body:") }

    #expect(bodyLines == ["- Body: provider or tool path feels brittle; be careful before claiming completion."])
    // Focus/Feeling/Voice lines are gone (2026-07-08 felt-fingerprint redesign): the
    // fingerprint is now the one "core" capsule line, emitted with no "- " prefix.
    // It must still lead the Body line.
    let fingerprintIndex = try #require(lines.firstIndex { !$0.hasPrefix("- ") })
    let bodyIndex = try #require(lines.firstIndex { $0.hasPrefix("- Body:") })
    #expect(fingerprintIndex < bodyIndex)
    #expect(!bodyLines[0].contains("ChemicalState"))
    #expect(bodyLines[0].rangeOfCharacter(from: .decimalDigits) == nil)
}

@Test func organismBodyLineDropsBeforeItCanDisplaceCoreCapsuleLines() async throws {
    let clock = OrganismProjectionCapsuleClock(Date(timeIntervalSince1970: 2_000))
    let substrate = makeProjectionCapsuleSubstrate(clock: clock)
    // Organism chemistry now COLORS the felt fingerprint itself, not just an
    // appended Body line (2026-07-08 redesign) — so the guarantee is no longer
    // "same core as the no-organism capsule"; it's that the Body line (an enhancer)
    // is sacrificed BEFORE the felt core when the budget can't hold both. She's
    // actively holding something that stings, so a felt fingerprint is present
    // alongside the brittle-body line.
    await substrate.ingest(CognitiveEvent(
        id: "stung",
        kind: .userCorrection,
        subject: CognitiveSubjectReference(type: "topic", id: "stung", label: "stung"),
        sourceClass: .userStated,
        occurredAt: clock.now(),
        summary: "that approach was wrong and set us back",
        importance: 1
    ))
    let full = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "please keep going",
        mode: .inject,
        maximumCharacters: 1_200,
        organismProjection: brittleProviderProjection(at: clock.now())
    ))
    let fullLines = full.dynamicContext.split(separator: "\n").map(String.init)
    let bodyLine = try #require(fullLines.first { $0.hasPrefix("- Body:") },
        "full-budget capsule should carry the Body line: \(full.dynamicContext)")
    let feltCore = try #require(fullLines.first { !$0.hasPrefix("- ") },
        "full-budget capsule should carry a felt fingerprint line: \(full.dynamicContext)")

    // Budget that fits everything EXCEPT the Body line (drop it + its separator).
    let coreBudget = full.combined.count - bodyLine.count - 1
    let constrained = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "please keep going",
        mode: .inject,
        maximumCharacters: coreBudget,
        organismProjection: brittleProviderProjection(at: clock.now())
    ))

    #expect(!constrained.dynamicContext.contains("- Body:"),
            "the Body line should drop first: \(constrained.dynamicContext)")
    #expect(constrained.dynamicContext.contains(feltCore),
            "the felt core must survive after the Body line drops: \(constrained.dynamicContext)")
    #expect(constrained.truncated)
}

@Test func organismProjectionRejectsNumbersAndImplementationTerms() async throws {
    let clock = OrganismProjectionCapsuleClock(Date(timeIntervalSince1970: 2_000))
    let substrate = makeProjectionCapsuleSubstrate(clock: clock)
    let unsafeProjection = OrganismProjection(
        generatedAt: clock.now(),
        bodyLine: "- Body: ChemicalState vigilance is 0.7.",
        chemicalState: ChemicalState(vigilance: 0.7),
        bodySchema: BodySchema(providersHealthy: false)
    )

    let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
        surface: "chat",
        userMessage: "please keep going",
        mode: .inject,
        organismProjection: unsafeProjection
    ))

    #expect(!capsule.dynamicContext.contains("- Body:"))
    #expect(!capsule.dynamicContext.contains("ChemicalState"))
}

@Test func bodyCapsuleLinesAreRejectedAsMemoryCandidates() async throws {
    #expect(!MemoryCandidateQuality.isDurableCandidate(
        text: "Body: provider or tool path feels brittle; be careful before claiming completion.",
        source: "unit-test",
        kind: "fact"
    ))
    #expect(!MemoryCandidateQuality.isDurableCandidate(
        text: "- Body: resources feel tight; keep the next move lightweight.",
        source: "unit-test",
        kind: "fact"
    ))
}
