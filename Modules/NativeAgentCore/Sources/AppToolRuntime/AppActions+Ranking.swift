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
// Blueprint: | `AppActions+Ranking.swift` | AppActions find ranking; exact IDs precede named pages in declaration order, then semantic and exact-token matches with retrieval-epoch attention evidence |

extension AppActions {
    /// Exact identities remain intact, regardless of the query's language. A leading + names an id; -<exact id> excludes that action
    /// explicitly.
    static func named(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { $0.isWhitespace || ",;!?()".contains($0) })
            .map { String($0.hasPrefix("+") ? $0.dropFirst() : $0[...]) })
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func intentWords(_ text: String) -> [String] { Array(Set(words(text))).sorted() }

    /// Page names are whole token sequences, including the door's existing aliases and integration ids. Prefer a longer name at the same
    /// position so "Mac Integration" names that page, rather than also naming "Mac".
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
            if let gate = MacIntegrationGates.byTool[action.tool] { add(gate.integration, page: action.page) }
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

    /// `degraded` says why the ranking fell back to words alone; nil when the embedder ranked it.
    static func ranked(_ query: String, pages: [String: QuietToolPage], dataRoot: URL, memory: SwiftNativeMemoryV2,
                       inventory snapshot: (actions: [AppAction], authored: [AppAction])? = nil)
        async throws -> (actions: [AppAction], degraded: String?, namedPages: Set<String>) {
        let contacts = (try? AgentPeerStore(dataRoot: dataRoot).list())?.map(\.name) ?? []
        let helpers = (try? BotDefinitionStore(dataRoot: dataRoot).list())?.map(\.name) ?? []
        let checked: (actions: [AppAction], authored: [AppAction])
        if let snapshot { checked = snapshot } else { checked = try await inventory(dataRoot: dataRoot) }
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
        // No embedder (or it changed mid-read): rank by words alone, and say so.
        func rankingFailure(_ detail: String) -> String {
            AgentWorkspacePorts.readFailure(ToolFailureError(detail, effects: .none, code: "action_ranking_unavailable"),
                reason: "action_ranking_unavailable", remedy: Repair.reconcile(
                    instruction: "Use the lexical matches. Read settings for memory search model status and repair the reported model or action-index fault before relying on semantic ranking.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("settings")])])))
        }
        var embedding: (asked: [[Float]], actions: [[Float]])?
        var degraded: String?
        do {
            let indexed = try await memory.indexedActionVectors(texts)
            // What the index lacks (this turn's own actions) is embedded with the ask, in its space.
            let missing = indexed.vectors.indices.filter { indexed.vectors[$0] == nil }
            let embedded = try await memory.embedForDerivedContextWithEpoch([positive] + missing.map { texts[$0] })
            let ask = Array(embedded.vectors.prefix(1))
            var vectors = indexed.vectors
            for (offset, vector) in zip(missing, embedded.vectors.dropFirst(1)) { vectors[offset] = vector }
            let actionVectors = vectors.compactMap { $0 }
            if embedded.epoch == indexed.epoch, embedded.vectors.count == 1 + missing.count,
               actionVectors.count == actions.count,
               (ask + actionVectors).allSatisfy({
                   $0.count == ask[0].count && !$0.isEmpty
                       && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 })
               }) {
                embedding = (ask, actionVectors)
            } else {
                await memory.requestActionIndexUpdate()
                degraded = rankingFailure("Action-index and query epochs differ or vectors are unusable. An index update was requested.")
            }
        } catch { degraded = rankingFailure(error.localizedDescription) }
        // Assume most inventory actions are irrelevant with a light-tailed cosine tail in this retrieval epoch.
        // Semantic matches must clear the shared attention chance bar; small/flat inventories provide no evidence.
        // Exact tokens and identities stand independently; multilingual coverage belongs to the embedder.
        let similarities = embedding.map { vectors in
            vectors.actions.map { VectorMath.cosine(vectors.asked.first, $0) }
        }
        let standings = VectorMath.standout(similarities ?? [])
        // Two deviations above the inventory, as a memory needs: what the ask
        // brings to mind. (10-29: the chance bar over ~420 actions sat near 4.5
        // deviations, meaning almost never counted and find fell back to shared
        // words, burying routes like sense.make under hundreds of word matches.)
        let bar = ContextSelectionConfiguration.memoryStandoutDeviations
        var ranked: [(offset: Int, action: AppAction, semantic: Bool, similarity: Double, own: Int, lexical: Int)] = []
        for (offset, action) in actions.enumerated() where !excluded.contains(action.id) {
            let lexical = hits(Set(intentWords(texts[offset])), asked)
            let own = hits(ownWords(action), asked)
            let similarity = similarities?[offset] ?? 0
            let semantic = !standings.isEmpty && (standings[offset].map { $0 >= bar } ?? false)
            if named.contains(action.id.lowercased()) || (pagesNamed.contains(action.page) && !action.isItemRead) || lexical > 0 || semantic {
                ranked.append((offset, action, semantic, similarity, own, lexical))
            }
        }
        return (ranked.sorted {
            let leftNamed = named.contains($0.action.id.lowercased())
            let rightNamed = named.contains($1.action.id.lowercased())
            if leftNamed != rightNamed { return leftNamed }
            let leftPage = pagesNamed.contains($0.action.page) && !$0.action.isItemRead
            let rightPage = pagesNamed.contains($1.action.page) && !$1.action.isItemRead
            if leftPage != rightPage { return leftPage }
            if leftPage { return $0.offset < $1.offset }
            if $0.semantic != $1.semantic { return $0.semantic }
            // Closeness of meaning orders word matches too, not only standouts.
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.own != $1.own { return $0.own > $1.own }
            if $0.lexical != $1.lexical { return $0.lexical > $1.lexical }
            return $0.offset < $1.offset
        }.map(\.action).reduce(into: (seen: Set<String>(), kept: [AppAction]())) { result, action in
            // One action once: the same id registered under two labels is one route.
            if result.seen.insert(action.id).inserted { result.kept.append(action) }
        }.kept, degraded, pagesNamed)
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

    /// The actions find matches, best first, each id once; item reads are its read_next.
    static func matchedActions(_ ranked: [AppAction]) -> [AppAction] {
        var seen = Set<String>()
        return ranked.filter { !$0.isItemRead && seen.insert($0.id).inserted }
    }

    /// An action's own identity and authored label, without stemming or aliases.
    static func ownWords(_ action: AppAction) -> Set<String> { Set(intentWords(action.id + " " + action.label)) }

    /// Exact normalized tokens only; morphology belongs to semantic retrieval.
    static func hits(_ own: Set<String>, _ asked: [String]) -> Int {
        asked.filter { own.contains($0) }.count
    }
}
