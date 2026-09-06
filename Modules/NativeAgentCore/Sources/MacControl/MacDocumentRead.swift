// MacDocumentRead.swift — THE READ ORGAN (fable51 sweep item 33).
//
// "Read this contract." "What does this PDF say?" Those were not things the
// body could do, and not for a subtle reason: every perception organ in this
// module is built for a WINDOW, and a window is not a document.
//
//   • `look` is capped at 6,144 bytes for the whole payload, 12 readouts, and
//     40 characters per value. Those caps are correct — a glance that costs a
//     page of tokens is not a glance — and they make a contract unreadable by
//     construction: the overflow renders "… N more below (scrollable)" and the
//     text is simply gone.
//   • There is no PDFKit anywhere in the app, so a PDF on screen was pixels.
//   • Nothing scrolls and accumulates, so anything past the first viewport was
//     unreachable without the model driving `act` in a loop and stitching the
//     frames itself at full token cost — which is exactly the clause-5 failure:
//     the human world reaching her as WORK instead of as a sense.
//
// `read` is deliberately NOT `screen`. They answer different questions and are
// priced differently:
//
//     screen → "what is in front of me, and what can I do to it?"
//              One frame. Controls first. Bounded hard, on purpose.
//     read   → "what does this DOCUMENT say?"
//              All of it. Text only. Lossless, and paged.
//
// TWO ROUTES, and it picks between them by asking what the thing IS:
//
//   (a) EXTRACT. If the front window names a file (`AXDocument`) or a path was
//       given, and it is a PDF or plain text, the file itself is the truth.
//       PDFKit for a PDF, a decode for text. No screen, no scrolling, no OCR
//       guesswork — the characters the author wrote.
//   (b) ACCUMULATE. Otherwise: read the frontmost scroll container's text,
//       scroll one viewport, read again, merge on the overlap, and keep going
//       until the content stops changing or a hard frame cap bites.
//
// THE OUTPUT IS WHOLE, and that is the point of the item. This organ applies NO
// display cap of its own below its hard safety ceiling: it hands the complete
// text back, and the turn's EXISTING lossless spill (`ProviderToolResultProjection`
// → `ProviderToolResultRecoveryStore` → `tool_result_page`) retains it and pages
// it. There is deliberately no second store here — a document pager living in
// MacControl would be a parallel silo of the thing that already works.
//
// REDACTION is the same boundary the clipboard organ uses, reused rather than
// re-implemented: `MacClipboardRead.redacted` runs the shape redactor line by
// line, because a document is prose with (at most) a secret in it and blanking
// the whole contract because line 9 is an API key would blind the organ this
// exists to build.
//
// AND `look`'s BUDGETS ARE UNTOUCHED. This file owns its OWN walk with its own
// caps for exactly that reason: raising `MacAXLimits.hardValueChars` (200) or
// `hardMaxNodes` (400) so a document would fit would have re-priced every
// glance in the system. Nothing here reads or writes those.

import Foundation
import NativeAgentCore
import PersistenceCore

#if canImport(PDFKit) && os(macOS)
import PDFKit
#endif

/// User, 2026-09-06: THE TURN'S FILE-ACCESS MODE, carried to the one organ that
/// can name a file the caller never did.
///
/// `read` with no `path` clears only the accessibility category, because "read
/// what is in front of me" is a screen read. But this organ then asks the front
/// window for its `AXDocument` and OPENS THAT FILE OFF DISK — so a session
/// running under `fileAccess=none`, whose every pathful call the chat gate
/// refuses by name, still got a file read through the pathless one. The gate
/// cannot fix it alone: the path does not exist yet when the gate runs, and the
/// mode is not visible down here.
///
/// So the gate BINDS this around its dispatch and the organ reads it. Bound
/// false (never set) for every caller that has no per-turn mode — direct
/// library callers, the bridge, tests — which leaves their behaviour exactly as
/// it was; the MacControl file policy remains the fence for those.
public enum MacControlTurnFileAccess {
    /// True when the turn's file-access mode is `none`: no file may be opened
    /// for this turn, whoever named it. The organ falls back to the window's
    /// own AX text and says in the receipt that it declined the path.
    @TaskLocal public static var deniesFileReads: Bool = false
}

