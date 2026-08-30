import Context
import Foundation
import Testing

// MARK: - Repo scanning support
//
// Same shape as ActivityWatchArchitectureTests: walk up to the repo root from
// this file, read production sources, strip comments so prose that NAMES a
// symbol in order to explain it does not count as a use of it.

/// Walks up from this source file to the repository root (the directory holding
/// the root `Package.swift` next to `Modules/`).
private func repositoryRoot() -> URL? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let manifest = directory.appendingPathComponent("Package.swift")
        let modules = directory.appendingPathComponent("Modules", isDirectory: true)
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: modules.path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
    return nil
}

/// Strips `//` line comments and `/* */` block comments. A guard that counts a
/// comment as a producer is a guard that passes on documentation.
private func strippingComments(_ source: String) -> String {
    var out = ""
    var index = source.startIndex
    var inBlock = false
    while index < source.endIndex {
        let rest = source[index...]
        if inBlock {
            if rest.hasPrefix("*/") {
                inBlock = false
                index = source.index(index, offsetBy: 2)
            } else {
                index = source.index(after: index)
            }
            continue
        }
        if rest.hasPrefix("/*") {
            inBlock = true
            index = source.index(index, offsetBy: 2)
            continue
        }
        if rest.hasPrefix("//") {
            while index < source.endIndex, source[index] != "\n" {
                index = source.index(after: index)
            }
            continue
        }
        out.append(source[index])
        index = source.index(after: index)
    }
    return out
}

/// Every production `.swift` line under the given repo-relative trees, comments
/// removed and `case …` pattern-match lines dropped.
///
/// Dropping `case` lines is what separates a PRODUCER from a CONSUMER. The
/// feedback reducer and the coordinator's signal-name switch both mention every
/// signal in the vocabulary — as `case .outcome(.contradicted):` — and counting
/// those would make a signal that nothing can ever emit look perfectly alive.
private func productionCodeLines(under relativePaths: [String]) throws -> [(file: String, line: String)] {
    let root = try #require(repositoryRoot())
    var out: [(String, String)] = []
    for relativePath in relativePaths {
        let directory = root.appendingPathComponent(relativePath)
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { continue }
        for case let file as URL in walker where file.pathExtension == "swift" {
            let raw = try String(contentsOf: file, encoding: .utf8)
            for line in strippingComments(raw).split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("case ") { continue }
                out.append((file.lastPathComponent, trimmed))
            }
        }
    }
    return out
}

/// Case names declared in `enum <name>` inside one source file, in order.
private func declaredCaseNames(ofEnum enumName: String, inFileAt relativePath: String) throws -> [String] {
    let root = try #require(repositoryRoot())
    let raw = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    let source = strippingComments(raw)
    guard let declaration = source.range(of: "enum \(enumName)") else {
        Issue.record("enum \(enumName) not found in \(relativePath) — did it move or get renamed?")
        return []
    }
    var depth = 0
    var body = ""
    var started = false
    for character in source[declaration.lowerBound...] {
        if character == "{" {
            depth += 1
            started = true
            if depth == 1 { continue }
        }
        if character == "}" {
            depth -= 1
            if depth == 0 { break }
        }
        if started, depth >= 1 { body.append(character) }
    }
    var names: [String] = []
    for line in body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("case ") else { continue }
        // `case selection`, `case correction(ContextCorrectionEffect)`,
        // `case localPrivate = "local_private"`, `case a, b, c`.
        let tail = trimmed.dropFirst("case ".count)
        for piece in tail.split(separator: ",") {
            let name = piece
                .split(separator: "=").first.map(String.init)?
                .split(separator: "(").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !name.isEmpty { names.append(name) }
        }
    }
    return names
}

