import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatCompactionCommit.swift` | Verified compaction commit, pending recovery and settlement |
extension ChatSessionAutocompactor {
    func replace(
        _ fold: Fold,
        in pass: Pass,
        rows: [JSONValue], sourceBytes: Data,
        trigger: String,
        model: String,
        surface: String,
        runId: String?,
        recollection: (blocks: [ChatCompactionDistiller.Block], model: String)?
    ) async throws -> ChatSessionCompactionOutcome {
        let sessionId = pass.sessionId
        let messagesPath = pass.messagesPath
        let before = rows.count
        let replaceCount = fold.replaced.count
        let transcriptChars = Self.transcriptCharacterCount(rows)
        let estimatedTokens = max(0, Int((Double(transcriptChars) / pass.divisor).rounded()))
        let sourceNote = ChatCompactionRowRendering.receiptSourceNote(fold.removableRows, sessionId: sessionId)
        let summary = "Recollection pending; original messages are retained in the compaction backup."
        let nowISO = ISO8601DateFormatter().string(from: now())
        let summaryId = "compact-\(UUID().uuidString.lowercased())"
        // A verified backup is mandatory before destructive compaction. It
        // also gives the distiller the exact replaced source.
        try Task.checkCancellation()
        let backupURL = try backupCurrentMessages(sessionId: sessionId, messagesPath: messagesPath, sourceBytes: sourceBytes, rows: rows)
        // WHICH stretch of life this recollection stands for. Recorded so a
        // second consolidation owner (the dream lane) can tell whether it
        // has already consumed this material, without re-reading the backup
        // or re-summarizing the same turns. See ChatSessionRecollections.
        let coverage = Self.coverageRange(fold.removableRows)
        var summaryMetadata: [String: JSONValue] = [
            "kind": .string(ChatSessionRecollections.rowKind),
            ChatSessionRecollections.continuityProvenanceKey:
                ChatSessionRecollections.continuityProvenance(for: fold.removableRows),
            "messages_replaced": .int(Int64(replaceCount)),
            "trigger": .string(trigger),
            "lane": .string(ChatSessionCompactionOutcome.lane(forTrigger: trigger)),
            "surface": .string(surface),
            "receipt_source_note": .string(sourceNote),
            "recollection_mode": .string(fold.rollsUpRecollections ? "rollup" : "append"),
        ]
        if let from = coverage.from {
            summaryMetadata[ChatSessionRecollections.coversFromKey] = .string(from)
        }
        if let until = coverage.until {
            summaryMetadata[ChatSessionRecollections.coversUntilKey] = .string(until)
        }
        if let recollection {
            summaryMetadata["distill"] = .string("llm")
            summaryMetadata["distill_model"] = .string(recollection.model)
        } else {
            summaryMetadata["distill"] = .string("pending")
            summaryMetadata["distill_backup"] = .string(backupURL.lastPathComponent)
        }
        // Keep the existing wire key: ALL earlier blocks survive an ordinary
        // fold and must stay out of its prompt, as does the dream-safe prefix.
        summaryMetadata["distill_preserved_pending_ids"] = .array(fold.retainedRows.compactMap {
            guard case .object(let object) = $0 else { return nil }
            return object["id"]
        })
        if !fold.preservedCards.isEmpty {
            summaryMetadata[InlineInteractionCompactionRetention.preservedMetadataKey] =
                .int(Int64(fold.preservedCards.count))
        }
        let summaryTemplate: [String: JSONValue] = [
            "id": .string(summaryId),
            "sessionId": .string(sessionId),
            "role": .string("system"),
            "content": .string(summary),
            "createdAt": .string(nowISO),
            "source": .string("native_autocompaction"),
            "metadata": .object(summaryMetadata),
        ]
        let summaryRows = recollection.map {
            ChatCompactionDistiller.recollectionRows(
                $0.blocks, template: summaryTemplate, sessionId: sessionId,
                model: $0.model, preservedCards: fold.preservedCards.count
            )
        } ?? [.object(summaryTemplate)]
        // Earlier blocks first, then ALL new blocks in source order,
        // preserved cards/results and the untouched tail. One atomic write.
        let nextRows = fold.retainedRows + summaryRows + fold.pendingResults
            + fold.preservedCards + fold.kept
        try Task.checkCancellation()
        // Retained recollections keep their exact on-disk line bytes too,
        // including legacy formatting. Only newly written blocks serialize.
        var originalBlocks: [JSONValue: Data] = [:]
        let lines = sourceBytes.split(separator: 0x0A).filter { $0.contains { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D } }
        for (row, line) in zip(rows, lines) where Self.isRecollection(row) {
            originalBlocks[row] = Data(line)
        }
        var transcript = Data()
        for row in nextRows {
            if let original = originalBlocks[row] {
                transcript.append(original)
            } else {
                transcript.append(contentsOf: try row.serialize(pretty: false).utf8)
            }
            transcript.append(0x0A)
        }
        try Task.checkCancellation()
        try ContactThread.replace(transcript, to: messagesPath)
        let sourceBytesAfter = Self.fileSize(messagesPath)
        let outcome = ChatSessionCompactionOutcome(
            sessionId: sessionId,
            compacted: true,
            reason: "swift-native-autocompaction",
            trigger: trigger,
            thresholdTokens: pass.thresholdTokens,
            estimatedTokensBefore: estimatedTokens,
            transcriptCharsBefore: transcriptChars,
            messagesBefore: before,
            messagesAfter: nextRows.count,
            messagesReplaced: replaceCount,
            summaryChars: Self.transcriptCharacterCount(summaryRows),
            sourceBytesBefore: pass.sourceBytesBefore,
            sourceBytesAfter: sourceBytesAfter,
            summaryRowId: recollection == nil ? summaryId : nil,
            backupPath: recollection == nil ? backupURL.path : nil,
            recollectionSource: recollection == nil ? fold.removableRows : []
        )
        await emitCompactionTrace(
            outcome,
            model: model,
            surface: surface,
            runId: runId,
            status: "ok"
        )
        return outcome.carrying(transcript)
    }
    func pendingDistillationOutcome(
        sessionId: String, messagesPath: URL, rows: inout [JSONValue], transcript: inout Data,
        trigger: String, sourceBytes: Int64
    ) async throws -> ChatSessionCompactionOutcome? {
        for row in rows where Self.hasPendingDistillation(row) {
            guard case .object(var object) = row,
                  case .string(let id)? = object["id"],
                  case .object(var metadata)? = object["metadata"] else { continue }
            guard case .int(let count)? = metadata["messages_replaced"], count > 0 else {
                throw await pendingFailure(CocoaError(.fileReadCorruptFile), sessionId: sessionId, rowId: id)
            }
            let backup: String
            if case .string(let recorded)? = metadata["distill_backup"],
               recorded == URL(fileURLWithPath: recorded).lastPathComponent {
                backup = recorded
            } else {
                do {
                    backup = try await recoverDistillationBackup(
                        sessionId: sessionId, metadata: metadata, messagesReplaced: Int(count)
                    ).lastPathComponent
                } catch {
                    throw await pendingFailure(error, sessionId: sessionId, rowId: id)
                }
            }
            if metadata["distill"] != .string("pending") || metadata["distill_backup"] != .string(backup) {
                metadata["distill"] = .string("pending")
                metadata["distill_backup"] = .string(backup)
                metadata.removeValue(forKey: "distill_process")
                object["metadata"] = .object(metadata)
                if let rewritten = try ContactThread.editingRow(in: transcript, matching: { fields in
                    return fields["id"] == .string(id)
                }, replacement: { _ in [.object(object)] }) {
                    try Task.checkCancellation()
                    try ContactThread.replace(rewritten, to: messagesPath)
                    transcript = rewritten
                    if let rowIndex = rows.firstIndex(where: { row in
                        guard case .object(let fields) = row else { return false }
                        return fields["id"] == .string(id)
                    }) {
                        rows[rowIndex] = .object(object)
                    }
                }
            }
            let backupPath = sessionDir(sessionId: sessionId).appendingPathComponent(backup)
            let source: [JSONValue]
            do {
                let backupRows = try await readJSONLHonest(backupPath).rows
                guard backupRows.count >= Int(count) else { throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -7) }
                let preservedIDs: Set<String>
                if case .array(let ids)? = metadata["distill_preserved_pending_ids"] {
                    preservedIDs = Set(ids.compactMap {
                        guard case .string(let id) = $0 else { return nil }
                        return id
                    })
                } else { preservedIDs = [] }
                let replaced = backupRows.prefix(Int(count)).filter {
                    guard case .object(let object) = $0 else { return true }
                    if metadata["recollection_mode"] == .string("append"),
                       ChatCompactionRowRendering.isRecollection(object) { return false }
                    guard case .string(let id)? = object["id"] else { return true }
                    return !preservedIDs.contains(id)
                }
                let (_, compactible) = InlineInteractionCompactionRetention.splitPendingResults(replaced)
                source = InlineInteractionCompactionRetention.split(compactible).removable
            } catch {
                throw await pendingFailure(error, sessionId: sessionId, rowId: id)
            }
            return ChatSessionCompactionOutcome(
                sessionId: sessionId, compacted: false, reason: "distillation pending",
                trigger: trigger, thresholdTokens: config.thresholdTokens,
                estimatedTokensBefore: 0, transcriptCharsBefore: Self.transcriptCharacterCount(rows),
                messagesBefore: rows.count, messagesAfter: rows.count,
                messagesReplaced: Int(count), summaryChars: 0,
                sourceBytesBefore: sourceBytes, sourceBytesAfter: sourceBytes,
                summaryRowId: id, backupPath: backupPath.path, recollectionSource: source
            )
        }
        return nil
    }
    private func pendingFailure(_ error: Error, sessionId: String, rowId: String) async -> ToolFailureError {
        let owner = "chat/messages/\(sessionId).jsonl#\(rowId).distill_backup"
        let words = "The retained recollection source is unavailable: \(error.localizedDescription). Repair its backup before compacting again."
        let next = ToolFailureError.call("app", ["action": .string("chat.compact"), "args": .object(["session_id": .string(sessionId)])])
        await RepairOwed.owe(dataRoot, id: UUID().uuidString, kind: .run, operation: "chat.compact:" + sessionId + ":" + rowId,
            owner: owner, words: words, nextCall: next).value
        return ToolFailureError(words, effects: .none, owner: owner, nextCall: next)
    }
    private func recoverDistillationBackup(
        sessionId: String, metadata: [String: JSONValue], messagesReplaced: Int
    ) async throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: sessionDir(sessionId: sessionId), includingPropertiesForKeys: nil
        )
        var matched: (url: URL, rows: [JSONValue])?
        for candidate in entries where candidate.lastPathComponent.hasPrefix("messages.compact.")
            && candidate.pathExtension == "jsonl" {
            let rows: [JSONValue]
            do {
                rows = try await readJSONLHonest(candidate).rows
            } catch {
                FileHandle.standardError.write(Data(
                    "ChatSessionAutocompactor: distillation backup recovery could not read \(candidate.lastPathComponent): \(error)\n".utf8
                ))
                continue
            }
            guard rows.count >= messagesReplaced else { continue }
            let preserved: [JSONValue]
            if case .array(let ids)? = metadata["distill_preserved_pending_ids"] { preserved = ids }
            else { preserved = [] }
            let replaced = rows.prefix(messagesReplaced).filter {
                guard case .object(let fields) = $0, let id = fields["id"] else { return true }
                return !preserved.contains(id)
            }
            let coverage = Self.coverageRange(replaced)
            guard let from = coverage.from, let until = coverage.until,
                  metadata[ChatSessionRecollections.coversFromKey] == .string(from),
                  metadata[ChatSessionRecollections.coversUntilKey] == .string(until),
                  metadata[ChatSessionRecollections.continuityProvenanceKey]
                    == ChatSessionRecollections.continuityProvenance(for: replaced) else { continue }
            if let matched, matched.rows != replaced {
                throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -7, userInfo: [
                    NSLocalizedDescriptionKey: "Pending recollection has ambiguous source backups; its source is retained for repair."
                ])
            }
            matched = (candidate, replaced)
        }
        guard let matched else {
            throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -7, userInfo: [
                NSLocalizedDescriptionKey: "Pending recollection has no matching source backup; its source is retained for repair."
            ])
        }
        return matched.url
    }
    func skipped(
        sessionId: String,
        reason: String,
        trigger: String,
        thresholdTokens: Int? = nil,
        estimatedTokensBefore: Int = 0,
        transcriptCharsBefore: Int = 0,
        messagesBefore: Int = 0,
        messagesAfter: Int = 0,
        sourceBytesBefore: Int64 = 0
    ) -> ChatSessionCompactionOutcome {
        ChatSessionCompactionOutcome(
            sessionId: sessionId,
            compacted: false,
            reason: reason,
            trigger: trigger,
            thresholdTokens: thresholdTokens ?? config.thresholdTokens,
            estimatedTokensBefore: estimatedTokensBefore,
            transcriptCharsBefore: transcriptCharsBefore,
            messagesBefore: messagesBefore,
            messagesAfter: messagesAfter,
            messagesReplaced: 0,
            summaryChars: 0,
            sourceBytesBefore: sourceBytesBefore,
            sourceBytesAfter: sourceBytesBefore
        )
    }
}