public enum MacDocumentRead {
    // MARK: - Bounds, and why each one

    /// Viewport-fulls one call will read before it stops and SAYS it stopped.
    /// Forty screens of a document is a book chapter; past that the honest
    /// answer is "there is more, ask again" rather than an unbounded loop
    /// driving the user's scroll wheel.
    public static let maxFrames = 40
    /// The hard safety ceiling on accumulated characters. Not a display cap —
    /// the spill pager carries everything under it losslessly — but an
    /// unbounded accumulator is a memory shape, not a feature.
    public static let maxAccumulatedChars = 400_000
    /// Nodes one FRAME's walk may visit. Far above `MacAXLimits.hardMaxNodes`
    /// (400) because a page of dense text is hundreds of `AXStaticText` runs,
    /// and deliberately in this file rather than by raising that constant.
    public static let maxNodesPerFrame = 3_000
    /// Depth one frame's walk descends. Web content nests deeply.
    public static let maxDepthPerFrame = 30
    /// Characters kept from ONE text node. A node longer than this is a whole
    /// document in one `AXTextArea` — which is the good case, and the reason
    /// this is 200x `MacAXLimits.hardValueChars` rather than equal to it.
    public static let maxCharsPerNode = 40_000
    /// How far back the overlap merge looks for the seam between two frames.
    public static let maxOverlapLines = 400
    /// Bytes of a file this organ will read. A 32 MB PDF is a large book.
    public static let maxFileBytes = 32 * 1024 * 1024
    /// PDF pages one call extracts.
    public static let maxPDFPages = 400
    /// The overlap band deliberately left between two scroll steps, as a
    /// fraction of the viewport height. Scrolling a FULL viewport leaves the
    /// two frames sharing no line, and a merge with no seam cannot tell
    /// "continued" from "jumped past something".
    public static let scrollOverlapFraction = 0.15
    /// Floor and ceiling on that band, in points.
    public static let minScrollOverlapPoints = 40.0
    public static let maxScrollOverlapPoints = 200.0

    // MARK: - The clock (gpt-5.5 review)
    //
    // `read` is a LIVE read: it runs outside the operation store's deadline
    // path ON PURPOSE, because a replayable operation record would let a later
    // call answer with a document that has since changed. What that bought was
    // an organ with NO bound on it at all — and it is the heaviest AX caller in
    // the module, hundreds of synchronous round trips per frame across up to
    // `maxFrames` frames. One app that stops answering and the whole turn hangs
    // behind AX's own six-second-per-call default, times every call.
    //
    // Two bounds, because they catch different failures:
    //   • `axMessagingTimeoutSeconds` — ONE round trip to the app being read.
    //     Set on that app's element only, never process-wide (the system-wide
    //     timeout belongs to exactly one organ, and it is not this one).
    //   • `deadlineSeconds` — the wall clock across the whole accumulation, for
    //     an app that answers every call, just slowly.
    // Whichever bites, the answer says so: a partial document is reported as
    // truncated by the clock, and a read that got nothing refuses in words.

    /// The bound on one AX round trip to the app being read.
    public static let axMessagingTimeoutSeconds: Float = 2.0
    /// The bound on the whole screen route.
    public static let deadlineSeconds: Double = 20.0
    /// The refusal code and truncation slug the clock uses.
    public static let timedOutReason = "read_timed_out"
    public static let deadlineTruncationReason = "deadline"

