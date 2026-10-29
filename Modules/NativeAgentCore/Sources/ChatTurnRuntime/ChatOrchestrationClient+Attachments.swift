import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import MacControl
// Blueprint: | `ChatOrchestrationClient+Attachments.swift` | image/document admission and voice evidence projection; audio remains an attachment, never a provider content block |

extension SwiftNativeChatOrchestrationClient {
    /// Convert delivered `MultimodalAttachment`s into native `.image` content
    /// blocks. Skips non-image types (audio/file/etc.) and entries with empty
    /// base64. Returns `[]` when nothing actionable — callers stay on the
    /// pre-multimodal `.user(text)` shape (byte-identical wire body).
    nonisolated static func imageBlocksFromAttachments(
        _ attachments: [MultimodalAttachment]
    ) -> [LLMContentBlock] {
        var out: [LLMContentBlock] = []
        for a in attachments {
            let type = a.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "image" else { continue }
            guard !a.base64.isEmpty else { continue }
            out.append(.image(
                mediaType: a.mime,
                base64: a.base64,
                name: a.name,
                byteSize: a.byteSize
            ))
        }
        return out
    }

    // MARK: - Trust ▸ Multimodal, at the point of use
    //
    // Read vision and PDF policy fresh each turn so Trust changes apply on the next turn.

    /// Missing policy or keys use TrustCenter defaults; existing unreadable or malformed policy fails closed.
    /// SavedTrustPolicyAuthority validates the whole policy and distinguishes dangling symlinks from absent files.
    nonisolated static func multimodalPolicyAllows(
        _ key: String,
        default fallback: Bool,
        dataRoot: URL
    ) -> Bool {
        SavedTrustPolicyAuthority.flag(
            block: "multimodalPolicy",
            key: key,
            default: fallback,
            dataRoot: dataRoot
        )
    }

    /// Per-document character cap for PDFs and plain text; truncation is named to the model.
    static let documentIngestionCharacterCap = 40_000

    /// Shared character budget spent in attachment order; exhausted documents are skipped with a count and reason.
    static let turnDocumentCharacterBudget = 120_000

    /// What the model gets for this turn's attachments: the image blocks it is
    /// allowed to see, and the user message with an honest note appended for
    /// anything that was skipped or read out of a document.
    struct TurnAttachmentInput: Sendable {
        let imageBlocks: [LLMContentBlock]
        let userMessage: String
        let queryUserMessage: String
    }

    nonisolated static func turnAttachmentInput(
        message: String,
        attachments: [MultimodalAttachment],
        dataRoot: URL,
        queryUserMessage: String? = nil,
        runId: String? = nil
    ) throws -> TurnAttachmentInput {
        let queryMessage = queryUserMessage ?? message
        if attachments.contains(where: {
            $0.mime.lowercased() == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                || ($0.name.map { ($0 as NSString).pathExtension.lowercased() } == "docx")
        }) {
            throw ChatOrchestrationError.underlying("DOCX attachments are not supported yet. Attach a PDF or text file instead.")
        }
        guard !attachments.isEmpty else {
            return TurnAttachmentInput(imageBlocks: [], userMessage: message, queryUserMessage: queryMessage)
        }
        var notes: [String] = []
        for (index, attachment) in attachments.enumerated() {
            guard let utterance = attachment.utterance else { continue }
            let reference = attachment.path ?? runId.map {
                attachmentURL(chatRoot: dataRoot.appendingPathComponent("chat"), runId: $0, index: index).path
            } ?? attachment.id
            notes.append(try utterance.evidence(audioReference: reference))
        }

        // "Allow vision API calls". Off → the images never become blocks, and
        // the model is told so in the same shape LLMClient+Real uses when a
        // non-vision adapter drops them: honest, and explicitly not licence to
        // describe what it did not see.
        let visionAllowed = multimodalPolicyAllows("vision_api_calls", default: true, dataRoot: dataRoot)
        let imageBlocks = visionAllowed ? imageBlocksFromAttachments(attachments) : []
        if !visionAllowed {
            let skipped = imageBlocksFromAttachments(attachments).count
            if skipped > 0 {
                notes.append(
                    "[NOTE TO ASSISTANT: the user attached \(skipped) image(s), but "
                    + "\"Allow vision API calls\" is off in Trust Center ▸ Permissions, so the "
                    + "image(s) were skipped and NOT sent. Tell the user honestly that you could "
                    + "not view them and that the switch is what stopped it — do NOT guess or "
                    + "pretend to describe them.]")
            }
        }

        // Plain text requires no Trust switch and shares one ingestion pass and per-turn budget with PDFs.
        notes.append(contentsOf: documentAttachmentNotes(
            attachments, dataRoot: dataRoot, query: queryMessage))

        guard !notes.isEmpty else {
            return TurnAttachmentInput(imageBlocks: imageBlocks, userMessage: message, queryUserMessage: queryMessage)
        }
        let composed = ([message] + notes)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let composedQuery = ([queryMessage] + notes)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return TurnAttachmentInput(imageBlocks: imageBlocks, userMessage: composed, queryUserMessage: composedQuery)
    }

