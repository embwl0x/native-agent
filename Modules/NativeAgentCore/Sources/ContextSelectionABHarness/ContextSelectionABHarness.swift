import Context
import Foundation

// ContextSelectionABHarness — offline A/B for the selection score rebalance
// (docs/build_plans/selection-score-rebalance.md).
//
// Answers ONE question with numbers instead of taste: does giving the CURRENT
// user message its own ranking weight (`ContextScoreWeights.messageCoverage`)
// make selection more query-responsive without moving the mandatory set or
// blowing the latency gate?
//
//   swift run ContextSelectionABHarness \
//       --store data/context/context.sqlite \
//       --queries data/evals/selection_ab_queries.json \
//       --out /tmp/selection_ab_report.json
//
// Hermeticity (nativeagent-hermetic-tests): the live store is NEVER opened.
// The harness shells out to `sqlite3 <src> ".backup '<tmp>'"` first — a
// consistent copy taken under SQLite's own backup API, which is safe against a
// concurrently-writing app and leaves the source byte-identical (the WAL is
// read, not checkpointed by us). Everything downstream reads the copy.
//
// Read path: ContextSQLiteStore.loadActiveGeneration() + the same
// per-atom ContextSelectionIndexEntry snapshot ContextFlowCoordinator builds
// for the arena, handed to ContextSelector.select(_:from:pinnedTo:). Only the
// arena's hot/warm entry mirrors are omitted — select() reads nothing but
// `snapshot.selectionIndex` off the snapshot (plus the generation/fingerprint
// guards, which are honored here).
//
// LIMITATION, on purpose: no query embedding is supplied, so `semanticCosine`
// is 0 for every candidate in every variant. This is a LEXICAL-ONLY A/B. It is
// the right comparison for a lexical feature (messageCoverage) — all three
// variants are handicapped identically — but the absolute selections here are
// not what a warm-embedder production turn would produce.

// MARK: - Variants

struct Variant {
    let name: String
    let weights: ContextScoreWeights
}

let variants: [Variant] = [
    // A is the PRE-rebalance baseline and must stay pinned to an explicit 0:
    // ContextScoreWeights()'s default messageCoverage is now the SHIPPED
    // value (1.5), so a bare default here would silently equal the shipped
    // variant and the A/B would report no delta (gpt-5.5 review 2026-08-13 #2).
    Variant(name: "A_baseline_coverage_0", weights: ContextScoreWeights(messageCoverage: 0)),
    Variant(name: "SHIPPED_default", weights: ContextScoreWeights()),
    Variant(name: "C_coverage_2.5", weights: ContextScoreWeights(messageCoverage: 2.5)),
]

// Production-shaped budgets for a chat turn (spec §5). `maximumCharacterBudget`
// mirrors ContextTurnRequest's bounded escape hatch: only a
// `mandatoryBudgetExceeded` selection is retried, and never above the ceiling.
let characterBudget = 32_000
let maximumCharacterBudget = 48_000
let minimumQueryCharacters = 3

// MARK: - Report shapes

struct QueryResult: Codable {
    let index: Int
    let query: String
    let dynamicAtomIDs: [String]
    let mandatoryAtomIDs: [String]
    let dynamicAtomCount: Int
    let selectionMicroseconds: Int
    let usedCharacters: Int
    let expandedBudget: Bool
    let topPick: AtomScore?
    let dynamicScores: [AtomScore]
}

struct AtomScore: Codable {
    let atomID: String
    let kind: String
    let messageCoverage: Double
    let tokenOverlap: Double
    let total: Double
}

struct VariantReport: Codable {
    let variant: String
    let messageCoverageWeight: Double
    let meanPairwiseJaccard: Double
    let distinctDynamicSelections: Int
    let meanDynamicAtomCount: Double
    let p50SelectionMicroseconds: Int
    let p95SelectionMicroseconds: Int
    let meanMessageCoverageOfTopPick: Double
    let queries: [QueryResult]
}

struct MandatoryDivergence: Codable {
    let queryIndex: Int
    let query: String
    let variant: String
    let baselineVariant: String
    let onlyInBaseline: [String]
    let onlyInVariant: [String]
}

struct HarnessReport: Codable {
    let generatedAt: String
    let storePath: String
    let storeBackupPath: String
    let queriesPath: String
    let generationID: Int64
    let sourceFingerprint: String
    let atomCount: Int
    let sourceCount: Int
    let queryCount: Int
    let evaluatedQueryCount: Int
    let skippedQueryCount: Int
    let skippedQueryIndexes: [Int]
    let characterBudget: Int
    let maximumCharacterBudget: Int
    let embeddingUsed: Bool
    let limitations: [String]
    let mandatorySetIdenticalAcrossVariants: Bool
    let mandatoryDivergences: [MandatoryDivergence]
    let variants: [VariantReport]
}

