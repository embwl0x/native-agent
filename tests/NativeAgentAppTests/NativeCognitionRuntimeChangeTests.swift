import Foundation
import Testing
import CognitiveSubstrate
import PersistenceCore
@testable import NativeAgentApp

@Test func cognitionRuntimePublishesPayloadFreeOwnerInvalidationAfterEvent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: CognitiveConfiguration(enabled: true, persistenceEnabled: false),
        organismConfigurationOverride: .disabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
    await runtime.bootstrap()
    let stream = await runtime.changes()
    let next = Task { () -> NativeCognitionRuntimeChange? in
        for await change in stream { return change }
        return nil
    }

    await runtime.observe(CognitiveEvent(
        id: "change-test",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "conversation", id: "change-test"),
        sourceClass: .userStated,
        occurredAt: Date(),
        summary: "hello",
        importance: 0.5,
        turnKind: .live
    ))

    let change = try #require(await next.value)
    #expect(change.revision > 0)
    #expect(change.reason == "event:userMessageReceived")
}

@Test func cognitionRuntimePublishesAfterScheduledMicrocycleStateAndTelemetrySettle() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: false,
            workspaceEnabled: true,
            affectEnabled: true,
            backgroundMicrocyclesEnabled: true
        ),
        organismConfigurationOverride: .disabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
    await runtime.bootstrap()
    await runtime.observe(CognitiveEvent(
        id: "microcycle-change-test",
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(type: "conversation", id: "microcycle-change-test"),
        sourceClass: .userStated,
        occurredAt: Date(),
        summary: "settle this field",
        importance: 0.7,
        turnKind: .live
    ))

    let stream = await runtime.changes()
    let terminal = Task { () -> NativeCognitionRuntimeChange? in
        for await change in stream where change.reason == "microcycle_settlement:finished" {
            return change
        }
        return nil
    }
    await runtime.flushPendingMicrocycleForProof()

    let change = try #require(await terminal.value)
    #expect(change.reason == "microcycle_settlement:finished")
    #expect(await runtime.microcycleTelemetrySnapshot().completedCount == 1)
}

@Test func cognitionRuntimePublishesAfterControlMutationWithoutWaitingForPoll() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: CognitiveConfiguration(enabled: true, persistenceEnabled: false),
        organismConfigurationOverride: .disabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
    await runtime.bootstrap()
    let stream = await runtime.changes()
    let next = Task { () -> NativeCognitionRuntimeChange? in
        for await change in stream { return change }
        return nil
    }

    await runtime.setAblation("affect", enabled: true)

    let change = try #require(await next.value)
    #expect(change.reason == "experiment:ablation")
}

@Test func cognitionRuntimePublishesInvalidationForDirectSomaticMutation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: .disabled,
        organismConfigurationOverride: .enabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
    await runtime.bootstrap()
    let stream = await runtime.changes()
    let next = Task { () -> NativeCognitionRuntimeChange? in
        for await change in stream { return change }
        return nil
    }

    await runtime.ingestOrganismSignal(
        kind: .providerFailed,
        sourceOrgan: "provider.test",
        prewarmContext: false
    )

    let change = try #require(await next.value)
    #expect(change.reason == "somatic:providerFailed")
}