    /// Read documents in attachment order with the read organ's extractors; only PDFs require the ingestion switch.
    /// Each document respects its cap and the remaining turn budget; skipped, cut and unreadable inputs are named to the model.
    /// The user query selects overlong passages only; fitting documents stay whole, and an empty query selects the prefix.
    nonisolated static func documentAttachmentNotes(
        _ attachments: [MultimodalAttachment],
        dataRoot: URL,
        query: String = ""
    ) -> [String] {
        let pdfCount = attachments.filter { isPDFAttachment($0) }.count
        var notes: [String] = []
        let pdfAllowed = pdfCount == 0
            || multimodalPolicyAllows("file_ingestion_pdf", default: true, dataRoot: dataRoot)
        if pdfCount > 0, !pdfAllowed {
            notes.append(
                "[NOTE TO ASSISTANT: \(pdfCount) PDF attachment(s) were skipped — "
                + "\"Allow PDF file ingestion\" is off in Trust Center ▸ Permissions. Say so "
                + "plainly; do NOT guess at what the document(s) say.]")
        }

        var remainingBudget = turnDocumentCharacterBudget
        var skippedForBudget = 0
        for attachment in attachments {
            let isPDF = isPDFAttachment(attachment)
            if isPDF, !pdfAllowed { continue }
            guard isPDF || isPlainTextAttachment(attachment) else { continue }
            // Admit the budget before decoding or extraction so skipped documents remain unread.
            guard remainingBudget > 0 else {
                skippedForBudget += 1
                continue
            }
            let label = isPDF ? "PDF" : "text file"
            let name = attachment.name ?? (isPDF ? "attachment.pdf" : "attachment.txt")
            guard let data = Data(base64Encoded: attachment.base64), !data.isEmpty else {
                notes.append(
                    "[NOTE TO ASSISTANT: the \(label) \"\(name)\" was attached but its bytes could "
                    + "not be read, so it was skipped. Say so; do NOT guess at its contents.]")
                continue
            }
            // Plain-text attachments must contain text bytes; a filename extension alone cannot authorize binary decoding.
            if !isPDF, !attachmentBytesAreText(data) {
                notes.append(
                    "[NOTE TO ASSISTANT: the \(label) \"\(name)\" was skipped — "
                    + "\(textSkipReason(.unreadableDocument)). Say so; do NOT guess at its "
                    + "contents.]")
                continue
            }
            switch MacDocumentRead.extract(data: data, kind: isPDF ? .pdf : .text) {
            case .failure(let failure):
                let reason = isPDF ? pdfSkipReason(failure) : textSkipReason(failure)
                notes.append(
                    "[NOTE TO ASSISTANT: the \(label) \"\(name)\" was skipped — \(reason). Say so; "
                    + "do NOT guess at its contents.]")
            case .success(let extracted):
                var text = extracted.text
                var cut = extracted.truncated
                let allowance = min(documentIngestionCharacterCap, remainingBudget)
                let fullCount = text.count
                var selected = false
                if text.count > allowance {
                    // Third pass, item 4: an over-long document used to hand
                    // over its first N characters — for three contracts, three
                    // introductions and none of the clauses asked about. Take
                    // the passages that answer THIS turn instead, each marked
                    // with its line range so the rest can be asked for by
                    // location. No query (or nothing matched) keeps the old
                    // prefix exactly.
                    if let excerpt = DocumentExcerpt.selected(
                        text: text, query: query, allowance: allowance
                    ) {
                        text = excerpt
                        selected = true
                    } else {
                        text = String(text.prefix(allowance))
                    }
                    cut = true
                }
                remainingBudget -= text.count
                let subject = isPDF ? "the attached PDF" : "the attached file"
                let header: String
                if selected {
                    header = "[Text of \(subject) \"\(name)\" — the passages of it that match "
                        + "this request, marked with their line numbers. The document is "
                        + "\(fullCount) characters; the passages below are what you were given. "
                        + "If you need a different part, say which and ask for it:]"
                } else if cut {
                    header = "[Text of \(subject) \"\(name)\", cut off after the first "
                        + "\(text.count) characters — there is more you were not given:]"
                } else {
                    header = "[Text of \(subject) \"\(name)\":]"
                }
                notes.append(header + "\n" + text)
            }
        }
        if skippedForBudget > 0 {
            notes.append(
                "[NOTE TO ASSISTANT: \(skippedForBudget) further document attachment(s) were not "
                + "read at all — this turn's \(turnDocumentCharacterBudget)-character budget for "
                + "attached documents was already spent by the ones above. Say so, and offer to "
                + "take them one at a time; do NOT guess at their contents.]")
        }
        return notes
    }

