import Foundation
import AuthoredCapabilities
import CognitiveSubstrate
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ApprovalInbox
import ChatToolRuntime
import AgentConversations
import Context
import ContextFlow
import MemoryV2
import PersonaEngine
import Desk
import Experiences
import Studio
import Transcripts
// Blueprint: | `NativeCognitionRuntime+Readouts.swift` | `NativeCognitionRuntime` change stream, Observatory, Doctor and capsule readouts; `GrowthWeekFace` binds frozen facts to the part face cache |

extension NativeCognitionRuntime {
    public func changes() -> AsyncStream<NativeCognitionRuntimeChange> {
        let id = UUID()
        let pair = AsyncStream<NativeCognitionRuntimeChange>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        changeContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(id) }
        }
        return pair.stream
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    public func publishRuntimeChange(reason: String) {
        changeRevision &+= 1
        let change = NativeCognitionRuntimeChange(
            revision: changeRevision,
            occurredAt: now(),
            reason: String(reason.prefix(96))
        )
        for continuation in changeContinuations.values {
            continuation.yield(change)
        }
    }

    public func substrateForIntegration() async -> CognitiveSubstrate {
        await bootstrap()
        return substrate
    }

    public func observatoryDetail() async -> CognitiveObservatoryDetail {
        await bootstrap()
        let inspectFixedAt = now()
        let organism = await organismKernel.refreshBodySchemaAndFrozenRead(
            await organismBodySample(at: inspectFixedAt), integratesChemistry: false,
            canonicalAffect: await substrate.canonicalAffectProjection(at: inspectFixedAt), fixedAt: inspectFixedAt)
        let read = await substrate.frozenRead(at: inspectFixedAt)
        let configuration = read.configuration
        // One inspection supplies felt mode and cold-start preview without consuming
        // cadence; live previews mirror the last delivered capsule.
        let inspectRequest = requestWithOrganismProjection(
            CognitiveCapsuleRequest(
                surface: "chat",
                userMessage: lastInjectedCapsule?.userMessage ?? "observatory preview",
                mode: .inspectOnly,
                maximumCharacters: min(1_200, configuration.maximumCapsuleCharacters)
            ),
            projection: organism.projection,
            toward: organism.toward,
            at: inspectFixedAt
        )
        // All workspace-derived fields share the same substrate read epoch.
        let feltMode = await substrate.feltModeReading(for: inspectRequest, from: read)

        let capsulePreview: CognitiveCapsule?
        let capsulePreviewInfo: CapsulePreviewInfo?
        if let last = lastInjectedCapsule {
            capsulePreview = last.capsule
            capsulePreviewInfo = CapsulePreviewInfo(
                source: .liveInjected,
                userMessage: last.userMessage,
                at: last.capsule.generatedAt
            )
        } else {
            let synthetic = await substrate.compileFrozenCapsulePresentation(inspectRequest, from: read).capsule
            let nonEmpty = synthetic.combined.isEmpty ? nil : synthetic
            capsulePreview = nonEmpty
            capsulePreviewInfo = nonEmpty == nil ? nil : CapsulePreviewInfo(source: .synthetic, userMessage: nil, at: nil)
        }
        let receiptRead = await substrate.receiptReadSnapshot()
        let schemas = await substrate.schemaProposalSnapshot()
        let timeline = await substrate.developmentalTimelineSnapshot(proposals: schemas, limit: 240)
        return CognitiveObservatoryDetail(
            configuration: configuration,
            summary: await substrate.observatorySnapshot(from: read),
            substrate: read.snapshot,
            workspace: read.workspace,
            associations: await substrate.associationSnapshot(),
            schemaProposals: schemas,
            developmentalTimeline: Array(timeline.prefix(40)),
            growthWeek: await substrate.growthWeek(from: timeline),
            reflections: await substrate.reflectionReceiptSnapshot(),
            receiptRead: receiptRead,
            organism: organism.snapshot,
            capsulePreview: capsulePreview,
            capsulePreviewInfo: capsulePreviewInfo,
            feltMode: feltMode
        )
    }

    public func doctorRead() async -> CognitiveDoctorRead? {
        guard let bootstrapTask else { return nil }
        await bootstrapTask.value
        let date = now()
        let cognition = await substrate.frozenRead(at: date)
        let organism = await organismKernel.frozenRead(at: date)
        return CognitiveDoctorRead(
            configuration: cognition.configuration,
            affect: cognition.affect,
            substrate: cognition.snapshot,
            workspace: cognition.workspace,
            associations: await substrate.doctorAssociationSnapshot(at: date),
            receiptRead: await substrate.receiptReadSnapshot(),
            organism: organism.snapshot,
            capsulePreviewInfo: lastInjectedCapsule.map {
                CapsulePreviewInfo(source: .liveInjected, userMessage: $0.userMessage, at: $0.capsule.generatedAt)
            }
        )
    }

    public func subconsciousRuntimeState() async -> NativeSubconsciousRuntimeState {
        let configuration = await substrate.configurationSnapshot()
        let organism = await organismKernel.snapshot()
        return NativeSubconsciousRuntimeState(
            enabled: configuration.enabled,
            capsuleEnabled: configuration.capsuleInjectionEnabled,
            backgroundEnabled: configuration.backgroundMicrocyclesEnabled,
            reflectionEnabled: configuration.reflectiveCallsEnabled,
            reflectionBudget: configuration.dailyReflectionCallBudget,
            organismEnabled: organism.enabled
        )
    }


    public func lastInjectedCapsuleBridgeSummary() async -> CognitiveBridgeCapsuleSummary {
        guard let last = lastInjectedCapsule else {
            return CognitiveBridgeCapsuleSummary(
                source: "none",
                generatedAt: nil,
                hasBodyLine: false,
                bodyLine: nil,
                dynamicContextCharacters: 0,
                truncated: nil
            )
        }
        let bodyLine = Self.bodyLine(inCapsuleDynamicContext: last.capsule.dynamicContext)
        return CognitiveBridgeCapsuleSummary(
            source: "live_injected",
            generatedAt: last.capsule.generatedAt,
            hasBodyLine: bodyLine != nil,
            bodyLine: bodyLine,
            dynamicContextCharacters: last.capsule.dynamicContext.count,
            truncated: last.capsule.truncated
        )
    }
}

/// The source epoch belongs to this readout, publication ordering to L0's
/// LatestRead. No projection helper is ever launched from a view render.
actor GrowthWeekFace {
    private let faces: Task<PartFaces, Never>
    private var previous: JSONValue?
    private var epoch: UInt64 = 0

    init(dataRoot: URL, host: any CognitionHost) {
        faces = Task { @MainActor in
            PartFaces(dataRoot: dataRoot) { id, input, version in
                await host.readoutFace(id: id, input: input, version: version, dataRoot: dataRoot)
            }
        }
    }

    func read(_ input: JSONValue) async -> PartFaceSnapshot {
        // Native window membership is in the frozen packet. An unchanged
        // read reuses the face; an edited part invalidates it through L0.
        if input != previous { epoch &+= 1; previous = input }
        let selectedEpoch = epoch
        return await faces.value.sourceChanged(id: "growth-week", epoch: selectedEpoch, input: input)
    }
}
