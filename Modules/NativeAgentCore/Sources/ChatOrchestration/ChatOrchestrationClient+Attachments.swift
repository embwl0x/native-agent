import Foundation
import NativeAgentCore
import MacControl

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

    // MARK: - Trust ▸ Multimodal, at the point of use (2026-09-06)
    //
    // "Allow vision API calls" and "Allow PDF file ingestion" round-tripped to
    // <dataRoot>/trust/policy.json and NOTHING read them: every attached image
    // reached the provider with the switch off, and no PDF ever reached it with
    // the switch on. These two readers close both halves.
    //
    // FRESH ON EVERY TURN, deliberately, the way MemoryPolicyGate reads the
    // memory switches: no launch-time snapshot, so a flip in Trust lands on the
    // next turn. The file is small and this runs once per turn.

    /// One boolean out of `multimodalPolicy`. Missing file / missing key →
    /// `fallback` (matching the shipped defaults in TrustCenter+Defaults, so
    /// the gate and the switch can never disagree about "unset"). A file that
    /// exists but cannot be read or parsed, a wrongly-typed `multimodalPolicy`
    /// block, or a non-Bool value is policy TrustCenter itself rejects — those
    /// fail CLOSED rather than quietly running the default.
    nonisolated static func multimodalPolicyAllows(
        _ key: String,
        default fallback: Bool,
        dataRoot: URL
    ) -> Bool {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return fallback }
        guard let data = try? Data(contentsOf: path) else { return false }
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let present = top["multimodalPolicy"]
        if present != nil, !(present is [String: Any]) { return false }
        guard let block = present as? [String: Any] else { return fallback }
        guard let raw = block[key] else { return fallback }
        guard let value = raw as? Bool else { return false }
        return value
    }

    /// Characters of extracted document text one attachment contributes to a
    /// turn. A contract is worth reading; a 400-page appendix is not worth a
    /// turn's whole context, and the note SAYS when the cut happened.
    /// 2026-09-06: one cap for PDFs and plain text — an attached .md is as
    /// capable of eating a turn's context as an attached .pdf.
    static let documentIngestionCharacterCap = 40_000

    /// Characters of extracted document text ALL of a turn's attachments may
    /// contribute between them. 2026-09-06: the per-attachment cap was the only
    /// bound, and both file pickers allow unlimited multiple selection — ten
    /// documents were ten times 40k, and the turn's context went with them. The
    /// budget is spent in attachment order; once it is gone the remaining
    /// documents are skipped and the model is told how many and why.
    static let turnDocumentCharacterBudget = 120_000

    /// What the model gets for this turn's attachments: the image blocks it is
    /// allowed to see, and the user message with an honest note appended for
    /// anything that was skipped or read out of a document.
    struct TurnAttachmentInput: Sendable {
        let imageBlocks: [LLMContentBlock]
        let userMessage: String
    }

    nonisolated static func turnAttachmentInput(
        message: String,
        attachments: [MultimodalAttachment],
        dataRoot: URL
    ) -> TurnAttachmentInput {
        guard !attachments.isEmpty else {
            return TurnAttachmentInput(imageBlocks: [], userMessage: message)
        }
        var notes: [String] = []

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

        // 2026-09-06: a .txt/.md attachment reached the model as nothing at all
        // — it attaches as type "file", never became a content block, and no
        // lane read it. Same road as the PDF text, no switch: nothing in Trust
        // claims to govern plain text. PDFs and plain text share one pass so
        // they also share one per-turn character budget.
        notes.append(contentsOf: documentAttachmentNotes(attachments, dataRoot: dataRoot))

        guard !notes.isEmpty else {
            return TurnAttachmentInput(imageBlocks: imageBlocks, userMessage: message)
        }
        let composed = ([message] + notes)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return TurnAttachmentInput(imageBlocks: imageBlocks, userMessage: composed)
    }

    /// Every document attachment of a turn — PDFs under "Allow PDF file
    /// ingestion", plain text under no switch (none claims to govern it) — read
    /// in ONE pass, in attachment order, through the same extractors the `read`
    /// organ uses. Anything skipped, cut, or unreadable is named to the model
    /// rather than being left as a filename it can invent contents for.
    ///
    /// 2026-09-06: this was two passes with a 40k cap each and no ceiling on
    /// how many attachments could claim one. One pass, one budget: each
    /// document takes at most `documentIngestionCharacterCap`, and no more than
    /// what is left of `turnDocumentCharacterBudget`; when the budget is spent
    /// the rest are skipped and counted in a note that names the budget.
    nonisolated static func documentAttachmentNotes(
        _ attachments: [MultimodalAttachment],
        dataRoot: URL
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
            // 2026-09-07: budget admission comes before decoding and extraction,
            // so a spent budget skips the work too and the "not read at all"
            // note below stays true.
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
            // 2026-09-06: MacDocumentRead.decodeText rejects only a NUL in the
            // first 4 KiB and then falls back to ISO-8859-1, which decodes ANY
            // byte sequence — so a renamed binary with a .txt extension arrived
            // as a page of mojibake presented as a document. The read organ
            // keeps that latitude (a person named that file by path); a chat
            // attachment named itself, so here the bytes must really be text.
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
                if text.count > allowance {
                    text = String(text.prefix(allowance))
                    cut = true
                }
                remainingBudget -= text.count
                let subject = isPDF ? "the attached PDF" : "the attached file"
                let header = cut
                    ? "[Text of \(subject) \"\(name)\", cut off after the first "
                        + "\(text.count) characters — there is more you were not given:]"
                    : "[Text of \(subject) \"\(name)\":]"
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