    nonisolated static func isPDFAttachment(_ attachment: MultimodalAttachment) -> Bool {
        let mime = attachment.mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = (attachment.name ?? "").lowercased()
        return mime == "application/pdf" || name.hasSuffix(".pdf")
    }

    /// UTF-8, or UTF-16 announced by a BOM. Deliberately narrower than
    /// `MacDocumentRead.decodeText`, whose ISO-8859-1 fallback never fails and
    /// so cannot tell a text file from a renamed binary.
    nonisolated static func attachmentBytesAreText(_ data: Data) -> Bool {
        if String(data: data, encoding: .utf8) != nil { return true }
        let bom = [UInt8](data.prefix(2))
        guard bom.count == 2, bom == [0xFF, 0xFE] || bom == [0xFE, 0xFF] else { return false }
        return String(data: data, encoding: .utf16) != nil
    }

    /// Text by EXTENSION first (the same allow-list the `read` organ uses — a
    /// .png decodes to garbage that looks like a short document), then by mime
    /// for the surfaces that deliver a file without a usable name. Images and
    /// PDFs are somebody else's job.
    nonisolated static func isPlainTextAttachment(_ attachment: MultimodalAttachment) -> Bool {
        let type = attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard type != "image" else { return false }
        let mime = attachment.mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = (attachment.name ?? "").lowercased()
        guard mime != "application/pdf", !name.hasSuffix(".pdf") else { return false }
        if !name.isEmpty, MacDocumentRead.kind(forPath: name) == .text { return true }
        if mime.hasPrefix("text/") { return true }
        return mime == "application/json" || mime == "application/xml"
    }

    nonisolated static func textSkipReason(_ failure: MacDocumentRead.ExtractionFailure) -> String {
        switch failure {
        case .fileTooLarge: return "it is too large to read in one go"
        case .unreadableDocument: return "its bytes are not readable text"
        case .noTextInDocument: return "it is empty"
        default: return "its text could not be extracted"
        }
    }

    nonisolated static func pdfSkipReason(_ failure: MacDocumentRead.ExtractionFailure) -> String {
        switch failure {
        case .fileTooLarge: return "it is too large to read in one go"
        case .encryptedDocument: return "it is password-protected"
        case .noTextInDocument: return "it has no text layer — it is pictures of pages, not characters"
        default: return "its text could not be extracted"
        }
    }
}
