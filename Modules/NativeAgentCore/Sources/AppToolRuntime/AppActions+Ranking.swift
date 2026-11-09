import AgentConversations
import AgentWorkspace
import Foundation
import MacIntegration
import MemoryV2
import NativeAgentCore
import PersistenceCore
import StandingBots
import ToolRegistry
import AuthoredCapabilities
import ChatToolRuntime
import PersonaEngine
import Senses
import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import AttentionRouting
import NativeAgentShared
import ProviderRouting
import DeviceSync
import TrustCenter
import ChatTurnContracts
import ChromeControl
import TurnTrace
import Studio
// Blueprint: | `AppActions+Ranking.swift` | Exact ids/pages precede checked semantic matches; item gaps stay local |

extension AppActions {
    /// Exact identities remain intact, regardless of the query's language. A leading + names an id; -<exact id> excludes that action explicitly.
    static func named(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { $0.isWhitespace || ",;!?()".contains($0) })
            .map { String($0.hasPrefix("+") ? $0.dropFirst() : $0[...]) })
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func intentWords(_ text: String) -> [String] { Array(Set(words(text))).sorted() }

    /// Cache tokens by exact text because every turn ranks the same action inventory.
    static func wordSet(_ text: String) -> Set<String> {
        wordSetLock.withLock {
            if let known = wordSets[text] { return known }
            let set = Set(words(text))
            if wordSets.count >= 4096 { wordSets.removeAll(keepingCapacity: true) }
            wordSets[text] = set
            return set
        }
    }
    private static let wordSetLock = NSLock()
    nonisolated(unsafe) private static var wordSets: [String: Set<String>] = [:]

    /// Prefer the longest whole-token page name at a position so a compound name does not also select its shorter page.
    static func namedPages(_ query: String, actions: [AppAction], pages: [String: QuietToolPage]) -> Set<String> {
        var names: [String: Set<String>] = [:]
        func add(_ name: String, page: String) {
            let key = words(name).joined(separator: " ")
            if !key.isEmpty { names[key, default: []].insert(page) }
        }
        let registeredPages = QuietToolPage.all + [QuietToolPage.inbox] + QuietToolPage.unindexed + Array(pages.values)
        let ownPages = Set(actions.map(\.page) + registeredPages.map(\.id)).subtracting(["*"])
        for page in ownPages { add(page, page: page) }
        for page in registeredPages { add(page.title, page: page.id) }
        for (alias, page) in AppDoorNames.aliases where ownPages.contains(page) { add(alias, page: page) }
        for action in actions where action.page != "*" {
            if let gate = action.schema?.macIntegration { add(gate.integration, page: action.page) }
        }
        let candidates = names.map { (words: words($0.key), pages: $0.value) }.sorted { $0.words.count > $1.words.count }
        let asked = words(query)
        var result = Set<String>(), offset = 0
        while offset < asked.count {
            if let match = candidates.first(where: { asked.dropFirst(offset).starts(with: $0.words) }) {
                result.formUnion(match.pages)
                offset += match.words.count
            } else { offset += 1 }
        }
        return result
    }

    /// Ranking requires a checked catalog and one usable embedding epoch.
    static func ranked(_ query: String, pages: [String: QuietToolPage], dataRoot: URL, memory: SwiftNativeMemoryV2,
                       inventory snapshot: (actions: [AppAction], authored: [AppAction])? = nil, intentOnly: Bool = false, turn: Turn?)
        async throws -> (actions: [AppAction], namedPages: Set<String>, gaps: [String: String]) {
        let contacts = try AgentPeerStore(dataRoot: dataRoot).list().map(\.name)
        let helpers = try BotDefinitionStore(dataRoot: dataRoot).list().map(\.name)
        let checked: (actions: [AppAction], authored: [AppAction])
        if let snapshot { checked = snapshot } else { checked = try await inventory(dataRoot: dataRoot, turn: turn) }
        let actions = checked.actions
        let texts = actionTexts(actions, pages: pages, contacts: contacts, helpers: helpers)
        let tokens = named(query)
        let excluded = Set(actions.map(\.id).filter { tokens.contains("-" + $0.lowercased()) })
        let named = tokens
        let positive = query.split(whereSeparator: \.isWhitespace).filter {
            !excluded.contains(String($0.dropFirst())) || !$0.hasPrefix("-")
        }.joined(separator: " ")
        let asked = intentWords(positive)
        let pagesNamed = namedPages(positive, actions: actions, pages: pages)
        // A failed semantic index cannot certify a successful word-only search.
        func rankingFailure(_ detail: String) -> ToolFailureError {
            ToolFailureError(detail, effects: .none, owner: "action discovery",
                nextCall: ToolFailureError.call("app", ["page": .string("settings")]), code: "action_ranking_unavailable",
                instruction: """
                    Read settings for memory search model status and repair the reported model or action-index fault, then repeat discovery.
                    """, recovery: .repair)
        }
        let embedding: (asked: [Float], actions: [Int: [Float]])
        var actionGaps: [String: String] = [:]
        var timings: [String: JSONValue] = [:]
        defer { TurnTraceBus.fireFromContext(kind: "context.ranking.summary", payload: .object(["stageMs": .object(timings)]), turn: turn) }
        do {
            let indexStart = DispatchTime.now().uptimeNanoseconds
            let indexed = try await memory.indexedActionVectors(texts)
            timings["index_read"] = .int(Int64((DispatchTime.now().uptimeNanoseconds - indexStart) / 1_000_000))
            // What the index lacks (this turn's own actions) is embedded with the ask, in its space.
            let missing = indexed.vectors.indices.filter { indexed.vectors[$0] == nil && indexed.unembeddable[$0] == nil }
            let embeddingStart = DispatchTime.now().uptimeNanoseconds
            let embedded = try await memory.embedForDerivedContextItemsWithEpoch([positive] + missing.map { texts[$0] })
            timings["embedding"] = .int(Int64((DispatchTime.now().uptimeNanoseconds - embeddingStart) / 1_000_000))
            guard embedded.epoch == indexed.epoch, embedded.items.count == 1 + missing.count else {
                await memory.requestActionIndexUpdate()
                throw rankingFailure("Action-index and query epochs differ or prediction outcomes are missing. An index update was requested.")
            }
            guard case .vector(let ask) = embedded.items[0] else {
                throw rankingFailure("The action search query is unembeddable: \(embedded.items[0]).")
            }
            var vectors = indexed.vectors
            var gaps = indexed.unembeddable
            for (offset, item) in zip(missing, embedded.items.dropFirst(1)) {
                switch item {
                case .vector(let vector): vectors[offset] = vector
                case .unembeddable(let reason): gaps[offset] = reason
                }
            }
            try VectorMath.requireUsable(ask)
            var actionVectors: [Int: [Float]] = [:]
            for offset in vectors.indices {
                if let reason = gaps[offset] {
                    actionGaps[actions[offset].id] = reason
                    TurnTraceBus.fireFromContext(kind: "context.ranking.gap", payload: .object([
                        "action": .string(actions[offset].id), "reason": .string(reason),
                        "epoch": .string(indexed.epoch.rawValue)
                    ]), turn: turn)
                    continue
                }
                guard let vector = vectors[offset] else {
                    throw rankingFailure("Action search has no prediction outcome for \(actions[offset].id).")
                }
                try VectorMath.requireUsable(vector, dimensions: ask.count)
                actionVectors[offset] = vector
            }
            embedding = (ask, actionVectors)
        } catch let failure as ToolFailureError where failure.failureCode == "action_ranking_unavailable" { throw failure }
        catch { throw rankingFailure(error.localizedDescription) }
        // Assume most inventory actions are irrelevant with a light-tailed cosine tail in this retrieval epoch. Semantic matches must clear the shared
        // attention chance bar; small/flat inventories provide no evidence. Exact tokens and identities stand independently; multilingual coverage belongs to
        // the embedder.
        let offsets = embedding.actions.keys.sorted()
        let similarities = offsets.map { VectorMath.cosine(embedding.asked, embedding.actions[$0]) }
        let similarityByOffset = Dictionary(uniqueKeysWithValues: zip(offsets, similarities))
        let standings = Dictionary(uniqueKeysWithValues: zip(offsets, VectorMath.standout(similarities)))
        // Two deviations clear the chance bar; a higher threshold over hundreds of actions admits almost no semantic matches.
        let bar = ContextSelectionConfiguration.memoryStandoutDeviations
        var ranked: [(offset: Int, action: AppAction, semantic: Bool, similarity: Double, own: Int, lexical: Int)] = []
        for (offset, action) in actions.enumerated() where !excluded.contains(action.id) {
            guard let similarity = similarityByOffset[offset] else { continue }
            let lexical = hits(wordSet(texts[offset]), asked)
            let own = hits(ownWords(action), asked)
            let semantic = standings[offset].flatMap { $0 }.map { $0 >= bar } == true
            if named.contains(action.id.lowercased()) || (pagesNamed.contains(action.page) && !action.isItemRead) || lexical > 0 || semantic {
                ranked.append((offset, action, semantic, similarity, own, lexical))
            }
        }
        return (ranked.sorted {
            // An unknown id is an intent, not an exact page request: "desk list" must not promote a ledger just for saying "list".
            if intentOnly, $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            let leftNamed = named.contains($0.action.id.lowercased())
            let rightNamed = named.contains($1.action.id.lowercased())
            if leftNamed != rightNamed { return leftNamed }
            let leftPage = pagesNamed.contains($0.action.page) && !$0.action.isItemRead
            let rightPage = pagesNamed.contains($1.action.page) && !$1.action.isItemRead
            if leftPage != rightPage { return leftPage }
            // Exact requested words still order actions within the named page.
            if leftPage { return $0.own != $1.own ? $0.own > $1.own : $0.offset < $1.offset }
            if $0.semantic != $1.semantic { return $0.semantic }
            // An action's own name and title outrank vague semantic closeness; semantic scores then order the rest.
            if $0.own != $1.own { return $0.own > $1.own }
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.lexical != $1.lexical { return $0.lexical > $1.lexical }
            return $0.offset < $1.offset
        }.map(\.action).reduce(into: (seen: Set<String>(), kept: [AppAction]())) { result, action in
            // One action once: the same id registered under two labels is one route.
            if result.seen.insert(action.id).inserted { result.kept.append(action) }
        }.kept, pagesNamed, actionGaps)
    }

    /// The same exact text feeds launch/change indexing and query ranking.
    static func actionTexts(_ actions: [AppAction], pages: [String: QuietToolPage],
                            contacts: [String], helpers: [String]) -> [String] {
        actions.map { action in
            let names = ["agent.message", "agent.read"].contains(action.id) ? contacts
                : (["bot.ask", "bot.list"].contains(action.id) ? helpers : [])
            return [firstSentence(ToolNameAliases.foldedProse(action.schema?.description ?? foldSchemas[action.tool]?.description ?? action.label)),
                    action.id.replacingOccurrences(of: ".", with: " "), action.label,
                    action.scope, pages[action.page]?.title ?? action.page, pages[action.page]?.summary ?? "",
                    action.argSpecs.flatMap(\.names).joined(separator: " "),
                    names.joined(separator: ", ")].joined(separator: " ")
        }
    }

    static func matchedActions(_ ranked: [AppAction]) -> [AppAction] {
        var seen = Set<String>()
        return ranked.filter { !$0.isItemRead && seen.insert($0.id).inserted }
    }

    /// Identity and authored label comparisons must not stem tokens or expand aliases.
    static func ownWords(_ action: AppAction) -> Set<String> { wordSet(action.id + " " + action.label) }

    /// Exact normalized tokens only; morphology belongs to semantic retrieval.
    static func hits(_ own: Set<String>, _ asked: [String]) -> Int {
        asked.filter { own.contains($0) }.count
    }
}
