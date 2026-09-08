import Foundation
import NativeAgentCore
import NativeAgentEvaluation
import ChatOrchestration
import ProviderRouting

extension ChatDriveMain {
    static func runProviderTransplantEvalV2(
        fixturePath: String,
        authorizationPath: String?,
        outputPath: String?,
        publicSafeMode: Bool
    ) async throws {
        // Public-safe mode is a process boundary, not merely a provider-runner
        // option. Refuse before opening artifacts, registries, or output paths
        // so the env override is both no-egress and byte-preserving.
        guard !publicSafeMode else { throw FrozenMindEvaluationError.publicSafeMode }
        // V2 intentionally constructs only the configured provider router and
        // LLM adapters. It never constructs ChatOrchestration, persona, memory,
        // cognition, tools, feedback, or an action dispatcher.
        let fixtureData = try readBoundedFrozenMindArtifact(path: fixturePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(FrozenMindEvaluationFixtureArtifact.self, from: fixtureData)
        let inputs: [String: FrozenMindScenarioInput]
        switch fixture.contentClass {
        case .generatedNonPersonal:
            // Generated egress is authorized only for the exact factory-owned
            // closed fixture. A caller-controlled, merely self-consistent JSON
            // artifact must not be able to relabel personal bytes as generated.
            inputs = try FrozenMindGeneratedFixtureFactory.validatedGeneratedInputs(fixture)
        case .personal:
            inputs = try fixture.validatedInputs()
        }

        let authorization: FrozenMindEvaluationAuthorization
        let authorizer: any FrozenMindEvaluationEgressAuthorizing
        switch fixture.contentClass {
        case .generatedNonPersonal:
            guard authorizationPath == nil else {
                throw FrozenMindEvaluationError.authorizationRejected
            }
            let now = Date()
            let expiresAt = min(fixture.epochManifest.expiresAt, fixture.evaluationManifest.expiresAt)
            authorization = FrozenMindEvaluationAuthorization(
                manifest: fixture.evaluationManifest,
                epochManifest: fixture.epochManifest,
                approvedTargets: Set(fixture.evaluationManifest.targets),
                approvedAt: now.addingTimeInterval(-1),
                expiresAt: expiresAt,
                retentionExpiresAt: expiresAt,
                localApprovalReceiptID: "generated-nonpersonal:\(fixture.evaluationManifest.manifestDigest)"
            )
            authorizer = GeneratedNonPersonalFrozenMindEvaluationEgressAuthorizer()

        case .personal:
            guard let authorizationPath else {
                throw FrozenMindEvaluationError.authorizationRejected
            }
            let authorizationData = try readBoundedFrozenMindArtifact(
                path: authorizationPath,
                maximumBytes: 256 * 1_024
            )
            let artifact = try decoder.decode(
                FrozenMindEvaluationLocalAuthorizationArtifact.self,
                from: authorizationData
            )
            authorization = try artifact.validatedAuthorization(
                manifest: fixture.evaluationManifest,
                epochManifest: fixture.epochManifest
            )
            authorizer = ExactLocalFrozenMindEvaluationEgressAuthorizer(expected: authorization)
        }

        let lifecycleAudit = FrozenMindProviderLifecycleAudit()
        let router = SwiftNativeProviderRouting()
        let llm = SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(),
            openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            xaiOAuthDirect: XAIOAuthDirectAdapter(),
            moonshot: MoonshotAdapter(),
            kimiCode: AnthropicAdapter.kimiCode(),
            openRouter: OpenRouterAdapter(),
            lifecycleObserver: lifecycleAudit
        )
        let providers = (try? await router.listProviders()) ?? []
        let providersByID = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pairs: [(FrozenMindProviderTarget, any FrozenMindEvaluationProviderCalling)] =
            fixture.evaluationManifest.targets.map { target in
                let provider = providersByID[target.providerID]
                let configured = provider?.configured == true
                let lastError = provider?.lastError?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    target,
                    LLMFrozenMindEvaluationProviderCaller(
                        target: target,
                        client: llm,
                        lifecycleAudit: lifecycleAudit,
                        configured: configured,
                        liveHealth: configured && (lastError?.isEmpty ?? true)
                            ? .healthy : .unavailable,
                        maximumInputBytes: fixture.evaluationManifest.budget.maximumInputBytesPerCall,
                        maximumOutputBytes: fixture.evaluationManifest.budget.maximumOutputBytesPerCall
                    )
                )
            }
        let callers = Dictionary(uniqueKeysWithValues: pairs)
        let revisions = frozenMindArtifactRevisions(fixture.epochManifest)
        let report = try await FrozenMindEvaluationRunner.run(
            epochManifest: fixture.epochManifest,
            manifest: fixture.evaluationManifest,
            inputs: inputs,
            callers: callers,
            authorization: authorization,
            authorizer: authorizer,
            publicSafeMode: publicSafeMode,
            beforeRevisions: { revisions },
            afterRevisions: { revisions }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let reportData = try encoder.encode(report)
        guard reportData.count <= 32 * 1_024 * 1_024 else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        if let outputPath {
            let url = URL(fileURLWithPath: outputPath).standardizedFileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try reportData.write(to: url, options: .atomic)
            _ = chmod(url.path, 0o600)
            print([
                "wrote frozen-mind report: \(url.path)",
                "reportDigest=\(report.reportDigest)",
                "functionalContractPassed=\(report.functionalContractPassed)",
            ].joined(separator: " "))
        } else {
            print(String(decoding: reportData, as: UTF8.self))
        }
    }

