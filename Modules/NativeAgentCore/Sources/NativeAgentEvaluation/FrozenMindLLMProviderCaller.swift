import CryptoKit
import Foundation
import ChatOrchestration
import NativeAgentCore

// MARK: - Exact provider lifecycle capture

/// Correlates the shared provider router's started/terminal events with one
/// Frozen-Mind invocation. The caller binds the invocation id as the LLM
/// session id, so the actual provider/auth transport and effective model come
/// from the real routing chokepoint instead of being inferred from a model
/// prefix after the fact.
public actor FrozenMindProviderLifecycleAudit: LLMCallLifecycleObserving {
    public struct Record: Sendable, Equatable {
        public let started: LLMCallLifecycleEvent
        public let terminal: LLMCallLifecycleEvent

        public var actualTarget: FrozenMindProviderTarget {
            FrozenMindProviderTarget(
                providerID: started.providerId,
                modelID: started.model,
                reasoningEffort: started.reasoningEffort
            )
        }
    }

    private struct Pending: Sendable {
        var started: [LLMCallLifecycleEvent] = []
        var terminal: [LLMCallLifecycleEvent] = []
    }

    private var armedInvocationIDs: Set<String> = []
    private var eventsByInvocationID: [String: Pending] = [:]

    public init() {}

    public func arm(invocationID: String) throws {
        guard !invocationID.isEmpty,
              armedInvocationIDs.insert(invocationID).inserted,
              eventsByInvocationID[invocationID] == nil
        else { throw FrozenMindLLMProviderCallingError.duplicateInvocation(invocationID) }
        eventsByInvocationID[invocationID] = Pending()
    }

    public func observeProviderCall(_ event: LLMCallLifecycleEvent) async {
        guard event.surface == LLMFrozenMindEvaluationProviderCaller.surface,
              let invocationID = event.sessionId,
              armedInvocationIDs.contains(invocationID),
              var pending = eventsByInvocationID[invocationID]
        else { return }

        switch event.phase {
        case .started:
            pending.started.append(event)
        case .succeeded, .failed, .cancelled:
            pending.terminal.append(event)
        }
        eventsByInvocationID[invocationID] = pending
    }

    public func consume(invocationID: String) throws -> Record {
        defer {
            armedInvocationIDs.remove(invocationID)
            eventsByInvocationID.removeValue(forKey: invocationID)
        }
        guard let pending = eventsByInvocationID[invocationID],
              pending.started.count == 1,
              pending.terminal.count == 1,
              let started = pending.started.first,
              let terminal = pending.terminal.first,
              started.id == terminal.id,
              started.providerId == terminal.providerId,
              started.model == terminal.model,
              started.surface == terminal.surface,
              started.sessionId == terminal.sessionId,
              started.streaming == false,
              terminal.streaming == false
        else { throw FrozenMindLLMProviderCallingError.invalidLifecycle(invocationID) }
        return Record(started: started, terminal: terminal)
    }

    public func discard(invocationID: String) {
        armedInvocationIDs.remove(invocationID)
        eventsByInvocationID.removeValue(forKey: invocationID)
    }
}

public enum FrozenMindLLMProviderCallingError: Error, Sendable, Equatable {
    case wrongTarget(expected: String, actual: String)
    case invocationExpired
    case inputDigestMismatch
    case inputTooLarge(actual: Int, maximum: Int)
    case outputTooLarge(actual: Int, maximum: Int)
    case duplicateInvocation(String)
    case invalidLifecycle(String)
}

/// Production Frozen-Mind V2 provider adapter. It uses the ordinary LLMClient
/// boundary (and therefore the same provider/auth routing as chat), but never
/// constructs ChatOrchestration, tools, memory, feedback, or an action owner.
///
/// The exact route and terminal phase are sourced from
/// `FrozenMindProviderLifecycleAudit`, which must also be installed as the
/// SwiftNativeLLMClient lifecycle observer. Both structured and natural passes
/// use the already-frozen model-visible bytes supplied by the V2 runner.
public struct LLMFrozenMindEvaluationProviderCaller: FrozenMindEvaluationProviderCalling {
    public static let surface = "provider_transplant_eval_v2"

