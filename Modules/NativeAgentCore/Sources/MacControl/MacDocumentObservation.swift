import Foundation
import NativeAgentShared
import Senses
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ApplicationServices)
import ApplicationServices
import UserNotifications
import Experiences
import CryptoKit
import os
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacDocumentObservation.swift` | Document reading and screen text extraction within the existing observation |
extension SwiftNativeMacControl {
    /// Milliseconds waited after a scroll before the next walk. A scroll is
    /// delivered to the app asynchronously and an app that lays out on the next
    /// runloop turn would otherwise be walked mid-scroll — which reads as "the
    /// content did not change" and ends the accumulation one screen early.
    static let documentReadSettleMilliseconds = 140
    /// READ. The whole document, in words, and never through `look`'s budgets.
    ///
    /// An explicit path reads that file. Otherwise read the selected window's
    /// live text, including unsaved edits that its on-disk document omits.
    func handleRead(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        func result(
            ok: Bool,
            _ output: [String: JSONValue],
            error: String? = nil
        ) -> MacControlResult {
            MacControlResult(
                ok: ok,
                action: "read",
                output: .object(output),
                error: error,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        func refuse(_ code: String, _ words: String, _ extra: [String: JSONValue] = [:]) -> MacControlResult {
            var output: [String: JSONValue] = [
                "read": .bool(false),
                "status": .string(code),
                "error": .string(code),
                "message": .string(words),
            ]
            for (key, value) in extra { output[key] = value }
            return result(ok: false, output, error: code)
        }
        // Read the frontmost window or the named running app's window without activating it.
        let requestedApp: String? = {
            guard let raw = body["app"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }()
        // Only a caller-named path asks for disk contents. AXDocument names
        // the saved file, which may be older than the live window.
        let rawPath = body["path"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPath = (rawPath?.isEmpty ?? true) ? nil : rawPath
        // ROUTE (a): EXTRACT.
        if let path = requestedPath.map(NativeAgentWorkspaceRoot.fileSpelling) {
            do {
            switch try extractDocument(at: path) {
            case .success(let extracted):
                let redaction = MacClipboardRead.redacted(extracted.text)
                var output: [String: JSONValue] = [
                    "read": .bool(true),
                    "source": .string("file"),
                    "path": .string(path),
                    "named_by": .string("caller"),
                    "chars": .int(Int64(redaction.text.count)),
                    "truncated": .bool(extracted.truncated),
                    "text": .string(redaction.text),
                ]
                if let pages = extracted.pages { output["document_pages"] = .int(Int64(pages)) }
                if !extracted.pagesWithoutText.isEmpty {
                    output["pages_without_text"] = .array(extracted.pagesWithoutText.map { .int(Int64($0)) })
                    output["message"] = .string("Incomplete PDF extraction: pages "
                        + extracted.pagesWithoutText.map(String.init).joined(separator: ", ")
                        + " have no extractable text and were skipped. Look at those pages to read their pixels.")
                }
                Self.attachRedaction(redaction, to: &output)
                return result(ok: true, output)
            case .failure(let failure):
                return refuse(
                    failure.rawValue,
                    MacDocumentRead.words(for: failure, path: path),
                    ["path": .string(path)]
                )
            }
            } catch {
                let cause = error as NSError
                return refuse("file_access_failed",
                    "I couldn't open \(path): \(cause.localizedDescription). Check the file's access permissions and that its volume is connected.",
                    ["path": .string(path), "cause_domain": .string(cause.domain), "cause_code": .int(Int64(cause.code))])
            }
        }
        // Resolve live state only for the screen route. An explicit file read
        // does not depend on any running app, AX grant or window.
        var target: MacAXAppInfo?
        if accessibilitySource.isTrusted() {
            if let requestedApp {
                let resolution = MacBackgroundSight.resolve(requestedApp, among: accessibilitySource.runningApps())
                guard case .matched(let app) = resolution else {
                    let code = resolution.failureCode ?? "app_not_running"
                    return refuse(code,
                        MacBackgroundSight.words(for: resolution, requested: requestedApp) ?? code,
                        ["requested_app": .string(requestedApp)])
                }
                target = app
            } else {
                target = accessibilitySource.frontmostApp()
            }
        }
        let selectedWindow = target.flatMap { accessibilitySource.windowRoot(pid: $0.processIdentifier) }
        // ROUTE (b): ACCUMULATE.
        return await readFromScreen(
            started: started,
            body: body,
            app: target,
            window: selectedWindow
        )
    }
    /// Open the explicitly requested file and turn it into characters.
    private func extractDocument(
        at path: String
    ) throws -> Result<MacDocumentRead.Extracted, MacDocumentRead.ExtractionFailure> {
        // THE SAME FENCE `file/read` runs, before and after resolving symlinks,
        // and it runs FIRST. "It is a document" is not an exemption: a
        // credentials file is a text file, and an organ that reads text files
        // would otherwise be the one door in the module that walks around this.
        if let reason = MacControlSensitivePathFence.reason(forPath: path) {
            _ = reason
            return .failure(.sensitivePath)
        }
        let kind = MacDocumentRead.kind(forPath: path)
        if case .unsupported = kind { return .failure(.unsupportedType) }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if let reason = MacControlSensitivePathFence.reason(forPath: url.path) {
            _ = reason
            return .failure(.sensitivePath)
        }
        let data: Data
        do {
            data = try fileManagerAdapter.readData(
                at: url,
                maxBytes: MacDocumentRead.maxFileBytes + 1
            )
        } catch let error as POSIXError where error.code == .ENOENT {
            return .failure(.fileNotFound)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .failure(.fileNotFound)
        }
        return MacDocumentRead.extract(data: data, kind: kind)
    }
    /// THE ACCUMULATE ROUTE. Read the selected container's text. An uncut frame
    /// entirely from AXTextArea values is already whole, even in a background
    /// window. Otherwise scroll one viewport (minus an overlap band), walk
    /// again, merge on the seam, and stop the moment a frame adds nothing.
    ///
    /// WHEN SCROLLING, WHAT IT EMITS: one `.move` to aim the wheel at the
    /// container's centre, and vertical `.scroll` events. No key, no button, no
    /// AX action, no attribute write. That emission set is the whole reason this
    /// verb is graded a read, and `MacDocumentReadTests` greps the sink to keep
    /// it true.
    ///
    /// AND IT PUTS THE SCROLL BACK. The user's document is left where it was
    /// found, using its captured scrollbar value and readback. Without a
    /// writable position, return the visible screenful without scrolling.
    private func readFromScreen(
        started: Date,
        body: [String: JSONValue],
        app requestedTarget: MacAXAppInfo?,
        window selectedWindow: MacAXElementRef?
    ) async -> MacControlResult {
        let passive = MacObservationMode.current == .passive
        if passive, MacScreenLock.isCovered() {
            let message = MacScreenLock.passiveReply
            return MacControlResult(ok: false, action: "read",
                output: .object(["message": .string(message)]),
                error: "passive_observation", durationMs: 0)
        }
        func result(ok: Bool, _ output: [String: JSONValue], error: String? = nil) -> MacControlResult {
            return MacControlResult(
                ok: ok,
                action: "read",
                output: .object(output),
                error: error,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        func refuse(_ code: String, _ words: String) -> MacControlResult {
            result(
                ok: false,
                [
                    "read": .bool(false),
                    "source": .string("screen"),
                    "status": .string(code),
                    "error": .string(code),
                    "message": .string(words),
                ],
                error: code
            )
        }
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "read") }
        guard let app = requestedTarget else {
            return refuse("no_window", MacDocumentRead.noWindowWords)
        }
        // `windowRoot(pid:)` and NOT `frontmostWindowRoot()`: with `app` named,
        // the window this reads must be that app's, whether or not it is the one
        // in front — and asking by pid is what makes the read work without
        // activating anything.
        guard let window = selectedWindow else {
            return refuse("no_window", MacDocumentRead.noWindowWords)
        }
        // Outside operation-store deadlines, bound AX calls per app and check wall time in each search/walk.
        // Restore the app-scoped per-call timeout on exit; see `MacDocumentRead`'s clock contract.
        let deadline = now().addingTimeInterval(MacDocumentRead.deadlineSeconds)
        func walkShouldStop() -> Bool { Task.isCancelled || now() >= deadline }
        #if canImport(ApplicationServices) && os(macOS)
        if let source = accessibilitySource as? SystemMacAXElementSource {
            source.setMessagingTimeout(
                pid: app.processIdentifier,
                seconds: MacDocumentRead.axMessagingTimeoutSeconds
            )
        }
        defer {
            if let source = accessibilitySource as? SystemMacAXElementSource {
                // 0 restores the system default — the bound belonged to this
                // read, not to the app.
                source.setMessagingTimeout(pid: app.processIdentifier, seconds: 0)
            }
        }
        #endif
        // Select from the captured window's topology, never its first sidebar.
        // A focus path or named section decides; otherwise require one document
        // root, or one scroll root when the app exposes no document role.
        let focus = accessibilitySource.focusedElementPath(relativeTo: window)
        let section = body["section"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The search finds containers; a document's own text is the reader's
        // (its own budget, below), so an unnamed search stops at a document
        // root instead of spending the window's node cap inside a long page.
        var atDocumentRoot = false
        let search = MacAXLimits.$readDeadline.withValue(deadline) {
            MacAccessibilityReader.walk(source: accessibilitySource, root: window, limits: .deepPage,
                read: { ref in
                    var attributes: MacAXAttributes?
                    #if canImport(ApplicationServices) && os(macOS)
                    if section == nil, let source = self.accessibilitySource as? SystemMacAXElementSource {
                        attributes = source.topologyAttributes(of: ref)
                    } else {
                        attributes = self.accessibilitySource.attributes(of: ref)
                    }
                    #else
                    attributes = self.accessibilitySource.attributes(of: ref)
                    #endif
                    atDocumentRoot = section == nil
                        && ["AXWebArea", "AXTextArea"].contains(attributes?.role ?? "")
                    return attributes
                }, deadline: deadline, stopAtCut: true, descendInto: { _ in !atDocumentRoot })
        }
        guard !search.truncated else {
            return refuse("document_target_unreadable", "The document-container search was incomplete (\(search.truncationReasons.joined(separator: ", "))). No scrolling was attempted.")
        }
        let candidates = search.nodes.filter { ["AXScrollArea", "AXWebArea", "AXTextArea"].contains($0.attributes.role) }
        let chosen: MacAXNode?
        if let section, !section.isEmpty {
            let matches = search.nodes.filter { $0.attributes.title?.caseInsensitiveCompare(section) == .orderedSame }
            guard matches.count == 1 else {
                return refuse("document_target_ambiguous", "The named document section is absent or ambiguous. Name one readable section.")
            }
            chosen = matches.first
        } else if let focus, let focused = candidates.filter({ focus.starts(with: $0.path) })
            .max(by: { $0.path.count < $1.path.count }) {
            chosen = focused
        } else {
            let documents = candidates.filter { ["AXWebArea", "AXTextArea"].contains($0.attributes.role) }
            let pool = documents.isEmpty ? candidates : documents
            let roots = pool.filter { node in
                !pool.contains { $0.path.count < node.path.count && node.path.starts(with: $0.path) }
            }
            guard roots.count <= 1 else {
                return refuse("document_target_ambiguous", "This window exposes several readable regions. Focus the document or name its section before reading.")
            }
            chosen = roots.first ?? search.nodes.first
        }
        guard let chosen, let container = chosen.element else { return refuse("no_window", MacDocumentRead.noWindowWords) }
        let containerRole = chosen.attributes.role
        let containerFrame = walkShouldStop() ? nil : accessibilitySource.attributes(of: container)?.frame
        let scrollContainer = container
        let takeover = MacDocumentReadTakeover()
        let observation = attentionEventSource.start { _ in takeover.mark() }
        defer { observation.stop() }
        @Sendable func stopReason() async -> String? {
            if Task.isCancelled { return "cancelled" }
            if takeover.occurred { return "yielded_to_user" }
            if let refusal = await attentionActionRefusal(action: "read", body: body) {
                return refusal.error ?? "yielded_to_user"
            }
            // Recheck after the actor hop, immediately before the emission.
            if Task.isCancelled { return "cancelled" }
            if takeover.occurred { return "yielded_to_user" }
            guard let frame = containerFrame,
                  accessibilitySource.documentScrollTargetIsCurrent(
                    window: window, container: scrollContainer, frame: frame, pid: app.processIdentifier
                  ) else { return "scroll_target_changed" }
            return nil
        }
        var accumulator = MacDocumentRead.Accumulator()
        let firstFrame = MacDocumentRead.frameLines(source: accessibilitySource, root: container, shouldStop: walkShouldStop)
        if firstFrame.lines.isEmpty {
            if Task.isCancelled {
                return refuse("cancelled", "The document read was cancelled before any text was read.")
            }
            if firstFrame.secureNodes > 0 {
                return refuse("secure_content", MacDocumentRead.secureContentWords)
            }
            // The clock, not the window: an app that ate the deadline before
            // answering with a single line is UNRESPONSIVE, which is a
            // different fact from a window that publishes no text — and
            // reporting the second when the first is true sends the caller off
            // to `screen` for a window that will not answer that either.
            if now() >= deadline {
                return refuse(
                    MacDocumentRead.timedOutReason,
                    MacDocumentRead.timedOutWords(app: app.name)
                )
            }
            return refuse("no_readable_text", MacDocumentRead.emptyScreenWords)
        }
        _ = accumulator.absorb(firstFrame.lines)
        var framesTruncated = firstFrame.truncated
        var framesRedacted = firstFrame.didRedact
        // AXTextArea values already contain the beginning and end. Only a
        // viewport read needs scroll capture, input or a current scroll target.
        let scrollRestoration = passive || firstFrame.wholeText || walkShouldStop() ? nil : MacDocumentScrollRestoration.capture(source: accessibilitySource, container: container)
        let canScroll = eventSink.isAvailable && (containerFrame?.h ?? 0) > 0 && scrollRestoration != nil
        var framesRead = 1
        var steps = 0
        var truncationReason: String? = Task.isCancelled ? "cancelled"
            : (now() >= deadline ? MacDocumentRead.deadlineTruncationReason
               : ((accumulator.remainingCharacters == 0 && !firstFrame.wholeText) || accumulator.truncated ? "char_cap" : nil))
        var reachedEnd = firstFrame.wholeText && truncationReason == nil
        if passive, !firstFrame.wholeText { truncationReason = "passive_viewport_only" }
        if canScroll, let frame = containerFrame {
            let delta = MacDocumentRead.scrollStepPoints(viewportHeight: frame.h)
            let centreX = frame.x + frame.w / 2
            let centreY = frame.y + frame.h / 2
            if truncationReason == nil { truncationReason = await stopReason() }
            if truncationReason == nil {
                eventSink.post(mouse: MacMouseEvent(phase: .move, button: .left, x: centreX, y: centreY))
            }
            while framesRead < MacDocumentRead.maxFrames {
                if truncationReason != nil { break }
                if let reason = await stopReason() { truncationReason = reason; break }
                // THE WALL CLOCK, checked BEFORE the next scroll rather than
                // after it: a step already taken has to be put back, and there
                // is no point buying one more frame from an app that has
                // already spent the budget. Breaking here (rather than
                // returning) is deliberate — the scroll restoration below is
                // owed to User's document whether the read finished or not.
                if now() >= deadline {
                    truncationReason = MacDocumentRead.deadlineTruncationReason
                    break
                }
                // `down` moves the content up, which is what a person means by
                // scrolling down — the same sign convention `act` uses.
                eventSink.post(scroll: MacScrollEvent(deltaX: 0, deltaY: -delta, unit: .pixel))
                steps += 1
                await Self.settleForDocumentRead()
                if let reason = await stopReason() { truncationReason = reason; break }
                let next = MacDocumentRead.frameLines(
                    source: accessibilitySource, root: container,
                    characterLimit: accumulator.remainingCharacters, shouldStop: walkShouldStop
                )
                framesRead += 1
                framesTruncated = framesTruncated || next.truncated
                framesRedacted = framesRedacted || next.didRedact
                let nothingNew = accumulator.absorb(next.lines)
                if Task.isCancelled { truncationReason = "cancelled"; break }
                if now() >= deadline { truncationReason = MacDocumentRead.deadlineTruncationReason; break }
                if nothingNew {
                    // The container can be replaced during the walk: invalid
                    // AX attributes also yield an empty, non-truncated frame.
                    // Accept its end only while the original target is current.
                    truncationReason = await stopReason()
                    reachedEnd = !next.truncated && truncationReason == nil
                    break
                }
                if accumulator.characters >= MacDocumentRead.maxAccumulatedChars {
                    truncationReason = "char_cap"
                    break
                }
            }
            if !reachedEnd && truncationReason == nil && framesRead >= MacDocumentRead.maxFrames {
                truncationReason = "frame_cap"
            }
        }
        // Clipped/zero-motion end probes must not overshoot the
        // original position. Restore its captured value, then read it back.
        // Accumulation has already decided which text was read. A target
        // change here prevents restoration, not completion of that read.
        var restored: Bool?
        if steps > 0, let scrollRestoration {
            let binding = MacDriverContext.binding?.settlementBinding()
            restored = await settle {
                await MacDriverContext.$binding.withValue(binding) {
                    guard await stopReason() == nil else { return false }
                    let accepted = scrollRestoration.restore()
                    if accepted { await Self.settleForDocumentRead() }
                    let finalStop = await stopReason()
                    return accepted && finalStop == nil && scrollRestoration.isRestored
                }
            }
        }
        let redaction = MacClipboardRead.redacted(accumulator.text)
        var output: [String: JSONValue] = [
            "read": .bool(true),
            "source": .string("screen"),
            "app": app.toJSON(),
            "container_role": .string(containerRole),
            "frames": .int(Int64(framesRead)),
            "scroll_steps": .int(Int64(steps)),
            "reached_end": .bool(reachedEnd),
            "truncated": .bool(truncationReason != nil || framesTruncated),
            "gaps": .bool(accumulator.sawGap),
            "chars": .int(Int64(redaction.text.count)),
            "text": .string(redaction.text),
        ]
        if let truncationReason { output["truncation_reason"] = .string(truncationReason) }
        if let restored { output["scroll_restored"] = .bool(restored) }
        // A scrolling read walks down from where the window is: when that is
        // below the first line, say so rather than call the rest the document.
        if scrollRestoration?.startedBelowBeginning == true {
            output["truncated"] = .bool(true)
            output["started_below_beginning"] = .bool(true)
            output["message"] = .string("This read started where the window was scrolled, below the document's beginning. Scroll it to the top and read again for the opening.")
        }
        if !firstFrame.wholeText && !canScroll {
            output["truncated"] = .bool(true)
            if output["truncation_reason"] == nil {
                output["truncation_reason"] = .string("viewport_only_no_restorable_scroll")
            }
            output["reached_end"] = .bool(false)
            output["scrollable"] = .bool(false)
            output["message"] = .string(MacDocumentRead.scrollUnavailableWords)
        }
        // The clock wins the message when it bit: "this is the beginning, not
        // the document" is the thing the caller most needs to hear, and it is
        // the only truncation reason that is about the APP rather than about a
        // cap this organ chose.
        if truncationReason == MacDocumentRead.deadlineTruncationReason {
            output["timed_out"] = .bool(true)
            output["message"] = .string(MacDocumentRead.deadlineWords(app: app.name))
        }
        if accumulator.sawGap {
            output["gap_note"] = .string(
                "Two screenfuls shared no line, so I cannot promise nothing fell between them."
            )
        }
        Self.attachRedaction(redaction, to: &output)
        if framesRedacted { output["redacted"] = .bool(true) }
        return result(ok: true, output)
    }
    private static func settleForDocumentRead() async {
        try? await Task.sleep(nanoseconds: UInt64(documentReadSettleMilliseconds) * 1_000_000)
    }
    /// The redaction channel, identical on both routes: a blanked line is
    /// REDACTION and says so, never a short document.
    private static func attachRedaction(
        _ redaction: MacClipboardRead.Redaction,
        to output: inout [String: JSONValue]
    ) {
        output["redacted"] = .bool(redaction.didRedact)
        guard redaction.didRedact else { return }
        output["redactions"] = .array(redaction.redactedLines.map { line in
            .object(["line": .int(Int64(line.line)), "reason": .string(line.reason)])
        })
    }
}
