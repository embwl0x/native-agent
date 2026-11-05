import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
import MacControl
// Blueprint: | `ChatOrchestrationClient+Attachments.swift` | Trust-gated images and bounded document excerpts; audio stays attached |

extension SwiftNativeChatOrchestrationClient {
    /// Only nonempty image attachments become image blocks; text-only turns retain their original wire shape.
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

    // MARK: - Reading preferences, at the point of use
    // Read vision and PDF preferences each turn so Settings changes apply on the next turn.

    /// Missing policy or keys use TrustCenter defaults; existing unreadable or malformed policy fails closed.
    /// TrustCenter validates the whole policy and distinguishes dangling symlinks from absent files.
    nonisolated static func multimodalPolicyAllows(
        _ key: String,
        default fallback: Bool,
        dataRoot: URL
    ) throws -> Bool {
        try SwiftNativeTrustCenter(dataRoot: dataRoot).savedPolicyFlag(
            block: "multimodalPolicy",
            key: key,
            default: fallback
        )
    }

    /// Per-document character cap for PDFs and plain text; truncation is named to the model.
    static let documentIngestionCharacterCap = 40_000

    /// Shared character budget spent in attachment order; exhausted documents are skipped with a count and reason.
    static let turnDocumentCharacterBudget = 120_000

    /// Report every skipped or extracted attachment so the model knows what it actually received.
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

        // Disabled vision withholds image blocks and explicitly reports that nothing was seen.
        let visionAllowed = try multimodalPolicyAllows("vision_api_calls", default: true, dataRoot: dataRoot)
        let imageBlocks = visionAllowed ? imageBlocksFromAttachments(attachments) : []
        if !visionAllowed {
            let skipped = imageBlocksFromAttachments(attachments).count
            if skipped > 0 {
                notes.append(
                    "[NOTE TO ASSISTANT: the user attached \(skipped) image(s), but "
                    + "Image understanding is off in Settings (settings.image_understanding), so the "
                    + "image(s) were skipped and NOT sent. Tell the user honestly that you could "
                    + "not view them and that the switch is what stopped it — do NOT guess or "
                    + "pretend to describe them.]")
            }
        }

        // Plain text requires no Trust switch and shares one ingestion pass and per-turn budget with PDFs.
        notes.append(contentsOf: try documentAttachmentNotes(
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

    /// Read documents in attachment order under per-document and turn caps; only PDFs require the ingestion switch.
    /// Name skipped, cut and unreadable inputs. Queries select only overlong passages; unusable selection stays unavailable.
    nonisolated static func documentAttachmentNotes(
        _ attachments: [MultimodalAttachment],
        dataRoot: URL,
        query: String = ""
    ) throws -> [String] {
        let pdfCount = attachments.filter { isPDFAttachment($0) }.count
        var notes: [String] = []
        let pdfAllowed = try pdfCount == 0
            || multimodalPolicyAllows("file_ingestion_pdf", default: true, dataRoot: dataRoot)
        if pdfCount > 0, !pdfAllowed {
            notes.append(
                "[NOTE TO ASSISTANT: \(pdfCount) PDF attachment(s) were skipped — "
                + "Read PDFs is off in Settings (settings.pdf_reading). Say so "
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
                    switch DocumentExcerpt.selected(text: text, query: query, allowance: allowance) {
                    case .passages(let excerpt):
                        text = excerpt
                        selected = true
                    case .noMatch:
                        notes.append("""
                            [The attached \(label) \"\(name)\" exceeds this turn's allowance. No passages matched the request in the extracted text. \
                            No document text was supplied. Ask for a specific section or a location to read; do not infer its contents.]
                            """)
                        continue
                    case .unavailable(let reason):
                        notes.append("""
                            [Passage selection for the attached \(label) \"\(name)\" is unavailable: \(reason) No document text was supplied. Ask for \
                            a specific section or a location to read; do not infer its contents.]
                            """)
                        continue
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

    /// UTF-8, or UTF-16 announced by a BOM. This admission probe precedes
    /// document extraction, whose decoder also rejects decoded NUL characters.
    nonisolated static func attachmentBytesAreText(_ data: Data) -> Bool {
        if String(data: data, encoding: .utf8) != nil { return true }
        let bom = [UInt8](data.prefix(2))
        guard bom.count == 2, bom == [0xFF, 0xFE] || bom == [0xFE, 0xFF] else { return false }
        return String(data: data, encoding: .utf16) != nil
    }

    /// Prefer the read organ's extension allowlist so binary images cannot masquerade as text; use MIME when no usable name exists.
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
        case .unreadableDocument, .unreadableTextEncoding: return "its bytes are not readable text"
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