    private let target: FrozenMindProviderTarget
    private let client: any LLMClient
    private let lifecycleAudit: FrozenMindProviderLifecycleAudit
    private let configured: Bool
    private let liveHealth: FrozenMindProviderLiveHealth
    private let maximumInputBytes: Int
    private let maximumOutputBytes: Int
    private let now: @Sendable () -> Date

    public init(
        target: FrozenMindProviderTarget,
        client: any LLMClient,
        lifecycleAudit: FrozenMindProviderLifecycleAudit,
        configured: Bool = false,
        liveHealth: FrozenMindProviderLiveHealth = .unknown,
        maximumInputBytes: Int = FrozenMindEvaluationBudget.hardMaximumInputBytesPerCall,
        maximumOutputBytes: Int = FrozenMindEvaluationBudget.hardMaximumOutputBytesPerCall,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.target = target
        self.client = client
        self.lifecycleAudit = lifecycleAudit
        self.configured = configured
        self.liveHealth = liveHealth
        self.maximumInputBytes = min(
            FrozenMindEvaluationBudget.hardMaximumInputBytesPerCall,
            max(0, maximumInputBytes)
        )
        self.maximumOutputBytes = min(
            FrozenMindEvaluationBudget.hardMaximumOutputBytesPerCall,
            max(0, maximumOutputBytes)
        )
        self.now = now
    }

