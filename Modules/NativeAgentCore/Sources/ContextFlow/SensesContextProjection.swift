import Context
import Foundation
import MemoryV2
import Senses

/// A bounded unread-news slot, separate from topic-selected memories.
public struct SensesContextProjection: ContextCompiledProjectionProvider, Sendable {
    public static let maximumItems = 4
    public static let maximumUTF8Bytes = 4_096
    public static let maximumItemUTF8Bytes = 1_024
    private static let owner = "nativeagent.sense-news"
    public init() {}
    public var projectionIdentifier: String { Self.owner }
    public var invalidationNamespaces: Set<String> { ["sense-news"] }
    public var refreshesBeforeTurn: Bool { true }

    private static func sourceID(_ item: SenseNews) -> ContextSourceID {
        ContextStableID.source(owner: owner, locator: "senses/news/" + item.id.uuidString)
    }
    private static func atomID(_ item: SenseNews) -> ContextAtomID {
        ContextStableID.atom(sourceID: sourceID(item), kind: .news, headingPath: [], blockAnchor: "news")
    }

    public func excludedAtomIDs(in generation: ContextStoredGeneration) async -> Set<ContextAtomID> {
        let unread = Set(await SenseNewsBoard.shared.latest(limit: SenseNewsBoard.capacity).map(Self.atomID))
        return Set(generation.atoms.filter { $0.draft.kind == .news && !unread.contains($0.draft.id) }.map(\.draft.id))
    }

    public func didDeliver(_ items: [ContextPacketItem]) async {
        let delivered = Set(items.filter { $0.pointer.kind == .news }.map { $0.pointer.atomID })
        guard !delivered.isEmpty else { return }
        let unread = await SenseNewsBoard.shared.latest(limit: SenseNewsBoard.capacity)
        let ids = Set(unread.filter { delivered.contains(Self.atomID($0)) }.map(\.id))
        if !ids.isEmpty { await SenseNewsBoard.shared.acknowledge(ids) }
    }

    public func compiledProjection(previousSources: [ContextSourceID: ContextCompiledSource]) async throws -> ContextCompiledProjectionResult {
        let news = await SenseNewsBoard.shared.latest(limit: SenseNewsBoard.capacity)
        let surfaces = Set(MemoryRecordDisclosurePolicy.localPrivateSurfaces.map(ContextSurface.init(rawValue:)))
        var sources: [ContextCompiledSource] = []
        var selected = Set<ContextSourceID>()
        var remaining = Self.maximumUTF8Bytes
        func bounded(_ text: String, bytes: Int) -> String {
            guard text.utf8.count > bytes else { return text }
            var result = ""
            var used = 0
            for character in text {
                let size = String(character).utf8.count
                guard used + size <= bytes - "…".utf8.count else { break }
                result.append(character); used += size
            }
            return result + "…"
        }
        for item in news {
            if selected.count == Self.maximumItems { break }
            try Task.checkCancellation()
            let senseID = ContextSecretContentPolicy.redactedFragment(item.senseID)
            let safeAddress = ContextSecretContentPolicy.redactedFragment(item.address)
            let safeSummary = ContextSecretContentPolicy.redactedFragment(item.summary)
            let tag = "[sense \(senseID) v\(item.version)]"
            let time = ISO8601DateFormatter().string(from: item.at)
            let raw = ContextSecretContentPolicy.redactedFragment(
                NativeContextProjectionText.clean("\(time) · \(tag) · \(safeAddress) · \(safeSummary)"))
            guard tag.utf8.count <= 160,
                  !NativeContextProjectionText.containsDisallowedControl(raw),
                  !ContextSecretContentPolicy.containsSecretLikeContent(safeAddress),
                  !ContextSecretContentPolicy.containsSecretLikeContent(safeSummary),
                  !ContextSecretContentPolicy.containsSecretLikeContent(raw) else { continue }
            // The address never spends the delta's reserved space. Ellipses
            // explicitly identify bounded prefixes; no clipped line is whole.
            let address = bounded(NativeContextProjectionText.clean(safeAddress), bytes: 320)
            let lead = "\(time) · \(tag) · \(address) · "
            // Keep each update visible. Divide the remaining space over the
            // short lines instead of letting the newest consume older news.
            let summaryLines = safeSummary.split(separator: "\n").map { NativeContextProjectionText.clean(String($0)) }
            let summaryBudget = max(0, Self.maximumItemUTF8Bytes - lead.utf8.count)
            let lineBudget = max(4, (summaryBudget - max(0, summaryLines.count - 1)) / max(1, summaryLines.count))
            let composed = lead + summaryLines.map { bounded($0, bytes: lineBudget) }.joined(separator: "\n")
            let body = bounded(ContextSecretContentPolicy.redactedFragment(composed), bytes: Self.maximumItemUTF8Bytes)
            guard body.utf8.count <= remaining else { break }
            let locator = "senses/news/" + item.id.uuidString
            let id = Self.sourceID(item)
            guard selected.insert(id).inserted else { continue }
            remaining -= body.utf8.count
            let hash = ContextStableID.digest(parts: ["sense-news-v1", body, String(item.at.timeIntervalSince1970)])
            guard previousSources[id]?.sourceHash != hash else { continue }
            let descriptor = ContextSourceDescriptor(id: id, owner: Self.owner, kind: .other,
                canonicalLocator: locator, authority: .inferred, privacy: .localPrivate,
                permittedSurfaces: surfaces, injectionPolicy: .always)
            let atom = ContextAtomDraft(
                id: Self.atomID(item),
                sourceID: id, kind: .news, headingPath: [],
                sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
                sourceHash: hash, body: body, authority: .inferred, confidence: 0.5,
                freshness: ContextFreshness(updatedAt: item.at, expiresAt: item.at.addingTimeInterval(SenseNewsBoard.maximumAge)), privacy: .localPrivate,
                permittedSurfaces: surfaces, injectionPolicy: .always, contentRole: .untrustedExternalData,
                entities: [ContextEntity(kind: "sense", id: senseID, label: senseID)],
                triggers: NativeContextProjectionText.triggers(body), activation: 0,
                recentUsefulness: 0, decayState: 1, embedding: nil)
            sources.append(ContextCompiledSource(descriptor: descriptor, sourceHash: hash, atoms: [atom]))
        }
        let old = Set(previousSources.values.filter { $0.descriptor.owner == Self.owner }.map(\.descriptor.id))
        return ContextCompiledProjectionResult(changedSources: sources, removedSourceIDs: old.subtracting(selected))
    }
}
