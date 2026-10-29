// Saved documents extract directly; live documents accumulate overlapping AX
// frames through the shared walker with document bounds. Full AXTextArea values
// need no scrolling. Every cut is reported, secrets are redacted in context,
// and the existing tool-result spill retains the text without a second pager.

import Foundation
import NativeAgentCore
import Senses
import PersistenceCore
import TrustCenter
#if canImport(PDFKit) && os(macOS)
import PDFKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon) && os(macOS)
import Carbon
#endif

// Blueprint: | `MacDocumentRead.swift` | `MacDocumentRead`: bounded document extraction and scrolling accumulation; observed scrollbar restoration, admitted file access, deadlines and redacted read frames |

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

    // MARK: - The clock
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
        "txt", "text", "md", "markdown", "csv", "tsv", "log",
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
        /// True when a bound cut the walk, so "the document ends here" is
        /// never claimed by a walk that simply stopped.
        public let truncated: Bool
        /// Every kept line came from an AXTextArea value, and no bound cut
        /// the frame. Those values contain the whole text, beyond the viewport.
        public let wholeText: Bool
        /// Secure fields SEEN (never read). Used only to phrase the refusal
        /// when a container turns out to be nothing but a password box.
        public let secureNodes: Int
        public let didRedact: Bool

        public init(lines: [String], truncated: Bool, secureNodes: Int, didRedact: Bool = false, wholeText: Bool = false) {
            self.lines = lines
            self.truncated = truncated
            self.wholeText = wholeText
            self.secureNodes = secureNodes
            self.didRedact = didRedact
        }
    }

    /// Document-order text with document bounds and secure-subtree pruning.
    public static func frameLines(
        source: any MacAXElementSource,
        root: MacAXElementRef,
        characterLimit: Int = maxAccumulatedChars,
        shouldStop: () -> Bool = { Task.isCancelled }
    ) -> Frame {
        var lines: [String] = []
        var wholeText = true
        var secure = Set<Int>()
        let snapshot = MacAccessibilityReader.walk(source: source, root: root, limits: .document,
            read: { ref in
                guard let a = source.attributes(of: ref) else { return nil }
                if secureFieldRoles.contains(a.role) || a.subrole.map(secureFieldRoles.contains) == true {
                    secure.insert(ref.id)
                }
                return a
            }, deadline: .distantFuture, descendInto: { !secure.contains($0.id) }, shouldStop: shouldStop)
        let collected = snapshot.nodes.filter { node in
            node.element.map { secure.contains($0.id) } != true
        }.map { node in
            MacAXNode(attributes: node.attributes,
                path: node.path.isEmpty && node.attributes.role == "AXWindow" ? [] : [0] + node.path)
        }
        var truncated = snapshot.truncated
        // Keep captions and ancestry until the shared screen redactor has
        // judged every line; values alone cannot identify a CVV.
        let context = MacScreenViewTextRedaction.nodeSecretContext(collected)
        let limit = max(0, min(characterLimit, maxAccumulatedChars))
        var characters = 0
        var didRedact = false
        collection: for node in collected where textRoles.contains(node.attributes.role) {
            let a = node.attributes
            let value = nonEmpty(a.value)
            guard let raw = value ?? nonEmpty(a.title) else { continue }
            if raw.count > maxCharsPerNode { truncated = true }
            let enclosing = MacScreenViewTextRedaction.enclosingKinds(
                forNodeAt: a.frame, path: node.path, among: context.enclosingCaptions
            )
            for line in split(raw) {
                let redacted: JSONValue
                if a.value != nil, MacScreenViewBuilder.isSecretField(role: a.role, subrole: a.subrole, label: a.title) {
                    redacted = MacScreenViewTextRedaction.redactedText(line, reason: "secure_field")
                } else {
                    redacted = MacScreenViewTextRedaction.redactedNodeString(
                        line, valueChars: maxCharsPerNode, frame: a.frame,
                        under: a.value == nil ? nil : a.title, enclosing: enclosing, context: context
                    )
                }
                let text: String
                if case .string(let safe) = redacted {
                    text = safe
                } else {
                    didRedact = true
                    let reason: String
                    if case .object(let object) = redacted,
                       case .string(let value)? = object["reason"] { reason = value }
                    else { reason = "secret" }
                    text = "[redacted: \(reason)]"
                }
                let remaining = limit - characters - (lines.isEmpty ? 0 : 1)
                guard remaining > 0 else { truncated = true; break collection }
                let kept = String(text.prefix(remaining))
                characters += kept.count + (lines.isEmpty ? 0 : 1)
                lines.append(kept)
                wholeText = wholeText && a.role == "AXTextArea" && value != nil
                if kept.count < text.count { truncated = true; break collection }
            }
        }
        SenseAppReadCapture.current?.appendFrame(nodes: MacScreenViewTextRedaction.redactedNodesJSON(collected,
            valueChars: max(1, collected.reduce(0) { max($0, max($1.attributes.title?.count ?? 0, $1.attributes.value?.count ?? 0)) })),
            truncated: truncated)
        return Frame(lines: lines, truncated: truncated, secureNodes: secure.count,
                     didRedact: didRedact, wholeText: wholeText && !lines.isEmpty && !truncated)
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
        public private(set) var sawGap = false
        public private(set) var characters = 0
        public private(set) var truncated = false
        private var previousFrame: [String] = []

        public init() {}

        public var text: String { lines.joined(separator: "\n") }
        public var remainingCharacters: Int { max(0, maxAccumulatedChars - characters) }

        private mutating func append(_ fresh: [String]) {
            for line in fresh {
                let remaining = remainingCharacters - (lines.isEmpty ? 0 : 1)
                guard remaining > 0 else { truncated = true; break }
                let kept = String(line.prefix(remaining))
                characters += kept.count + (lines.isEmpty ? 0 : 1)
                lines.append(kept)
                if kept.count < line.count { truncated = true; break }
            }
        }

        /// Returns true when this frame has nothing new, independently of the character cap.
        public mutating func absorb(_ frame: [String]) -> Bool {
            guard !frame.isEmpty else {
                previousFrame = frame
                return true
            }
            guard !lines.isEmpty else {
                append(frame)
                previousFrame = frame
                return false
            }
            // 1. The frame is byte-identical to the last one: nothing moved.
            if frame == previousFrame {
                previousFrame = frame
                return true
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
                return true
            }
            if stripped.count != frame.count, let result = mergeOnOverlap(stripped) {
                previousFrame = frame
                return result
            }
            // 4. Genuinely no shared line. Keep the content and SAY so.
            append(stripped)
            previousFrame = frame
            sawGap = true
            return false
        }

        private mutating func mergeOnOverlap(_ frame: [String]) -> Bool? {
            let tail = Array(lines.suffix(maxOverlapLines))
            let maxK = min(tail.count, frame.count)
            guard maxK > 0 else { return nil }
            for k in stride(from: maxK, through: 1, by: -1)
            where Array(tail.suffix(k)) == Array(frame.prefix(k)) {
                let fresh = Array(frame.dropFirst(k))
                guard !fresh.isEmpty else { return true }
                append(fresh)
                return false
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
        /// True when a cap or a page without text left the extraction incomplete.
        public let truncated: Bool
        /// One-based PDF page numbers inspected but omitted for lack of text.
        public let pagesWithoutText: [Int]

        public init(text: String, pages: Int?, truncated: Bool, pagesWithoutText: [Int] = []) {
            self.text = text
            self.pages = pages
            self.truncated = truncated
            self.pagesWithoutText = pagesWithoutText
        }
    }

    /// Every way an extraction can honestly fail. Each maps to WORDS at the
    /// handler, never to a bare code.
    public enum ExtractionFailure: String, Sendable, Equatable, Error {
        case fileTooLarge = "file_too_large"
        case unreadableDocument = "unreadable_document"
        case fileNotFound = "file_not_found"
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

    /// Recognize UTF-16 byte order before rejecting binary NULs. A file that
    /// decodes to a run of NULs is a binary that happened to have a text
    /// extension, and saying so beats returning mojibake as a document.
    static func decodeText(_ data: Data) -> String? {
        let bom = Array(data.prefix(2))
        if bom == [0xff, 0xfe] || bom == [0xfe, 0xff] {
            guard let utf16 = String(data: data, encoding: .utf16), !utf16.contains("\0") else { return nil }
            return utf16
        }
        let head = data.prefix(4096)
        if head.contains(0) { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
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
        var pagesWithoutText: [Int] = []
        for index in 0..<min(total, maxPDFPages) {
            let trimmed = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                pagesWithoutText.append(index + 1)
                truncated = true
                continue
            }
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
        return .success(Extracted(text: joined, pages: total, truncated: truncated, pagesWithoutText: pagesWithoutText))
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
        case .fileNotFound:
            return "There is no file at \(path). Check the exact path (list the folder with files.list); nothing was read."
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
            + "beginning of it, not the whole thing. Ask again for more."
    }

}

// Restore the observed scrollbar value, never the requested wheel distance; an end probe may move less or not at all.
final class MacDocumentScrollRestoration: @unchecked Sendable {
    #if canImport(ApplicationServices) && os(macOS)
    private let owner: AXUIElement
    private let scrollbar: AXUIElement
    private let value: NSNumber

    private init(owner: AXUIElement, scrollbar: AXUIElement, value: NSNumber) {
        self.owner = owner
        self.scrollbar = scrollbar
        self.value = value
    }
    #endif

    static func capture(source: any MacAXElementSource, container: MacAXElementRef) -> MacDocumentScrollRestoration? {
        #if canImport(ApplicationServices) && os(macOS)
        guard let source = source as? SystemMacAXElementSource else { return nil }
        var candidate = source.element(container)
        for _ in 0..<32 {
            guard let node = candidate else { return nil }
            _ = source.prepareForRead(node)
            if let bar = MacAXAttributeRead.copyElement(node, kAXVerticalScrollBarAttribute) {
                let bar = source.prepareForRead(bar)
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
                      settable.boolValue,
                      let value = MacAXAttributeRead.copyRaw(bar, kAXValueAttribute) as? NSNumber,
                      value.doubleValue.isFinite else { return nil }
                return MacDocumentScrollRestoration(owner: node, scrollbar: bar, value: value)
            }
            if MacAXAttributeRead.copyString(node, kAXRoleAttribute) == "AXWindow" { return nil }
            candidate = MacAXAttributeRead.copyElement(node, kAXParentAttribute)
        }
        #endif
        return nil
    }

    func restore() -> Bool {
        #if canImport(ApplicationServices) && os(macOS)
        guard let current = MacAXAttributeRead.copyElement(owner, kAXVerticalScrollBarAttribute),
              CFEqual(current, scrollbar) else { return false }
        // Avoid even a no-op write when the downward end probe never moved.
        if isRestored { return true }
        guard MacDriverContext.binding?.allowsAction == true else { return false }
        return AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, value) == .success
        #else
        return false
        #endif
    }

    var isRestored: Bool {
        #if canImport(ApplicationServices) && os(macOS)
        guard let current = MacAXAttributeRead.copyElement(owner, kAXVerticalScrollBarAttribute),
              CFEqual(current, scrollbar),
              let observed = MacAXAttributeRead.copyRaw(scrollbar, kAXValueAttribute) as? NSNumber else { return false }
        return observed == value
        #else
        return false
        #endif
    }

    /// The read began below the document's first line; `nil` when the app gives no minimum.
    var startedBelowBeginning: Bool? {
        #if canImport(ApplicationServices) && os(macOS)
        guard let minimum = MacAXAttributeRead.copyRaw(scrollbar, kAXMinValueAttribute) as? NSNumber else { return nil }
        return value.doubleValue > minimum.doubleValue
        #else
        return nil
        #endif
    }
}
