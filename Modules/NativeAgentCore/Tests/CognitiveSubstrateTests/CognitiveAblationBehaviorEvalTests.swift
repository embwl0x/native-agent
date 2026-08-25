import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Eval coverage ledger — `substrate.ablation.control`.
// The Observatory's Workspace ablation is a real intervention over the same
// read projection that reaches its panel and a frozen turn capsule.
@Test func workspaceAblation_changesLiveAndFrozenWorkspaceProjection() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let mind = CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            maximumWorkspaceItems: 8
        ),
        dependencies: CognitiveSubstrateDependencies(now: { now })
    )
    await mind.ingest(CognitiveEvent(
        id: "workspace-ablation",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "topic", id: "auction-house", label: "Auction House"),
        sourceClass: .userStated,
        occurredAt: now,
        summary: "Check the auction house listings.",
        importance: 0.9
    ))

    #expect(!(await mind.workspaceSnapshot()).items.isEmpty)
    #expect(!(await mind.frozenRead(at: now)).workspace.items.isEmpty)

    await mind.setAblation("workspace", enabled: false)
    #expect((await mind.workspaceSnapshot()).items.isEmpty)
    #expect((await mind.frozenRead(at: now)).workspace.items.isEmpty)

    await mind.setAblation("workspace", enabled: true)
    #expect(!(await mind.workspaceSnapshot()).items.isEmpty)
    #expect(!(await mind.frozenRead(at: now)).workspace.items.isEmpty)
}
