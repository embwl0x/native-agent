/// A manual release is complete only after both the owner operation and the
/// immediately refreshed status agree that the CoreML model is not resident.
/// This keeps a no-op release from looking like reclaimed memory.
public enum EmbeddingsMemoryReleaseVerification {
    public struct Result: Equatable {
        public let ok: Bool
        public let error: String?
        public let detail: String
    }

    public static func verify(
        releasedSnapshot: EmbeddingRuntimeSnapshot?,
        reportedModelLoaded: Bool?
    ) -> Result {
        guard let releasedSnapshot else {
            return .init(
                ok: false,
                error: "Embedding runtime was unavailable, so memory release could not be verified.",
                detail: "No embedding runtime snapshot was returned after the release request."
            )
        }

        guard !releasedSnapshot.coreMLLoaded else {
            return .init(
                ok: false,
                error: "Embedding model is still loaded after release.",
                detail: "The embedding runtime still reports a resident CoreML model."
            )
        }

        guard reportedModelLoaded == false else {
            return .init(
                ok: false,
                error: "Embedding memory release could not be confirmed.",
                detail: "The refreshed embedding status did not confirm that the model was unloaded."
            )
        }

        return .init(
            ok: true,
            error: nil,
            detail: "Released Swift CoreML embedding model memory."
        )
    }
}