/// Dead-vocabulary guards for the two Context enums whose members are declared
/// in one place and produced in another.
///
/// The failure they catch is the one that never shows up as a crash or a red
/// test: a case exists, the reducer implements weighty behavior for it, and
/// NOTHING in the app can emit it. Downstream, that reads as a healthy feature.
/// It cost the ledger two live findings — `.expansion` is a declared receipt
/// kind with no writer at all, and the feedback loop's entire NEGATIVE pole
/// (`correction.contradicts` at outcomeUtility -0.45, the largest magnitude in
/// the table) has no producer, so the only signal with weight in production is
/// positive-only and self-reinforcing.
///
/// Each guard is: parse the declared cases from source, find each case's
/// producer token in production code, and require every case to be either
/// PRODUCED or written down in a dated dormancy list with a reason. That makes
/// both directions fail loudly — adding a case with no producer, and removing
/// the last producer of a case that used to be live.
@Suite("Fluid Context vocabulary reachability")
struct ContextVocabularyReachabilityTests {
    private static let contextModule = "Modules/NativeAgentCore/Sources/Context"
    private static let productionTrees = [
        "Modules/NativeAgentCore/Sources",
        "Sources",
    ]

    // MARK: - Receipt kinds

    /// `ContextReceiptKind` is the whole observability vocabulary of the context
    /// lane: nothing else records what selection, compilation, prewarm, memory
    /// pressure or degradation did. Receipts are only ever written through
    /// `ContextSQLiteStore.recordReceipt`, and the Context module is its only
    /// caller, so the producer scan is scoped there.
    @Test
    func everyContextReceiptKindHasAWriterOrADatedDormancyReason() throws {
        /// Declared kinds with no writer anywhere, each with the date it was
        /// established and why it is tolerated. Burn these down; never grow the
        /// list without a reason a reader can check.
        let dormant: [String: String] = [
            // 2026-08-23 (coverage ledger, fence core.context): declared kind
            // with ZERO producers in the repo and zero rows in the live store.
            // The expansion lane records its outcome as a FEEDBACK signal
            // (ContextTurnRuntime.recordExpansion) and never as a receipt, so
            // this case is schema vocabulary that makes a future reader believe
            // expansion telemetry exists. Retire it or give it a writer.
            "expansion": "no producer in repo; expansion telemetry rides the feedback signal instead",
        ]

        let kinds = try declaredCaseNames(
            ofEnum: "ContextReceiptKind",
            inFileAt: "\(Self.contextModule)/ContextFlowModels.swift"
        )
        #expect(kinds.count >= 7, "receipt-kind vocabulary shrank unexpectedly: \(kinds)")

        let lines = try productionCodeLines(under: [Self.contextModule])
        #expect(!lines.isEmpty)

        var unwritten: [String] = []
        var dormantButWritten: [String] = []
        for kind in kinds {
            let written = lines.contains { $0.line.contains("kind: .\(kind)") }
            if written, dormant[kind] != nil { dormantButWritten.append(kind) }
            if !written, dormant[kind] == nil { unwritten.append(kind) }
        }
        #expect(
            unwritten.isEmpty,
            """
            ContextReceiptKind case(s) \(unwritten.sorted()) have no writer. Either the \
            only durable signal for that lane just went dark, or the case is dead schema \
            vocabulary — give it a writer or add a dated dormancy entry.
            """
        )
        #expect(
            dormantButWritten.isEmpty,
            "kind(s) \(dormantButWritten.sorted()) are listed dormant but now have a writer — remove the dormancy entry"
        )
        // The dormancy list must not outlive its subject either.
        let unknownDormant = Set(dormant.keys).subtracting(kinds)
        #expect(unknownDormant.isEmpty, "dormancy list names kind(s) that no longer exist: \(unknownDormant.sorted())")
    }

    // MARK: - Feedback signals

    /// Every leaf of the `ContextFeedbackSignal` vocabulary, mapped to the one
    /// literal token a production caller must write to emit it. The forwarders
    /// (`ContextPreparedTurn.recordRetry` and friends) are declarations, so the
    /// tokens carry a leading `.` and only match CALL sites.
    private static let feedbackProducerTokens: [String: String] = [
        "selection": "signal: .selection",
        "expansion": ".recordExpansion(",
        "retry": ".recordRetry()",
        "correction.confirms": ".correction(.confirms)",
        "correction.contradicts": ".correction(.contradicts)",
        "outcome.completed": ".recordOutcome(.completed)",
        "outcome.confirmed": ".recordOutcome(.confirmed)",
        "outcome.contradicted": ".recordOutcome(.contradicted)",
        "outcome.abandoned": ".recordOutcome(.abandoned)",
    ]

    @Test
    func everyContextFeedbackSignalLeafHasAProducerOrADatedDormancyReason() throws {
        /// 2026-08-30: applied canonical memory corrections now produce an
        /// atom-exact contradiction through the prepared-turn provenance map.
        /// Affirmation and whole-turn confirmation remain deliberately dormant:
        /// completion/praise must not certify all selected context as useful.
        let dormant: [String: String] = [
            "correction.confirms": "no authoritative per-memory confirmation producer",
            "outcome.confirmed": "no producer; only .completed/.abandoned are emitted by the tool loop",
            "outcome.contradicted": "no producer; only .completed/.abandoned are emitted by the tool loop",
        ]

        // Parse the vocabulary out of source so ADDING a case fails here.
        let signalCases = try declaredCaseNames(
            ofEnum: "ContextFeedbackSignal",
            inFileAt: "\(Self.contextModule)/ContextFeedback.swift"
        )
        let correctionCases = try declaredCaseNames(
            ofEnum: "ContextCorrectionEffect",
            inFileAt: "\(Self.contextModule)/ContextFeedback.swift"
        )
        let outcomeCases = try declaredCaseNames(
            ofEnum: "ContextTurnOutcome",
            inFileAt: "\(Self.contextModule)/ContextFeedback.swift"
        )
        var leaves: [String] = []
        for signalCase in signalCases {
            switch signalCase {
            case "correction": leaves += correctionCases.map { "correction.\($0)" }
            case "outcome": leaves += outcomeCases.map { "outcome.\($0)" }
            default: leaves.append(signalCase)
            }
        }
        #expect(leaves.count == 9, "feedback vocabulary changed: \(leaves.sorted())")

        // Every leaf needs a producer token, or the scan below is vacuous for it.
        let untokenized = Set(leaves).subtracting(Self.feedbackProducerTokens.keys)
        #expect(
            untokenized.isEmpty,
            "new feedback signal leaf/leaves \(untokenized.sorted()) — add the token a producer must write, then re-run"
        )

        let lines = try productionCodeLines(under: Self.productionTrees)
        #expect(lines.count > 1_000, "production scan found only \(lines.count) lines — did the guard lose its target?")

        var unreachable: [String] = []
        var dormantButProduced: [String] = []
        for leaf in leaves {
            guard let token = Self.feedbackProducerTokens[leaf] else { continue }
            let produced = lines.contains { $0.line.contains(token) }
            if produced, dormant[leaf] != nil { dormantButProduced.append(leaf) }
            if !produced, dormant[leaf] == nil { unreachable.append(leaf) }
        }
        #expect(
            unreachable.isEmpty,
            """
            ContextFeedbackSignal leaf/leaves \(unreachable.sorted()) can no longer be \
            produced by any production caller. The reducer still implements them, so the \
            loss is invisible — restore the producer or add a dated dormancy entry.
            """
        )
        #expect(
            dormantButProduced.isEmpty,
            """
            leaf/leaves \(dormantButProduced.sorted()) are listed dormant but now HAVE a \
            producer — good news; delete the dormancy entry so the guard keeps its teeth.
            """
        )
        let unknownDormant = Set(dormant.keys).subtracting(leaves)
        #expect(unknownDormant.isEmpty, "dormancy list names leaf/leaves that no longer exist: \(unknownDormant.sorted())")
    }
}
