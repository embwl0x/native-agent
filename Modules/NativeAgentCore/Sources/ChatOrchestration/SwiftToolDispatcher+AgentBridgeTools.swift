import Foundation
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import SlackConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

extension SwiftToolDispatcher {

    /// Stamp every delegated wake with the runtime contract that produced it.
    /// Older job records deliberately remain unstamped: readers can then keep
    /// historical uncertainty separate from evidence produced by this build.
    static func stampDelegationProducer(on payload: inout [String: JSONValue]) {
        payload["producerSchemaVersion"] = .int(1)
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "NativeAgentSourceRevision") as? String else {
            return
        }
        let revision = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard revision.count == 40, revision.allSatisfy({ $0.isHexDigit }) else { return }
        payload["producerSourceRevision"] = .string(revision)
    }

    /// Optional exact Desk binding for delegated work. The visible alias is
    /// accepted at the tool edge, but only the stable live handle crosses into
    /// bridge job evidence. No fuzzy title/topic inference is allowed.
    func delegationDeskHandle(_ input: [String: JSONValue]) async throws -> String? {
        guard let raw = input["desk_item"] else { return nil }
        guard case .string(let value) = raw else {
            throw AutonomyGateError.toolDenied(reason: "delegation: desk_item must be a string")
        }
        let reference = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 2026-09-07: models spell "no desk item" as a sentinel string; the
        // agent looped 78 times on desk_item "none" being "not a live Desk
        // item". An empty or sentinel value means no desk binding, like omission.
        let noItem: Set<String> = ["", "none", "null", "nil", "no", "n/a", "na", "-"]
        if noItem.contains(reference.lowercased()) { return nil }
        let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
        guard let item = state.items.first(where: {
            $0.handle == reference || $0.alias == reference
        }) else {
            throw AutonomyGateError.toolDenied(
                reason: "delegation: desk_item '\(reference)' is not a live Desk item"
            )
        }
        return item.handle
    }
    /// Delegated bridge transcripts contain prompts and replies, so retain a
    /// bounded recent audit window rather than letting an unobserved side feed
    /// grow forever. Session pointers are not audits; a last-message sidecar
    /// is removed only with the matching evicted audit, never by itself while
    /// an active Codex process may still be writing it.
    static let agentBridgeAuditRetention = 100
    private static let agentBridgeAuditLock = NSLock()

    static func trimAgentBridgeAudits(in directory: URL) {
        agentBridgeAuditLock.lock()
        defer { agentBridgeAuditLock.unlock() }
        let fm = FileManager.default
        let audits = ((try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { file in
            file.pathExtension == "json"
                && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }
        guard audits.count > agentBridgeAuditRetention else { return }
        for file in audits.prefix(audits.count - agentBridgeAuditRetention) {
            try? fm.removeItem(at: file)
            guard !fm.fileExists(atPath: file.path) else { continue }
            let runID = file.deletingPathExtension().lastPathComponent
            let lastMessage = directory.appendingPathComponent("\(runID)-last-message.txt")
            try? fm.removeItem(at: lastMessage)
        }
    }
    /// A wire handle over the builder CLIs' existing conversation state.
    /// NativeAgent does not copy transcripts or create a second session store:
    /// Codex owns its thread id, while Claude and OMP own per-topic pointers.
    enum BuilderConversationAgent: String {
        case codex
        case claude
        case omp
    }

    struct BuilderConversationSelection {
        let conversationId: String?
        let resumeId: String?
        let topic: String?
    }

    enum BuilderConversationMode: String, Equatable {
        case new
        case resume
    }

    enum BuilderConversationReferenceError: Error {
        case malformed(expectedAgent: BuilderConversationAgent)
        case invalidMode
        case modeConflict(mode: BuilderConversationMode)
        case agentMismatch(expected: BuilderConversationAgent, actual: String)
        case topicMismatch(conversationId: String, topic: String)

        var envelope: JSONValue {
            switch self {
            case .malformed(let expectedAgent):
                return .object([
                    "status": .string("failed"),
                    "reason": .string("invalid_conversation_id"),
                    "fix": .string("Pass the exact \(expectedAgent.rawValue):… conversationId returned by the first builder message."),
                ])
            case .invalidMode:
                return .object([
                    "status": .string("failed"),
                    "reason": .string("invalid_conversation_mode"),
                    "fix": .string("Use conversation_mode='new' with no conversation_id, or conversation_mode='resume' with the exact returned conversationId."),
                ])
            case .modeConflict(let mode):
                return .object([
                    "status": .string("failed"),
                    "reason": .string("conversation_mode_conflict"),
                    "conversationMode": .string(mode.rawValue),
                    "fix": .string(mode == .new
                        ? "Remove conversation_id when starting new work."
                        : "Pass the exact conversationId returned by the earlier builder message when resuming."),
                ])
            case .agentMismatch(let expected, let actual):
                return .object([
                    "status": .string("failed"),
                    "reason": .string("conversation_agent_mismatch"),
                    "expectedAgent": .string(expected.rawValue),
                    "actualAgent": .string(actual),
                    "fix": .string("Reply with the same builder tool that created this conversation."),
                ])
            case .topicMismatch(let conversationId, let topic):
                return .object([
                    "status": .string("failed"),
                    "reason": .string("conversation_topic_mismatch"),
                    "conversationId": .string(conversationId),
                    "topic": .string(topic),
                    "fix": .string("Omit topic when replying, or use the topic encoded by conversationId."),
                ])
            }
        }
    }

    /// The ONE answer to "did the caller actually reference a conversation?".
    /// `builderConversationSelection` treats an empty `conversation_id` as
    /// absent; the worktree allocator's `isFollowUp` has to agree or empty is
    /// only half-absent — it would take the follow-up branch and reject a
    /// caller-supplied working_directory as a `follow_up_directory_conflict`
    /// on what is, by the same rule, brand new work.
    static func builderConversationReferenceSupplied(in input: [String: JSONValue]) -> Bool {
        guard case .string(let raw)? = input["conversation_id"] else {
            // A non-string value is malformed, not absent —
            // builderConversationSelection rejects it before this is read.
            return input["conversation_id"] != nil
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func builderMessageId(input: [String: JSONValue]) -> String {
        guard case .string(let raw)? = input["message_id"] else { return UUID().uuidString }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? UUID().uuidString : String(value.prefix(160))
    }

    /// Legacy synchronous invoke cwd selection; async bridge admission has its own trust checks.
    static func builderInvokeWorkingDirectory(input: [String: JSONValue], dataRoot: URL) -> String {
        if case .string(let c)? = input["cwd"], !c.isEmpty { return c }
        _ = try? NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
        return builderSourceRepoRoot(dataRoot: dataRoot)?.path
            ?? builderWorkspaceRoot(dataRoot: dataRoot).path
    }

    static func builderConversationSelection(
        input: [String: JSONValue],
        agent: BuilderConversationAgent,
        topic: String?,
        messageId: String
    ) -> Result<BuilderConversationSelection, BuilderConversationReferenceError> {
        let requestedMode: BuilderConversationMode?
        if let rawMode = input["conversation_mode"] {
            guard case .string(let raw) = rawMode,
                  let mode = BuilderConversationMode(
                    rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  ) else {
                return .failure(.invalidMode)
            }
            requestedMode = mode
        } else {
            requestedMode = nil
        }

        let suppliedReference: String?
        if let rawReference = input["conversation_id"] {
            guard case .string(let raw) = rawReference else {
                return .failure(.malformed(expectedAgent: agent))
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 2026-08-28 (upgrade-sweep C9-1): an EMPTY conversation_id means
            // "no conversation", which is exactly what omitting the key means —
            // the tool description already says "omit it for new work". Many
            // tool-calling models cannot emit an absent optional and send "".
            // Rejecting that as `invalid_conversation_id` cost 75 of the 101
            // live claude_message failures in traces/events.jsonl (turn_traces
            // 2026-08-*, all with `"conversation_id": ""`). Empty is absent.
            suppliedReference = value.isEmpty ? nil : value
        } else {
            suppliedReference = nil
        }

        if requestedMode == .new, suppliedReference != nil {
            // Never discard a non-empty stale handle and silently start a
            // different job. The caller must make the new-work intent exact.
            return .failure(.modeConflict(mode: .new))
        }
        if requestedMode == .resume, suppliedReference == nil {
            return .failure(.modeConflict(mode: .resume))
        }

        guard let suppliedReference else {
            if agent == .codex {
                return .success(.init(conversationId: nil, resumeId: nil, topic: topic))
            }
            let stableTopic = topic ?? "conversation-\(shortStableBuilderMessageId(messageId))"
            let slug = builderTopicSlug(stableTopic)
            return .success(.init(
                conversationId: "\(agent.rawValue):\(slug)",
                resumeId: slug,
                topic: slug
            ))
        }

        let pieces = suppliedReference.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return .failure(.malformed(expectedAgent: agent)) }
        let actualAgent = String(pieces[0])
        guard actualAgent == agent.rawValue else {
            return .failure(.agentMismatch(expected: agent, actual: actualAgent))
        }
        let resumeId = String(pieces[1])
        guard !resumeId.isEmpty, resumeId.count <= 160,
              resumeId.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value)
                      || (65...90).contains(value)
                      || (97...122).contains(value)
                      || scalar == "-" || scalar == "_" || scalar == "."
              }) else {
            return .failure(.malformed(expectedAgent: agent))
        }

        if agent != .codex {
            guard builderTopicSlug(resumeId) == resumeId else {
                return .failure(.malformed(expectedAgent: agent))
            }
            if let topic, builderTopicSlug(topic) != resumeId {
                return .failure(.topicMismatch(conversationId: suppliedReference, topic: topic))
            }
        }
        return .success(.init(
            conversationId: suppliedReference,
            resumeId: resumeId,
            topic: agent == .codex ? topic : resumeId
        ))
    }

    /// Matches `topicSlug` in both builder wake helpers: ASCII lowercase
    /// alphanumerics, collapsed dash separators, 64-character ceiling.
    private static func builderTopicSlug(_ raw: String) -> String {
        var output = ""
        var pendingSeparator = false
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(value) || (97...122).contains(value)
            if isASCIIAlphaNumeric {
                if pendingSeparator, !output.isEmpty { output.append("-") }
                pendingSeparator = false
                output.unicodeScalars.append(scalar)
            } else if !output.isEmpty {
                pendingSeparator = true
            }
        }
        let canonical = String(output.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return canonical.isEmpty ? "general" : canonical
    }

    /// File-internal accessor so the replay guard slugs a topic EXACTLY the way
    /// the conversation-reference validator above does. A second slug function
    /// would be a cross-vocabulary seam waiting to silently mismatch.
    static func builderTopicSlugForReplayGuard(_ raw: String) -> String {
        builderTopicSlug(raw)
    }

    private static func shortStableBuilderMessageId(_ messageId: String) -> String {
        SHA256.hash(data: Data(messageId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func stringField(_ name: String, in value: JSONValue) -> String? {
        guard case .object(let object) = value, case .string(let string)? = object[name] else { return nil }
        return string
    }

    struct BuilderReviewPairError: Error {
        let value: JSONValue
    }

    static func pairReviewerRequested(
        in input: [String: JSONValue]
    ) -> Result<Bool, BuilderReviewPairError> {
        guard let value = input["pair_reviewer"] else { return .success(false) }
        guard case .bool(let requested) = value else {
            return .failure(BuilderReviewPairError(value: .object([
                "status": .string("failed"),
                "reason": .string("invalid_pair_reviewer"),
                "fix": .string("pair_reviewer must be true or false."),
            ])))
        }
        return .success(requested)
    }

    // MARK: - time_now handler

    /// Return current date/time in multiple representations. Zero-input,
    /// zero-side-effect, always safe. Caught by Agent 2026-06-08: she
    /// called time_now mid-test and got "not in the dispatch table" —
    /// the name is sensible, the tool just was never built. Now it is.
    static func impl_time_now() -> JSONValue {
        let now = Date()
        let isoUTC = ISO8601DateFormatter().string(from: now)
        let isoLocalFormatter = ISO8601DateFormatter()
        isoLocalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoLocalFormatter.timeZone = TimeZone.current
        let isoLocal = isoLocalFormatter.string(from: now)
        let epoch = Int64(now.timeIntervalSince1970)
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        let weekdayNames = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
        let weekdayName = weekdayNames[max(1, min(7, weekday)) - 1]
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        let humanFormatter = DateFormatter()
        humanFormatter.dateStyle = .full
        humanFormatter.timeStyle = .medium
        humanFormatter.timeZone = TimeZone.current
        let human = humanFormatter.string(from: now)
        return .object([
            "iso_utc": .string(isoUTC),
            "iso_local": .string(isoLocal),
            "epoch_seconds": .int(epoch),
            "weekday": .string(weekdayName),
            "day_of_year": .int(Int64(dayOfYear)),
            "human": .string(human),
            "timezone": .string(TimeZone.current.identifier),
            "timezone_offset_seconds": .int(Int64(TimeZone.current.secondsFromGMT(for: now))),
        ])
    }

    /// Keep deduplication and the capped append under the same inbox lock.
    /// Claude includes reviewer pairing in operation identity; OMP does not.
    static func appendBuilderInboxMessage(
        _ messageId: String,
        entry: [String: JSONValue],
        to inboxURL: URL,
        queuedAt: String,
        comparePairReviewer: Bool,
        maxLines: Int,
        logLabel: String,
        persistence: SwiftNativePersistenceCore,
        quarantine: BuilderInboxQuarantineNote
    ) async throws -> (status: String, retryWake: Bool, queuedAt: String) {
        try await persistence.withFileLock(inboxURL) {
            let existing = try await checkedBuilderInboxMessage(
                messageId, inboxURL: inboxURL, persistence: persistence, quarantine: quarantine
            )
            if case .object(let object)? = existing {
                let operationFields = ["text", "topic", "conversationId", "workingDirectory", "deskHandle"]
                guard operationFields.allSatisfy({ object[$0] == entry[$0] }),
                      (object["requireExistingConversation"] == .bool(true)) == (entry["requireExistingConversation"] == .bool(true)),
                      !comparePairReviewer || object["pairReviewer"] == entry["pairReviewer"] else {
                    return ("conflict", false, queuedAt)
                }
                if let session = stringField("sessionId", in: .object(object)), !session.isEmpty {
                    guard object["sessionId"] == entry["sessionId"],
                          object["priority"] == entry["priority"],
                          object["timeoutSeconds"] == entry["timeoutSeconds"] else {
                        return ("conflict", false, queuedAt)
                    }
                }
                return ("duplicate", builderInboxAllowsExplicitWakeRetry(object),
                        stringField("createdAt", in: .object(object)) ?? queuedAt)
            }
            try await appendJSONLCapped(
                .object(entry), to: inboxURL, using: persistence,
                maxLines: maxLines, logLabel: logLabel, takeLock: false
            )
            return ("appended", false, queuedAt)
        }
    }

    /// Carries a quarantine out of the flock'd read-dedup-append closure, which
    /// is `@Sendable` and so cannot write to a captured local. Only the send
    /// that actually quarantined stamps it, so the receipt names THIS call's
    /// damage — never an older `.quarantined-<ts>` sibling still on disk.
    final class BuilderInboxQuarantineNote: @unchecked Sendable {
        private let lock = NSLock()
        private var quarantinedPath: String?
        var path: String? { lock.withLock { quarantinedPath } }
        func record(_ path: String) { lock.withLock { quarantinedPath = path } }
    }

    static func checkedBuilderInboxMessage(
        _ messageId: String,
        inboxURL: URL,
        persistence: SwiftNativePersistenceCore,
        quarantine: BuilderInboxQuarantineNote
    ) async throws -> JSONValue? {
        let scan = try await persistence.readJSONLReporting(inboxURL)
        guard scan.report.isClean,
              scan.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else {
            // Self-heal instead of wedging the bridge. This used to throw, so a
            // SINGLE torn line failed EVERY later send to that agent until a
            // human repaired the file by hand — the bridge went dark and stayed
            // dark. Move the damaged bytes aside (never delete), then return nil
            // so the caller appends into a fresh inbox. A quarantine failure
            // still throws: appending onto bytes we could not preserve would be
            // the silent-drop this path exists to prevent.
            let aside = try await quarantineBuilderInbox(
                inboxURL,
                report: scan.report,
                parsedRowCount: scan.rows.count,
                persistence: persistence
            )
            quarantine.record(aside.path)
            return nil
        }
        let matching = scan.rows.filter { row in
            guard case .object(let object) = row else { return false }
            return object["messageId"] == .string(messageId) || object["id"] == .string(messageId)
        }
        guard matching.count <= 1 else {
            throw PersistenceCoreError.ioFailure("builder inbox message identity is ambiguous; original bytes preserved")
        }
        if case .object(let row)? = matching.first,
           let id = row["id"], let canonicalId = row["messageId"], id != canonicalId {
            throw PersistenceCoreError.ioFailure("builder inbox message identity conflicts; original bytes preserved")
        }
        return matching.first
    }

    /// A quarantined inbox may have held an admission of THIS very message that
    /// no longer parses, so the send that recovers the bridge has to say so out
    /// loud. The old behaviour failed every send forever; the new one must not
    /// trade that for a silent second admission.
    static func stampBuilderInboxQuarantine(
        _ note: BuilderInboxQuarantineNote,
        on response: inout [String: JSONValue]
    ) {
        guard let aside = note.path else { return }
        response["inboxQuarantined"] = .object([
            "quarantinedPath": .string(aside),
            "note": .string("The previous inbox was malformed. Its bytes were moved aside, NOT deleted, and a fresh inbox was started so this send could land. An earlier admission of this same message may sit inside the preserved file — reconcile against it before assuming this was the first."),
        ])
    }

    /// Rename aside, NEVER delete — the same contract the claude session
    /// pointer takeover uses for `.stale-<ts>` (script/claude_thread_wakeup.js
    /// `renameSessionPointerAside`): a file that turns out to be recoverable is
    /// still on disk, and a human can read `<name>.quarantined-<ts>` to see
    /// exactly which messages were set aside. An error receipt lands in a
    /// sibling `bridge-inbox-quarantine.jsonl` so the loss is recorded rather
    /// than silent. Throws if the bytes could NOT be preserved.
    private static func quarantineBuilderInbox(
        _ inboxURL: URL,
        report: JSONLReadReport,
        parsedRowCount: Int,
        persistence: SwiftNativePersistenceCore
    ) async throws -> URL {
        let fileManager = FileManager.default
        let stamp = String(Int(Date().timeIntervalSince1970))
        var aside = inboxURL.appendingPathExtension("quarantined-\(stamp)")
        var collision = 1
        while fileManager.fileExists(atPath: aside.path) {
            aside = inboxURL.appendingPathExtension("quarantined-\(stamp)-\(collision)")
            collision += 1
        }
        try fileManager.moveItem(at: inboxURL, to: aside)
        let receipt: [String: JSONValue] = [
            "event": .string("builder_inbox_quarantined"),
            "quarantinedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "inboxPath": .string(inboxURL.path),
            "quarantinedPath": .string(aside.path),
            "reason": .string("builder inbox is malformed; original bytes preserved"),
            "malformedLineCount": .int(Int64(report.malformedLineCount)),
            "trailingPartialLine": .bool(report.trailingPartialLine),
            "physicalLineCount": .int(Int64(report.physicalLineCount)),
            "parsedRowCount": .int(Int64(parsedRowCount)),
        ]
        // Best effort: the bytes are already safe, and a receipt write failure
        // must not turn a recovered send back into a dark bridge.
        try? await persistence.appendJSONLDurable(
            .object(receipt),
            to: inboxURL.deletingLastPathComponent()
                .appendingPathComponent("bridge-inbox-quarantine.jsonl")
        )
        return aside
    }

    static func builderInboxAllowsExplicitWakeRetry(
        _ row: [String: JSONValue],
        requiresSession: Bool = true
    ) -> Bool {
        guard row["read"] == .bool(false),
              let createdAt = stringField("createdAt", in: .object(row)),
              !createdAt.isEmpty else { return false }
        if requiresSession {
            guard let session = stringField("sessionId", in: .object(row)),
                  !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        switch row["consumedAt"] {
        case nil, .null: return true
        case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    /// Accepts only a bare `owner/name` GitHub slug. Rejects anything that
    /// could be read as a filesystem path or a traversal attempt, so the
    /// resolver is never handed model-authored path syntax.
    static func isWellFormedRepositorySlug(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 140 else { return false }
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("..") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._"
        )
        for part in parts {
            guard !part.isEmpty, part.count <= 100 else { return false }
            guard part.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        }
        return true
    }

    /// Repository slugs a codex_message request mentions, most-confident first.
    ///
    /// This exists because forgetting the `repository` parameter silently costs
    /// the caller the whole `github-command-repository-network-v1` execution
    /// profile: no network, no writable checkout, so Codex has zero GitHub paths
    /// and grinds until the harness kills the turn (2026-08-05 incident, turn
    /// 019fd2e5-0b16-7b31-bf28-1df55570c4bd). Omission must be impossible, not
    /// merely rare.
    ///
    /// This widens only WHERE the slug is read from, never the trust boundary:
    /// every candidate still goes through `GitHubCommandCheckoutResolver`, whose
    /// anchor is the checkout's own git remote. The explicit `repository`
    /// parameter already accepts any model-authored slug, so reading one out of
    /// the request text grants no authority the caller did not already have.
    static func repositorySlugCandidates(inRequestText text: String) -> [String] {
        var urlSlugs: [String] = []
        var bareSlugs: [String] = []
        // github.com/<owner>/<name> is unambiguous; a bare owner/name token is a
        // weaker signal and is only consulted when no URL names a repository.
        for rawToken in text.split(whereSeparator: { $0.isWhitespace }) {
            var token = String(rawToken).trimmingCharacters(
                in: CharacterSet(charactersIn: "`\"'<>(),;:[]{}!?*")
            )
            if token.isEmpty { continue }
            // Both the https path form and the SSH form git@github.com:owner/name.
            let hostRange = token.range(of: "github.com/") ?? token.range(of: "github.com:")
            if let range = hostRange {
                var slug = String(token[range.upperBound...])
                for suffix in [".git", "/pull", "/issues", "/tree", "/blob", "/commit", "/compare"] {
                    if let cut = slug.range(of: suffix) { slug = String(slug[slug.startIndex..<cut.lowerBound]) }
                }
                let parts = slug.split(separator: "/").prefix(2).map(String.init)
                if parts.count == 2 {
                    let candidate = "\(parts[0])/\(parts[1])"
                    if isWellFormedRepositorySlug(candidate), !urlSlugs.contains(candidate) {
                        urlSlugs.append(candidate)
                    }
                }
                continue
            }
            // A bare token must be exactly owner/name -- never a path fragment
            // ("docs/build_plans" resolves to nothing, but rejecting the shape
            // early keeps the resolver off obviously-wrong candidates).
            if token.hasPrefix("/") || token.hasSuffix("/") { continue }
            if token.hasSuffix(".git") { token = String(token.dropLast(4)) }
            guard isWellFormedRepositorySlug(token) else { continue }
            let parts = token.split(separator: "/").map(String.init)
            guard parts.count == 2, parts[0].count >= 2, parts[1].count >= 2 else { continue }
            if !bareSlugs.contains(token) { bareSlugs.append(token) }
        }
        // Cap the resolver's work: each candidate walks directories and shells
        // out to git. A request naming a dozen slugs is not a repo request.
        return Array((urlSlugs.isEmpty ? bareSlugs : urlSlugs).prefix(8))
    }

    /// Resolve at most ONE checkout from the request text. Ambiguity -- two
    /// different repositories that both resolve -- yields nil and the send
    /// proceeds with today's no-profile behavior, because guessing which
    /// repository the caller meant would hand Codex a network-enabled writable
    /// checkout of the wrong tree.
    enum AgentBridgeWorkingDirectoryResolution {
        case success(String?)
        case failure(JSONValue)
    }

    /// Resolve an explicit bridge cwd at the same effect-time TrustCenter
    /// boundary as native shell tools. Canonical workspace/source roots remain
    /// valid in ordinary modes. An external directory requires active Full Mac
    /// file authority plus the explicit outside-workspace allow posture.
    func resolveAgentBridgeWorkingDirectory(
        input: [String: JSONValue],
        surface: String
    ) async -> AgentBridgeWorkingDirectoryResolution {
        guard case .string(let raw)? = input["working_directory"] else {
            return .success(nil)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Optional string fields are sometimes serialized as "" by tool-calling
        // models. Match conversation_id's omission semantics: an empty cwd does
        // not request a path, while a non-empty invalid path still fails closed.
        guard !trimmed.isEmpty else { return .success(nil) }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.object([
                "status": .string("failed"),
                "reason": .string("working_directory_invalid"),
                "workingDirectory": .string(url.path),
                "detail": .string("working_directory must resolve to an existing absolute directory."),
            ]))
        }

        if Self.builderAllowedRoots(dataRoot: dataRoot).contains(where: { root in
            let rootPath = root.path
            return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
        }) {
            return .success(url.path)
        }

        if let reason = MacControlSensitivePathFence.reason(forPath: url.path)
            ?? MacControlSensitivePathFence.protectedSystemMutationReason(forPath: url.path) {
            return .failure(.object([
                "status": .string("failed"),
                "reason": .string("working_directory_sensitive_path_denied"),
                "workingDirectory": .string(url.path),
                "detail": .string(reason),
            ]))
        }

        let access = await fullMacToolAccess(surface: surface)
        guard access.fullMacActive,
              access.fileOpsAllowed,
              Self.builderYoloPermissionLevels.contains(access.permissionLevel),
              access.outsideWorkspaceDefault == "allow" else {
            return .failure(.object([
                "status": .string("failed"),
                "reason": .string("working_directory_outside_workspace_denied"),
                "workingDirectory": .string(url.path),
                "workspaceRoot": .string(Self.builderWorkspaceRoot(dataRoot: dataRoot).path),
                "detail": .string("An external coding directory requires active Full Mac YOLO with outside-workspace access set to allow."),
            ]))
        }
        return .success(url.path)
    }

    var builderWorktreeConfigRoot: URL {
        agentBridgeConfigRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
    }

    static func builderWorktreeFailureEnvelope(
        reason: String,
        detail: String
    ) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string(reason),
            "detail": .string(detail),
            "fix": .string("Repair the selected Git checkout or its isolated worktree, then retry the builder message."),
        ])
    }

    static func bridgeConfigDirectory(named name: String, configRootOverride: URL? = nil) -> URL {
        if let configRootOverride {
            return configRootOverride.appendingPathComponent(name, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func returnBridgeUnavailableEnvelope(
        _ readiness: AgentBridgeRuntime.ReturnPathReadiness
    ) -> JSONValue {
        .object([
            "status": .string("failed"),
            "reason": .string("return_bridge_unavailable"),
            "detail": .string(readiness.reason),
            "return_path_ready": .bool(false),
            "token_present": .bool(readiness.tokenPresent),
            "descriptor_present": .bool(readiness.descriptorPresent),
            "fix": .string("Keep NativeAgent open and retry. The authenticated local return bridge starts automatically; Developer Mode is not required."),
        ])
    }

    /// One lifecycle owner for the Codex, Claude, and OMP wake helpers. The
    /// shared adapter drains both pipes while the child runs, feeds stdin off
    /// the waiting path, bounds captured output, and owns cancellation plus
    /// process-tree timeout escalation. Builder-specific wrappers only supply
    /// environment and deadline policy.
    static func runBuilderWakeupHelper(
        node: URL,
        helper: URL,
        inputData: Data,
        cwd: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> JSONValue {
        // The helpers address the agent and the user by their configured
        // names (2026-09-05: the scripts used to carry the maintainer's).
        var environment = environment
        if environment["NATIVE_AGENT_AGENT_NAME"] == nil || environment["NATIVE_AGENT_USER_NAME"] == nil {
            let names = AgentBridgeRuntime.configuredNames(dataRoot: PersistenceCore.defaultDataRoot())
            environment["NATIVE_AGENT_AGENT_NAME"] = environment["NATIVE_AGENT_AGENT_NAME"] ?? names.agent
            environment["NATIVE_AGENT_USER_NAME"] = environment["NATIVE_AGENT_USER_NAME"] ?? names.user
        }
        let result: ProcessRunResult
        do {
            result = try await SystemProcessAdapter().run(
                executable: node.path,
                arguments: [helper.path],
                currentDirectory: cwd,
                environment: environment,
                standardInput: inputData,
                timeoutSeconds: timeoutSeconds,
                outputByteLimit: 8 * 1024 * 1024
            )
        } catch is CancellationError {
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_cancelled"),
                "helper": .string(helper.path),
                "admissionOutcome": .string("unknown"),
                "note": .string("The helper was cancelled after possible dispatch. Inspect the original message's delegation status before any resend."),
            ])
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("helper_spawn_failed"),
                "helper": .string(helper.path),
                "error": .string(String(describing: error)),
            ])
        }

        return builderWakeupHelperReceipt(result: result, helper: helper)
    }

    /// Pure interpretation of the shared process owner's evidence. A helper
    /// exit code is never a substitute for its structured admission receipt.
    static func builderWakeupHelperReceipt(result: ProcessRunResult, helper: URL) -> JSONValue {
        let stderrText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        func unavailable(_ reason: String) -> JSONValue {
            var envelope: [String: JSONValue] = [
                "status": .string("failed"),
                "reason": .string(reason),
                "helper": .string(helper.path),
                "exitCode": .int(Int64(result.exitCode)),
                "admissionOutcome": .string("unknown"),
                "note": .string("No trustworthy helper receipt was received. Work may already have been admitted; inspect the original message's delegation status before any resend."),
            ]
            if !stderrText.isEmpty {
                envelope["stderrPreview"] = .string(String(stderrText.prefix(500)))
            }
            return .object(envelope)
        }
        if result.timedOut { return unavailable("helper_timeout") }
        if result.stdoutTruncated { return unavailable("helper_output_truncated") }

        let stdoutText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = stdoutText.split(separator: "\n").last.map(String.init) ?? ""
        let parsed = [stdoutText, lastLine]
            .lazy
            .filter { !$0.isEmpty }
            .compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONValue.parse($0) }
            .first
        guard let parsed else { return unavailable("helper_returned_no_json") }
        guard case .object(var object) = parsed,
              case .string(let status)? = object["status"],
              !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable("helper_invalid_receipt")
        }
        if result.exitCode != 0 && !["failed", "skipped"].contains(status) {
            guard case .object(var failure) = unavailable("helper_exit_conflict") else {
                return unavailable("helper_exit_conflict")
            }
            failure["helperReportedReceipt"] = parsed
            return .object(failure)
        }
        object["helper"] = .string(helper.path)
        object["exitCode"] = .int(Int64(result.exitCode))
        if !stderrText.isEmpty {
            object["stderrPreview"] = .string(String(stderrText.prefix(500)))
        }
        return .object(object)
    }


    // MARK: - Runs-ledger append for sub-agent spawns
    //
    // Shared tail for invoke_claude / invoke_codex: translate the tool-result
    // envelope into one RunRecord row in <dataRoot>/runs/runs.json. The
    // envelope's "completed" maps to the ledger's "succeeded" (the status
    // string the Runs UI colors green); a watchdog kill maps to "timeout".
    static func appendSpawnRunToLedger(
        kind: String,
        result: JSONValue,
        model: String?,
        prompt: String,
        startedAt: Date,
        dataRoot: URL
    ) async {
        guard case .object(let obj) = result else { return }
        let rawStatus: String = {
            if case .string(let s)? = obj["status"] { return s }
            return "unknown"
        }()
        let timedOut: Bool = {
            if case .bool(let b)? = obj["timedOut"] { return b }
            if case .string(let reason)? = obj["reason"], reason.hasPrefix("timeout_after_") { return true }
            return false
        }()
        let status = rawStatus == "completed" ? "succeeded" : (timedOut ? "timeout" : rawStatus)
        let runId: String = {
            if case .string(let r)? = obj["runId"], !r.isEmpty { return r }
            return UUID().uuidString
        }()
        let reply: String? = {
            if case .string(let r)? = obj["reply"], !r.isEmpty { return r }
            return nil
        }()
        var errorParts: [String] = []
        if status != "succeeded" {
            if case .string(let reason)? = obj["reason"] { errorParts.append(reason) }
            if case .string(let detail)? = obj["detail"], !detail.isEmpty { errorParts.append(detail) }
            if case .string(let stderrText)? = obj["stderr"], !stderrText.isEmpty { errorParts.append(stderrText) }
        }
        await RunLedger.append(
            id: runId,
            kind: kind,
            status: status,
            model: model,
            prompt: prompt,
            output: reply,
            error: errorParts.isEmpty ? nil : errorParts.joined(separator: "\n"),
            createdAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            dataRoot: dataRoot
        )
    }

}

