/// Interpretation of the canonical runtime snapshot for status surfaces.
public struct EmbeddingStatusReadiness {
    public let requestedCoreML: Bool
    public let isFailClosed: Bool
    public let effectiveBackend: String
}

extension MemoryStatusProjection {
    public static func embeddingReadiness(_ runtime: EmbeddingRuntimeSnapshot) -> EmbeddingStatusReadiness {
        let requestedCoreML = runtime.requestedBackend != ManagedEmbeddingProvider.mockBackend
        let effectiveCoreML = runtime.effectiveBackend == ManagedEmbeddingProvider.coreMLBackend
        let isFailClosed = runtime.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend
        return EmbeddingStatusReadiness(
            requestedCoreML: requestedCoreML,
            isFailClosed: isFailClosed,
            effectiveBackend: isFailClosed ? "unavailable" : (effectiveCoreML ? "local" : "hash")
        )
    }
}