    /// Roles whose value/title is DOCUMENT TEXT. Controls are deliberately
    /// absent: `read` answers "what does it say", and a toolbar button's label
    /// is not part of the contract. `AXSecureTextField` is absent for a
    /// stronger reason — see `secureFieldRoles` below.
    public static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXTextArea", "AXTextField",
        "AXLink", "AXParagraph", "AXCell", "AXListMarker",
    ]

    /// Roles that hold a SECRET. Reused from the closed loop rather than
    /// re-listed, so one edit covers both.
    public static var secureFieldRoles: Set<String> { MacActClosedLoop.secureFieldRoles }

    /// Containers that scroll, most specific first. `AXWebArea` is not itself
    /// a scroll container but it IS the readable body of a browser window, and
    /// when nothing scrolls the frame walk still wants the page rather than the
    /// chrome.
    public static let containerRoles: [String] = [
        "AXScrollArea", "AXWebArea", "AXTextArea", "AXGroup",
    ]

    // MARK: - What the target IS

    public enum DocumentKind: Sendable, Equatable {
        case pdf
        case text
        /// The path exists but this organ cannot put it into words. The string
        /// is the extension, so the refusal can name it.
        case unsupported(String)
    }

    /// Extensions read as plain text. Deliberately a list, not "anything that
    /// decodes": a `.png` decodes to garbage that LOOKS like a short document.
    public static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rtf", "csv", "tsv", "log",
        "json", "yaml", "yml", "toml", "xml", "html", "htm", "swift", "py",
        "js", "ts", "c", "h", "cpp", "hpp", "m", "mm", "sh", "rb", "go",
        "rs", "java", "kt", "sql", "ini", "conf", "cfg", "plist", "srt",
    ]

    public static func kind(forPath path: String) -> DocumentKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if textExtensions.contains(ext) { return .text }
        return .unsupported(ext.isEmpty ? "no extension" : ext)
    }

    // MARK: - One frame of the screen, in text

    /// What ONE bounded walk of a container found.
    public struct Frame: Sendable, Equatable {
        public let lines: [String]
        public let nodes: Int
        /// True when a bound cut the walk, so "the document ends here" is
        /// never claimed by a walk that simply stopped.
        public let truncated: Bool
        /// Secure fields SEEN (never read). Used only to phrase the refusal
        /// when a container turns out to be nothing but a password box.
        public let secureNodes: Int

        public init(lines: [String], nodes: Int, truncated: Bool, secureNodes: Int) {
            self.lines = lines
            self.nodes = nodes
            self.truncated = truncated
            self.secureNodes = secureNodes
        }
    }

    /// THE FRAME WALK — this organ's own, with this organ's caps.
    ///
    /// Depth-first preorder like `MacAccessibilityReader.walk`, because reading
    /// order is document order and any other traversal returns a shuffled
    /// contract. It does not reuse that function only because its caps are the
    /// glance's caps, and a glance's caps are what item 33 is about.
    public static func frameLines(
        source: any MacAXElementSource,
        root: MacAXElementRef
    ) -> Frame {
        var lines: [String] = []
        var nodes = 0
        var secure = 0
        var truncated = false
        var stack: [(ref: MacAXElementRef, depth: Int)] = [(root, 1)]

        while let item = stack.popLast() {
            if nodes >= maxNodesPerFrame {
                truncated = true
                break
            }
            guard let attributes = source.attributes(of: item.ref) else { continue }
            nodes += 1

            let role = attributes.role
            let subrole = attributes.subrole
            if secureFieldRoles.contains(role) || subrole.map(secureFieldRoles.contains) == true {
                // SEEN, never read: a secure field's value never enters the
                // accumulator, and descending into one buys nothing.
                secure += 1
                continue
            }
            if textRoles.contains(role) {
                // The VALUE is the text; the title is the label. For a static
                // text run macOS puts the words in whichever it likes, so take
                // the value and fall back to the title rather than choosing.
                let raw = nonEmpty(attributes.value) ?? nonEmpty(attributes.title)
                if let raw {
                    for line in split(raw) { lines.append(line) }
                }
            }
            guard item.depth < maxDepthPerFrame else {
                if source.childCount(of: item.ref) > 0 { truncated = true }
                continue
            }
            let budget = max(0, maxNodesPerFrame - nodes)
            let total = source.childCount(of: item.ref)
            let children = source.children(of: item.ref, limit: budget)
            if total > children.count { truncated = true }
            for child in children.reversed() {
                stack.append((child, item.depth + 1))
            }
        }
        return Frame(lines: lines, nodes: nodes, truncated: truncated, secureNodes: secure)
    }

    static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One AX value can be a whole paragraph or a whole document. Split it into
    /// LINES, because the line is the unit the cross-frame merge identifies on.
    static func split(_ raw: String) -> [String] {
        String(raw.prefix(maxCharsPerNode))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Cross-frame identity: the merge

    /// What absorbing one frame did.
    public enum Absorption: Sendable, Equatable {
        /// New lines were appended, and how many.
        case added(Int)
        /// Everything in this frame was already here. The content did not move
        /// — which is how a scroll-and-accumulate learns it has reached the end
        /// without asking the app a question no app answers honestly.
        case nothingNew
        /// New lines were appended, but the frames shared NO line, so whether
        /// something fell between them is unknown. Reported, never smoothed
        /// over.
        case addedWithGap(Int)
    }

    /// The accumulator. Cross-frame identity, applied to TEXT.
    ///
    /// The live scene tracker (`SwiftToolDispatcherFourVerbLiveScene`) does this
    /// for visual regions by matching geometry, colour and salience across
    /// frames. A line of text needs none of that: two frames of the same
    /// document share a literal run of identical lines at the seam, and the
    /// longest such run IS the identity. So the same idea, in the form the
    /// substrate actually offers.
    ///
    /// Longest-overlap merge, not a seen-set: a set would silently delete the
    /// second occurrence of "Signed:" thirty pages later, and a document full
    /// of repeated headings would come back gutted.
    public struct Accumulator: Sendable {
        public private(set) var lines: [String] = []
        public private(set) var frames = 0
        public private(set) var sawGap = false
        private var previousFrame: [String] = []

        public init() {}

        public var text: String { lines.joined(separator: "\n") }
        public var characters: Int { text.count }

        public mutating func absorb(_ frame: [String]) -> Absorption {
            frames += 1
            guard !frame.isEmpty else {
                previousFrame = frame
                return .nothingNew
            }
            guard !lines.isEmpty else {
                lines = frame
                previousFrame = frame
                return .added(frame.count)
            }
            // 1. The frame is byte-identical to the last one: nothing moved.
            if frame == previousFrame {
                previousFrame = frame
                return .nothingNew
            }
            // 2. The seam. Longest run of lines shared by the accumulated tail
            //    and this frame's head.
            if let result = mergeOnOverlap(frame) {
                previousFrame = frame
                return result
            }
            // 3. No seam. Before calling that a gap, strip the STICKY CHROME —
            //    a header/footer that is redrawn identically in every frame
            //    sits at the boundary and hides the real seam behind itself.
            let stripped = Self.strippingSticky(frame, sharedWith: previousFrame)
            if stripped.isEmpty {
                previousFrame = frame
                return .nothingNew
            }
            if stripped.count != frame.count, let result = mergeOnOverlap(stripped) {
                previousFrame = frame
                return result
            }
            // 4. Genuinely no shared line. Keep the content and SAY so.
            lines.append(contentsOf: stripped)
            previousFrame = frame
            sawGap = true
            return .addedWithGap(stripped.count)
        }

        private mutating func mergeOnOverlap(_ frame: [String]) -> Absorption? {
            let tail = Array(lines.suffix(maxOverlapLines))
            let maxK = min(tail.count, frame.count)
            guard maxK > 0 else { return nil }
            for k in stride(from: maxK, through: 1, by: -1)
            where Array(tail.suffix(k)) == Array(frame.prefix(k)) {
                let fresh = Array(frame.dropFirst(k))
                guard !fresh.isEmpty else { return .nothingNew }
                lines.append(contentsOf: fresh)
                return .added(fresh.count)
            }
            return nil
        }

        /// Drop the leading and trailing runs this frame shares with the last
        /// one. Those are the parts of the window that do NOT scroll.
        static func strippingSticky(_ frame: [String], sharedWith previous: [String]) -> [String] {
            guard !previous.isEmpty else { return frame }
            var head = 0
            while head < frame.count, head < previous.count, frame[head] == previous[head] {
                head += 1
            }
            var tail = 0
            while tail < frame.count - head,
                  tail < previous.count - head,
                  frame[frame.count - 1 - tail] == previous[previous.count - 1 - tail] {
                tail += 1
            }
            guard head > 0 || tail > 0 else { return frame }
            return Array(frame.dropFirst(head).dropLast(tail))
        }
    }

    // MARK: - The scroll step

    /// How far one step scrolls a container of this height, in points, with the
    /// deliberate overlap band held back so the merge always has a seam.
    public static func scrollStepPoints(viewportHeight: Double) -> Int32 {
        let height = max(1, viewportHeight)
        let overlap = min(maxScrollOverlapPoints, max(minScrollOverlapPoints, height * scrollOverlapFraction))
        let step = max(40, height - overlap)
        return Int32(min(step, 4_000).rounded())
    }

    // MARK: - Extraction (route a)

    public struct Extracted: Sendable, Equatable {
        public let text: String
        /// PDF page count, when the format has pages.
        public let pages: Int?
        /// True when a cap cut the extraction.
        public let truncated: Bool

        public init(text: String, pages: Int?, truncated: Bool) {
            self.text = text
            self.pages = pages
            self.truncated = truncated
        }
    }

    /// Every way an extraction can honestly fail. Each maps to WORDS at the
    /// handler, never to a bare code.
    public enum ExtractionFailure: String, Sendable, Equatable, Error {
        case fileTooLarge = "file_too_large"
        case unreadableDocument = "unreadable_document"
        case encryptedDocument = "encrypted_document"
        case noTextInDocument = "no_text_in_document"
        case unsupportedType = "unsupported_document_type"
        /// The path is behind the module's sensitive-path fence. Reading a
        /// document is not a reason for that fence to stop applying: a keychain
        /// or a credentials file is exactly as sensitive when it is asked for as
        /// a "document".
        case sensitivePath = "sensitive_path_denied"
    }

    public static func extract(
        data: Data,
        kind: DocumentKind
    ) -> Result<Extracted, ExtractionFailure> {
        guard data.count <= maxFileBytes else { return .failure(.fileTooLarge) }
        switch kind {
        case .unsupported:
            return .failure(.unsupportedType)
        case .text:
            guard let decoded = decodeText(data) else { return .failure(.unreadableDocument) }
            let cut = String(decoded.prefix(maxAccumulatedChars))
            guard !cut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.noTextInDocument)
            }
            return .success(Extracted(
                text: cut,
                pages: nil,
                truncated: cut.count < decoded.count
            ))
        case .pdf:
            return extractPDF(data)
        }
    }

    /// UTF-8 first, then the two encodings a Mac actually produces. A file that
    /// decodes to a run of NULs is a binary that happened to have a text
    /// extension, and saying so beats returning mojibake as a document.
    static func decodeText(_ data: Data) -> String? {
        let head = data.prefix(4096)
        if head.contains(0) { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }

    static func extractPDF(_ data: Data) -> Result<Extracted, ExtractionFailure> {
        #if canImport(PDFKit) && os(macOS)
        guard let document = PDFDocument(data: data) else {
            return .failure(.unreadableDocument)
        }
        if document.isEncrypted && document.isLocked {
            return .failure(.encryptedDocument)
        }
        let total = document.pageCount
        guard total > 0 else { return .failure(.unreadableDocument) }
        var pieces: [String] = []
        var characters = 0
        var truncated = total > maxPDFPages
        for index in 0..<min(total, maxPDFPages) {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if characters + trimmed.count > maxAccumulatedChars {
                pieces.append(String(trimmed.prefix(max(0, maxAccumulatedChars - characters))))
                truncated = true
                break
            }
            pieces.append(trimmed)
            characters += trimmed.count
        }
        let joined = pieces.joined(separator: "\n\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A scanned contract: pages of pixels with no text layer. This
            // organ does not OCR — `screen` is the eye for pixels — and saying
            // so is the answer, not an empty document.
            return .failure(.noTextInDocument)
        }
        return .success(Extracted(text: joined, pages: total, truncated: truncated))
        #else
        _ = data
        return .failure(.unsupportedType)
        #endif
    }

    // MARK: - Words

    /// Every refusal this organ can make, IN WORDS. One place, so the words a
    /// caller reads and the words a test pins are the same string.
    public static func words(for failure: ExtractionFailure, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        switch failure {
        case .fileTooLarge:
            return "\"\(name)\" is larger than \(maxFileBytes / (1024 * 1024)) MB, "
                + "which is more than I will read in one go."
        case .unreadableDocument:
            return "I can open \"\(name)\" but I cannot make text out of it — "
                + "it is damaged or it is not the kind of file its name claims."
        case .encryptedDocument:
            return "\"\(name)\" is password-protected, so I cannot read it. "
                + "Open it yourself and I will read what is on screen."
        case .noTextInDocument:
            return "\"\(name)\" has no text layer — it is pictures of pages, not characters. "
                + "I would have to look at it rather than read it; ask me to look at the screen instead."
        case .unsupportedType:
            return "\"\(name)\" is not a document I can read as text. "
                + "I read PDFs and plain-text files; for anything else, ask me to look at the screen."
        case .sensitivePath:
            return "\"\(name)\" is behind the fence I do not read across — keys, credentials and "
                + "the system's own private stores. That is not something a document read gets around."
        }
    }

    public static let noDocumentWords =
        "There is no document in front of me to read. Bring one up, or give me a file path."

    public static let noWindowWords =
        "There is nothing in front of me right now — no window I can read."

    public static let secureContentWords =
        "What is in front of me is a secure field — a password box — and macOS does not publish "
        + "its contents to anything, including me. Nothing was read."

    public static let emptyScreenWords =
        "The window in front of me publishes no readable text. If it is a picture, a canvas or a "
        + "video, ask me to look at the screen instead — reading it would return nothing."

    public static let scrollUnavailableWords =
        "I can read what is on screen but I cannot scroll it, so this is only the first screenful."

    /// The clock ran out before a single line came back — the app is not
    /// answering, which is a different fact from a window with no text in it.
    public static func timedOutWords(app: String) -> String {
        "\(app) stopped answering while I was reading it — I waited "
            + "\(Int(deadlineSeconds)) seconds and got nothing back, so I stopped rather than "
            + "hanging on it. Nothing was read and nothing was changed. It may be busy or beach-"
            + "balling; try again once it is responding."
    }

    /// The clock ran out PART WAY. There is a real answer; it is just not all
    /// of one, and saying which is the whole point.
    public static func deadlineWords(app: String) -> String {
        "\(app) was answering too slowly to finish the document inside "
            + "\(Int(deadlineSeconds)) seconds, so this is what I had read when I stopped — the "
            + "beginning of it, not the whole thing. I put the scroll back. Ask again for more."
    }

    /// The AX-inferred document could not clear the file policy, so the file
    /// route was not taken and the window's own text was read instead.
    public static func filePolicyDeclinedWords(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return "The window in front names \"\(name)\" as its file, but opening a file is file access and "
            + "I do not have it right now — so I read what the window itself shows instead of the "
            + "document on disk. Turn on Full Mac file access if you want the file's own text."
    }
}
