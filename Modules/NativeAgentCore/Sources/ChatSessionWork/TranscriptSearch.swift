import Foundation
// Blueprint: | `TranscriptSearch.swift` | `TranscriptSearchDocument`, `TranscriptSearchResult`, `TranscriptSearchResponse`, `TranscriptSearch` |

/// A rebuildable projection over an already loaded transcript.
/// JSONL remains authoritative: this type writes no sidecar index and
/// owns no session lifecycle.
public struct TranscriptSearchDocument: Sendable, Equatable {
    public let messageID: String
    public let ordinal: Int
    public let content: String

    public init(messageID: String, ordinal: Int, content: String) {
        self.messageID = messageID
        self.ordinal = ordinal
        self.content = content
    }
}

public struct TranscriptSearchResult: Identifiable, Sendable, Equatable {
    public let messageID: String
    public let ordinal: Int

    public var id: String { "\(ordinal):\(messageID)" }

    public init(messageID: String, ordinal: Int) {
        self.messageID = messageID
        self.ordinal = ordinal
    }
}

public struct TranscriptSearchResponse: Sendable, Equatable {
    public let query: String
    public let results: [TranscriptSearchResult]
    public let totalMatchCount: Int

    public var isTruncated: Bool { totalMatchCount > results.count }
}

public enum TranscriptSearch {
    /// Query work is bounded before Foundation normalization or comparison.
    public static let maximumQueryScalars = 256
    /// Huge repetitive histories remain searchable without retaining an
    /// unbounded navigation array. The exact total is still reported.
    public static let maximumNavigableResults = 2_000

    public static func boundedInput(_ raw: String) -> String {
        var bounded = ""
        bounded.reserveCapacity(maximumQueryScalars * 2)
        for scalar in raw.unicodeScalars.prefix(maximumQueryScalars) {
            bounded.unicodeScalars.append(scalar)
        }
        return bounded
    }

    public static func boundedQuery(_ raw: String) -> String {
        let bounded = boundedInput(raw)
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func search(
        query rawQuery: String,
        documents: [TranscriptSearchDocument],
        maximumResults: Int = maximumNavigableResults
    ) -> TranscriptSearchResponse {
        searchCancellable(
            query: rawQuery,
            documents: documents,
            maximumResults: maximumResults,
            shouldCancel: { false }
        ) ?? TranscriptSearchResponse(query: boundedQuery(rawQuery), results: [], totalMatchCount: 0)
    }

    /// The controller uses this form so a superseded query stops consuming CPU
    /// instead of leaving an unstructured full-history scan behind it.
    public static func searchCancellable(
        query rawQuery: String,
        documents: [TranscriptSearchDocument],
        maximumResults: Int = maximumNavigableResults,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> TranscriptSearchResponse? {
        let query = boundedQuery(rawQuery)
        guard !query.isEmpty, maximumResults > 0 else {
            return TranscriptSearchResponse(query: query, results: [], totalMatchCount: 0)
        }

        var newestFirst: [TranscriptSearchResult] = []
        newestFirst.reserveCapacity(min(maximumResults, documents.count))
        var totalMatchCount = 0
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")

        // Retain the newest bounded results, which are the useful ones in a
        // conversation, but continue the scan so the total remains exact.
        for (scanIndex, document) in documents.reversed().enumerated() {
            if scanIndex.isMultiple(of: 64), shouldCancel() { return nil }
            guard document.content.range(of: query, options: options, locale: locale) != nil else {
                continue
            }
            totalMatchCount += 1
            if newestFirst.count < maximumResults {
                newestFirst.append(TranscriptSearchResult(
                    messageID: document.messageID,
                    ordinal: document.ordinal
                ))
            }
        }

        return TranscriptSearchResponse(
            query: query,
            results: newestFirst.reversed(),
            totalMatchCount: totalMatchCount
        )
    }

}
