import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import CognitiveSubstrate
import Studio

// Blueprint: | `DreamProvenance.swift` | `DreamEntryProvenance` and `DreamSourceRef`: per-claim dream support, source resolution and section-aware peer provenance |

/// An original row, its known exchange, or a consolidated stretch.
public struct DreamSourceRef: Sendable, Equatable {
    public var kind: String
    public var id: String
    public var sessionID: String?
    public var livedDate: String
    public var messageID: String?

    public init(kind: String, id: String, sessionID: String? = nil, livedDate: String, messageID: String? = nil) {
        self.kind = kind
        self.id = id
        self.sessionID = sessionID
        self.livedDate = livedDate
        self.messageID = messageID
    }

    public var reference: String {
        "\(kind):\(sessionID.map { $0 + "/" } ?? "")\(id)\(messageID.map { "#message:" + $0 } ?? "")@\(livedDate)"
    }
}

/// Each claim keeps only the experiences the dream named for that claim.
/// Old diary-wide provenance cannot establish a claim's support.
public struct DreamEntryProvenance: Sendable, Codable, Equatable {
    public var quote: String
    public var sourceRefs: [String]

    private enum CodingKeys: String, CodingKey {
        case quote
        case sourceRefs = "source_refs"
    }

    private static let prefix = "<!-- claim-sources "
    private static let peersPrefix = "<!-- dream-peers "

    /// A day's entry holds one peers line per dream section; the day's peers
    /// are their union, and unknown when any section's are.
    static func peerIds(in content: String) -> [String]? {
        let lines = content.components(separatedBy: "\n").filter { $0.hasPrefix(peersPrefix) }
        // One marker per dream of the night: a dream without one leaves the
        // whole day's peers unknown.
        guard !lines.isEmpty, lines.count >= max(1, DreamNight(content).dreams.count) else { return nil }
        return CognitiveReflectionCause.unionPeerIds(lines.map { line in
            guard line.hasSuffix(" -->") else { return nil }
            return try? JSONDecoder().decode([String].self, from: Data(line.dropFirst(peersPrefix.count).dropLast(4).utf8))
        })
    }

    static func peerBlock(_ peers: [String]?) throws -> String {
        "\(peersPrefix)\(String(decoding: try JSONEncoder().encode(peers), as: UTF8.self)) -->\n"
    }

    static func transcriptCause(_ row: [String: JSONValue], session: String) -> CognitiveReflectionCause? {
        guard case .string(let role)? = row["role"] else { return nil }
        var metadata: [String: JSONValue] = [:]
        if case .object(let value)? = row["metadata"] { metadata = value }
        metadata["sessionId"] = .string(session)
        if let recollection = ChatSessionRecollections.recollection(fromTranscriptRow: .object(row), sessionId: session) {
            // Continuity records the participant, not the consumed peer checkpoint.
            return CognitiveReflectionCause(text: "\(DreamCycleRunner.recollectionRole):\n\(recollection.text)")
        }
        guard ["user", "assistant"].contains(role), case .string(let content)? = row["content"] else { return nil }
        let text = "\(role):\n\(content)"
        var peers = CognitiveSubstrate.peerIdentity(metadata: metadata).map { [$0] } ?? []
        let binding = ChatSessionRecollections.continuityBinding(role: role, metadata: metadata)
        if case .object(let value)? = binding, case .string(let participant)? = value["participant"],
           participant.hasPrefix("peer:") { peers.append(participant) }
        var carried = [metadata["untrusted_sources"]]
        if case .object(let origin)? = metadata["origin"] {
            carried += [origin["peerSources"], origin["elevatedPeerSources"]]
        }
        for value in carried.compactMap({ $0 }) {
            guard case .array(let sources) = value else { return CognitiveReflectionCause(text: text) }
            for source in sources {
                guard case .string(let peer) = source else { return CognitiveReflectionCause(text: text) }
                peers.append(peer)
            }
        }
        return CognitiveReflectionCause(text: text, sourcePeerIds: Array(Set(peers)).sorted())
    }