// MARK: - Entry point

@main
struct ContextSelectionABHarnessMain {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(
                Data("ContextSelectionABHarness: \(error)\n".utf8)
            )
            exit(1)
        }
    }

    static func run() async throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))

        // 1. Consistent copy. The live file is never opened by this process.
        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selection-ab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let backupURL = workDirectory.appendingPathComponent("context.sqlite")
        try backupStore(from: options.store, to: backupURL)

        // 2. Latest completed generation, through the production read path.
        let store = try ContextSQLiteStore(databaseURL: backupURL)
        guard let generation = try await store.loadActiveGeneration() else {
            throw HarnessError.noActiveGeneration(options.store.path)
        }
        let snapshot = try makeSelectionSnapshot(for: generation)

        // 3. Queries.
        let allQueries = try loadQueries(options.queries)
        var evaluated: [(index: Int, text: String)] = []
        var skipped: [Int] = []
        for (index, query) in allQueries.enumerated() {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < minimumQueryCharacters {
                skipped.append(index)
            } else {
                evaluated.append((index, query))
            }
        }

        let authorization = ContextSelectionAuthorization(
            allowedOrigins: [.localAuthenticated],
            allowedPrivacy: Set(ContextPrivacy.allCases),
            allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
        )

        // 4. Three variants over the same generation, snapshot, and needs.
        var variantReports: [VariantReport] = []
        for variant in variants {
            let selector = ContextSelector(
                configuration: ContextSelectionConfiguration(weights: variant.weights)
            )
            // Untimed warmup so the first real query does not carry this
            // variant's cold-path cost into the latency percentiles.
            if let first = evaluated.first {
                _ = try? select(
                    query: first.text,
                    selector: selector,
                    generation: generation,
                    snapshot: snapshot,
                    authorization: authorization
                )
            }
            var results: [QueryResult] = []
            for query in evaluated {
                let outcome = try select(
                    query: query.text,
                    selector: selector,
                    generation: generation,
                    snapshot: snapshot,
                    authorization: authorization
                )
                results.append(makeQueryResult(
                    index: query.index,
                    query: query.text,
                    outcome: outcome
                ))
            }
            variantReports.append(makeVariantReport(variant: variant, results: results))
        }

        // 5. Mandatory invariant: identical across variants for every query.
        let divergences = mandatoryDivergences(variantReports)

        let report = HarnessReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            storePath: options.store.path,
            storeBackupPath: backupURL.path,
            queriesPath: options.queries.path,
            generationID: generation.generation.id,
            sourceFingerprint: generation.generation.sourceFingerprint,
            atomCount: generation.atoms.count,
            sourceCount: generation.sources.count,
            queryCount: allQueries.count,
            evaluatedQueryCount: evaluated.count,
            skippedQueryCount: skipped.count,
            skippedQueryIndexes: skipped,
            characterBudget: characterBudget,
            maximumCharacterBudget: maximumCharacterBudget,
            embeddingUsed: false,
            limitations: [
                "Lexical-only A/B: no query embedding is supplied, so semanticCosine is 0 for every candidate in every variant.",
                "Cognitive inputs (activation, workingAtomIDs, contextualTerms, predictedToolGroups, recentTurns) are empty — this measures the message signal in isolation, not a full production turn.",
                "Feedback utility/decay overrides are not applied; stored per-atom values are used as-is.",
            ],
            mandatorySetIdenticalAcrossVariants: divergences.isEmpty,
            mandatoryDivergences: divergences,
            variants: variantReports
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: options.out, options: .atomic)

        printSummary(report, reportPath: options.out)
    }
}

// MARK: - Options

struct Options {
    let store: URL
    let queries: URL
    let out: URL

    init(arguments: [String]) throws {
        var store: String?
        var queries: String?
        var out: String?
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw HarnessError.missingValue(flag)
                }
                index += 1
                return arguments[index]
            }
            switch flag {
            case "--store": store = try value()
            case "--queries": queries = try value()
            case "--out": out = try value()
            case "--help", "-h":
                print(Options.usage)
                exit(0)
            default:
                throw HarnessError.unknownArgument(flag)
            }
            index += 1
        }
        guard let store, let queries, let out else {
            throw HarnessError.usage(Options.usage)
        }
        self.store = URL(fileURLWithPath: store).standardizedFileURL
        self.queries = URL(fileURLWithPath: queries).standardizedFileURL
        self.out = URL(fileURLWithPath: out).standardizedFileURL
    }

    static let usage = """
    usage: ContextSelectionABHarness --store <context.sqlite> \
    --queries <queries.json> --out <report.json>
    """
}

enum HarnessError: Error, CustomStringConvertible {
    case usage(String)
    case missingValue(String)
    case unknownArgument(String)
    case backupFailed(status: Int32, output: String)
    case backupMissing
    case noActiveGeneration(String)
    case malformedQueries(String)

