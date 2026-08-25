import Foundation

/// The mounted Memory search field distinguishes a still-running canonical
/// search from an honest empty result and from a failed semantic reader whose
/// keyword fallback also found nothing.
enum MemorySearchPresentation: Equatable {
    case allMemories
    case searching
    case results
    case empty
    case unavailable(String)

    static func matchesCurrentQuery(_ query: String, resultQuery: String?) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count >= 3
            && resultQuery?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
    }

    /// Semantic results are usable only when they name the query currently in
    /// the field. Even then, an empty semantic array is not enough evidence to
    /// suppress the cheap lexical fallback: the embedder can be unavailable,
    /// weak, or return an incomplete projection while the rendered memory list
    /// still has an exact text match.
    static func displayedRecords<Record>(
        _ records: [Record],
        query: String,
        semanticResults: [Record]?,
        resultQuery: String?,
        lexicalMatch: (Record, String) -> Bool
    ) -> [Record] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        let lexical = records.filter { lexicalMatch($0, trimmed.lowercased()) }
        guard matchesCurrentQuery(query, resultQuery: resultQuery),
              let semanticResults,
              !semanticResults.isEmpty else {
            return lexical
        }
        return semanticResults
    }

    static func resolve(
        query: String,
        resultCount: Int,
        isLoading: Bool,
        error: String?
    ) -> Self {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return .allMemories
        }
        if isLoading { return .searching }
        if resultCount > 0 { return .results }
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(error)
        }
        return .empty
    }
}
