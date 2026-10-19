import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import CognitiveSubstrate
import Studio

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

    static func peerIds(in content: String) -> [String]? {
        guard let line = content.components(separatedBy: "\n").last(where: { $0.hasPrefix(peersPrefix) }),
              line.hasSuffix(" -->") else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(line.dropFirst(peersPrefix.count).dropLast(4).utf8))
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

    static func renderBlock(_ claims: [Self], content: String, sources: [DreamSourceRef]) throws -> String {
        guard !content.contains("<!-- claim-sources"), !content.contains("<!-- dream-peers") else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "dream prose contains reserved claim metadata"))
        }
        let allowed = Set(sources.map(\.reference))
        var result = ""
        for claim in claims {
            guard !claim.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  content.contains(claim.quote), Set(claim.sourceRefs).isSubset(of: allowed) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "dream claim has unbound source lineage"))
            }
            let data = try JSONEncoder().encode(claim)
            result += "\(prefix)\(String(decoding: data, as: UTF8.self)) -->\n"
        }
        return result
    }

    static func sources(for quote: String? = nil, in content: String) -> [String] {
        var refs = Set<String>()
        for line in content.trimmingCharacters(in: .newlines).components(separatedBy: "\n").reversed() {
            guard line.hasPrefix(prefix), line.hasSuffix(" -->") else { break }
            let json = line.dropFirst(prefix.count).dropLast(4)
            guard let claim = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
                  quote == nil || claim.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                    == quote?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            refs.formUnion(claim.sourceRefs)
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
