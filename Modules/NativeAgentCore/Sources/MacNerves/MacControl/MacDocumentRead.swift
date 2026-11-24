// Saved files and live AX accumulation share redaction and spill retention; full AXTextArea values need no scroll. Report every cut so partial text cannot
// masquerade as a whole document.

import Foundation
import NativeAgentShared
import NativeAgentCore
import SenseCore
import PersistenceCore
import DeskCore
import PDFKit
import ApplicationServices
import CoreGraphics
import AppKit
import Carbon

// Blueprint: | `MacDocumentRead.swift` | `MacDocumentRead`: Bounded extraction, accumulation and observed scroll restoration |

public enum MacDocumentRead {
    // MARK: - Bounds, and why each one

    /// Forty viewports bound a book-chapter-sized read; report remaining content instead of driving the scroll wheel indefinitely.
    public static let maxFrames = 40
    /// Cap accumulated characters to bound memory while the spill pager retains everything under the cap losslessly.
    public static let maxAccumulatedChars = 400_000
    /// Dense pages contain hundreds of static-text runs, so document frames need a larger node budget without widening ordinary perception caps.
    public static let maxNodesPerFrame = 3_000
    /// Web document content nests deeply, requiring a document-specific depth budget.
    public static let maxDepthPerFrame = 30
    /// A single AXTextArea can hold a whole document, so its value cap is 200 times the ordinary look cap.
    public static let maxCharsPerNode = 40_000
    /// A 32 MB file budget accommodates book-sized PDFs while bounding extraction memory.
    public static let maxFileBytes = 32 * 1024 * 1024
    public static let maxPDFPages = 400
    /// Leave an overlap band so adjacent frames share a merge seam; full-viewport scrolls cannot distinguish continuation from skipped text.
    public static let scrollOverlapFraction = 0.15
    public static let minScrollOverlapPoints = 40.0
    public static let maxScrollOverlapPoints = 200.0

    // MARK: - The clock
    // Live reads bypass replayable operation records because documents can change between calls. Bound both per-app AX round trips and total wall time: one
    // catches unanswered calls, the other slow cumulative progress. Report partial text as clock-truncated and refuse empty deadline-exhausted reads.

    /// Bound individual AX calls so an unresponsive app cannot multiply the system timeout across every node.
    public static let axMessagingTimeoutSeconds: Float = 2.0
    /// Bound total accumulation so individually responsive AX calls cannot prolong the turn indefinitely.
    public static let deadlineSeconds: Double = 20.0
    /// Share the clock failure slug between refusals and partial-read truncation.
    public static let timedOutReason = "read_timed_out"
    public static let deadlineTruncationReason = "deadline"