// MARK: - Stale-wakeup replay guard (W2b, upgrade campaign 2026-08 Track A)
//
// L1#14, in User's words: "the bridge is still replaying old wakeups as if they
// are new." The shape of that failure is narrow and identifiable — the SAME
// message text, on the SAME topic, fired again at a runner that already ran it
// to completion and already handed the answer back. Each replay costs a real
// spawned session, real tokens, and produces a second copy of an answer nobody
// asked for twice.
//
// This guard reads the target store BEFORE the wakeup spawn and returns a
// receipt instead of enqueuing, when and only when all four hold:
//
//   1. Same topic slug (slugged through the dispatcher's own
//      `builderTopicSlug`, never a second implementation).
//   2. Byte-identical payload text. Same topic with DIFFERENT text is normal
//      follow-up work and must always go through — this is the single most
//      important non-suppression, because getting it wrong silently strands
//      real work.
//   3. The prior job is TERMINAL: it carries a completion stamp or a terminal
//      status word. An in-flight job is not a replay; the bridges already
//      serialize per topic and have their own in-flight handling.
//   4. The prior job's answer was CONFIRMED DELIVERED. A job whose delivery was
//      lost or unconfirmed is deliberately NOT suppressed — re-asking after an
//      answer went missing is the correct human action, and blocking it would
//      strand the work permanently. This is why the guard cannot be "is there a
//      terminal job with this topic".
//
// Plus a recency window (default 24h): an identical request made weeks later is
// a deliberate re-run, not a replay.
//
// WIRE FENCE: nothing here writes, and no script/*.js is touched. The store
// paths mirror the JS writers' own resolution order (env override, then
// ~/.config) so the guard can never read a different directory than the writer.
enum WakeupReplayGuard {

