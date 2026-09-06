import Foundation

/// Prepared wording and embedding, admitted together by the canonical transaction.
public struct ReviewedMomentAcceptance: Sendable {
    public let expectedContent: String
    public let content: String
    public let embedding: [Float]?
    public let embeddingEpoch: String?

    public init(expectedContent: String, content: String, embedding: [Float]?, embeddingEpoch: String?) {
        self.expectedContent = expectedContent
        self.content = content
        self.embedding = embedding
        self.embeddingEpoch = embeddingEpoch
    }
}