    /// Collect document text roles only; control labels are not document prose, and secure fields never enter this channel.
    public static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXTextArea", "AXTextField",
        "AXLink", "AXParagraph", "AXCell", "AXListMarker",
    ]

    /// Roles that hold a SECRET. Reused from the closed loop rather than re-listed, so one edit covers both.
    public static var secureFieldRoles: Set<String> { MacActClosedLoop.secureFieldRoles }

    // MARK: - What the target IS

    public enum DocumentKind: Sendable, Equatable {
        case pdf
        case text
        /// Retain unsupported extensions so the refusal can name the format it cannot extract.
        case unsupported(String)
    }

    /// Use an explicit text extension list; arbitrary binary data can decode into plausible garbage.
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

    fileprivate struct LineAnchor: Sendable, Equatable {
        let element: MacAXElementRef?
        let indexInElement: Int
        let y: Double?
        let readable: Bool
    }

    public struct Frame: Sendable, Equatable {
        public let lines: [String]
        /// True when a bound cut the walk, so "the document ends here" is never claimed by a walk that simply stopped.
        public let truncated: Bool
        /// Every kept line came from an AXTextArea value, and no bound cut the frame. Those values contain the whole text, beyond the viewport.
        public let wholeText: Bool
        /// Secure fields SEEN (never read). Used only to phrase the refusal when a container turns out to be nothing but a password box.
        public let secureNodes: Int
        public let didRedact: Bool
        fileprivate var anchors: [LineAnchor] = []

        public init(lines: [String], truncated: Bool, secureNodes: Int, didRedact: Bool = false, wholeText: Bool = false) {
            self.lines = lines
            self.truncated = truncated
            self.wholeText = wholeText
            self.secureNodes = secureNodes
            self.didRedact = didRedact
        }
    }

    /// Prune secure subtrees before collecting text so credentials never enter a read frame.
    public static func frameLines(
        source: any MacAXElementSource,
        root: MacAXElementRef,
        characterLimit: Int = maxAccumulatedChars,
        context: MacOperationContext, shouldStop: () -> Bool = { Task.isCancelled }) -> Frame {
        var lines: [String] = []
        var anchors: [LineAnchor] = []
        var wholeText = true
        var secure = Set<Int>()
        let snapshot = MacAccessibilityReader.walk(source: source, root: root, limits: .document, read: { ref, context in
                guard let a = source.attributes(of: ref, context: context) else { return nil }
                if secureFieldRoles.contains(a.role) || a.subrole.map(secureFieldRoles.contains) == true {
                    secure.insert(ref.id)
                }
                return a
            }, deadline: .distantFuture, descendInto: { !secure.contains($0.id) }, context: context, shouldStop: shouldStop)
        let collected = snapshot.nodes.filter { node in
            node.element.map { secure.contains($0.id) } != true
        }.map { node in
            MacAXNode(attributes: node.attributes,
                path: node.path.isEmpty && node.attributes.role == "AXWindow" ? [] : [0] + node.path, element: node.element)
        }
        var truncated = snapshot.truncated
        // Keep captions and ancestry until the shared screen redactor has judged every line; values alone cannot identify a CVV.
        let secretContext = MacScreenViewTextRedaction.nodeSecretContext(collected)
        let limit = max(0, min(characterLimit, maxAccumulatedChars))
        var characters = 0
        var didRedact = false
        collection: for node in collected where textRoles.contains(node.attributes.role) {
            let a = node.attributes
            let editorValue = a.role == "AXTextArea" && a.value?.isEmpty == false
            guard let raw = editorValue ? a.value : a.value.trimmedNonEmpty ?? a.title.trimmedNonEmpty else { continue }
            let nodeTruncated = raw.count > maxCharsPerNode
            if nodeTruncated { truncated = true }
            let enclosing = MacScreenViewTextRedaction.enclosingKinds(
                forNodeAt: a.frame, path: node.path, among: secretContext.enclosingCaptions
            )
            let rawLines = raw.prefix(maxCharsPerNode).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            for (index, original) in rawLines.enumerated() {
                let line = original.trimmingCharacters(in: .whitespaces)
                guard editorValue || !line.isEmpty else { continue }
                let redacted: JSONValue
                if a.value != nil, MacScreenViewBuilder.isSecretField(role: a.role, subrole: a.subrole, label: a.title) {
                    redacted = MacScreenViewTextRedaction.redactedText(line, reason: "secure_field")
                } else {
                    redacted = MacScreenViewTextRedaction.redactedNodeString(
                        line, valueChars: maxCharsPerNode, frame: a.frame,
                        under: a.value == nil ? nil : a.title, enclosing: enclosing, context: secretContext
                    )
                }
                let text: String
                if case .string(let safe) = redacted {
                    text = editorValue ? String(original) : safe
                } else {
                    didRedact = true
                    let reason: String
                    if case .object(let object) = redacted,
                       case .string(let value)? = object["reason"] { reason = value }
                    else { reason = "secret" }
                    text = "[redacted: \(reason)]"
                }
                let remaining = limit - characters - (lines.isEmpty ? 0 : 1)
                guard remaining > 0 || (remaining == 0 && text.isEmpty) else { truncated = true; break collection }
                let kept = String(text.prefix(remaining))
                characters += kept.count + (lines.isEmpty ? 0 : 1)
                lines.append(kept)
                anchors.append(LineAnchor(element: node.element, indexInElement: index, y: a.frame?.y,
                                          readable: redacted.stringValue != nil && !kept.isEmpty && kept == text && !nodeTruncated))
                wholeText = wholeText && editorValue
                if kept.count < text.count { truncated = true; break collection }
            }
        }
        context.appCapture?.appendFrame(nodes: MacScreenViewTextRedaction.redactedNodesJSON(collected,
            valueChars: max(1, collected.reduce(0) { max($0, max($1.attributes.title?.count ?? 0, $1.attributes.value?.count ?? 0)) })),
            truncated: truncated)
        var frame = Frame(lines: lines, truncated: truncated, secureNodes: secure.count,
                          didRedact: didRedact, wholeText: wholeText && !lines.isEmpty && !truncated)
        frame.anchors = anchors
        return frame
    }

    // MARK: - Cross-frame identity: the merge

    /// A moving AX run must contain a distinct readable line. Recycled cells can keep their AX identity even when they hold different rows.
    public struct Accumulator: Sendable {
        public private(set) var lines: [String] = []
        public private(set) var sawGap = false
        public private(set) var characters = 0
        public private(set) var truncated = false
        private var previousFrame: Frame?

        public init() {}

        public var text: String { lines.joined(separator: "\n") }
        public var remainingCharacters: Int { max(0, maxAccumulatedChars - characters) }

        private mutating func append(_ fresh: ArraySlice<String>) {
            for line in fresh {
                let remaining = remainingCharacters - (lines.isEmpty ? 0 : 1)
                guard remaining > 0 || (remaining == 0 && line.isEmpty) else { truncated = true; break }
                let kept = String(line.prefix(remaining))
                characters += kept.count + (lines.isEmpty ? 0 : 1)
                lines.append(kept)
                if kept.count < line.count { truncated = true; break }
            }
        }

        public mutating func absorb(_ frame: Frame, source: any MacAXElementSource) {
            let previous = previousFrame
            previousFrame = frame
            guard let previous else { append(frame.lines[...]); return }

            func matches(_ old: Int, _ new: Int, moved: Bool) -> Bool {
                guard previous.anchors.indices.contains(old), frame.anchors.indices.contains(new) else { return false }
                let before = previous.anchors[old], after = frame.anchors[new]
                guard let oldY = before.y, let newY = after.y, oldY.isFinite, newY.isFinite,
                      moved ? newY < oldY : newY == oldY,
                      before.indexInElement == after.indexInElement,
                      let oldElement = before.element, let newElement = after.element,
                      source.sameElement(oldElement, newElement) else { return false }
                return previous.lines[old] == frame.lines[new]
            }

            // Fixed headers and footers can sit outside a proven seam. Keep them when the seam is unknown.
            let sharedLimit = min(previous.lines.count, frame.lines.count)
            var head = 0
            while head < sharedLimit, matches(head, head, moved: false) {
                head += 1
            }
            var tail = 0
            let oldEnd = previous.lines.count, newEnd = frame.lines.count
            while tail < sharedLimit - head, matches(oldEnd - 1 - tail, newEnd - 1 - tail, moved: false) {
                tail += 1
            }
            let oldBodyEnd = oldEnd - tail
            let newBodyEnd = newEnd - tail
            let oldRows = Dictionary(grouping: head..<oldBodyEnd, by: { previous.lines[$0] })
            let newRows = Dictionary(grouping: head..<newBodyEnd, by: { frame.lines[$0] })
            for new in head..<newBodyEnd {
                let line = frame.lines[new]
                guard newRows[line]?.count == 1, let old = oldRows[line], old.count == 1,
                      matches(old[0], new, moved: true),
                      previous.anchors[old[0]].readable, frame.anchors[new].readable else { continue }

                // Any proven overlap must include this first distinct shared line in the new prefix. It determines the only possible alignment.
                let start = old[0] - (new - head)
                let count = oldBodyEnd - start
                if start >= head, count <= newBodyEnd - head,
                   (0..<count).allSatisfy({ matches(start + $0, head + $0, moved: true) }) {
                    // Re-seat the fixed footer after the new document lines.
                    characters -= lines.suffix(tail).reduce(0) { $0 + $1.count + 1 }
                    lines.removeLast(tail)
                    append(frame.lines[(head + count)...])
                    return
                }
                break
            }
            append(frame.lines[...])
            sawGap = true
        }
    }

    // MARK: - The scroll step

    /// Retain the overlap band in every scroll step so accumulation has a merge seam.
    public static func scrollStepPoints(viewportHeight: Double) -> Int32 {
        let height = max(1, viewportHeight)
        let overlap = min(maxScrollOverlapPoints, max(minScrollOverlapPoints, height * scrollOverlapFraction))
        let step = max(40, height - overlap)
        return Int32(min(step, 4_000).rounded())
    }

    // MARK: - Extraction (route a)

    public struct Extracted: Sendable, Equatable {
        public let text: String
        public let pages: Int?
        /// Keep incomplete extraction explicit when caps or textless pages omit content.
        public let truncated: Bool
        /// Retain one-based omitted page numbers so textless gaps are identifiable.
        public let pagesWithoutText: [Int]

        public init(text: String, pages: Int?, truncated: Bool, pagesWithoutText: [Int] = []) {
            self.text = text
            self.pages = pages
            self.truncated = truncated
            self.pagesWithoutText = pagesWithoutText
        }
    }

    /// Map extraction failures to actionable words rather than bare codes.
    public enum ExtractionFailure: String, Sendable, Equatable, Error {
        case fileTooLarge = "file_too_large"
        case unreadableDocument = "unreadable_document"
        case unreadableTextEncoding = "unreadable_text_encoding"
        case fileNotFound = "file_not_found"
        case encryptedDocument = "encrypted_document"
        case noTextInDocument = "no_text_in_document"
        case unsupportedType = "unsupported_document_type"
        /// Document extraction obeys the sensitive-path fence because keychains and credential files remain sensitive when requested as documents.
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
            guard let decoded = decodeText(data) else { return .failure(.unreadableTextEncoding) }
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

    /// Document extraction is strict UTF-8, or UTF-16 with a byte-order mark. Reject invalid sequences and decoded NULs; never guess another encoding or
    /// manufacture replacement characters. Validate the entire byte slice.
    static func decodeText(_ data: Data) -> String? {
        let bom = Array(data.prefix(2))
        let decoded: String?
        if bom == [0xff, 0xfe] {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bom == [0xfe, 0xff] {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            decoded = String(data: data, encoding: .utf8)
        }
        guard let decoded, !decoded.contains("\0") else { return nil }
        return decoded
    }

    static func extractPDF(_ data: Data) -> Result<Extracted, ExtractionFailure> {
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
            // Scanned PDFs may have no text layer; report that format limit rather than claim an empty document or silently switch to OCR.
            return .failure(.noTextInDocument)
        }
        return .success(Extracted(text: joined, pages: total, truncated: truncated, pagesWithoutText: pagesWithoutText))
    }

    // MARK: - Words

    /// Keep refusal wording at one owner so all callers receive the same recovery direction.
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
        case .unreadableTextEncoding:
            return "The bytes read from \"\(name)\" are not valid UTF-8 or BOM-marked UTF-16 text without NUL characters. "
                + "No text was returned. The encoding may be unsupported, the bytes damaged, or the read limit may split a character."
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

    /// No text before deadline means unresponsive, which is distinct from a readable window with no text.
    public static func timedOutWords(app: String) -> String {
        "\(app) stopped answering while I was reading it — I waited "
            + "\(Int(deadlineSeconds)) seconds and got nothing back, so I stopped rather than "
            + "hanging on it. Nothing was read and nothing was changed. It may be busy or beach-"
            + "balling; try again once it is responding."
    }

    /// Retain text read before the deadline and report incompleteness rather than discard the partial answer.
    public static func deadlineWords(app: String) -> String {
        "\(app) was answering too slowly to finish the document inside "
            + "\(Int(deadlineSeconds)) seconds, so this is what I had read when I stopped — the "
            + "beginning of it, not the whole thing. Ask again for more."
    }

}