    enum Store {
        case claude
        case omp
        case codex
    }

    /// Everything the receipt needs to say WHICH prior job matched. Every field
    /// is read off the record — nothing is inferred.
    struct Match: Equatable {
        let jobId: String
        let topicSlug: String
        let completedAt: String?
        let statusWord: String?
        let storeLabel: String
    }

    /// How long an identical completed request keeps suppressing a re-fire.
    static let defaultWindow: TimeInterval = 24 * 60 * 60

    /// Escape hatch. Set to 1/true/yes to force every wakeup through, e.g. when
    /// deliberately re-running an identical delegated job.
    static let disableEnvironmentKey = "NATIVE_AGENT_WAKEUP_REPLAY_GUARD_DISABLED"

    static func isDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let raw = environment[disableEnvironmentKey]?.lowercased() ?? ""
        return ["1", "true", "yes"].contains(raw)
    }

    /// Resolve the jobs directory for a store, mirroring the JS writer's own
    /// order: an explicit override (tests / `agentBridgeConfigRoot`) wins, then
    /// the writer's env var, then `~/.config`.
    static func jobsDirectory(
        for store: Store,
        configRoot: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        func home(_ bridge: String) -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent(bridge, isDirectory: true)
        }
        switch store {
        case .claude:
            let base = configRoot?.appendingPathComponent("claude-bridge", isDirectory: true)
                ?? environment["NATIVE_AGENT_CLAUDE_BRIDGE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home("claude-bridge")
            return base.appendingPathComponent("wake-jobs", isDirectory: true)
        case .omp:
            let base = configRoot?.appendingPathComponent("omp-bridge", isDirectory: true)
                ?? environment["NATIVE_AGENT_OMP_BRIDGE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home("omp-bridge")
            return base.appendingPathComponent("wake-jobs", isDirectory: true)
        case .codex:
            if let configRoot {
                return configRoot
                    .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
                    .appendingPathComponent("reply-jobs", isDirectory: true)
            }
            if let override = environment["NATIVE_AGENT_CODEX_REPLY_JOBS_DIR"] {
                return URL(fileURLWithPath: override)
            }
            return home("codex-nativeagent-bridge")
                .appendingPathComponent("reply-jobs", isDirectory: true)
        }
    }

    /// The prior terminal, delivered, identical job — or nil, meaning "post the
    /// wakeup". Every failure to read is nil: the guard NEVER blocks work
    /// because a directory was unreadable.
    static func terminalDuplicate(
        store: Store,
        jobsDirectory: URL,
        topic: String?,
        text: String,
        now: Date,
        window: TimeInterval = defaultWindow
    ) -> Match? {
        let wanted = SwiftToolDispatcher.builderTopicSlugForReplayGuard(topic ?? "")
        guard !text.isEmpty else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path)) ?? []
        var best: (Match, Date)?
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = jobsDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONValue.parse(data),
                  case .object(let record) = parsed else { continue }
            guard let candidate = match(
                store: store, record: record, url: url,
                wantedSlug: wanted, text: text, now: now, window: window
            ) else { continue }
            // Newest match wins, so the receipt names the most recent run.
            let stamp = parseISO(candidate.completedAt) ?? .distantPast
            if best == nil || stamp > best!.1 { best = (candidate, stamp) }
        }
        return best?.0
    }

    private static func match(
        store: Store,
        record: [String: JSONValue],
        url: URL,
        wantedSlug: String,
        text: String,
        now: Date,
        window: TimeInterval
    ) -> Match? {
        switch store {
        case .claude, .omp:
            // Both wake-job writers persist the whole request under `payload`.
            guard case .object(let payload)? = record["payload"],
                  string(payload, "text") == text else { return nil }
            // `topicSlug` is written by the claude runner; the OMP record only
            // carries the raw topic in its payload, so slug that instead. Both
            // go through the dispatcher's slug function, so both agree.
            let slug = string(record, "topicSlug")
                ?? SwiftToolDispatcher.builderTopicSlugForReplayGuard(string(payload, "topic") ?? "")
            guard slug == wantedSlug else { return nil }
            let completedAt = string(record, "completedAt")
            let statusWord = (string(record, "runStatus") ?? string(record, "status"))?.lowercased()
            guard isTerminal(completedAt: completedAt, statusWord: statusWord) else { return nil }
            guard succeeded(statusWord: statusWord) else { return nil }
            guard deliveryConfirmed(record) else { return nil }
            guard withinWindow(completedAt, now: now, window: window) else { return nil }
            return Match(
                jobId: string(record, "messageId") ?? url.deletingPathExtension().lastPathComponent,
                topicSlug: slug,
                completedAt: completedAt,
                statusWord: statusWord,
                storeLabel: store == .claude ? "claude" : "omp"
            )

        case .codex:
            // A DELIVERED codex reply-job is unlinked by the bridge, so a
            // terminal record still sitting in reply-jobs/ is one whose handoff
            // is pending recovery — the WORK is done, and re-firing duplicates
            // it. Records preserved under `undelivered/` are never scanned (the
            // caller does not descend into it), which is the point: an
            // undeliverable job must stay re-askable.
            guard case .array(let entries)? = record["entries"] else { return nil }
            var matched = false
            for entry in entries {
                guard case .object(let e) = entry,
                      case .object(let payload)? = e["payload"],
                      string(payload, "text") == text else { continue }
                let slug = SwiftToolDispatcher.builderTopicSlugForReplayGuard(
                    string(payload, "topic") ?? "")
                if slug == wantedSlug { matched = true; break }
            }
            guard matched else { return nil }
            guard case .object(let execution)? = record["completedExecution"],
                  case .object(let turnResult)? = execution["turnResult"] else { return nil }
            let completedAt = string(turnResult, "completedAt")
            let statusWord = string(turnResult, "status")?.lowercased()
            guard isTerminal(completedAt: completedAt, statusWord: statusWord) else { return nil }
            guard succeeded(statusWord: statusWord) else { return nil }
            guard withinWindow(completedAt, now: now, window: window) else { return nil }
            return Match(
                jobId: string(record, "id") ?? url.deletingPathExtension().lastPathComponent,
                topicSlug: wantedSlug,
                completedAt: completedAt,
                statusWord: statusWord,
                storeLabel: "codex"
            )
        }
    }

    static let terminalStatusWords: Set<String> = [
        "completed", "complete", "succeeded", "success",
        "failed", "failure", "error", "errored",
        "timeout", "timed_out", "cancelled", "canceled", "aborted", "spawn_failed",
    ]

    static let successStatusWords: Set<String> = [
        "completed", "complete", "succeeded", "success",
    ]

    static func isTerminal(completedAt: String?, statusWord: String?) -> Bool {
        if completedAt != nil { return true }
        if let statusWord, terminalStatusWords.contains(statusWord) { return true }
        return false
    }

    /// A FAILED prior run is not a replay to suppress — retrying failed work is
    /// exactly what a re-send is for.
    static func succeeded(statusWord: String?) -> Bool {
        guard let statusWord else { return false }
        return successStatusWords.contains(statusWord)
    }

    /// Claude writes `bridgeStatus`; OMP writes a `bridge` object with a
    /// `status`. Only an explicit "delivered" counts — `deliveryLost` true, an
    /// unknown bridge status, or no bridge record at all all mean the answer is
    /// not known to have arrived, so the re-send goes through.
    static func deliveryConfirmed(_ record: [String: JSONValue]) -> Bool {
        if case .bool(true)? = record["deliveryLost"] { return false }
        if let status = string(record, "bridgeStatus") { return status == "delivered" }
        if case .object(let bridge)? = record["bridge"] {
            return string(bridge, "status") == "delivered"
        }
        return false
    }

    static func withinWindow(_ completedAt: String?, now: Date, window: TimeInterval) -> Bool {
        // No completion stamp means we cannot prove recency. Terminal-by-status
        // with no timestamp is a legacy/hand-edited shape; treat it as OUT of
        // the window so the wakeup proceeds rather than being blocked by a
        // record we cannot date.
        guard let date = parseISO(completedAt) else { return false }
        return now.timeIntervalSince(date) <= window && date <= now.addingTimeInterval(window)
    }

    /// The receipt that replaces the wakeup envelope. `status: "skipped"` keeps
    /// it in the same vocabulary the other non-spawn outcomes already use
    /// (`disabled_by_environment`, `helper_not_found`, `deduplicated`), so no
    /// caller needs a new branch to understand it.
    static func receipt(_ match: Match) -> JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string("skipped"),
            "reason": .string("already_completed"),
            "jobId": .string(match.jobId),
            "topicSlug": .string(match.topicSlug),
            "store": .string(match.storeLabel),
            "detail": .string("This exact request already ran to completion on this topic and "
                + "its answer was delivered. The durable inbox row was still written; only the "
                + "duplicate wake was skipped."),
            "fix": .string("Change the message text to send new work on this topic, or set "
                + "\(disableEnvironmentKey)=1 to force an identical re-run."),
        ]
        if let completedAt = match.completedAt { obj["completedAt"] = .string(completedAt) }
        if let statusWord = match.statusWord { obj["priorRunStatus"] = .string(statusWord) }
        return .object(obj)
    }

    // MARK: - Local readers (deliberately not shared with the projector: this
    // guard must keep working if that file changes shape, and the two answer
    // different questions).

    private static func string(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s.isEmpty ? nil : s }
        return nil
    }

    static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso)
    }
}
