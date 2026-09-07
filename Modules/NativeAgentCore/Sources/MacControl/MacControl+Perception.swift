import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension SwiftNativeMacControl {
    // MARK: - fable51 item 33: the read organ

    /// Milliseconds waited after a scroll before the next walk. A scroll is
    /// delivered to the app asynchronously and an app that lays out on the next
    /// runloop turn would otherwise be walked mid-scroll — which reads as "the
    /// content did not change" and ends the accumulation one screen early.
    static let documentReadSettleMilliseconds = 140

    /// READ. The whole document, in words, and never through `look`'s budgets.
    ///
    /// Two routes and it picks by asking what the thing IS (see
    /// `MacDocumentRead`'s header). The file route wins when there is a file,
    /// because a PDF's own characters beat anything scraped off a rendering of
    /// them — but a file this organ cannot parse falls THROUGH to the screen
    /// route rather than refusing, because the window is still right there and
    /// "I can see it but I refuse to read it" is not an answer a body gives.
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
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
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

        // fable51 item 32a/33 (gpt-5.5 review) — WHOSE WINDOW. Absent means the
        // one in front, which is all `read` has ever meant. Named means that
        // running app's front window, resolved through the SAME organ
        // `screen(app:)` resolves through and read through `windowRoot(pid:)` —
        // nothing here activates, launches or raises anything, so reading a
        // document in a background window costs User no focus.
        let requestedApp: String? = {
            guard let raw = body.stringValue("app")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }()

        // Resolved ONCE and used by both routes: the file the window names and
        // the window's own text have to come from the SAME window, or the
        // answer is a splice of two of them.
        var target: MacAXAppInfo?
        if accessibilitySource.isTrusted() {
            if let requestedApp {
                let resolution = MacBackgroundSight.resolve(
                    requestedApp,
                    among: accessibilitySource.runningApps()
                )
                guard case .matched(let app) = resolution else {
                    let code = resolution.failureCode ?? "app_not_running"
                    return refuse(
                        code,
                        MacBackgroundSight.words(for: resolution, requested: requestedApp)
                            ?? "I couldn't find a running app called \"\(requestedApp)\".",
                        ["requested_app": .string(requestedApp)]
                    )
                }
                target = app
            } else {
                target = accessibilitySource.frontmostApp()
            }
        }

        // Which file, if any. An explicit `path` is the caller naming one; with
        // none, the window is ASKED whether it is showing a document.
        let rawPath = body.stringValue("path")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPath = (rawPath?.isEmpty ?? true) ? nil : rawPath
        let namedByCaller = requestedPath != nil
        var documentPath = requestedPath.map { NSString(string: $0).expandingTildeInPath }
        // gpt-5.5 review — AN AX-INFERRED PATH IS STILL A FILE READ.
        //
        // A `read` with no `path` clears only the accessibility category at the
        // tool layer, by design: "read the thing in front of me" is the same
        // authority as `look`. But the window's `AXDocument` then handed a
        // FILESYSTEM PATH to `extractDocument(at:)`, which opened the whole file
        // off disk — so a call that never named a path got a file read that the
        // file policy never saw, and a named path could not have got. The fence
        // is not about who typed the path; it is about opening a file. So the
        // inferred path clears the SAME file policy an explicit one clears, and
        // when it does not, the file route is simply not taken: the window is
        // right there, and its own text is what the accessibility category is
        // actually the authority over.
        var declinedInferredPath: (path: String, reason: String)?
        if documentPath == nil, let target,
           let inferred = accessibilitySource.frontmostDocumentPath(pid: target.processIdentifier) {
            // User, 2026-09-06: the TURN's file-access mode outranks the Mac
            // file policy here. Under fileAccess=none the chat gate refuses a
            // pathful `read`; without this the pathless one still opened the
            // front window's document, which is the same file read by another
            // name. AX text only, and the receipt says which path was declined.
            if MacControlTurnFileAccess.deniesFileReads {
                declinedInferredPath = (path: inferred, reason: "file_access_none")
            } else if let reason = await fileClearanceReason(forPath: inferred, body: body) {
                declinedInferredPath = (path: inferred, reason: reason)
            } else {
                documentPath = inferred
            }
        }

        // ROUTE (a): EXTRACT.
        if let path = documentPath {
            switch extractDocument(at: path) {
            case .success(let extracted):
                let redaction = MacClipboardRead.redacted(extracted.text)
                var output: [String: JSONValue] = [
                    "read": .bool(true),
                    "source": .string("file"),
                    "path": .string(path),
                    "named_by": .string(namedByCaller ? "caller" : "front_window"),
                    "chars": .int(Int64(redaction.text.count)),
                    "truncated": .bool(extracted.truncated),
                    "text": .string(redaction.text),
                ]
                if let target, !namedByCaller { output["app"] = target.toJSON() }
                if let pages = extracted.pages { output["document_pages"] = .int(Int64(pages)) }
                Self.attachRedaction(redaction, to: &output)
                return result(ok: true, output)
            case .failure(let failure):
                // The CALLER named this file: their question was about the
                // file, so the answer is about the file.
                if namedByCaller {
                    return refuse(
                        failure.rawValue,
                        MacDocumentRead.words(for: failure, path: path),
                        ["path": .string(path)]
                    )
                }
                // WE inferred it from the window. The window is still there and
                // still readable, so fall through and read THAT, saying which
                // file we could not parse and why.
                return await readFromScreen(
                    started: started,
                    body: body,
                    app: target,
                    fellBackFrom: (path: path, reason: failure.rawValue),
                    declinedInferredPath: nil
                )
            }
        }

        // ROUTE (b): ACCUMULATE.
        return await readFromScreen(
            started: started,
            body: body,
            app: target,
            fellBackFrom: nil,
            declinedInferredPath: declinedInferredPath
        )
    }

    /// The file-policy clearance an AX-INFERRED document path must pass before
    /// it may be opened, reported as a reason string or `nil` for cleared.
    ///
    /// Deliberately the same two layers `gatePreflightOutcome` runs for an
    /// EXPLICIT `path` (`macControlFilePolicyPathKeys(forAction: "read")`), in
    /// the same order: the `file_ops` category gate, then the workspace-root
    /// file policy for this specific path. It lives HERE rather than at the
    /// tool layer because the path does not exist yet when the tool layer runs
    /// — the window has not been asked. And a nil provider proceeds, matching
    /// the pre-flight's own convention for direct library callers and tests.
    private func fileClearanceReason(
        forPath path: String,
        body: [String: JSONValue]
    ) async -> String? {
        guard let provider = policyProvider else { return nil }
        guard let policy = await provider.currentPolicy() else {
            return "mac_control_policy_unavailable"
        }
        let trigger = body.stringValue("trigger").flatMap { $0.isEmpty ? nil : $0 } ?? "user"
        let decision = MacControlGate.gate(policy, category: "file_ops", trigger: trigger)
        guard decision.allowed else { return decision.reason }
        return MacControlGate.fileReason(policy, forPaths: [path], now: now())
    }

    /// Open the file and turn it into characters. Split out so the fall-through
    /// above reads as one decision instead of a nest.
    private func extractDocument(
        at path: String
    ) -> Result<MacDocumentRead.Extracted, MacDocumentRead.ExtractionFailure> {
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
                maxBytes: MacDocumentRead.maxFileBytes
            )
        } catch {
            return .failure(.unreadableDocument)
        }
        return MacDocumentRead.extract(data: data, kind: kind)
    }

    /// THE ACCUMULATE ROUTE. Walk the frontmost scroll container's text, scroll
    /// one viewport (minus a deliberate overlap band), walk again, merge on the
    /// seam, and stop the moment a frame adds nothing.
    ///
    /// WHAT IT EMITS, exhaustively: one `.move` to aim the wheel at the
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
        fellBackFrom: (path: String, reason: String)?,
        declinedInferredPath: (path: String, reason: String)?
    ) async -> MacControlResult {
        func result(ok: Bool, _ output: [String: JSONValue], error: String? = nil) -> MacControlResult {
            var output = output
            if let fellBackFrom {
                output["fell_back_from"] = .object([
                    "path": .string(fellBackFrom.path),
                    "reason": .string(fellBackFrom.reason),
                ])
            }
            // The file route was AVAILABLE and was not taken, because opening
            // that file is file access this call does not hold. Said out loud:
            // a silently downgraded read is a read the caller mistakes for the
            // document.
            if let declinedInferredPath {
                output["file_route_declined"] = .object([
                    "path": .string(declinedInferredPath.path),
                    "reason": .string(declinedInferredPath.reason),
                    "words": .string(
                        MacDocumentRead.filePolicyDeclinedWords(path: declinedInferredPath.path)
                    ),
                ])
            }
            return MacControlResult(
                ok: ok,
                action: "read",
                output: .object(output),
                error: error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
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
        guard let window = accessibilitySource.windowRoot(pid: app.processIdentifier) else {
            return refuse("no_window", MacDocumentRead.noWindowWords)
        }

        // gpt-5.5 review — THE CLOCK. See `MacDocumentRead`'s "The clock" note:
        // this organ runs outside the operation store's deadline path on
        // purpose, and it is the heaviest AX caller in the module, so it carries
        // its own two bounds. The per-call one is scoped to THIS app's element
        // and put back on the way out; the wall-clock one is checked between
        // frames below.
        let deadline = now().addingTimeInterval(MacDocumentRead.deadlineSeconds)
        #if canImport(ApplicationServices) && os(macOS)
        if accessibilitySource is SystemMacAXElementSource {
            SystemMacAXElementSource.setMessagingTimeout(
                pid: app.processIdentifier,
                seconds: MacDocumentRead.axMessagingTimeoutSeconds
            )
        }
        defer {
            if accessibilitySource is SystemMacAXElementSource {
                // 0 restores the system default — the bound belonged to this
                // read, not to the app.
                SystemMacAXElementSource.setMessagingTimeout(pid: app.processIdentifier, seconds: 0)
            }
        }
        #endif

        // The READ TARGET: the most specific scrollable/readable container the
        // window offers, falling back to the window itself. A window that IS
        // the text area answers at the first role.
        var container = window
        var containerRole = accessibilitySource.attributes(of: window)?.role ?? "AXWindow"
        for role in MacDocumentRead.containerRoles {
            if let hit = MacAccessibilityReader.findFirst(
                role: role,
                source: accessibilitySource,
                root: window
            ).hit {
                container = hit.ref
                containerRole = role
                break
            }
        }
        let containerFrame = accessibilitySource.attributes(of: container)?.frame
        let scrollContainer = container
        let takeover = MacDocumentReadTakeover()
        let observation = attentionEventSource.start { _ in takeover.mark() }
        defer { observation.stop() }
        func stopReason() async -> String? {
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
        let firstFrame = MacDocumentRead.frameLines(source: accessibilitySource, root: container)
        if firstFrame.lines.isEmpty {
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

        // Can we move the viewport at all? Answer honestly rather than
        // returning one screenful as if it were the document.
        let scrollRestoration = MacDocumentScrollRestoration.capture(source: accessibilitySource, container: container)
        let canScroll = eventSink.isAvailable && (containerFrame?.h ?? 0) > 0 && scrollRestoration != nil
        var framesRead = 1
        var steps = 0
        var reachedEnd = false
        var truncationReason: String?

        if canScroll, let frame = containerFrame {
            let delta = MacDocumentRead.scrollStepPoints(viewportHeight: frame.h)
            let centreX = frame.x + frame.w / 2
            let centreY = frame.y + frame.h / 2
            truncationReason = await stopReason()
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
                let next = MacDocumentRead.frameLines(source: accessibilitySource, root: container)
                framesRead += 1
                let absorbed = accumulator.absorb(next.lines)
                if case .nothingNew = absorbed {
                    reachedEnd = true
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

        // 2026-09-06: clipped/zero-motion end probes must not overshoot the
        // original position. Restore its captured value, then read it back.
        var restored: Bool?
        if steps > 0, let scrollRestoration {
            if let reason = await stopReason() {
                truncationReason = reason
                restored = false
            } else {
                let accepted = scrollRestoration.restore()
                if accepted { await Self.settleForDocumentRead() }
                let finalStop = await stopReason()
                restored = accepted && finalStop == nil && scrollRestoration.isRestored
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
            "truncated": .bool(truncationReason != nil || firstFrame.truncated),
            "gaps": .bool(accumulator.sawGap),
            "chars": .int(Int64(redaction.text.count)),
            "text": .string(redaction.text),
        ]
        if let truncationReason { output["truncation_reason"] = .string(truncationReason) }
        if let restored { output["scroll_restored"] = .bool(restored) }
        if !canScroll {
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

    func handleAXStatus() -> MacControlResult {
        let started = now()
        let trusted = accessibilitySource.isTrusted()
        var output: [String: JSONValue] = ["trusted": .bool(trusted)]
        if !trusted {
            output["note"] = .string(MacAccessibilityReader.notTrustedNote)
            output["grant_path"] = .string("System Settings → Privacy & Security → Accessibility")
        }
        if let app = accessibilitySource.frontmostApp() {
            output["frontmost_app"] = app.toJSON()
        }
        // The STATUS read itself always succeeds — "I don't have permission" is
        // a true answer, not a failure. Only the tree/find reads fail closed.
        return MacControlResult(
            ok: true,
            action: "ax_status",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// One read EPOCH: the root, its walk, and the focused element's path
    /// anchored to THAT root — never a focus fetched later against whatever
    /// window is frontmost by then (gpt-5.5 BLOCKING 2026-08-22: a focus path
    /// from a different tree that happens to exist in the old snapshot makes a
    /// look lie about where the cursor is). If the focus is not under this
    /// root, `focusPath` is nil and the percept says "focus unknown".
    /// - Parameter pid: when given, the window is taken from THAT process
    ///   instead of from whatever is frontmost — `mac_act`'s identity guard
    ///   (B3) must re-read the app the frame came from, or a background act
    ///   would be refused as drift the moment another app took focus.
    private func axSnapshot(
        limits: MacAXLimits,
        pid: Int32? = nil
    ) -> MacAnchoredRead {
        anchoredSnapshot(limits: limits, pid: pid, window: nil)
    }

    /// One vocabulary for the self-refusal across every read tool.
    static let selfInspectionError = "self_inspection_unsupported"
    static let selfInspectionNote =
        "the target is NativeAgent's own window, and reading our own UI over AX "
        + "deadlocks the app (in-process AppKit re-entry) — self-inspection via AX "
        + "is refused; look at another app's window instead"

    private func selfInspectionResult(action: String, started: Date) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "trusted": .bool(true),
                "status": .string(Self.selfInspectionError),
                "error": .string(Self.selfInspectionError),
                "message": .string(Self.selfInspectionNote),
            ]),
            error: Self.selfInspectionError,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// The outcome of a WINDOW-ANCHORED read (gpt-5.5 round-3 B1/B2).
    ///
    /// "No window" is three different facts and the caller has to tell them
    /// apart: the app is gone, the app is there but the window she looked at is
    /// not, or several windows are equally plausible and picking one would be a
    /// coin flip.
    enum MacAnchoredRead {
        case read(MacAXRead)
        case appGone
        case windowGone
        case windowDrifted(String)
        /// The target is NativeAgent's own process. An AX walk of our own tree
        /// re-enters AppKit in-process (P1 deadlock, sample 2026-08-28:
        /// `AXUIElementCopyActionNames` on our own toolbar ran
        /// `+[NSToolbarView defaultMenu]` → `-[NSOperation waitUntilFinished]`
        /// on a background cooperative thread while the main thread was parked
        /// in SwiftUI's update lock — mutual wait, force-kill to recover).
        /// AX perception is for OTHER processes; the walk is refused before a
        /// single element is read.
        case selfProcess
    }

    /// One read epoch, optionally anchored to a NAMED WINDOW of a named process.
    ///
    /// - `pid` nil ⇒ the frontmost window of the frontmost app (`mac_ax_tree`,
    ///   `mac_ax_find`, the first look).
    /// - `pid` given, `window` nil ⇒ that process's first window, as before.
    /// - `pid` AND `window` given ⇒ the window whose composite identity matches,
    ///   or a refusal. Never "focused, else main, else first" inside the pid:
    ///   with two windows of one app, a focus change between the look and the
    ///   act silently re-points the read at the other one, and the pid claim
    ///   still passes (round-2 B2 was necessary, not sufficient).
    func anchoredSnapshot(
        limits: MacAXLimits,
        pid: Int32?,
        window: MacAXWindowIdentity?
    ) -> MacAnchoredRead {
        // See `MacAnchoredRead.selfProcess` — refusing here, before any element
        // is resolved, is what keeps the in-process AppKit re-entry deadlock
        // structurally unreachable from every snapshot caller.
        if pid == getpid() { return .selfProcess }
        let root: MacAXElementRef
        var identity: MacAXWindowIdentity?
        if let pid {
            let candidates = accessibilitySource.windowRoots(pid: pid)
            guard !candidates.isEmpty else { return .appGone }
            if let window {
                switch MacAXWindowIdentity.match(
                    window,
                    among: candidates.map { (handle: $0, identity: $0.identity) }
                ) {
                case .matched(let hit, _):
                    root = hit.ref
                    identity = hit.identity
                case .gone:
                    return .windowGone
                case .ambiguous(let reason):
                    return .windowDrifted(reason)
                }
            } else {
                root = candidates[0].ref
                identity = candidates[0].identity
            }
        } else {
            if let front = accessibilitySource.frontmostApp(),
               front.processIdentifier == getpid() {
                return .selfProcess
            }
            guard let frontmost = accessibilitySource.frontmostWindowRoot() else { return .appGone }
            root = frontmost
            // The frontmost read still names its window, so the FRAME it mints
            // can be re-found later — that is what makes the first look
            // anchorable at all. The window's INDEX is unknown on this path
            // (`frontmostWindowRoot()` answers with a window, not a position),
            // and `nil` is how the identity says so: an index it guessed at
            // would score a wrong candidate up.
            if let app = accessibilitySource.frontmostApp(),
               let attributes = accessibilitySource.attributes(of: root) {
                identity = MacAXWindowIdentity(
                    pid: app.processIdentifier,
                    index: nil,
                    role: attributes.role,
                    subrole: attributes.subrole,
                    title: attributes.title,
                    frame: attributes.frame
                )
            }
        }
        let snapshot = MacAccessibilityReader.walk(
            source: accessibilitySource,
            root: root,
            limits: limits
        )
        let focusPath = accessibilitySource.focusedElementPath(relativeTo: root)
        return .read(MacAXRead(
            snapshot: snapshot,
            // S7 — a pid-anchored read reports THAT process, never
            // `frontmostApp()`. When the source cannot name it, the pid itself
            // is still the truth and stays carried (the frame's whole anchor
            // hangs off it); the NAME is not invented from another app's.
            app: pid.map { anchored in
                accessibilitySource.appInfo(pid: anchored)
                    ?? MacAXAppInfo(
                        name: "pid \(anchored)",
                        bundleIdentifier: nil,
                        processIdentifier: anchored
                    )
            } ?? accessibilitySource.frontmostApp(),
            rootTitle: snapshot.nodes.first?.attributes.title,
            focusPath: focusPath,
            root: root,
            windowIdentity: identity
        ))
    }

    /// Agent round 2, her #1-ranked gap — PAGE-FIRST perception for a
    /// Chromium/Electron window.
    ///
    /// The ordinary walk starts at the window and spends its 400 nodes and 12
    /// levels on the toolbar and the bookmarks bar, hitting `depth_cap` before
    /// it reaches the `AXWebArea` at all: her Chrome look was blind to the page
    /// she was looking at. So when the frontmost window is chromium-family and
    /// a web area can be FOUND (bounded, read-only, same seam), the percept is
    /// compiled from the PAGE, and the browser chrome collapses to one line.
    ///
    /// Paths stay WINDOW-RELATIVE: the page walk is re-based onto the web
    /// area's own path, because `mac_act` resolves a child-index chain from the
    /// window root and a page-relative path would address a different element
    /// entirely.
    func pageScoped(
        _ windowRead: MacAXRead,
        limits: MacAXLimits,
        scope: MacLookScope
    ) -> (read: MacAXRead, seam: [String: JSONValue]) {
        var seam: [String: JSONValue] = [:]
        let chromiumFamily = MacChromiumAccessibility.looksChromium(
            bundleId: windowRead.app?.bundleIdentifier,
            snapshot: windowRead.snapshot
        ) || MacChromiumAccessibility.hasWebArea(windowRead.snapshot)
        guard scope != .chrome, chromiumFamily else {
            seam["scope"] = .string(scope == .page && !chromiumFamily ? "chrome" : scope.rawValue)
            if scope == .page, !chromiumFamily {
                seam["scope_reason"] = .string("not_a_chromium_window")
            }
            return (windowRead, seam)
        }
        let search = MacAccessibilityReader.findFirst(
            role: "AXWebArea",
            source: accessibilitySource,
            root: windowRead.root
        )
        guard let web = search.hit else {
            // gpt-5.5 round-3 S5 — the fallback to chrome scope is right; the
            // REASON was not. A deep or wide Chromium shell can spend the
            // 160-node search budget before reaching the page, and reporting
            // that as `no_web_area_found` claims the page does not exist on the
            // authority of a search that never got there.
            seam["scope"] = .string("chrome")
            if let reason = search.truncationReason {
                seam["scope_reason"] = .string("web_area_search_truncated")
                seam["web_area_search_limit"] = .string(reason)
                seam["web_area_search_budget"] = .object([
                    "max_depth": .int(Int64(MacAccessibilityReader.findFirstMaxDepth)),
                    "node_budget": .int(Int64(MacAccessibilityReader.findFirstNodeBudget)),
                ])
                seam["scope_note"] = .string(
                    "the search for the page ran out of \(reason == "node_cap" ? "nodes" : "depth") "
                    + "before finding it — this is the browser chrome, and the page may still be "
                    + "there unseen"
                )
            } else {
                seam["scope_reason"] = .string("no_web_area_found")
            }
            return (windowRead, seam)
        }
        if scope == .both {
            // The whole window in ONE walk, page included as far as the budget
            // reaches. Named honestly: the page COMPETES with the chrome for
            // the node budget here, which is exactly the failure `page` exists
            // to avoid.
            seam["scope"] = .string("both")
            seam["web_area_path"] = .array(web.path.map { .int(Int64($0)) })
            seam["scope_note"] = .string(
                "the page shares the node budget with the browser chrome in this scope — use "
                + "scope:\"page\" to spend the whole budget on the page"
            )
            return (windowRead, seam)
        }
        let pageWalk = MacAccessibilityReader.walk(
            source: accessibilitySource,
            root: web.ref,
            limits: limits
        )
        // Re-base every path onto the web area's own path from the window root.
        let rebased = MacAXTreeSnapshot(
            nodes: pageWalk.nodes.map { MacAXNode(attributes: $0.attributes, path: web.path + $0.path) },
            truncated: pageWalk.truncated,
            truncationReasons: pageWalk.truncationReasons,
            skippedAtLeast: pageWalk.skippedAtLeast
        )
        let pageFocus = accessibilitySource.focusedElementPath(relativeTo: web.ref).map { web.path + $0 }
        let chromeControls = windowRead.snapshot.nodes.filter { node in
            MacPerceptionCompiler.isInteractive(node.attributes)
                && !node.path.starts(with: web.path)
        }.count
        seam["scope"] = .string("page")
        seam["web_area_path"] = .array(web.path.map { .int(Int64($0)) })
        seam["chrome"] = .string(
            "browser chrome: toolbar + bookmarks bar, \(chromeControls) control(s) — "
            + "call mac_look {scope: \"chrome\"} to address them"
        )
        seam["chrome_controls"] = .int(Int64(chromeControls))
        return (
            MacAXRead(
                snapshot: rebased,
                app: windowRead.app,
                // The WINDOW's title, not the web area's: it is what names the
                // window in every other channel, and dropping it here would
                // make the page look like it belonged to nothing.
                rootTitle: windowRead.rootTitle,
                focusPath: pageFocus,
                root: web.ref,
                // The page walk is still a walk OF THAT WINDOW — the frame it
                // mints has to be re-findable, and the web area is not a window.
                windowIdentity: windowRead.windowIdentity
            ),
            seam
        )
    }

    private static func axTruncationJSON(_ snapshot: MacAXTreeSnapshot, limits: MacAXLimits) -> [String: JSONValue] {
        [
            "truncated": .bool(snapshot.truncated),
            "truncation_reasons": .array(snapshot.truncationReasons.map { .string($0) }),
            "skipped_at_least": .int(Int64(snapshot.skippedAtLeast)),
            "max_nodes": .int(Int64(limits.maxNodes)),
            "max_depth": .int(Int64(limits.maxDepth)),
        ]
    }

    func handleAXTree(_ body: [String: JSONValue]) -> MacControlResult {
        let started = now()
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "ax_tree") }
        let limits = Self.axLimits(from: body)
        let anchored = axSnapshot(limits: limits)
        if case .selfProcess = anchored {
            return selfInspectionResult(action: "ax_tree", started: started)
        }
        guard case .read(let read) = anchored else {
            return MacControlResult(
                ok: false,
                action: "ax_tree",
                output: .object([
                    "trusted": .bool(true),
                    "status": .string("no_frontmost_window"),
                    "error": .string("no_frontmost_window"),
                ]),
                error: "no_frontmost_window",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        var output: [String: JSONValue] = Self.axTruncationJSON(read.snapshot, limits: limits)
        output["trusted"] = .bool(true)
        output["app"] = read.app?.toJSON() ?? .null
        // W3.5-FIX-R3 — the SIBLING organ's leak. `mac_view` redacts its text
        // channel, legend and window title; `ax_tree` reads the same screen
        // through the same walk and shipped every node title/value and the
        // window title RAW into the same trace/persist/sync sinks. Same
        // standalone shape redactor, applied here at the tool-serialization
        // boundary so `MacAccessibilityReader`'s walk stays byte-identical.
        output["window_title"] = read.rootTitle.map {
            MacScreenViewTextRedaction.redactedLegendString($0, valueChars: limits.valueChars)
        } ?? .null
        output["count"] = .int(Int64(read.snapshot.nodes.count))
        output["nodes"] = .array(
            MacScreenViewTextRedaction.redactedNodesJSON(
                read.snapshot.nodes,
                valueChars: limits.valueChars
            )
        )
        return MacControlResult(
            ok: true,
            action: "ax_tree",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: - native-look item 2: `look`

    /// The Chromium/Electron live seam. Runs BEFORE the walk that matters.
    ///
    /// Returns the snapshot to compile from. Order:
    ///   1. one ordinary walk;
    ///   2. if the frontmost app looks Chromium-family (known bundle id, or a
    ///      web-less shell-sized window), set both enhanced-AX flags on the APP
    ///      element and read them back;
    ///   3. if the first walk found no `AXWebArea`, poll every 500 ms for up to
    ///      4 s and re-walk EXACTLY ONCE more.
    ///
    /// The flag is left set (see `MacChromiumAccessibility` for the lifetime
    /// rule) and cleared lazily here when the frontmost app changed or the last
    /// frame expired — never by a background timer.
    ///
    /// - Parameters anchorPid/anchorWindow: gpt-5.5 round-3 B2. The POST-ACT
    ///   read must be of the window the act happened in, not of whatever is
    ///   frontmost by then: a correct background act followed by a frontmost
    ///   read describes — and then STORES AS THE NEW FRAME — a different app's
    ///   window entirely. When they are given, every walk here (including the
    ///   Chromium settle re-walk) targets that window, and the outcome carries
    ///   the anchor failure instead of silently reading something else.
    func lookSnapshot(
        limits: MacAXLimits,
        scope: MacLookScope = .page,
        anchorPid: Int32? = nil,
        anchorWindow: MacAXWindowIdentity? = nil
    ) async -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
        var seam: [String: JSONValue] = [
            "chromium_family": .bool(false),
            "enhanced_ax_set": .bool(false),
            "rewalked": .bool(false),
        ]
        func anchoredRead() -> MacAnchoredRead {
            anchoredSnapshot(limits: limits, pid: anchorPid, window: anchorWindow)
        }
        let firstAnchor = anchoredRead()
        // A self-process target is a refusal on BOTH the anchored and the
        // unanchored path — the caller needs the reason, not a generic
        // "no window" (the walk was refused, not absent).
        if case .selfProcess = firstAnchor { return (nil, seam, firstAnchor) }
        var read: MacAXRead? = {
            if case .read(let hit) = firstAnchor { return hit }
            return nil
        }()
        // Only the ANCHORED call reports an anchor failure; an unanchored look
        // has no window to have lost.
        let anchorFailure: MacAnchoredRead? = {
            guard anchorPid != nil || anchorWindow != nil else { return nil }
            if case .read = firstAnchor { return nil }
            return firstAnchor
        }()
        if anchorFailure != nil { return (nil, seam, anchorFailure) }

        /// A2 — the page-first descent, applied to whatever walk we end up
        /// with. Outside the live-source guard below on purpose: the ENHANCED-AX
        /// flag needs a real AX app element, but finding the web area and
        /// walking from it is ordinary reading that any source can answer, which
        /// is also what makes it testable against a synthetic Chromium tree.
        func scoped(
            _ candidate: (read: MacAXRead?, seam: [String: JSONValue])
        ) -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
            guard let value = candidate.read else { return (nil, candidate.seam, nil) }
            let outcome = pageScoped(value, limits: limits, scope: scope)
            var merged = candidate.seam
            for (key, item) in outcome.seam { merged[key] = item }
            return (outcome.read, merged, nil)
        }

        #if canImport(ApplicationServices) && os(macOS)
        // The seam only exists for the LIVE source. A synthetic/unavailable
        // source has no app element to flag, and pretending otherwise would be
        // a stub that reports work it did not do.
        guard accessibilitySource is SystemMacAXElementSource else { return scoped((read, seam)) }
        // B2 — the ANCHOR's pid wins. Flagging (and later clearing) enhanced-AX
        // on whatever is frontmost while reading an anchored background window
        // would mutate a third app's accessibility state.
        let pid = anchorPid
            ?? read?.app?.processIdentifier
            ?? accessibilitySource.frontmostApp()?.processIdentifier
        // Lazy clear: the previous app's flag stops being the frame's flag the
        // moment the frontmost app changes or the frame dies.
        let previous = await MacChromiumAccessibilityState.shared.current()
        let frameExpired = await lookFrameStore.isExpired(now: now())
        if let previous, previous != pid || frameExpired {
            SystemMacAXElementSource.setEnhancedAccessibility(pid: previous, enabled: false)
            await MacChromiumAccessibilityState.shared.note(pid: nil)
            seam["enhanced_ax_cleared_pid"] = .int(Int64(previous))
        }

        guard let pid,
              MacChromiumAccessibility.looksChromium(
                bundleId: read?.app?.bundleIdentifier,
                snapshot: read?.snapshot
              )
        else { return scoped((read, seam)) }

        seam["chromium_family"] = .bool(true)
        // Chrome's setter returns kAXErrorCannotComplete and the flag STILL
        // takes effect, so the status is discarded and the READ-BACK is the
        // evidence. A false read-back is reported, not treated as fatal.
        let readsBack = SystemMacAXElementSource.setEnhancedAccessibility(pid: pid, enabled: true)
        seam["enhanced_ax_set"] = .bool(readsBack)
        await MacChromiumAccessibilityState.shared.note(pid: pid)

        if !MacChromiumAccessibility.hasWebArea(read?.snapshot) {
            let deadline = now().addingTimeInterval(MacChromiumAccessibility.settleSeconds)
            while now() < deadline {
                try? await Task.sleep(
                    nanoseconds: UInt64(MacChromiumAccessibility.pollSeconds * 1_000_000_000)
                )
                if case .read(let candidate) = anchoredRead(),
                   MacChromiumAccessibility.hasWebArea(candidate.snapshot) {
                    read = candidate
                    seam["rewalked"] = .bool(true)
                    break
                }
            }
            if seam["rewalked"] != .bool(true) {
                // Exactly one re-walk even when no web area ever appeared, so a
                // slow-but-enhanced tree is not missed and the caller learns the
                // settle produced nothing.
                if case .read(let candidate) = anchoredRead() {
                    read = candidate
                }
                seam["rewalked"] = .bool(true)
                seam["web_area_after_settle"] = .bool(MacChromiumAccessibility.hasWebArea(read?.snapshot))
            }
        }
        #endif
        return scoped((read, seam))
    }

    /// `mac_look` — the perception compiler's tool surface.
    ///
    /// Three grades of attention over ONE walk. `stare` is DELEGATED to
    /// `handleAXTree` rather than reimplemented, so the full-tree payload can
    /// never drift from `mac_ax_tree`'s.
    func handleLook(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let grade = (body.stringValue("grade") ?? "look").lowercased()
        guard ["glance", "look", "stare"].contains(grade) else {
            return MacControlResult(
                ok: false,
                action: "look",
                output: .object([
                    "error": .string("unknown_grade"),
                    "grade": .string(grade),
                    "message": .string("grade must be one of: glance, look, stare"),
                ]),
                error: "unknown_grade",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "look") }

        // fable51 item 32a — BACKGROUND SIGHT. `app` names a running app whose
        // front window is read WITHOUT activating it: the anchor
        // `lookSnapshot` has always accepted, finally reachable by a caller.
        // Nothing on this path focuses, launches or raises anything.
        var anchorPid: Int32?
        var anchoredApp: MacAXAppInfo?
        if let requested = body.stringValue("app")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard grade != "stare" else {
                return MacControlResult(
                    ok: false,
                    action: "look",
                    output: .object([
                        "error": .string("background_stare_unsupported"),
                        "message": .string(
                            "A background window can be read at glance or look; stare is the "
                            + "frontmost raw tree only."
                        ),
                    ]),
                    error: "background_stare_unsupported",
                    durationMs: Int(now().timeIntervalSince(started) * 1000),
                    viaSwift: true
                )
            }
            let resolution = MacBackgroundSight.resolve(
                requested,
                among: accessibilitySource.runningApps()
            )
            guard case .matched(let app) = resolution else {
                let words = MacBackgroundSight.words(for: resolution, requested: requested)
                    ?? "I couldn't find a running app called \"\(requested)\"."
                let code = resolution.failureCode ?? "app_not_running"
                return MacControlResult(
                    ok: false,
                    action: "look",
                    output: .object([
                        "trusted": .bool(true),
                        "grade": .string(grade),
                        "requested_app": .string(requested),
                        "status": .string(code),
                        "error": .string(code),
                        "message": .string(words),
                    ]),
                    error: code,
                    durationMs: Int(now().timeIntervalSince(started) * 1000),
                    viaSwift: true
                )
            }
            anchorPid = app.processIdentifier
            anchoredApp = app
        }

        if grade == "stare" {
            // The SAME payload mac_ax_tree returns, from the same handler.
            let tree = handleAXTree(body)
            var output: [String: JSONValue] = [:]
            if case .object(let object) = tree.output { output = object }
            output["grade"] = .string("stare")
            return MacControlResult(
                ok: tree.ok,
                action: "look",
                output: .object(output),
                error: tree.error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }

        guard let scope = MacLookScope.parse(body.stringValue("scope")) else {
            return MacControlResult(
                ok: false,
                action: "look",
                output: .object([
                    "error": .string("unknown_scope"),
                    "scope": body["scope"] ?? .null,
                    "message": .string("scope must be one of: page, chrome, both"),
                ]),
                error: "unknown_scope",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let limits = Self.axLimits(from: body)
        let (read, seam, anchor) = await lookSnapshot(
            limits: limits,
            scope: scope,
            anchorPid: anchorPid
        )
        if case .selfProcess? = anchor {
            return selfInspectionResult(action: "look", started: started)
        }
        guard let read else {
            // An anchored read that found nothing is a DIFFERENT fact from "no
            // frontmost window": the app is running but has no readable window
            // (minimized, or all windows closed). Saying the frontmost thing
            // would describe a window that was never asked about.
            let status = anchoredApp == nil ? "no_frontmost_window" : "no_window_in_app"
            var output: [String: JSONValue] = [
                "trusted": .bool(true),
                "grade": .string(grade),
                "status": .string(status),
                "error": .string(status),
            ]
            if let anchoredApp {
                output["requested_app"] = .string(anchoredApp.name)
                output["message"] = .string(
                    "\(anchoredApp.name) is running but has no window I can read right now "
                    + "(it may be minimized or have every window closed)."
                )
            }
            return MacControlResult(
                ok: false,
                action: "look",
                output: .object(output),
                error: status,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }

        let percept = MacPerceptionCompiler.compile(
            snapshot: read.snapshot,
            app: read.app,
            windowTitle: read.rootTitle,
            // Same read epoch as the walk, anchored to the walked root.
            focusPath: read.focusPath,
            maxAffordances: Self.intValue(body, "max_affordances") ?? MacPerceptionCompiler.maxAffordances
        )

        // Render FIRST, so the frame mints handles only for the rows she will
        // actually see (the byte budget may trim the tail) — "handles valid for
        // this frame_id" means the handles in THIS payload. A glance shows no
        // rows, so it mints every affordance and says how many are addressable.
        let capturedAt = now()
        let frameId = UUID().uuidString

        /// Everything except the byte accounting, so the S5 loop below can
        /// serialize the COMPLETE object — envelope, `how_to_read` and all —
        /// rather than a percept plus a guessed reserve.
        func envelopeJSON(_ rendering: MacLookPercept.LookRendering?) -> [String: JSONValue] {
            var output: [String: JSONValue] = [
                "trusted": .bool(true),
                "grade": .string(grade),
                "frame_id": .string(frameId),
                "captured_at": .string(ISO8601DateFormatter().string(from: capturedAt)),
                "frame_ttl_seconds": .int(Int64(MacLookFrameStore.ttlSeconds)),
                "seam": .object(seam),
                // fable51 item 32a — WHOSE window this is, and whether it is in
                // front. Both grades publish it because the caller's renderer
                // must not print "in front" over a background read: an
                // unanchored look is frontmost by construction, an anchored one
                // is only frontmost by coincidence.
                "front": .bool(
                    anchoredApp.map {
                        accessibilitySource.frontmostApp()?.processIdentifier == $0.processIdentifier
                    } ?? true
                ),
                "anchored": .bool(anchoredApp != nil),
                // Agent round 2 — `max_nodes`/`max_depth` read as "silently
                // ignored" because nothing in the payload said what they
                // resolved to. They are honored and CLAMPED (a caller may only
                // lower them); now the payload says so out loud.
                "limits": .object([
                    "max_nodes": .int(Int64(limits.maxNodes)),
                    "max_depth": .int(Int64(limits.maxDepth)),
                    "hard_max_nodes": .int(Int64(MacAXLimits.hardMaxNodes)),
                    "hard_max_depth": .int(Int64(MacAXLimits.hardMaxDepth)),
                ]),
            ]
            // fable51 item 32b (gpt-5.5 review) — THE WINDOW'S OWN RECTANGLE.
            // Both grades publish it because a caller that has to decide
            // whether raising this window would cover a point elsewhere on the
            // screen cannot answer that from the elements read INSIDE it: a
            // title bar, a toolbar and a blank body publish no element and are
            // still the window. The cross-app drag's coverage refusal turns on
            // this; absent when the walk could not name a window, which the
            // caller reads as "unknown", never as "empty".
            if let windowFrame = read.windowIdentity?.frame {
                output["window_frame"] = windowFrame.toJSON()
            }
            if grade == "glance" {
                output["glance"] = .string(percept.glanceLine())
                output["addressable_handles"] = .int(Int64(percept.affordances.count))
                output["how_to_read"] = .string(
                    "One distilled line. Call mac_look {grade: \"look\"} for the addressable "
                    + "affordances (\(percept.affordances.count) labeled control(s) in this frame), "
                    + "or {grade: \"stare\"} for the full AX tree."
                )
            } else if let rendering {
                if case .object(let lookObject) = rendering.json {
                    for (key, value) in lookObject { output[key] = value }
                }
                output["glance"] = .string(percept.glanceLine())
                output["percept_bytes"] = .int(Int64(rendering.bytes))
                output["how_to_read"] = .string(
                    "`affordances` are the things you can act on, each with a stable `handle` for "
                    + "THIS frame_id and its `path` as the fallback. `unlabeled` counts the "
                    + "interactive controls the app publishes no name for — they exist, they are "
                    + "just unnamed. `readouts` are the read-only values on screen (a total, a "
                    + "display, a status line) — what you can READ without touching anything. "
                    + "Handles are valid only for the latest frame; take another look "
                    + "if the screen may have changed."
                )
            }
            return output
        }

        func serializedSize(_ object: [String: JSONValue]) -> Int {
            (try? JSONValue.object(object).serializedData(pretty: false).count) ?? 0
        }

        var rendering: MacLookPercept.LookRendering? = grade == "look" ? percept.lookJSON() : nil
        var output = envelopeJSON(rendering)
        if grade == "look" {
            // gpt-5.5 round-2 S5 — the EXACT final cap. The old code held back a
            // fixed 768-byte reserve for the envelope and then measured; a
            // window with a long title and a fat `seam` blew straight through
            // `lookByteBudget` and the payload said `bytes: 6600` as if that
            // were fine. Now the COMPLETE object (including its own `bytes`
            // field, hence the slack) is serialized, and rows are trimmed until
            // it really fits.
            var reserve = MacPerceptionCompiler.lookEnvelopeReserve
            var attempts = 0
            while attempts < 8 {
                var candidate = output
                candidate["bytes"] = .int(Int64(MacPerceptionCompiler.lookByteBudget))
                let size = serializedSize(candidate)
                if size <= MacPerceptionCompiler.lookByteBudget { break }
                let overshoot = size - MacPerceptionCompiler.lookByteBudget
                reserve += overshoot + 64
                let next = percept.lookJSON(envelopeReserve: reserve)
                // The trimmer has nothing left to give: stop rather than spin.
                if next.bytes >= (rendering?.bytes ?? Int.max) { rendering = next; output = envelopeJSON(next); break }
                rendering = next
                output = envelopeJSON(next)
                attempts += 1
            }
        }

        let renderedRows: Int? = rendering.map { rendering in
            if case .object(let object) = rendering.json,
               case .array(let rows)? = object["affordances"] { return rows.count }
            return 0
        }

        // The frame is minted for BOTH structured grades: a glance that named a
        // control she then cannot address would be a tease, and item 3's verbs
        // resolve handles through exactly this store.
        await lookFrameStore.record(MacLookFrame.from(
            percept: percept,
            frameId: frameId,
            capturedAt: capturedAt,
            windowTitle: read.rootTitle,
            rendered: renderedRows,
            // B1 — WHICH window this look was of. Without it `mac_act` can only
            // re-find the app, and picks "focused, else main, else first"
            // inside it.
            windowIdentity: read.windowIdentity,
            // Recorded so the NEXT act can tell "the window changed" from "the
            // recompile ran under different bounds and lost rows".
            caps: MacLookCompileCaps(
                truncated: percept.truncated,
                maxAffordances: Self.intValue(body, "max_affordances")
                    ?? MacPerceptionCompiler.maxAffordances,
                maxNodes: limits.maxNodes,
                maxDepth: limits.maxDepth
            )
        ))

        if grade == "look" {
            // `bytes` is the WHOLE payload she receives, measured with the
            // field itself in place — the number is the truth, not an estimate.
            var measured = output
            // Fixpoint, because the number's own digits are part of the
            // payload: write the measured size, re-measure, repeat until it
            // stops moving (two passes in practice, three at a digit boundary).
            measured["bytes"] = .int(0)
            var claimed = serializedSize(measured)
            for _ in 0..<4 {
                measured["bytes"] = .int(Int64(claimed))
                let actual = serializedSize(measured)
                if actual == claimed { break }
                claimed = actual
            }
            output["bytes"] = .int(Int64(claimed))
            let exact = serializedSize(output)
            if exact > MacPerceptionCompiler.lookByteBudget {
                // Never silently over budget: an envelope alone can exceed it
                // (a pathological window title), and a caller sizing its context
                // must be told rather than surprised.
                output["byte_budget_exceeded"] = .bool(true)
                output["byte_budget"] = .int(Int64(MacPerceptionCompiler.lookByteBudget))
            }
        }
        return MacControlResult(
            ok: true,
            action: "look",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// The `ax_find` query, echoed back with its free-text fields shape-tested.
    /// `role` is an AX role constant (`AXButton`), never user text, so it rides
    /// out as-is — redacting it would break the caller's ability to see what it
    /// asked for with no secret to protect.
    static func redactedQueryJSON(_ query: MacAXQuery, valueChars: Int) -> JSONValue {
        func redacted(_ text: String?) -> JSONValue {
            guard let text else { return .null }
            return MacScreenViewTextRedaction.redactedLegendString(text, valueChars: valueChars)
        }
        return .object([
            "role": query.role.map { .string($0) } ?? .null,
            "title": redacted(query.title),
            "value": redacted(query.value),
        ])
    }

    func handleAXFind(_ body: [String: JSONValue]) throws -> MacControlResult {
        let started = now()
        let query = MacAXQuery(
            role: body.stringValue("role"),
            title: body.stringValue("title"),
            value: body.stringValue("value")
        )
        if query.isEmpty {
            throw MacControlError.missingField("role|title|value")
        }
        guard accessibilitySource.isTrusted() else { return axUntrustedResult(action: "ax_find") }
        // Search the SAME bounded tree ax_tree returns: node/depth caps stay
        // hard, and the truncation state rides along so a zero-match answer is
        // distinguishable from "the button was past the cap".
        let limits = Self.axLimits(from: body)
        let anchored = axSnapshot(limits: limits)
        if case .selfProcess = anchored {
            return selfInspectionResult(action: "ax_find", started: started)
        }
        guard case .read(let read) = anchored else {
            return MacControlResult(
                ok: false,
                action: "ax_find",
                output: .object([
                    "trusted": .bool(true),
                    "status": .string("no_frontmost_window"),
                    "error": .string("no_frontmost_window"),
                ]),
                error: "no_frontmost_window",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true
            )
        }
        let matches = MacAccessibilityReader.find(
            nodes: read.snapshot.nodes,
            query: query,
            limits: limits
        )
        var output: [String: JSONValue] = Self.axTruncationJSON(read.snapshot, limits: limits)
        output["trusted"] = .bool(true)
        output["app"] = read.app?.toJSON() ?? .null
        // W3.5-FIX-R4 — the CALLER's own words are an egress too. A model that
        // just read a code off the screen and calls
        // `mac_ax_find(value: "482913")` to locate the field puts that code
        // back into a tool result that is traced, persisted and synced — the
        // redaction on the way OUT is undone by the echo on the way IN. Same
        // standalone shape test as every other channel, so a non-secret query
        // ("Send", "AXButton") stays legible and the echo stays useful.
        output["query"] = Self.redactedQueryJSON(query, valueChars: limits.valueChars)
        output["searched"] = .int(Int64(read.snapshot.nodes.count))
        output["count"] = .int(Int64(matches.count))
        output["max_matches"] = .int(Int64(limits.maxMatches))
        // W3.5-FIX-R3 — a match is a node, so it leaks the same way. The
        // caption context is built from the WHOLE snapshot, not just the
        // matched set: a "2FA code" label that the query did not match still
        // names the value it sits above.
        output["matches"] = .array(
            MacScreenViewTextRedaction.redactedMatchesJSON(
                matches,
                valueChars: limits.valueChars,
                context: MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes)
            )
        )
        return MacControlResult(
            ok: true,
            action: "ax_find",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    // MARK: the fused view (W3.5)

    /// `view` — ONE frozen scene: the picture and the structure together, with
    /// every actionable element numbered on the image and the same number bound
    /// to its real AX path in the legend.
    ///
    /// The two perceptions are taken as close together as the machine allows
    /// (window rect → capture → AX walk, all in-process) and the residual gap
    /// is REPORTED as `fusion_gap_ms` rather than claimed to be zero. A stale
    /// pairing — marks drawn from one moment onto a picture from another — is
    /// the bug this whole tool exists to avoid, so the honest number matters:
    /// a large gap is a reason to look again, and only the caller can judge it.
    ///
    /// PARTIAL PERCEPTION IS STILL PERCEPTION. The two permissions are
    /// independent, so all four combinations return something true:
    ///   • AX + Screen Recording → the fused view.
    ///   • AX only              → the legend with no picture, and the reason.
    ///   • Screen Recording only → the picture with no marks, and the reason
    ///     (this is also the canvas/game/video case — point at a coordinate).
    ///   • neither              → both flags false and how to grant them.
    func handleView(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let viewStartedNs = DispatchTime.now().uptimeNanoseconds
        func cancelledResult() -> MacControlResult {
            MacControlResult(
                ok: false, action: "view",
                output: .object([
                    "view": .null, "view_current": .bool(false), "image": .null,
                    "view_note": .string("This screen request was cancelled; no new view was published."),
                ]),
                error: "view_capture_cancelled",
                durationMs: Int(now().timeIntervalSince(started) * 1000), viaSwift: true
            )
        }
        guard !Task.isCancelled else { return cancelledResult() }
        let captureTicket = await screenViewStore.beginCapture()
        func cancelCapture() async -> MacControlResult {
            await screenViewStore.cancelCapture(captureTicket)
            return cancelledResult()
        }
        guard !Task.isCancelled else { return await cancelCapture() }
        func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int64 {
            Int64((end &- start) / 1_000_000)
        }
        // The four-verb semantic screen consumes the same frozen capture as
        // mac_view, but its visual compiler must see the world rather than the
        // human-facing numbered ink we draw on top of it. This is an internal
        // rendering choice only: geometry, AX marks, redaction, permissions,
        // view storage, and the public result contract remain unchanged.
        let semanticRawFrame = body["semantic_raw_frame"] == .bool(true)
        let semanticFocusVisualSurface = body["semantic_focus_visual_surface"] == .bool(true)
        let scope: MacScreenCaptureScope = {
            if case .bool(true)? = body["full_screen"] { return .fullScreen }
            if (body.stringValue("scope") ?? "").lowercased() == "full_screen" { return .fullScreen }
            return .focusedWindow
        }()
        let limits = Self.axLimits(from: body)
        let maxMarks = Self.intValue(body, "max_marks") ?? MacScreenViewBuilder.hardMaxMarks
        let maxImageBytes = min(
            Self.intValue(body, "max_image_bytes") ?? MacScreenViewBuilder.hardMaxImageBytes,
            MacScreenViewBuilder.hardMaxImageBytes
        )

        let accessibilityTrusted = accessibilitySource.isTrusted()
        let screenTrusted = screenCaptureSource.isScreenRecordingTrusted()

        // 1. Where to look. The window rect comes from AX (the root node's own
        //    frame), so the capture is exactly the window — not a guessed crop.
        let axSnapshotStartedNs = DispatchTime.now().uptimeNanoseconds
        var windowRect: MacAXFrame?
        var app: MacAXAppInfo?
        var windowTitle: String?
        var snapshot: MacAXTreeSnapshot?
        var windowIdentity: MacAXWindowIdentity?
        var axSelfRefused = false
        if accessibilityTrusted {
            switch axSnapshot(limits: limits) {
            case .read(let read):
                snapshot = read.snapshot
                windowIdentity = read.windowIdentity
                app = read.app
                windowTitle = read.rootTitle
                windowRect = read.snapshot.nodes.first?.attributes.frame
            case .selfProcess:
                // The view degrades to pixels-only, like an untrusted AX read:
                // the capture is still honest, only the tree is refused.
                axSelfRefused = true
            case .appGone, .windowGone, .windowDrifted:
                break
            }
        }
        let transientMenus = app.map {
            MacTransientMenus.read(source: accessibilitySource, pid: $0.processIdentifier)
        } ?? []
        let axSnapshotFinishedNs = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled else { return await cancelCapture() }
        let captureRect: MacAXFrame? = (scope == .fullScreen) ? nil
            : MacTransientMenus.captureFrame(window: windowRect, menus: transientMenus)
        let capturedAt = now()
        let screenCaptureStartedNs = DispatchTime.now().uptimeNanoseconds
        let capture = await screenCaptureSource.capture(rect: captureRect)
        guard !Task.isCancelled else { return await cancelCapture() }
        let screenCaptureFinishedNs = DispatchTime.now().uptimeNanoseconds
        let observedPointer = pointerPositionSource.currentPosition()
        let fusionGapMs = Int(abs(now().timeIntervalSince(capturedAt)) * 1000)

        var output: [String: JSONValue] = [
            "accessibility_trusted": .bool(accessibilityTrusted),
            "screen_recording_trusted": .bool(screenTrusted),
            "scope": .string(scope.rawValue),
            "app": app?.toJSON() ?? .null,
            "transient_menus": MacTransientMenus.json(transientMenus),
            "pointer": observedPointer?.json ?? .null,
            // W3.5-FIX-R2 2 — the window title is visible screen text, but the
            // root AXWindow is not a TEXT role, so it never enters
            // `visibleText` and the source redaction never saw it. A title is
            // routinely the secret itself ("1Password — Recovery Code", a
            // terminal window titled with the token it just printed, a browser
            // tab whose title is the OTP), and it rode out raw into every
            // mac_view sink. Same standalone shape redactor as the legend.
            "window_title": windowTitle.map {
                MacScreenViewTextRedaction.redactedLegendString(
                    $0,
                    valueChars: limits.valueChars
                )
            } ?? .null,
            "fusion_gap_ms": .int(Int64(fusionGapMs)),
            "ax_snapshot_ms": .int(elapsedMilliseconds(
                from: axSnapshotStartedNs, to: axSnapshotFinishedNs
            )),
            "screen_capture_ms": .int(elapsedMilliseconds(
                from: screenCaptureStartedNs, to: screenCaptureFinishedNs
            )),
        ]
        if !accessibilityTrusted {
            output["accessibility_note"] = .string(MacAccessibilityReader.notTrustedNote)
        }
        if axSelfRefused {
            output["accessibility_note"] = .string(Self.selfInspectionNote)
        }
        if !screenTrusted {
            output["screen_recording_note"] = .string(Self.screenRecordingNote)
        }

        // 2. The geometry the whole fusion hangs on. With no picture there is
        //    still a frame of reference: the window rect itself, at 1 point per
        //    pixel — so the legend is complete and only the drawing is missing.
        let shot: MacScreenShot?
        var imageFailure: MacScreenCaptureFailure?
        switch capture {
        case .success(let value): shot = value
        case .failure(let failure):
            shot = nil
            imageFailure = failure
        }
        let geometry: MacScreenViewGeometry? = {
            if let shot { return MacScreenViewGeometry(shot: shot) }
            guard let rect = captureRect ?? windowRect, rect.w > 0, rect.h > 0 else { return nil }
            return MacScreenViewGeometry(
                bounds: rect,
                pixelWidth: Int(rect.w.rounded()),
                pixelHeight: Int(rect.h.rounded())
            )
        }()

        // 3. Number the actionable elements, and read what the window SAYS.
        //
        // THE EFFORTLESS-VISION ORDERING (User, 2026-08-12): the structured
        // channel is her primary vision — text she reads losslessly — and the
        // picture is the spatial backdrop it rides on. So both halves of the
        // structure are built even when there is no image at all: the numbered
        // controls AND the prose. The bar is "could she act correctly from the
        // legend alone", and a legend with no prose fails it — a set of
        // controls with no idea what the window says is not seeing the screen.
        let sceneSelectionStartedNs = DispatchTime.now().uptimeNanoseconds
        var selection = MacScreenViewBuilder.Selection(marks: [], omitted: 0, offscreen: 0)
        var text = MacScreenViewBuilder.TextSelection(items: [], omitted: 0)
        if let snapshot, let geometry {
            selection = MacScreenViewBuilder.select(
                nodes: snapshot.nodes,
                geometry: geometry,
                maxMarks: maxMarks
            )
            text = MacScreenViewBuilder.visibleText(
                nodes: snapshot.nodes,
                geometry: geometry,
                limit: Self.intValue(body, "max_text_items") ?? MacScreenViewBuilder.hardMaxTextItems
            )
        }
        let sceneSelectionFinishedNs = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled else { return await cancelCapture() }

        // 4. Draw them, under the byte cap. Pixel-first semantic perception
        // gets the dominant canvas/image cropped from the native capture BEFORE
        // PNG fitting. Otherwise a high-entropy moving canvas spends the whole
        // window's byte budget before OCR ever sees its small status text.
        var imageDownscale: Double?
        var imageBytes: Int?
        let imageRenderStartedNs = DispatchTime.now().uptimeNanoseconds
        if let shot, let geometry {
            let semanticFocusFrame = semanticFocusVisualSurface
                ? snapshot.flatMap {
                    MacScreenViewBuilder.dominantVisualSurface(nodes: $0.nodes, geometry: geometry)
                }
                : nil
            #if canImport(CoreGraphics)
            let renderShot = semanticFocusFrame.flatMap { shot.cropped(to: $0) } ?? shot
            #else
            let renderShot = shot
            #endif
            let renderGeometry = MacScreenViewGeometry(shot: renderShot)
            let placements = semanticRawFrame
                ? []
                : selection.marks.compactMap {
                    renderGeometry.placement(mark: $0.mark, frame: $0.frame)
                }
            let fitted = MacScreenViewBuilder.fitImage(maxBytes: maxImageBytes) { rung in
                guard !Task.isCancelled else { return nil }
                return screenImageRenderer.renderPNG(shot: renderShot, placements: placements, downscale: rung)
            }
            guard !Task.isCancelled else { return await cancelCapture() }
            if let fitted {
                output["image"] = .string(fitted.data.base64EncodedString())
                output["image_format"] = .string("png")
                output["image_annotations"] = .bool(!semanticRawFrame)
                imageDownscale = fitted.downscale
                imageBytes = fitted.data.count
                output["image_origin"] = .object([
                    "x": .double(renderGeometry.bounds.x),
                    "y": .double(renderGeometry.bounds.y),
                ])
                output["image_logical_size"] = .object([
                    "w": .double(renderGeometry.bounds.w),
                    "h": .double(renderGeometry.bounds.h),
                ])
                output["image_pixel_size"] = .object([
                    "w": .int(Int64(renderGeometry.pixelWidth)),
                    "h": .int(Int64(renderGeometry.pixelHeight)),
                ])
                output["semantic_focus_frame"] = semanticFocusFrame.map { frame in
                    .object([
                        "x": .double(frame.x), "y": .double(frame.y),
                        "w": .double(frame.w), "h": .double(frame.h),
                    ])
                } ?? .null
            } else {
                imageFailure = .exceedsByteCap
            }
        }
        let imageRenderFinishedNs = DispatchTime.now().uptimeNanoseconds
        output["image_render_ms"] = .int(elapsedMilliseconds(
            from: imageRenderStartedNs, to: imageRenderFinishedNs
        ))
        if output["image"] == nil {
            output["image"] = .null
            output["image_unavailable_reason"] = .string(
                (imageFailure ?? .captureFailed).rawValue
            )
        }
        output["image_bytes"] = imageBytes.map { .int(Int64($0)) } ?? .null
        output["image_downscale"] = imageDownscale.map { .double($0) } ?? .null
        output["max_image_bytes"] = .int(Int64(maxImageBytes))

        if let geometry {
            output["logical_size"] = .object([
                "w": .double(geometry.bounds.w),
                "h": .double(geometry.bounds.h),
            ])
            output["origin"] = .object([
                "x": .double(geometry.bounds.x),
                "y": .double(geometry.bounds.y),
            ])
            output["scale"] = .double(geometry.reportedScale)
            if output["image_pixel_size"] == nil {
                output["image_pixel_size"] = .object([
                    "w": .int(Int64(geometry.pixelWidth)),
                    "h": .int(Int64(geometry.pixelHeight)),
                ])
            }
        }

        // 5. Remember it, so `mark` can be resolved — and hand back its id.
        //    The id is the ONLY way to address these numbers later; an older
        //    one is refused rather than silently re-interpreted.
        guard !Task.isCancelled else { return await cancelCapture() }
        let viewId = UUID().uuidString
        let viewCurrent = await screenViewStore.record(MacScreenViewSnapshot(
            viewId: viewId,
            capturedAt: capturedAt,
            scope: scope,
            bounds: geometry?.bounds ?? MacAXFrame(x: 0, y: 0, w: 0, h: 0),
            appName: app?.name,
            windowTitle: windowTitle,
            marks: selection.marks,
            windowIdentity: windowIdentity
        ), captureTicket: captureTicket)
        if !viewCurrent && Task.isCancelled { return await cancelCapture() }
        output["view"] = viewCurrent ? .string(viewId) : .null
        output["view_current"] = .bool(viewCurrent)
        if !viewCurrent {
            output["view_note"] = .string("This capture was superseded or invalidated while in flight. Its image and legend are diagnostic only; take a fresh view before acting.")
        }
        output["captured_at"] = .string(ISO8601DateFormatter().string(from: capturedAt))
        // Motion perception needs subsecond frame spacing. Keep the legacy
        // human timestamp, but never round the machine observation clock.
        output["captured_at_epoch_seconds"] = .double(capturedAt.timeIntervalSince1970)
        output["view_ttl_seconds"] = .int(Int64(MacScreenViewStore.ttlSeconds))
        output["marks"] = .array(selection.marks.map { $0.toJSON(valueChars: limits.valueChars) })
        output["mark_count"] = .int(Int64(selection.marks.count))
        output["marks_omitted"] = .int(Int64(selection.omitted))
        output["marks_offscreen"] = .int(Int64(selection.offscreen))
        output["max_marks"] = .int(Int64(max(1, min(maxMarks, MacScreenViewBuilder.hardMaxMarks))))
        output["text"] = .array(text.items.map { $0.toJSON(valueChars: limits.valueChars) })
        output["text_omitted"] = .int(Int64(text.omitted))
        if let snapshot {
            output["ax_truncated"] = .bool(snapshot.truncated)
            output["ax_truncation_reasons"] = .array(snapshot.truncationReasons.map { .string($0) })
            output["ax_skipped_at_least"] = .int(Int64(snapshot.skippedAtLeast))
        }
        // ONE honest headline: anything the caller did not get to see.
        output["truncated"] = .bool(
            selection.truncated
                || text.omitted > 0
                || (snapshot?.truncated ?? false)
                || output["image"] == .null
        )
        output["how_to_read"] = .string(
            "`marks` and `text` ARE the view — they describe every control and everything the "
            + "window says, losslessly. Read them first; the image is the spatial backdrop showing "
            + "where each numbered thing sits, not something you need to decode to know what is "
            + "there. A mark with label_source \"nearby_text\" was named by inference from the text "
            + "beside it, and one with label_source \"none\" has no name the app publishes."
        )
        output["how_to_act"] = .string(
            "Act by NUMBER, not by coordinate: mac_ax_act {mark: N, view: \"\(viewId)\"} presses "
            + "the element the app's own way, mac_click {mark: N, view: \"\(viewId)\"} clicks its "
            + "centre. Coordinates are for the parts of the picture "
            + "with no marks (canvas, game, video). Marks are only valid for THIS view."
        )
        let viewFinishedNs = DispatchTime.now().uptimeNanoseconds
        output["scene_selection_ms"] = .int(elapsedMilliseconds(
            from: sceneSelectionStartedNs, to: sceneSelectionFinishedNs
        ))
        output["post_render_ms"] = .int(elapsedMilliseconds(
            from: imageRenderFinishedNs, to: viewFinishedNs
        ))
        output["view_total_ms"] = .int(elapsedMilliseconds(
            from: viewStartedNs, to: viewFinishedNs
        ))
        // ok reflects whether ANY perception came back. Both permissions off is
        // a real failure; either one on is a real answer.
        let ok = viewCurrent && (accessibilityTrusted || output["image"] != .null)
        return MacControlResult(
            ok: ok,
            action: "view",
            output: .object(output),
            error: ok ? nil : (viewCurrent ? "no_perception_available" : "view_capture_superseded"),
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true
        )
    }

    /// `mac_attention` — explicit, bounded continuity over `mac_view`.
    ///
    /// There is no frame loop and no model call here. Start installs passive
    /// system-event observers for a bounded lifetime and takes one fused view.
    /// Next sleeps on an event continuation (or its bounded deadline), then
    /// takes exactly one more fused view. Stop tears the observers down and
    /// invalidates the last attention-scene marks.
    func handleAttention(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()
        let mode = (body.stringValue("mode") ?? "status").lowercased()

        func result(
            ok: Bool,
            output: [String: JSONValue],
            error: String? = nil,
            status: Int? = nil
        ) -> MacControlResult {
            MacControlResult(
                ok: ok,
                action: "attention",
                output: .object(output),
                error: error,
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true,
                httpStatus: status
            )
        }

        switch mode {
        case "start":
            let duration = Self.intValue(body, "duration_seconds")
                ?? MacAttentionSessionStore.defaultDurationSeconds
            await screenViewStore.invalidate()
            guard let initial = await attentionStore.start(
                durationSeconds: duration,
                now: now(),
                eventSource: attentionEventSource
            ) else {
                return result(
                    ok: false,
                    output: [
                        "active": .bool(false),
                        "status": .string("unavailable"),
                    ],
                    error: "attention_observer_unavailable",
                    status: 501
                )
            }
            return await attentionViewResult(
                body: body,
                pending: initial,
                started: started,
                status: "started"
            )

        case "next":
            guard let sessionId = body.stringValue("session"), !sessionId.isEmpty else {
                return result(
                    ok: false,
                    output: ["active": .bool(false), "status": .string("invalid_request")],
                    error: "missing required field: session",
                    status: 400
                )
            }
            let after = Int64(Self.intValue(body, "after_sequence") ?? -1)
            let waitMs = Self.intValue(body, "wait_ms") ?? 1_500
            let pending = await attentionStore.waitForActivity(
                sessionId: sessionId,
                after: after,
                timeoutMilliseconds: waitMs,
                now: now()
            )
            if Task.isCancelled {
                return result(
                    ok: false,
                    output: ["active": .bool(true), "status": .string("cancelled")],
                    error: "attention_wait_cancelled",
                    status: 499
                )
            }
            guard let pending else {
                return result(
                    ok: false,
                    output: ["active": .bool(false), "status": .string("not_active")],
                    error: "attention_session_not_active",
                    status: 409
                )
            }
            return await attentionViewResult(
                body: body,
                pending: pending,
                started: started,
                status: pending.timedOutWaiting ? "refreshed" : "changed"
            )

        case "status":
            guard let current = await attentionStore.status(now: now()) else {
                return result(ok: true, output: [
                    "active": .bool(false),
                    "status": .string("idle"),
                ])
            }
            return result(ok: true, output: [
                "active": .bool(true),
                "status": .string(
                    current.yieldRequired ? "yield_required"
                        : (current.refreshRequired ? "refresh_required" : "watching")
                ),
                "attention": current.toJSON(),
            ])

        case "stop":
            let wasActive = await attentionStore.stop()
            await screenViewStore.invalidate()
            return result(ok: true, output: [
                "active": .bool(false),
                "status": .string(wasActive ? "stopped" : "already_idle"),
            ])

        default:
            return result(
                ok: false,
                output: ["active": .bool(false), "status": .string("invalid_request")],
                error: "invalid mode: expected start, next, status, or stop",
                status: 400
            )
        }
    }

    private func attentionViewResult(
        body: [String: JSONValue],
        pending: MacAttentionSnapshot,
        started: Date,
        status: String
    ) async -> MacControlResult {
        let view = await handleView(body)
        guard case .object(var output) = view.output,
              case .string(let viewId)? = output["view"] else {
            return MacControlResult(
                ok: false,
                action: "attention",
                output: view.output,
                error: view.error ?? "attention_view_unavailable",
                durationMs: Int(now().timeIntervalSince(started) * 1000),
                viaSwift: true,
                httpStatus: view.httpStatus
            )
        }
        let current = await attentionStore.observed(
            sessionId: pending.sessionId,
            viewId: viewId,
            sequence: pending.sequence,
            userSequence: pending.userSequence,
            now: now()
        ) ?? pending
        if current.refreshRequired {
            // Input raced the capture. Never leave its marks usable while the
            // result truthfully says the agent must yield and look again.
            await screenViewStore.invalidate()
        }
        output["status"] = .string(
            current.yieldRequired ? "yield_required"
                : (current.refreshRequired ? "refresh_required" : status)
        )
        output["attention"] = current.toJSON()
        output["how_to_continue"] = .string(
            "While this attention session is active, pass attention_session and "
            + "attention_user_sequence from this result to every Mac action. If yield_required "
            + "is true, do not act; call mac_attention next and re-read the fresh fused view."
        )
        return MacControlResult(
            ok: view.ok,
            action: "attention",
            output: .object(output),
            error: view.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            viaSwift: true,
            httpStatus: view.httpStatus
        )
    }

    static let screenRecordingNote =
        "NativeAgent does not have Screen Recording permission yet, so the picture half of the "
        + "view is missing (the accessibility legend still works). Grant it in System Settings → "
        + "Privacy & Security → Screen Recording (toggle NativeAgent on) and restart the app. "
        + "Only you can grant this — the app cannot toggle it. This is a SEPARATE permission from "
        + "Accessibility."

}