// Restore the observed scrollbar value, never the requested wheel distance; an end probe may move less or not at all.
// Restoration retains the original AXUIElement handles for the document and scrollbar.
final class MacDocumentScrollRestoration: @unchecked Sendable {
    private let owner: AXUIElement
    private let scrollbar: AXUIElement
    private let value: NSNumber
    private let barAttribute: String

    private init(owner: AXUIElement, scrollbar: AXUIElement, value: NSNumber, barAttribute: String) {
        self.owner = owner
        self.scrollbar = scrollbar
        self.value = value
        self.barAttribute = barAttribute
    }

    static func capture(source: any MacAXElementSource, container: MacAXElementRef, context: MacOperationContext) -> MacDocumentScrollRestoration? {
        guard let source = source as? SystemMacAXElementSource, let element = source.element(container) else { return nil }
        return capture(source: source, element: element, horizontal: false, needsRestore: true, context: context)
    }

    static func capture(source: SystemMacAXElementSource, element: AXUIElement, horizontal: Bool,
                        needsRestore: Bool, context: MacOperationContext) -> MacDocumentScrollRestoration? {
        let attribute = horizontal ? kAXHorizontalScrollBarAttribute : kAXVerticalScrollBarAttribute
        var candidate: AXUIElement? = element
        for _ in 0..<32 {
            guard let node = candidate else { return nil }
            _ = source.prepareForRead(node)
            if let bar = MacAXAttributeRead.copyElement(node, attribute, context: context) {
                let bar = source.prepareForRead(bar)
                if needsRestore {
                    var settable = DarwinBoolean(false)
                    guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
                          settable.boolValue else { return nil }
                }
                guard let value = MacAXAttributeRead.copyRaw(bar, kAXValueAttribute, context: context) as? NSNumber,
                      value.doubleValue.isFinite else { return nil }
                return MacDocumentScrollRestoration(owner: node, scrollbar: bar, value: value, barAttribute: attribute)
            }
            if MacAXAttributeRead.copyString(node, kAXRoleAttribute, context: context) == "AXWindow" { return nil }
            candidate = MacAXAttributeRead.copyElement(node, kAXParentAttribute, context: context)
        }
        return nil
    }