    var description: String {
        switch self {
        case .usage(let text): text
        case .missingValue(let flag): "missing value for \(flag)"
        case .unknownArgument(let flag): "unknown argument \(flag)"
        case .backupFailed(let status, let output):
            "sqlite3 .backup failed (exit \(status)): \(output)"
        case .backupMissing: "sqlite3 .backup produced no file"
        case .noActiveGeneration(let path): "no completed generation in \(path)"
        case .malformedQueries(let path):
            "expected {\"queries\": [\"...\"]} in \(path)"
        }
    }
}

// MARK: - Store copy

func backupStore(from source: URL, to destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    // `-readonly` so the source cannot be written even transiently; the backup
    // API still takes a transaction-consistent copy of a live WAL database.
    process.arguments = ["-readonly", source.path, ".backup '\(destination.path)'"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HarnessError.backupFailed(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self)
        )
    }
    guard FileManager.default.fileExists(atPath: destination.path) else {
        throw HarnessError.backupMissing
    }
}

// MARK: - Selection

/// Mirrors ContextFlowCoordinator.makeArenaSnapshot's selection index — the
/// only snapshot field `select()` reads — so the harness ranks off exactly the
/// lexical material a live turn ranks off.
func makeSelectionSnapshot(
    for generation: ContextStoredGeneration
) throws -> ContextGenerationSnapshot {
    var selectionIndex: [ContextAtomID: ContextSelectionIndexEntry] = [:]
    for atom in generation.atoms {
        selectionIndex[atom.draft.id] = ContextSelectionIndexEntry(atom: atom.draft)
    }
    return try ContextGenerationSnapshot(
        generationID: generation.generation.id,
        sourceFingerprint: generation.generation.sourceFingerprint,
        selectionIndex: selectionIndex
    )
}

struct SelectionOutcome {
    let packet: ContextPacket
    let microseconds: Int
    let expandedBudget: Bool
}

func select(
    query: String,
    selector: ContextSelector,
    generation: ContextStoredGeneration,
    snapshot: ContextGenerationSnapshot,
    authorization: ContextSelectionAuthorization
) throws -> SelectionOutcome {
    func need(budget: Int) -> NeedSignal {
        NeedSignal(
            message: query,
            surface: .chat,
            origin: .localAuthenticated,
            authorization: authorization,
            availableGenerationID: generation.generation.id,
            characterBudget: budget
        )
    }

    func run(_ budget: Int) throws -> (ContextPacket, Int) {
        let started = DispatchTime.now().uptimeNanoseconds
        let packet = try selector.select(
            need(budget: budget),
            from: generation,
            pinnedTo: snapshot,
            measureLatency: true
        )
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000)
        return (packet, packet.receipt.measuredSelectionMicroseconds ?? elapsed)
    }

    do {
        let (packet, micros) = try run(characterBudget)
        return SelectionOutcome(packet: packet, microseconds: micros, expandedBudget: false)
    } catch ContextSelectionError.mandatoryBudgetExceeded(let required, _)
        where required <= maximumCharacterBudget
    {
        // Same bounded escape hatch ContextFlowCoordinator applies: retry once,
        // never above the ceiling.
        let (packet, micros) = try run(max(characterBudget, required))
        return SelectionOutcome(packet: packet, microseconds: micros, expandedBudget: true)
    }
}

// MARK: - Metrics

func makeQueryResult(index: Int, query: String, outcome: SelectionOutcome) -> QueryResult {
    let packet = outcome.packet
    let dynamicItems = packet.selectedItems.filter { !$0.mandatory }
    let featuresByAtom = Dictionary(
        packet.receipt.candidateScores.map { ($0.atomID, $0.features) },
        uniquingKeysWith: { first, _ in first }
    )
    let dynamicScores = dynamicItems.map { item in
        let features = featuresByAtom[item.pointer.atomID]
        return AtomScore(
            atomID: item.pointer.atomID.rawValue,
            kind: item.pointer.kind.rawValue,
            messageCoverage: features?.messageCoverage ?? 0,
            tokenOverlap: features?.tokenOverlap ?? 0,
            total: features?.total ?? 0
        )
    }
    return QueryResult(
        index: index,
        query: query,
        dynamicAtomIDs: dynamicItems.map(\.pointer.atomID.rawValue),
        mandatoryAtomIDs: packet.receipt.mandatoryAtomIDs.map(\.rawValue).sorted(),
        dynamicAtomCount: dynamicItems.count,
        selectionMicroseconds: outcome.microseconds,
        usedCharacters: packet.budget.usedCharacters,
        expandedBudget: outcome.expandedBudget,
        // Packet order is mandatory-first then dynamic in rank order, so the
        // first dynamic item IS the top-ranked pick.
        topPick: dynamicScores.first,
        dynamicScores: dynamicScores
    )
}