    public func preflight(
        target requestedTarget: FrozenMindProviderTarget,
        manifest _: FrozenMindEvaluationManifest
    ) async throws -> FrozenMindProviderPreflight {
        FrozenMindProviderPreflight(
            requestedTarget: requestedTarget,
            resolvedTarget: target,
            configured: configured,
            liveHealth: liveHealth,
            supportsStrictJSON: true,
            supportsNaturalText: true,
            maximumInputBytes: maximumInputBytes,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    public func invoke(
        _ request: FrozenMindEvaluationProviderRequest
    ) async throws -> FrozenMindEvaluationProviderResult {
        guard request.target == target else {
            throw FrozenMindLLMProviderCallingError.wrongTarget(
                expected: target.routeID,
                actual: request.target.routeID
            )
        }
        guard now() < request.expiresAt else {
            throw FrozenMindLLMProviderCallingError.invocationExpired
        }

        let actualInputDigest = FrozenMindEvaluationManifest.inputDigest(
            system: request.system,
            prompt: request.prompt
        )
        guard actualInputDigest == request.expectedInputDigest else {
            throw FrozenMindLLMProviderCallingError.inputDigestMismatch
        }
        let inputBytes = request.system.utf8.count + request.prompt.utf8.count
        guard inputBytes <= maximumInputBytes else {
            throw FrozenMindLLMProviderCallingError.inputTooLarge(
                actual: inputBytes,
                maximum: maximumInputBytes
            )
        }
        let effectiveOutputMaximum = min(request.maximumOutputBytes, maximumOutputBytes)
        guard effectiveOutputMaximum > 0 else {
            throw FrozenMindLLMProviderCallingError.outputTooLarge(actual: 0, maximum: 0)
        }

        let lifecycleCorrelationID = Self.lifecycleCorrelationID(for: request.invocationID)
        try await lifecycleAudit.arm(invocationID: lifecycleCorrelationID)
        let startedAt = now()
        let output: String
        do {
            output = try await LLMCallContext.$surface.withValue(Self.surface) {
                try await LLMCallContext.$providerId.withValue(target.providerID) {
                    try await LLMCallContext.$reasoningEffort.withValue(target.reasoningEffort) {
                        try await LLMCallContext.$sessionId.withValue(lifecycleCorrelationID) {
                            try await client.complete(
                                prompt: request.prompt,
                                system: request.system,
                                model: target.modelID,
                                surface: Self.surface
                            )
                        }
                    }
                }
            }
        } catch is CancellationError {
            _ = try await lifecycleAudit.consume(invocationID: lifecycleCorrelationID)
            throw CancellationError()
        } catch {
            let record = try await lifecycleAudit.consume(invocationID: lifecycleCorrelationID)
            return result(
                request: request,
                record: record,
                output: nil,
                actualInputDigest: actualInputDigest,
                inputBytes: inputBytes,
                latencyMilliseconds: milliseconds(since: startedAt)
            )
        }

        let outputBytes = output.utf8.count
        let record = try await lifecycleAudit.consume(invocationID: lifecycleCorrelationID)
        return result(
            request: request,
            record: record,
            output: outputBytes <= effectiveOutputMaximum ? output : nil,
            actualOutputBytes: outputBytes,
            actualInputDigest: actualInputDigest,
            inputBytes: inputBytes,
            latencyMilliseconds: milliseconds(since: startedAt)
        )
    }

    private func result(
        request: FrozenMindEvaluationProviderRequest,
        record: FrozenMindProviderLifecycleAudit.Record,
        output: String?,
        actualOutputBytes: Int? = nil,
        actualInputDigest: String,
        inputBytes: Int,
        latencyMilliseconds: Int
    ) -> FrozenMindEvaluationProviderResult {
        let terminalPhase: FrozenMindProviderTerminalPhase = switch record.terminal.phase {
        case .started: .failed
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
        return FrozenMindEvaluationProviderResult(
            invocationID: request.invocationID,
            scenarioID: request.scenarioID,
            attempt: request.attempt,
            pass: request.pass,
            requestedTarget: request.target,
            actualTarget: record.actualTarget,
            canonicalPacketDigest: request.canonicalPacketDigest,
            actualInputDigest: actualInputDigest,
            terminalPhase: terminalPhase,
            output: output,
            actualOutputBytes: actualOutputBytes,
            logicalInputTokens: Self.logicalTokens(forByteCount: inputBytes),
            logicalOutputTokens: Self.logicalTokens(forByteCount: output?.utf8.count ?? 0),
            cacheReadBytes: 0,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    private func milliseconds(since date: Date) -> Int {
        max(0, Int(now().timeIntervalSince(date) * 1_000))
    }

    private static func logicalTokens(forByteCount byteCount: Int) -> Int {
        byteCount == 0 ? 0 : max(1, (byteCount + 3) / 4)
    }

    public static func lifecycleCorrelationID(for invocationID: String) -> String {
        let digest = SHA256.hash(data: Data(invocationID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "frozen-mind-v2:" + digest
    }
}

// MARK: - Explicit local fixture artifacts

public enum FrozenMindFixtureContentClass: String, Codable, Sendable {
    case generatedNonPersonal = "generated_nonpersonal"
    case personal
}

public struct FrozenMindScenarioInputArtifact: Codable, Sendable, Equatable {
    public let scenarioID: String
    public let system: String

    public init(scenarioID: String, system: String) {
        self.scenarioID = String(scenarioID.prefix(120))
        self.system = String(system.prefix(128_000))
    }
}

/// Deliberately separate from the payload-free evaluation report. This local
/// file is an explicit carrier for model-visible fixture bytes; the runner
/// reads it transiently and never copies those bytes into its report.
public struct FrozenMindEvaluationFixtureArtifact: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let contentClass: FrozenMindFixtureContentClass
    public let epochManifest: FrozenMindEpochManifest
    public let evaluationManifest: FrozenMindEvaluationManifest
    public let inputs: [FrozenMindScenarioInputArtifact]

    public init(
        contentClass: FrozenMindFixtureContentClass,
        epochManifest: FrozenMindEpochManifest,
        evaluationManifest: FrozenMindEvaluationManifest,
        inputs: [String: FrozenMindScenarioInput]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.contentClass = contentClass
        self.epochManifest = epochManifest
        self.evaluationManifest = evaluationManifest
        self.inputs = inputs.values
            .map { FrozenMindScenarioInputArtifact(scenarioID: $0.scenarioID, system: $0.system) }
            .sorted { $0.scenarioID < $1.scenarioID }
    }

    public func validatedInputs() throws -> [String: FrozenMindScenarioInput] {
        guard schemaVersion == Self.schemaVersion,
              evaluationManifest.epochManifestDigest == epochManifest.manifestDigest,
              evaluationManifest.canonicalPacketDigest == epochManifest.canonicalPacketDigest,
              evaluationManifest.targets == epochManifest.targets,
              Set(inputs.map(\.scenarioID)).count == inputs.count,
              Set(inputs.map(\.scenarioID)) == Set(evaluationManifest.scenarios.map(\.id)),
              contentClass != .generatedNonPersonal || epochManifest.privateDataCategories.isEmpty
        else { throw FrozenMindEvaluationError.invalidManifest }

        let values = Dictionary(uniqueKeysWithValues: inputs.map {
            ($0.scenarioID, FrozenMindScenarioInput(scenarioID: $0.scenarioID, system: $0.system))
        })
        let rebuilt = try FrozenMindEvaluationManifest(
            epochManifest: epochManifest,
            mode: evaluationManifest.mode,
            targets: evaluationManifest.targets,
            contracts: evaluationManifest.scenarios.map(\.contract),
            inputs: values,
            thresholds: evaluationManifest.thresholds,
            budget: evaluationManifest.budget,
            createdAt: evaluationManifest.createdAt,
            expiresAt: evaluationManifest.expiresAt
        )
        guard rebuilt == evaluationManifest else {
            throw FrozenMindEvaluationError.invalidManifest
        }
        return values
    }
}

/// Exact locally supplied approval artifact. It remains default-deny: merely
/// having a personal fixture does not authorize egress, and generated fixtures
/// cannot smuggle private categories through the nonpersonal lane.
public struct FrozenMindEvaluationLocalAuthorizationArtifact: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let evaluationManifestDigest: String
    public let epochManifestDigest: String
    public let scenarioVersion: String
    public let approvedTargets: [FrozenMindProviderTarget]
    public let privateDataCategories: [String]
    public let maximumCalls: Int
    public let maximumInputBytesPerCall: Int
    public let maximumOutputBytesPerCall: Int
    public let maximumTotalInputBytes: Int
    public let maximumTotalOutputBytes: Int
    public let maximumLogicalTokens: Int
    public let approvedAt: Date
    public let expiresAt: Date
    public let retentionExpiresAt: Date
    public let localApprovalReceiptID: String
    public let controlAuthority: Bool

    public init(authorization: FrozenMindEvaluationAuthorization) {
        self.schemaVersion = Self.schemaVersion
        self.evaluationManifestDigest = authorization.evaluationManifestDigest
        self.epochManifestDigest = authorization.epochManifestDigest
        self.scenarioVersion = authorization.scenarioVersion
        self.approvedTargets = authorization.approvedTargets.sorted()
        self.privateDataCategories = authorization.privateDataCategories
        self.maximumCalls = authorization.maximumCalls
        self.maximumInputBytesPerCall = authorization.maximumInputBytesPerCall
        self.maximumOutputBytesPerCall = authorization.maximumOutputBytesPerCall
        self.maximumTotalInputBytes = authorization.maximumTotalInputBytes
        self.maximumTotalOutputBytes = authorization.maximumTotalOutputBytes
        self.maximumLogicalTokens = authorization.maximumLogicalTokens
        self.approvedAt = authorization.approvedAt
        self.expiresAt = authorization.expiresAt
        self.retentionExpiresAt = authorization.retentionExpiresAt
        self.localApprovalReceiptID = authorization.localApprovalReceiptID
        self.controlAuthority = authorization.controlAuthority
    }

    public func validatedAuthorization(
        manifest: FrozenMindEvaluationManifest,
        epochManifest: FrozenMindEpochManifest
    ) throws -> FrozenMindEvaluationAuthorization {
        guard schemaVersion == Self.schemaVersion,
              evaluationManifestDigest == manifest.manifestDigest,
              epochManifestDigest == epochManifest.manifestDigest,
              scenarioVersion == manifest.fixtureVersion,
              Set(approvedTargets) == Set(manifest.targets),
              approvedTargets.count == Set(approvedTargets).count,
              privateDataCategories == epochManifest.privateDataCategories,
              maximumCalls == manifest.budget.maximumCalls,
              maximumInputBytesPerCall == manifest.budget.maximumInputBytesPerCall,
              maximumOutputBytesPerCall == manifest.budget.maximumOutputBytesPerCall,
              maximumTotalInputBytes == manifest.budget.maximumTotalInputBytes,
              maximumTotalOutputBytes == manifest.budget.maximumTotalOutputBytes,
              maximumLogicalTokens == manifest.budget.maximumLogicalTokens,
              approvedAt < expiresAt,
              retentionExpiresAt >= expiresAt,
              !localApprovalReceiptID.isEmpty,
              controlAuthority == false
        else { throw FrozenMindEvaluationError.authorizationRejected }

        let authorization = FrozenMindEvaluationAuthorization(
            manifest: manifest,
            epochManifest: epochManifest,
            approvedTargets: Set(approvedTargets),
            approvedAt: approvedAt,
            expiresAt: expiresAt,
            retentionExpiresAt: retentionExpiresAt,
            localApprovalReceiptID: localApprovalReceiptID
        )
        guard authorization.evaluationManifestDigest == evaluationManifestDigest,
              authorization.epochManifestDigest == epochManifestDigest,
              authorization.scenarioVersion == scenarioVersion,
              authorization.approvedTargets == Set(approvedTargets),
              authorization.privateDataCategories == privateDataCategories,
              authorization.maximumCalls == maximumCalls,
              authorization.maximumInputBytesPerCall == maximumInputBytesPerCall,
              authorization.maximumOutputBytesPerCall == maximumOutputBytesPerCall,
              authorization.maximumTotalInputBytes == maximumTotalInputBytes,
              authorization.maximumTotalOutputBytes == maximumTotalOutputBytes,
              authorization.maximumLogicalTokens == maximumLogicalTokens,
              authorization.approvedAt == approvedAt,
              authorization.expiresAt == expiresAt,
              authorization.retentionExpiresAt == retentionExpiresAt,
              authorization.localApprovalReceiptID == localApprovalReceiptID,
              authorization.controlAuthority == controlAuthority
        else { throw FrozenMindEvaluationError.authorizationRejected }
        return authorization
    }
}

public struct ExactLocalFrozenMindEvaluationEgressAuthorizer: FrozenMindEvaluationEgressAuthorizing {
    private let expected: FrozenMindEvaluationAuthorization

    public init(expected: FrozenMindEvaluationAuthorization) {
        self.expected = expected
    }

    public func validate(
        _ authorization: FrozenMindEvaluationAuthorization,
        manifest _: FrozenMindEvaluationManifest,
        epochManifest _: FrozenMindEpochManifest,
        at _: Date
    ) async -> Bool {
        authorization == expected
    }
}

public struct GeneratedNonPersonalFrozenMindEvaluationEgressAuthorizer: FrozenMindEvaluationEgressAuthorizing {
    public init() {}

    public func validate(
        _ authorization: FrozenMindEvaluationAuthorization,
        manifest: FrozenMindEvaluationManifest,
        epochManifest: FrozenMindEpochManifest,
        at date: Date
    ) async -> Bool {
        epochManifest.privateDataCategories.isEmpty
            && authorization.evaluationManifestDigest == manifest.manifestDigest
            && authorization.epochManifestDigest == epochManifest.manifestDigest
            && authorization.approvedAt <= date
            && authorization.expiresAt > date
            && authorization.localApprovalReceiptID.hasPrefix("generated-nonpersonal:")
    }
}