    func restore(context: MacOperationContext) -> Bool {
        guard let current = MacAXAttributeRead.copyElement(owner, barAttribute, context: context),
              CFEqual(current, scrollbar) else { return false }
        // Avoid even a no-op write when the downward end probe never moved.
        if isRestored(context: context) { return true }
        guard context.driver?.allowsAction(context: context) == true else { return false }
        guard (try? SystemMacAXElementSource.ensureRenderer(scrollbar, refresh: true, context: context)) != nil else { return false }
        guard context.driver?.allowsAction(context: context) == true else { return false }
        return AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, value) == .success
    }

    func isRestored(context: MacOperationContext) -> Bool {
        guard let current = MacAXAttributeRead.copyElement(owner, barAttribute, context: context),
              CFEqual(current, scrollbar),
              let observed = MacAXAttributeRead.copyRaw(scrollbar, kAXValueAttribute, context: context) as? NSNumber else { return false }
        return observed == value
    }

    /// Read the same scrollbar that owns restoration. Missing/invalid boundary evidence stays unknown; an unchanged position alone never proves the end.
    func observedPosition(context: MacOperationContext) -> (value: Double, atEnd: Bool?)? {
        guard let current = MacAXAttributeRead.copyElement(owner, barAttribute, context: context),
              CFEqual(current, scrollbar),
              let observed = MacAXAttributeRead.copyRaw(scrollbar, kAXValueAttribute, context: context) as? NSNumber,
              observed.doubleValue.isFinite else { return nil }
        let position = observed.doubleValue
        guard let minimum = MacAXAttributeRead.copyRaw(scrollbar, kAXMinValueAttribute, context: context) as? NSNumber,
              let maximum = MacAXAttributeRead.copyRaw(scrollbar, kAXMaxValueAttribute, context: context) as? NSNumber,
              minimum.doubleValue.isFinite, maximum.doubleValue.isFinite,
              minimum.doubleValue < maximum.doubleValue,
              position >= minimum.doubleValue, position <= maximum.doubleValue else {
            return (position, nil)
        }
        return (position, position == maximum.doubleValue)
    }

    func wheelReadback(delta: Int32, context: MacOperationContext) -> String? {
        guard let after = observedPosition(context: context)?.value,
              delta > 0 ? after < value.doubleValue : after > value.doubleValue else { return nil }
        return "The target scrollbar moved from \(value.doubleValue) to \(after) in the requested direction."
    }

    /// The read began below the document's first line; `nil` when the app gives no minimum.
    func startedBelowBeginning(context: MacOperationContext) -> Bool? {
        guard let minimum = MacAXAttributeRead.copyRaw(scrollbar, kAXMinValueAttribute, context: context) as? NSNumber else { return nil }
        return value.doubleValue > minimum.doubleValue
    }
}