    /// Resolve exact cited rows; an exchange identity groups recurrence, not its material.
    static func resolveSources(_ refs: Set<String>, dataRoot: URL,
        messages: [String: (session: String, row: [String: JSONValue])]
    ) async throws -> [String: CognitiveReflectionCause] {
        var material: [String: CognitiveReflectionCause] = [:]
        var journal: [StudioJournalEntry]?
        for ref in refs.sorted() {
            if let message = messages[ref] {
                material[ref] = transcriptCause(message.row, session: message.session)
                continue
            }
            let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let path = parts[1].split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(separator: "/", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "studio_entry":
                guard path.count == 1 else { continue }
                if journal == nil { journal = try await SwiftNativeStudioStore(dataRoot: dataRoot).journalEntriesIncludingArchive() }
                if let entry = journal?.first(where: { $0.id == path[0] }) {
                    material[ref] = CognitiveReflectionCause(text: String(decoding: try entry.toJSON().serializedData(pretty: true), as: UTF8.self))
                }
            default: break
            }
        }
        return material
    }

    /// A source reference without its `@<lived date>` tail.
    static func undated(_ reference: String) -> String {
        reference.lastIndex(of: "@").map { String(reference[..<$0]) } ?? reference
    }

    /// Text as words: curly quotes read as straight ones and runs of whitespace as one space.
    static func plain(_ text: String) -> String {
        let straight = text.map { char -> Character in
            switch char {
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}": return "\""
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}": return "'"
            default: return char
            }
        }
        return String(straight).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The claims her prose backs, as lineage lines. A claim the prose or the dream's reading
    /// does not back is left without lineage and named in `dropped`; it never costs the night.
    static func renderBlock(_ claims: [Self], content: String, sources: [DreamSourceRef], dropped: inout [String]) throws -> String {
        guard !content.contains("<!-- claim-sources"), !content.contains("<!-- dream-peers") else {
            throw NSError(domain: "NativeAgent.DreamEntryProvenance", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The dream's claim check refused the model's reply: its prose contains the reserved markers <!-- claim-sources or <!-- dream-peers. Nothing was written; the night stays owed and the next run retries it."])
        }
        // The model cites a source by its identity; the @date tail it may leave
        // off or misquote. What is kept is the dream's own reference and date.
        let canonical = Dictionary(sources.map { (undated($0.reference), $0.reference) }, uniquingKeysWith: { first, _ in first })
        var result = ""
        for (index, claim) in claims.enumerated() {
            let quote = "claims[\(index)] \"" + String(claim.quote.prefix(80)) + "\""
            guard !claim.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { dropped.append("claims[\(index)] has an empty quote"); continue }
            // A quote is the same words whatever the typography: curly or straight quotes, spacing.
            guard plain(content).contains(plain(claim.quote)) else { dropped.append(quote + " is not in the dream's prose"); continue }
            let unbound = claim.sourceRefs.filter { canonical[undated($0)] == nil }
            guard unbound.isEmpty else {
                dropped.append(quote + " cites sources this dream did not read: " + unbound.prefix(5).joined(separator: ", "))
                continue
            }
            var admitted = claim
            admitted.sourceRefs = claim.sourceRefs.compactMap { canonical[undated($0)] }
            let data = try JSONEncoder().encode(admitted)
            result += "\(prefix)\(String(decoding: data, as: UTF8.self)) -->\n"
        }
        return result
    }

    /// Each dream section of a day's entry (split at its `## ` heading) ends
    /// with its own claim lines; only that trailing block of each is read.
    static func sources(for quote: String? = nil, in content: String) -> [String] {
        var refs = Set<String>()
        for section in content.components(separatedBy: "\n## ") {
            for line in section.trimmingCharacters(in: .newlines).components(separatedBy: "\n").reversed() {
                guard line.hasPrefix(prefix), line.hasSuffix(" -->") else { break }
                let json = line.dropFirst(prefix.count).dropLast(4)
                guard let claim = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
                      quote == nil || plain(claim.quote) == quote.map(plain) else { continue }
                refs.formUnion(claim.sourceRefs)
            }
        }
        // Historical diary-wide refs recover material, never support a quoted claim.
        if quote == nil {
            for line in content.components(separatedBy: "\n") where line.hasPrefix("_Sources: ") && line.hasSuffix("_") {
                refs.formUnion(line.dropFirst(10).dropLast().components(separatedBy: " · ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
        }
        return refs.sorted()
    }

    public static func dateStem(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