func makeVariantReport(variant: Variant, results: [QueryResult]) -> VariantReport {
    let dynamicSets = results.map { Set($0.dynamicAtomIDs) }
    var pairwise: [Double] = []
    for i in dynamicSets.indices {
        for j in dynamicSets.index(after: i)..<dynamicSets.endIndex {
            pairwise.append(jaccard(dynamicSets[i], dynamicSets[j]))
        }
    }
    let distinct = Set(results.map { $0.dynamicAtomIDs.sorted().joined(separator: "|") })
    let latencies = results.map(\.selectionMicroseconds).sorted()
    let topCoverages = results.compactMap { $0.topPick?.messageCoverage }
    return VariantReport(
        variant: variant.name,
        messageCoverageWeight: variant.weights.messageCoverage,
        meanPairwiseJaccard: mean(pairwise),
        distinctDynamicSelections: distinct.count,
        meanDynamicAtomCount: mean(results.map { Double($0.dynamicAtomCount) }),
        p50SelectionMicroseconds: percentile(latencies, 0.50),
        p95SelectionMicroseconds: percentile(latencies, 0.95),
        meanMessageCoverageOfTopPick: mean(topCoverages),
        queries: results
    )
}

/// The mandatory set is authority/policy-derived — it must not move when a
/// ranking weight moves. Any row here is a loud failure of that invariant.
func mandatoryDivergences(_ reports: [VariantReport]) -> [MandatoryDivergence] {
    guard let baseline = reports.first else { return [] }
    var divergences: [MandatoryDivergence] = []
    for report in reports.dropFirst() {
        for (index, query) in report.queries.enumerated() {
            guard index < baseline.queries.count else { continue }
            let expected = Set(baseline.queries[index].mandatoryAtomIDs)
            let actual = Set(query.mandatoryAtomIDs)
            guard expected != actual else { continue }
            divergences.append(MandatoryDivergence(
                queryIndex: query.index,
                query: query.query,
                variant: report.variant,
                baselineVariant: baseline.variant,
                onlyInBaseline: expected.subtracting(actual).sorted(),
                onlyInVariant: actual.subtracting(expected).sorted()
            ))
        }
    }
    return divergences
}

func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
    let union = lhs.union(rhs)
    guard !union.isEmpty else { return 1 }
    return Double(lhs.intersection(rhs).count) / Double(union.count)
}

func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

/// Nearest-rank percentile over an already-sorted sample.
func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count - 1, max(0, rank - 1))]
}

// MARK: - Queries

func loadQueries(_ url: URL) throws -> [String] {
    struct Fixture: Decodable { let queries: [String] }
    let data = try Data(contentsOf: url)
    guard let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
        throw HarnessError.malformedQueries(url.path)
    }
    return fixture.queries
}

// MARK: - Human summary

func printSummary(_ report: HarnessReport, reportPath: URL) {
    print("generation \(report.generationID) — \(report.atomCount) atoms, "
        + "\(report.sourceCount) sources")
    print("queries: \(report.evaluatedQueryCount) evaluated, "
        + "\(report.skippedQueryCount) skipped (<\(minimumQueryCharacters) chars)")
    print("lexical-only (no query embedding); budget \(report.characterBudget)"
        + "/\(report.maximumCharacterBudget) chars")
    print("")
    let header = pad("variant", 16) + pad("meanJaccard", 14) + pad("distinct", 10)
        + pad("meanDynAtoms", 14) + pad("p50us", 8) + pad("p95us", 8)
        + pad("topCoverage", 12)
    print(header)
    print(String(repeating: "-", count: header.count))
    for variant in report.variants {
        print(
            pad(variant.variant, 16)
            + pad(format(variant.meanPairwiseJaccard, 4), 14)
            + pad(String(variant.distinctDynamicSelections), 10)
            + pad(format(variant.meanDynamicAtomCount, 2), 14)
            + pad(String(variant.p50SelectionMicroseconds), 8)
            + pad(String(variant.p95SelectionMicroseconds), 8)
            + pad(format(variant.meanMessageCoverageOfTopPick, 4), 12)
        )
    }
    print("")
    if report.mandatorySetIdenticalAcrossVariants {
        print("mandatory invariant: OK (identical across all variants, all queries)")
    } else {
        print("mandatory invariant: VIOLATED — "
            + "\(report.mandatoryDivergences.count) query/variant divergence(s)")
        for divergence in report.mandatoryDivergences.prefix(10) {
            print("  q\(divergence.queryIndex) \(divergence.variant): "
                + "-\(divergence.onlyInBaseline.count) +\(divergence.onlyInVariant.count)")
        }
    }
    print("report: \(reportPath.path)")
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

func format(_ value: Double, _ places: Int) -> String {
    String(format: "%.\(places)f", value)
}
