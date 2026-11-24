import Foundation
import NativeAgentShared
import SenseCore
import NativeAgentCore
import PersistenceCore
import DeskCore
import AppKit
import CoreGraphics
import ApplicationServices
import UserNotifications
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacDocumentObservation.swift` | Document reading and screen text extraction within the existing observation; `MacScreenDocumentRead` carries one screen read from its first frame through the scroll to the report |
extension SwiftNativeMacControl {
    /// Milliseconds waited after a scroll before the next walk. A scroll is delivered to the app asynchronously and an app that lays out on the next runloop
    /// turn would otherwise be walked mid-scroll. A position that has not advanced after this wait is reported as unconfirmed progress.
    static let documentReadSettleMilliseconds = 140
    /// READ. The whole document, in words, and never through `look`'s budgets. An explicit path reads that file. Otherwise read the selected window's live
    /// text, including unsaved edits that its on-disk document omits.
    func handleRead(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
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
        // Only a caller-named path asks for disk contents. AXDocument names the saved file, which may be older than the live window.
        let rawPath = body["path"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPath = (rawPath?.isEmpty ?? true) ? nil : rawPath
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
                var evidence: [String: JSONValue] = ["path": .string(path)]
                if failure == .fileNotFound {
                    evidence.merge(VerifiedPath.missingReadEvidence(URL(fileURLWithPath: path))) { _, owned in owned }
                }
                return refuse(
                    failure.rawValue,
                    MacDocumentRead.words(for: failure, path: path),
                    evidence
                )
            }
            } catch {
                let cause = error as NSError
                return refuse("file_access_failed",
                    "I couldn't open \(path): \(cause.localizedDescription). Check the file's access permissions and that its volume is connected.",
                    ["path": .string(path), "cause_domain": .string(cause.domain), "cause_code": .int(Int64(cause.code))])
            }
        }
        // Resolve live state only for the screen route. An explicit file read does not depend on any running app, AX grant or window.
        var target: MacAXAppInfo?
        if accessibilitySource(context: context).isTrusted() {
            if let requestedApp {
                let resolution = MacBackgroundSight.resolve(requestedApp, among: accessibilitySource(context: context).runningApps())
                guard case .matched(let app) = resolution else {
                    let code = resolution.failureCode ?? "app_not_running"
                    return refuse(code,
                        MacBackgroundSight.words(for: resolution, requested: requestedApp) ?? code,
                        ["requested_app": .string(requestedApp)])
                }
                target = app
            } else {
                target = accessibilitySource(context: context).frontmostApp()
            }
        }
        let selectedWindow = target.flatMap { accessibilitySource(context: context).windowRoot(pid: $0.processIdentifier, context: context) }
        return await readFromScreen(
            started: started,
            body: body,
            app: target,
            window: selectedWindow
        , turn: turn, context: context)
    }
    private func extractDocument(
        at path: String
    ) throws -> Result<MacDocumentRead.Extracted, MacDocumentRead.ExtractionFailure> {
        // Apply the file fence before and after symlink resolution; document extraction must not bypass credential-path protection.
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
    /// Uncut AXTextArea values are whole even in background windows. Viewport accumulation scrolls with overlap, but only scrollbar evidence proves the end.
    /// Emit only pointer positioning and vertical wheel events, then restore the captured scrollbar value with readback. Without a writable position, return
    /// visible text without scrolling.
    private func readFromScreen(
        started: Date,
        body: [String: JSONValue],
        app requestedTarget: MacAXAppInfo?,
        window selectedWindow: MacAXElementRef?,
        turn: Turn, context: MacOperationContext
    ) async -> MacControlResult {
        let passive = context.observationMode == .passive
        if let refusal = documentReadCoverRefusal(passive: passive) { return refusal }
        let reply = MacScreenReadReply(started: started, now: now)
        guard accessibilitySource(context: context).isTrusted() else { return axUntrustedResult(action: "read") }
        guard let app = requestedTarget else {
            return reply.refuse("no_window", MacDocumentRead.noWindowWords)
        }
        // Resolve the named process's window root so a background document read cannot silently target or activate the frontmost app.
        guard let window = selectedWindow else {
            return reply.refuse("no_window", MacDocumentRead.noWindowWords)
        }
        // Outside operation-store deadlines, bound AX calls per app and check wall time in each search/walk. Restore the app-scoped per-call timeout on exit;
        // see `MacDocumentRead`'s clock contract.
        let deadline = now().addingTimeInterval(MacDocumentRead.deadlineSeconds)
        func walkShouldStop() -> Bool { Task.isCancelled || now() >= deadline }
        if let source = accessibilitySource(context: context) as? SystemMacAXElementSource {
            source.setMessagingTimeout(
                pid: app.processIdentifier,
                seconds: MacDocumentRead.axMessagingTimeoutSeconds
            )
        }
        defer {
            if let source = accessibilitySource(context: context) as? SystemMacAXElementSource {
                // Reset the app-scoped timeout to the system default because this bound belongs only to the read.
                source.setMessagingTimeout(pid: app.processIdentifier, seconds: 0)
            }
        }
        let chosen: MacAXNode?
        switch chooseDocumentContainer(window: window, body: body, deadline: deadline, reply: reply, context: context) {
        case .next(let found): chosen = found
        case .reply(let refusal): return refusal
        }
        guard let chosen, let container = chosen.element else { return reply.refuse("no_window", MacDocumentRead.noWindowWords) }
        let containerRole = chosen.attributes.role
        let containerFrame = walkShouldStop() ? nil : accessibilitySource(context: context).attributes(of: container, context: context)?.frame
        let scrollContainer = container
        let scrollSource = accessibilitySource(context: context)
        let takeover = MacDocumentReadTakeover()
        let observation = attentionEventSource.start { _ in takeover.mark() }
        defer { observation.stop() }
        @Sendable func stopReason(_ context: MacOperationContext) async -> String? {
            if Task.isCancelled { return "cancelled" }
            if takeover.occurred { return "yielded_to_user" }
            if let refusal = await attentionActionRefusal(action: "read", body: body, turn: turn, context: context) {
                return refusal.error ?? "yielded_to_user"
            }
            // Recheck after the actor hop, immediately before the emission.
            if Task.isCancelled { return "cancelled" }
            if takeover.occurred { return "yielded_to_user" }
            guard let frame = containerFrame,
                  scrollSource.documentScrollTargetIsCurrent(
                    window: window, container: scrollContainer, frame: frame, pid: app.processIdentifier
                  , context: context) else { return "scroll_target_changed" }
            return nil
        }
        let reading: MacScreenDocumentRead
        switch readFirstDocumentFrame(app: app, container: container, containerRole: containerRole, containerFrame: containerFrame,
            passive: passive, deadline: deadline, walkShouldStop: walkShouldStop, reply: reply, context: context) {
        case .next(let read): reading = read
        case .reply(let refusal): return refusal
        }
        guard reading.canScroll else {
            return reply.result(ok: true, documentReadOutput(reading, restored: nil, context: context))
        }
        let held = await MacBodyNerve.holding(pid: app.processIdentifier, turn: turn, context: context, expect: .hidInput) {
            if let refusal = await scrollDocumentRead(reading, walkShouldStop: walkShouldStop, stopReason: stopReason, reply: reply,
                turn: turn, context: context) { return refusal }
            let restored = await restoreDocumentScroll(reading, stopReason: stopReason, context: context)
            return reply.result(ok: true, documentReadOutput(reading, restored: restored, context: context))
        }
        return held.value.recording(held.receipt)
    }
    /// A passive read stops at a covered screen, or when its readiness cannot be read.
    private func documentReadCoverRefusal(passive: Bool) -> MacControlResult? {
        if passive {
            do {
                if try MacScreenLock.isCovered() {
                    return MacControlResult(ok: false, action: "read",
                        output: .object(["message": .string(MacScreenLock.passiveReply)]),
                        error: "passive_observation", durationMs: 0)
                }
            } catch {
                return MacControlResult(ok: false, action: "read",
                    output: .object(["message": .string(error.localizedDescription)]),
                    error: "screen_readiness_unavailable", durationMs: 0)
            }
        }
        return nil
    }
    /// The window's one readable container: a named section, the focused region, or its single document (or scroll) root.
    private func chooseDocumentContainer(
        window: MacAXElementRef, body: [String: JSONValue], deadline: Date, reply: MacScreenReadReply, context: MacOperationContext
    ) -> MacScreenReadStep<MacAXNode?> {
        // Select from the captured window's topology, never its first sidebar. A focus path or named section decides; otherwise require one document root, or
        // one scroll root when the app exposes no document role.
        let focus = accessibilitySource(context: context).focusedElementPath(relativeTo: window, context: context)
        let section = body["section"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The search finds containers; a document's own text is the reader's (its own budget, below), so an unnamed search stops at a document root instead of
        // spending the window's node cap inside a long page.
        var atDocumentRoot = false
        let search = context.holding(\.readDeadline, deadline) {
            context in MacAccessibilityReader.walk(source: accessibilitySource(context: context), root: window, limits: .deepPage,
                read: { ref, context in
                    var attributes: MacAXAttributes?
                    if section == nil, let source = self.accessibilitySource(context: context) as? SystemMacAXElementSource {
                        attributes = source.topologyAttributes(of: ref, context: context)
                    } else {
                        attributes = self.accessibilitySource(context: context).attributes(of: ref, context: context)
                    }
                    atDocumentRoot = section == nil
                        && ["AXWebArea", "AXTextArea"].contains(attributes?.role ?? "")
                    return attributes
                }, deadline: deadline, stopAtCut: true, descendInto: { _ in !atDocumentRoot }, context: context)
        }
        guard !search.truncated else {
            return .reply(reply.refuse("document_target_unreadable", """
                The document-container search was incomplete (\(search.truncationReasons.joined(separator: ", "))). No scrolling was attempted.
                """))
        }
        let candidates = search.nodes.filter { ["AXScrollArea", "AXWebArea", "AXTextArea"].contains($0.attributes.role) }
        let chosen: MacAXNode?
        if let section, !section.isEmpty {
            let matches = search.nodes.filter { $0.attributes.title?.caseInsensitiveCompare(section) == .orderedSame }
            guard matches.count == 1 else {
                return .reply(reply.refuse("document_target_ambiguous", "The named document section is absent or ambiguous. Name one readable section."))
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
                return .reply(reply.refuse("document_target_ambiguous",
                    "This window exposes several readable regions. Focus the document or name its section before reading."))
            }
            chosen = roots.first ?? search.nodes.first
        }
        return .next(chosen)
    }
    /// The first screenful: refuse an unreadable one, otherwise open the read's progress with it and decide whether scrolling may follow.
    private func readFirstDocumentFrame(
        app: MacAXAppInfo, container: MacAXElementRef, containerRole: String, containerFrame: MacAXFrame?, passive: Bool, deadline: Date,
        walkShouldStop: () -> Bool, reply: MacScreenReadReply, context: MacOperationContext
    ) -> MacScreenReadStep<MacScreenDocumentRead> {
        var accumulator = MacDocumentRead.Accumulator()
        let source = accessibilitySource(context: context)
        let firstFrame = MacDocumentRead.frameLines(source: source, root: container, context: context,
            shouldStop: walkShouldStop)
        if firstFrame.lines.isEmpty {
            if Task.isCancelled {
                return .reply(reply.refuse("cancelled", "The document read was cancelled before any text was read."))
            }
            if firstFrame.secureNodes > 0 {
                return .reply(reply.refuse("secure_content", MacDocumentRead.secureContentWords))
            }
            // Deadline exhaustion means unresponsive, not textless; preserve that cause so callers cannot chase another read against the same stalled app.
            if now() >= deadline {
                return .reply(reply.refuse(
                    MacDocumentRead.timedOutReason,
                    MacDocumentRead.timedOutWords(app: app.name)
                ))
            }
            return .reply(reply.refuse("no_readable_text", MacDocumentRead.emptyScreenWords))
        }
        accumulator.absorb(firstFrame, source: source)
        var framesTruncated = firstFrame.truncated
        var framesRedacted = firstFrame.didRedact
        // AXTextArea values already contain the beginning and end. Only a viewport read needs scroll capture, input or a current scroll target.
        let scrollRestoration = passive || firstFrame.wholeText || walkShouldStop() ? nil : MacDocumentScrollRestoration.capture(source: source,
            container: container, context: context)
        let canScroll = eventSink.isAvailable && (containerFrame?.h ?? 0) > 0 && scrollRestoration != nil
        var framesRead = 1
        var steps = 0
        var truncationReason: String? = Task.isCancelled ? "cancelled"
            : (now() >= deadline ? MacDocumentRead.deadlineTruncationReason
               : ((accumulator.remainingCharacters == 0 && !firstFrame.wholeText) || accumulator.truncated ? "char_cap" : nil))
        var reachedEnd = firstFrame.wholeText && truncationReason == nil
        if passive, !firstFrame.wholeText { truncationReason = "passive_viewport_only" }
        return .next(MacScreenDocumentRead(app: app, container: container, containerRole: containerRole, containerFrame: containerFrame,
            deadline: deadline, firstFrame: firstFrame, accumulator: accumulator, framesTruncated: framesTruncated,
            framesRedacted: framesRedacted, scrollRestoration: scrollRestoration, canScroll: canScroll, framesRead: framesRead,
            steps: steps, truncationReason: truncationReason, reachedEnd: reachedEnd))
    }
    /// Scroll down a screenful at a time, absorbing each frame, until the end, a cap, the clock or the person stops it. A motor that cannot place the pointer
    /// ends the read; every other stop still owes the restoration.
    private func scrollDocumentRead(
        _ reading: MacScreenDocumentRead, walkShouldStop: () -> Bool, stopReason: @Sendable (MacOperationContext) async -> String?, reply: MacScreenReadReply,
        turn: Turn, context: MacOperationContext
    ) async -> MacControlResult? {
        let canScroll = reading.canScroll
        let containerFrame = reading.containerFrame
        let firstFrame = reading.firstFrame
        let scrollRestoration = reading.scrollRestoration
        let deadline = reading.deadline
        let container = reading.container
        if canScroll, let frame = containerFrame {
            let source = accessibilitySource(context: context)
            let delta = MacDocumentRead.scrollStepPoints(viewportHeight: frame.h)
            let centreX = frame.x + frame.w / 2
            let centreY = frame.y + frame.h / 2
            if reading.truncationReason == nil { reading.truncationReason = await stopReason(context) }
            var position = scrollRestoration?.observedPosition(context: context)
            if reading.truncationReason == nil {
                if let position {
                    reading.reachedEnd = position.atEnd == true && !firstFrame.truncated
                } else {
                    reading.truncationReason = "scroll_position_unavailable"
                }
            }
            if reading.truncationReason == nil && !reading.reachedEnd {
                do { try await eventSink.send(mouse: MacMouseEvent(phase: .move, button: .left, x: centreX, y: centreY), turn: turn, context: context) }
                catch { return reply.refuse("window_motor_unconfirmed", error.localizedDescription) }
            }
            while reading.framesRead < MacDocumentRead.maxFrames {
                if reading.truncationReason != nil || reading.reachedEnd { break }
                if let reason = await stopReason(context) { reading.truncationReason = reason; break }
                // Check the clock before another scroll; break rather than return so restoration remains owed even after deadline exhaustion.
                if now() >= deadline {
                    reading.truncationReason = MacDocumentRead.deadlineTruncationReason
                    break
                }
                // Scrolling down moves content up; retain the same direction convention as act.
                do { try await eventSink.send(scroll: MacScrollEvent(deltaX: 0, deltaY: -delta, unit: .pixel), turn: turn, context: context) }
                catch { reading.truncationReason = "window_motor_unconfirmed: " + error.localizedDescription; break }
                reading.steps += 1
                await Self.settleForDocumentRead()
                if let reason = await stopReason(context) { reading.truncationReason = reason; break }
                guard let observed = scrollRestoration?.observedPosition(context: context), let previous = position else {
                    reading.truncationReason = "scroll_position_unavailable"
                    break
                }
                if observed.value <= previous.value {
                    reading.truncationReason = "scroll_progress_unconfirmed"
                    break
                }
                position = observed
                let next = MacDocumentRead.frameLines(
                    source: source, root: container, context: context, shouldStop: walkShouldStop)
                reading.framesRead += 1
                reading.framesTruncated = reading.framesTruncated || next.truncated
                reading.framesRedacted = reading.framesRedacted || next.didRedact
                reading.accumulator.absorb(next, source: source)
                if Task.isCancelled { reading.truncationReason = "cancelled"; break }
                if now() >= deadline { reading.truncationReason = MacDocumentRead.deadlineTruncationReason; break }
                // The target can change during the walk. End evidence belongs to the original target.
                if let reason = await stopReason(context) { reading.truncationReason = reason; break }
                if observed.atEnd == true && !next.truncated && !next.lines.isEmpty && !reading.accumulator.truncated {
                    reading.reachedEnd = true
                    break
                }
                if reading.accumulator.truncated || reading.accumulator.remainingCharacters == 0 {
                    reading.truncationReason = "char_cap"
                    break
                }
            }
            if !reading.reachedEnd && reading.truncationReason == nil && reading.framesRead >= MacDocumentRead.maxFrames {
                reading.truncationReason = "frame_cap"
            }
        }
        return nil
    }
    /// Put the window back where the read found it, as settlement owed however the read ended.
    private func restoreDocumentScroll(
        _ reading: MacScreenDocumentRead, stopReason: @escaping @Sendable (MacOperationContext) async -> String?, context: MacOperationContext
    ) async -> Bool? {
        let steps = reading.steps
        let scrollRestoration = reading.scrollRestoration
        // Clipped/zero-motion end probes must not overshoot the original position. Restore its captured value, then read it back. Accumulation has already
        // decided which text was read. A target change here prevents restoration, not completion of that read.
        var restored: Bool?
        if steps > 0, let scrollRestoration {
            let binding = context.driver?.settlementBinding()
            restored = await settle {
                let context = context.settling()
                return await context.holding(\.driver, binding) { context in
                    guard await stopReason(context) == nil else { return false }
                    let accepted = scrollRestoration.restore(context: context)
                    if accepted { await Self.settleForDocumentRead() }
                    let finalStop = await stopReason(context)
                    return accepted && finalStop == nil && scrollRestoration.isRestored(context: context)
                }
            }
        }
        return restored
    }
    /// What the read found, with every reason it may be short of the whole document.
    private func documentReadOutput(_ reading: MacScreenDocumentRead, restored: Bool?, context: MacOperationContext) -> [String: JSONValue] {
        let accumulator = reading.accumulator
        let app = reading.app
        let containerRole = reading.containerRole
        let framesRead = reading.framesRead
        let steps = reading.steps
        let reachedEnd = reading.reachedEnd
        let truncationReason = reading.truncationReason
        let framesTruncated = reading.framesTruncated
        let scrollRestoration = reading.scrollRestoration
        let firstFrame = reading.firstFrame
        let canScroll = reading.canScroll
        let framesRedacted = reading.framesRedacted
        let redaction = MacClipboardRead.redacted(accumulator.text) { $0.trimmedNonEmpty }
        var output: [String: JSONValue] = [
            "read": .bool(true),
            "source": .string("screen"),
            "app": app.toJSON(),
            "container_role": .string(containerRole),
            "frames": .int(Int64(framesRead)),
            "scroll_steps": .int(Int64(steps)),
            "reached_end": .bool(reachedEnd),
            "truncated": .bool(truncationReason != nil || framesTruncated || accumulator.truncated || accumulator.sawGap),
            "gaps": .bool(accumulator.sawGap),
            "chars": .int(Int64(redaction.text.count)),
            "text": .string(redaction.text),
        ]
        if let truncationReason { output["truncation_reason"] = .string(truncationReason) }
        if let restored { output["scroll_restored"] = .bool(restored) }
        // A scrolling read walks down from where the window is: when that is below the first line, say so rather than call the rest the document.
        if scrollRestoration?.startedBelowBeginning(context: context) == true {
            output["truncated"] = .bool(true)
            output["started_below_beginning"] = .bool(true)
            output["message"] = .string("""
                This read started where the window was scrolled, below the document's beginning. Scroll it to the top and read again for the opening.
                """)
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
        // Clock truncation names app responsiveness rather than a chosen cap, so it takes precedence in the partial-read explanation.
        if truncationReason == MacDocumentRead.deadlineTruncationReason {
            output["timed_out"] = .bool(true)
            output["message"] = .string(MacDocumentRead.deadlineWords(app: app.name))
        }
        if accumulator.sawGap {
            output["gap_note"] = .string(
                "The read could not verify overlap between screenfuls. Some rows may be missing or repeated."
            )
        }
        Self.attachRedaction(redaction, to: &output)
        if framesRedacted { output["redacted"] = .bool(true) }
        return output
    }
    private static func settleForDocumentRead() async {
        try? await Task.sleep(nanoseconds: UInt64(documentReadSettleMilliseconds) * 1_000_000)
    }
    /// The redaction channel, identical on both routes: a blanked line is REDACTION and says so, never a short document.
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

/// A screen read's stage either goes on with what it found or ends the read with its reply.
private enum MacScreenReadStep<Value> {
    case next(Value)
    case reply(MacControlResult)
}

/// The read's replies, timed from when the read began.
private struct MacScreenReadReply {
    let started: Date
    let now: @Sendable () -> Date
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
}

/// One screen document read's progress, from its first frame through the scroll to the report. It lives for one call and never crosses isolation.
private final class MacScreenDocumentRead {
    let app: MacAXAppInfo
    let container: MacAXElementRef
    let containerRole: String
    let containerFrame: MacAXFrame?
    let deadline: Date
    let firstFrame: MacDocumentRead.Frame
    let scrollRestoration: MacDocumentScrollRestoration?
    let canScroll: Bool
    var accumulator: MacDocumentRead.Accumulator
    var framesTruncated: Bool
    var framesRedacted: Bool
    var framesRead: Int
    var steps: Int
    var truncationReason: String?
    var reachedEnd: Bool

    init(app: MacAXAppInfo, container: MacAXElementRef, containerRole: String, containerFrame: MacAXFrame?, deadline: Date,
         firstFrame: MacDocumentRead.Frame, accumulator: MacDocumentRead.Accumulator, framesTruncated: Bool, framesRedacted: Bool,
         scrollRestoration: MacDocumentScrollRestoration?, canScroll: Bool, framesRead: Int, steps: Int, truncationReason: String?,
         reachedEnd: Bool) {
        self.app = app
        self.container = container
        self.containerRole = containerRole
        self.containerFrame = containerFrame
        self.deadline = deadline
        self.firstFrame = firstFrame
        self.accumulator = accumulator
        self.framesTruncated = framesTruncated
        self.framesRedacted = framesRedacted
        self.scrollRestoration = scrollRestoration
        self.canScroll = canScroll
        self.framesRead = framesRead
        self.steps = steps
        self.truncationReason = truncationReason
        self.reachedEnd = reachedEnd
    }
}