    static func makeProviderTransplantFixture(
        rawTargets: String,
        outputPath: String,
        mode rawMode: String,
        lifetimeSeconds rawLifetimeSeconds: String?
    ) throws {
        guard let mode = FrozenMindEvaluationMode(rawValue: rawMode.lowercased()) else {
            throw FrozenMindEvaluationError.invalidManifest
        }
        let defaultLifetime = mode == .full ? 7_200 : 1_800
        let lifetimeSeconds = rawLifetimeSeconds.flatMap(Int.init) ?? defaultLifetime
        guard (300...7_200).contains(lifetimeSeconds) else {
            throw FrozenMindEvaluationError.invalidManifest
        }
        let targets = rawTargets.split(separator: ",").compactMap { raw -> FrozenMindProviderTarget? in
            let value = String(raw)
            guard let separator = value.firstIndex(of: ":") else { return nil }
            let provider = String(value[..<separator])
            let routeTail = String(value[value.index(after: separator)...])
            let model: String
            let effort: String?
            if let effortSeparator = routeTail.lastIndex(of: "@") {
                model = String(routeTail[..<effortSeparator])
                effort = String(routeTail[routeTail.index(after: effortSeparator)...])
            } else {
                model = routeTail
                effort = nil
            }
            guard !provider.isEmpty, !model.isEmpty else { return nil }
            guard effort?.isEmpty != true else { return nil }
            return FrozenMindProviderTarget(
                providerID: provider,
                modelID: model,
                reasoningEffort: effort
            )
        }
        guard targets.count == rawTargets.split(separator: ",").count else {
            throw FrozenMindEvaluationError.invalidManifest
        }
        let fixture = try FrozenMindGeneratedFixtureFactory.make(
            mode: mode,
            targets: targets,
            lifetime: TimeInterval(lifetimeSeconds)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(fixture)
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        let url = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: Data.WritingOptions.atomic)
        _ = chmod(url.path, 0o600)
        print("wrote generated nonpersonal frozen-mind fixture: \(url.path)")
    }

    static func readBoundedFrozenMindArtifact(
        path: String,
        maximumBytes: Int = 32 * 1_024 * 1_024
    ) throws -> Data {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == size, data.count <= maximumBytes else {
            throw FrozenMindEvaluationError.byteBudgetExceeded
        }
        return data
    }

    static func frozenMindArtifactRevisions(
        _ manifest: FrozenMindEpochManifest
    ) -> [FrozenMindOwnerRevision] {
        [
            FrozenMindOwnerRevision(
                owner: "context",
                revision: [
                    String(manifest.contextRevision.generationID),
                    manifest.contextRevision.sourceFingerprint,
                    String(manifest.contextRevision.arenaGenerationID),
                ].joined(separator: ":")
            ),
            manifest.cognitionRevision,
            manifest.organismRevision,
            FrozenMindOwnerRevision(owner: "persona", revision: manifest.personaDigest),
            FrozenMindOwnerRevision(owner: "trust", revision: manifest.trustPolicyDigest),
        ]
    }
}
