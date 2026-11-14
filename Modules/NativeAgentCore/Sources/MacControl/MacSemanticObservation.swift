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
// Blueprint: | `MacSemanticObservation.swift` | Shared semantic reads and exact-node search; named stopped/windowless apps report absence without launch |
extension SwiftNativeMacControl {
    /// Prepare renderer capabilities before the shared walk; native windows return immediately. Cold renderers wait on AX notifications, but only observed
    /// content growth renews the stall deadline. Activation belongs to the AX source; notifications never certify actions, and post-act reads retain the
    /// acted-window anchor.
    func lookSnapshot(
        limits: MacAXLimits,
        scope: MacLookScope = .page,
        anchorPid: Int32? = nil,
        anchorWindow: MacAXWindowIdentity? = nil,
        completeWindow: Bool = false,
        section: String? = nil,
        context: MacOperationContext
    ) async -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
        var seam: [String: JSONValue] = [
            "chromium_family": .bool(false),
            "enhanced_ax_set": .bool(false),
            "rewalked": .bool(false),
        ]
        // Resolve the app before walking; Chromium’s AXWebArea appears only after activation.
        let pid = anchorPid ?? anchorWindow?.pid ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier
        if PersonOnlyWindows.isOwnProcess(pid) { return (nil, seam, .selfProcess) }
        let app = pid.flatMap { accessibilitySource(context: context).appInfo(pid: $0) }
        let chromium: Bool
        do { chromium = try MacChromiumAccessibility.looksChromium(bundleId: app?.bundleIdentifier, pid: pid, snapshot: nil) }
        catch { return (nil, seam, .rendererUnavailable(error.localizedDescription)) }
        #if canImport(ApplicationServices) && os(macOS)
        var rendererEvents: MacAppSourceEvents?
        var observationError: Error?
        defer { rendererEvents?.cancel() }
        if accessibilitySource(context: context) is SystemMacAXElementSource, let pid {
            do { try await SystemMacAXElementSource.prepareRenderer(pid: pid, context: context) }
            catch {
                seam["renderer_activation"] = .object(MacChromiumAccessibilityState.shared.evidence(pid: pid))
                seam["renderer_wait_note"] = .string(error.localizedDescription)
                // Preserve the cause; a failed preparation is not zero windows.
                return (nil, seam, .rendererUnavailable(error.localizedDescription))
            }
            let evidence = MacChromiumAccessibilityState.shared.evidence(pid: pid)
            seam["renderer_activation"] = context.observationMode == .passive
                ? .object(["status": .string("passive_unchanged")]) : .object(evidence)
            seam["enhanced_ax_set"] = .bool(evidence["status"] == .string("enabled"))
            if chromium {
                seam["chromium_family"] = .bool(true)
                seam["complete_window"] = .bool(true)
            }
        }
        #endif
        func anchoredRead() -> MacAnchoredRead {
            anchoredSnapshot(limits: limits, pid: pid, window: anchorWindow, complete: completeWindow || chromium, section: section, context: context)
        }
        let firstAnchor = anchoredRead()
        #if canImport(ApplicationServices) && os(macOS)
        if accessibilitySource(context: context) is SystemMacAXElementSource, let pid, context.observationMode != .passive {
            seam["renderer_activation"] = .object(MacChromiumAccessibilityState.shared.evidence(pid: pid))
        }
        #endif
        // Self-process targets must explain refusal on anchored and unanchored reads rather than claim no window.
        if case .selfProcess = firstAnchor { return (nil, seam, firstAnchor) }
        if case .rendererUnavailable = firstAnchor { return (nil, seam, firstAnchor) }
        let read: MacAXRead? = {
            if case .read(let hit) = firstAnchor { return hit }
            return nil
        }()
        // Only anchored reads can report a lost anchor; unanchored reads never owned one.
        let anchorFailure: MacAnchoredRead? = {
            guard anchorPid != nil || anchorWindow != nil else { return nil }
            if case .read = firstAnchor { return nil }
            return firstAnchor
        }()
        if anchorFailure != nil { return (nil, seam, anchorFailure) }
        /// Page-first descent works on any source; only enhanced-AX activation requires a live app.
        func scoped(
            _ candidate: (read: MacAXRead?, seam: [String: JSONValue])
        ) -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
            guard let value = candidate.read else { return (nil, candidate.seam, nil) }
            let outcome: (read: MacAXRead, seam: [String: JSONValue])
            do { outcome = try pageScoped(value, limits: limits, scope: scope, completeWindow: completeWindow, context: context) }
            catch { return (nil, candidate.seam, .rendererUnavailable(error.localizedDescription)) }
            var merged = candidate.seam
            for (key, item) in outcome.seam { merged[key] = item }
            return (outcome.read, merged, nil)
        }
        #if canImport(ApplicationServices) && os(macOS)
        // Only live sources have app elements to activate; unavailable sources cannot claim preparation ran.
        guard accessibilitySource(context: context) is SystemMacAXElementSource else { return scoped((read, seam)) }
        // Minimized windows may expose empty shells rather than readable content.
        if let read, let source = accessibilitySource(context: context) as? SystemMacAXElementSource,
           let window = source.element(read.root),
           MacAXAttributeRead.copyBool(window, kAXMinimizedAttribute, context: context) == true {
            seam["window_minimized"] = .bool(true)
            return (read, seam, nil)
        }
        guard let pid, chromium
        else { return scoped((read, seam)) }
        let rendererWindow = read?.windowIdentity
        func rendererRead() -> MacAnchoredRead {
            anchoredSnapshot(limits: limits, pid: pid, window: rendererWindow, complete: true, section: section, context: context)
        }
        var result = scoped((read, seam))
        func rendererReady(_ inspected: (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?)) -> Bool {
            guard let read = inspected.read else { return false }
            let areas = read.snapshot.nodes.filter { $0.attributes.role == "AXWebArea" }
            // Native Chromium windows have no renderer to await.
            guard !areas.isEmpty else { return true }
            // Each renderer owns readiness; a ready sidebar cannot certify a hollow sibling, and loaded blank documents remain valid.
            guard let source = accessibilitySource(context: context) as? SystemMacAXElementSource else { return false }
            return areas.allSatisfy { area in
                // Read existing content even while busy; sibling text cannot certify this area.
                if read.snapshot.nodes.contains(where: { node in
                    node.path.count > area.path.count && node.path.starts(with: area.path)
                        && [node.attributes.title, node.attributes.value].contains {
                            !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        }
                }) { return true }
                guard let ref = area.element else { return false }
                let state: (loaded: Bool?, busy: Bool?) = MacAXExecutionLane.sync {
                    guard let element = source.element(ref) else { return (nil, nil) }
                    return (MacAXAttributeRead.copyBool(element, "AXLoaded", context: context),
                            MacAXAttributeRead.copyBool(element, kAXElementBusyAttribute, context: context))
                }
                return state.loaded == true && state.busy != true
            }
        }
        // Track renderer-local growth by live identity, excluding chrome, loading titles and rearrangements; sibling shrinkage cannot hide growth.
        func rendererContent(_ inspected: (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?)) -> [(element: AXUIElement, nodes: Int,
            textBytes: Int)] {
            guard let read = inspected.read,
                  let source = accessibilitySource(context: context) as? SystemMacAXElementSource else { return [] }
            let areas = read.snapshot.nodes.filter { $0.attributes.role == "AXWebArea" }
            var content: [(element: AXUIElement, nodes: Int, textBytes: Int)] = []
            for area in areas {
                guard let ref = area.element,
                      let element = MacAXExecutionLane.sync({ source.element(ref) }) else { continue }
                let descendants = read.snapshot.nodes.filter {
                    $0.path.count > area.path.count && $0.path.starts(with: area.path)
                }
                let textBytes = descendants.reduce(0) { total, node in
                    total + (node.attributes.title?.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count ?? 0)
                        + (node.attributes.value?.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count ?? 0)
                }
                content.append((element, descendants.count, textBytes))
            }
            return content
        }
        // Readiness and returned pages need the same complete window walk, not shallow counts of empty groups.
        func readyResult(_ ready: (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?)) -> (read: MacAXRead?, seam: [String: JSONValue],
            anchor: MacAnchoredRead?) {
            guard let read = ready.read else { return ready }
            if !MacChromiumAccessibility.hasWebArea(read.snapshot) {
                // No observed renderer is not proof of a loaded document; report shell boundaries while leaving native windows immediate.
                var native = ready
                native.seam["enhanced_ax_content"] = .string("no_renderer_tree")
                if context.observationMode == .passive, native.seam["enhanced_ax_set"] != .bool(true) {
                    native.seam["renderer_wait_note"] = .string(
                        "raw view · passive observation · Renderer accessibility is not enabled; observation waits for the app's exposed content.")
                }
                // Native windows are immediate complete AX reads, not renderer failures.
                return native
            }
            var settled = ready
            settled.seam["enhanced_ax_content"] = .string("available")
            if settled.seam["scope_reason"] == .string("enhanced_ax_pending") {
                settled.seam.removeValue(forKey: "scope_reason")
                settled.seam.removeValue(forKey: "scope_note")
            }
            return settled
        }
        if scope == .chrome { return result }
        if rendererReady(result) { return readyResult(result) }
        func unavailable(_ status: String, _ note: String) -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
            var reported = result
            reported.seam["renderer_wait"] = .string(status)
            reported.seam["enhanced_ax_content"] = .string(status)
            reported.seam["scope_reason"] = .string("enhanced_ax_" + status)
            reported.seam["scope_note"] = .string(note)
            reported.seam["renderer_wait_note"] = .string("raw view · accessibility · " + note)
            return reported
        }
        if context.readDeadline.map({ Date() >= $0 }) == true {
            return unavailable("time_budget", "partial: budget reached; this is only the accessibility content read so far.")
        }
        if rendererEvents == nil {
            // Renderer notifications may become available only after activation; finish registration and reread to close that race.
            do { rendererEvents = try MacAppSourceEvents(pid: pid, context: context) }
            catch { observationError = error }
        }
        guard let rendererEvents else {
            return unavailable("observation_unavailable",
                """
                    The renderer's content could not be awaited because app accessibility notifications are unavailable: \
                    \(observationError?.localizedDescription ?? "no observer").
                    """)
        }
        var previousContent = rendererContent(result)
        rendererEvents.watchContentStall(seconds: MacChromiumAccessibility.rendererStallSeconds, context: context)
        return await withTaskCancellationHandler {
            do {
                // Registration yields; its immediate reread closes the install race before callbacks or stall expiry drive further reads.
                for try await _ in rendererEvents.stream {
                    try Task.checkCancellation()
                    result.seam["ax_watch_coverage"] = rendererEvents.coverage
                    if context.readDeadline.map({ Date() >= $0 }) == true {
                        return unavailable("time_budget", "partial: budget reached; this is only the accessibility content read so far.")
                    }
                    let changedAnchor = rendererRead()
                    guard case .read(let changed) = changedAnchor else { return (nil, seam, changedAnchor) }
                    result = scoped((changed, seam))
                    result.seam["ax_watch_coverage"] = rendererEvents.coverage
                    if rendererReady(result) { return readyResult(result) }
                    let content = rendererContent(result)
                    let grew = MacAXExecutionLane.sync {
                        content.contains { current in
                            guard let previous = previousContent.first(where: { CFEqual($0.element, current.element) }) else {
                                return current.nodes > 0 || current.textBytes > 0
                            }
                            return current.nodes > previous.nodes || current.textBytes > previous.textBytes
                        }
                    }
                    previousContent = content
                    if grew {
                        rendererEvents.noteContentGrowth()
                    }
                    if rendererEvents.contentStalled {
                        return unavailable("stalled",
                            """
                                The renderer did not expose ready content and its accessibility subtree gained no nodes or text for \
                                \(Int(MacChromiumAccessibility.rendererStallSeconds)) seconds. This is its current accessibility tree.
                                """)
                    }
                }
                throw CancellationError()
            } catch is CancellationError {
                return unavailable("cancelled", "The renderer read was cancelled before ready content arrived. This is its current accessibility tree.")
            } catch {
                return unavailable("observation_unavailable",
                    """
                        The renderer's accessibility observation stopped before ready content arrived: \(error.localizedDescription). This is its current \
                        accessibility tree.
                        """)
            }
        } onCancel: {
            rendererEvents.cancel()
        }
        #else
        return scoped((read, seam))
        #endif
    }
    /// All grades share one walk; delegate stare to handleAXTree so full-tree semantics cannot drift.
    func handleLook(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        await lookFrameStore.read(context: context) { await self.captureLook(body, turn: turn, context: context) }
    }
    private func captureLook(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> (MacControlResult, MacLookFrame?) {
        var capturedFrame: MacLookFrame?
        let started = now()
        let grade = (body["grade"]?.stringValue ?? "look").lowercased()
        guard ["glance", "look", "stare"].contains(grade) else {
            return (MacControlResult(
                ok: false,
                action: "look",
                output: .object([
                    "error": .string("unknown_grade"),
                    "grade": .string(grade),
                    "message": .string("grade must be one of: glance, look, stare"),
                ]),
                error: "unknown_grade",
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            ), nil)
        }
        guard accessibilitySource(context: context).isTrusted() else { return (axUntrustedResult(action: "look"), nil) }
        // Named-app reads never focus, launch or raise the app.
        var anchorPid: Int32?
        var anchoredApp: MacAXAppInfo?
        if let requested = body["app"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard grade != "stare" else {
                return (MacControlResult(
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
                    durationMs: Int(now().timeIntervalSince(started) * 1000)
                ), nil)
            }
            let resolution = MacBackgroundSight.resolve(
                requested,
                among: accessibilitySource(context: context).runningApps()
            )
            guard case .matched(let app) = resolution else {
                let words = MacBackgroundSight.words(for: resolution, requested: requested)
                    ?? "I couldn't find a running app called \"\(requested)\"."
                if case .notRunning = resolution {
                    return (MacControlResult(
                        ok: true,
                        action: "look",
                        output: .object([
                            "trusted": .bool(true),
                            "grade": .string(grade),
                            "status": .string("ok"),
                            "app": .string(requested),
                            "requested_app": .string(requested),
                            "running": .bool(false),
                            "message": .string(words + " Nothing was launched or opened."),
                        ]),
                        error: nil,
                        durationMs: Int(now().timeIntervalSince(started) * 1000)
                    ), nil)
                }
                let code = resolution.failureCode ?? "app_not_running"
                return (MacControlResult(
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
                    durationMs: Int(now().timeIntervalSince(started) * 1000)
                ), nil)
            }
            anchorPid = app.processIdentifier
            anchoredApp = app
        }
        if context.observationMode != .passive {
            let pid = turn.macContinuation.flatMap { $0.isPending ? $0.app?.processIdentifier : nil }
                ?? anchorPid ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier
            if let pid {
                if let refusal = await macAdmissionRefusal(pid: pid, action: "look", reading: true, context: context) { return (refusal, nil) }
                anchorPid = pid
                if grade == "stare", accessibilitySource(context: context).frontmostApp()?.processIdentifier != pid {
                    return (injectionRefusal(action: "look", error: "front_changed", status: 409), nil)
                }
            }
        }
        // The reading budget begins with reading, after the app's admission wait.
        let context = context.observationMode == .passive ? context
            : context.with(\.readDeadline, Date().addingTimeInterval(MacAXLimits.readSeconds))
        if grade == "stare" {
            let tree = handleAXTree(body, context: context)
            var output: [String: JSONValue] = [:]
            if case .object(let object) = tree.output { output = object }
            output["grade"] = .string("stare")
            return (MacControlResult(
                ok: tree.ok,
                action: "look",
                output: .object(output),
                error: tree.error,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            ), nil)
        }
        guard let scope = MacLookScope.parse(body["scope"]?.stringValue) else {
            return (MacControlResult(
                ok: false,
                action: "look",
                output: .object([
                    "error": .string("unknown_scope"),
                    "scope": body["scope"] ?? .null,
                    "message": .string("scope must be one of: page, chrome, both"),
                ]),
                error: "unknown_scope",
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            ), nil)
        }
        let limits = Self.axLimits(from: body)
        let continuation = context.observationMode == .passive ? nil
            : turn.macContinuation.flatMap { $0.isPending ? $0 : nil }
        if let continuation {
            if let refusal = continuation.refusal(context: context) {
                return (MacControlResult(ok: false, action: "look",
                    output: .object(continuation.refusalOutput(refusal)), error: "continuation_unavailable",
                    durationMs: 0), nil)
            }
            anchorPid = continuation.app?.processIdentifier
            anchoredApp = continuation.app
        }
        // Reuse the owner’s post-effect read only while its window matches this look’s anchor.
        let carried = context.capture?.walked.flatMap { observed -> (read: MacAXRead, seam: [String: JSONValue])? in
            guard continuation == nil, body["section"] == nil, body["app_map"] == .bool(true), grade == "look",
                  let pid = anchorPid ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier,
                  observed.read.app?.processIdentifier == pid, let window = accessibilitySource(context: context).windowRoot(pid: pid, context: context),
                  accessibilitySource(context: context).sameElement(window, observed.read.root) else { return nil }
            return observed
        }
        // Clear rejected carried reads before replacement, so a timeout cannot expose the old window.
        if carried == nil { context.capture?.walked = nil }
        let snapshotted: (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) = if let carried {
            (carried.read, carried.seam, nil)
        } else {
            await lookSnapshot(
                limits: limits,
                scope: scope,
                anchorPid: anchorPid,
                anchorWindow: continuation?.window,
                completeWindow: body["app_map"] == .bool(true) && grade == "look",
                section: body["section"]?.stringValue
            , context: context)
        }
        var read = snapshotted.read
        var seam = snapshotted.seam
        let anchor = snapshotted.anchor
        if case .selfProcess? = anchor {
            return (selfInspectionResult(action: "look", started: started, context: context), nil)
        }
        if case .rendererUnavailable(let reason)? = anchor {
            return (MacControlResult(ok: false, action: "look", output: .object([
                "status": .string("renderer_accessibility_unavailable"),
                "message": .string(reason), "seam": .object(seam),
            ]), error: "renderer_accessibility_unavailable", durationMs: Int(now().timeIntervalSince(started) * 1000)), nil)
        }
        let minimized = seam["window_minimized"] == .bool(true)
        if body["app_map"] != .bool(true), !minimized, let seek = body["seek"]?.stringValue, let current = read {
            let found = seekScoped(current, seek: seek, limits: limits, context: context)
            read = found.read
            for (key, item) in found.seam { seam[key] = item }
        }
        // Record front app and key window for anchored acts even when no readable target exists; never self-AX.
        let frontmostAppJSON: JSONValue = {
            guard anchoredApp != nil, let front = accessibilitySource(context: context).frontmostApp(),
                  case .object(var object) = front.toJSON() else { return .null }
            if !PersonOnlyWindows.isOwnProcess(front.processIdentifier),
               let window = accessibilityActSource(context: context).focusedWindow(pid: front.processIdentifier, context: context) {
                object["window"] = window.identity.toJSON()
                context.capture?.foreground = MacForegroundSnapshot(app: front, window: window.identity)
            } else if PersonOnlyWindows.isOwnProcess(front.processIdentifier) {
                // Our own process is activated through AppKit, never self-AX.
                context.capture?.foreground = MacForegroundSnapshot(app: front, window: nil)
            } else {
                do {
                    if try accessibilityActSource(context: context).windows(pid: front.processIdentifier, context: context).isEmpty {
                        context.capture?.foreground = MacForegroundSnapshot(app: front, window: nil)
                    }
                } catch {
                    object["window_capture_error"] = .string(error.localizedDescription)
                }
            }
            return .object(object)
        }()
        let runningApps = runningAppProjection(context: context)
        guard let read, !minimized else {
            // An anchored app without a readable window differs from no frontmost window; describe only the requested app. Saver flags cannot diagnose
            // authentication; only the shared wake owner establishes a remaining lock.
            let covered = MacScreenLock.isLocked()
            let status = covered ? "display_obstructed"
                : minimized ? "window_minimized"
                : anchoredApp == nil ? "no_frontmost_window" : "no_window_in_app"
            var output: [String: JSONValue] = [
                "trusted": .bool(true),
                "grade": .string(grade),
                "status": .string(status),
                "error": .string(status),
            ].merging(runningApps) { _, new in new }
            if context.readDeadline.map({ Date() >= $0 }) == true {
                output["message"] = .string("partial: budget reached; no readable accessibility content arrived within the read budget.")
                return (MacControlResult(ok: false, action: "look", output: .object(output), error: "time_budget",
                    durationMs: Int(now().timeIntervalSince(started) * 1000)), nil)
            }
            if !covered, !minimized, case .windowDrifted(let reason)? = anchor {
                output["status"] = .string("observation_changed")
                output["error"] = .string("observation_changed")
                output["message"] = .string("The requested window changed while it was being read (\(reason)); no empty-window observation was established.")
                return (MacControlResult(ok: false, action: "look", output: .object(output), error: "observation_changed",
                    durationMs: Int(now().timeIntervalSince(started) * 1000)), nil)
            }
            if covered {
                output["message"] = .string(MacScreenLock.reply)
            } else if minimized {
                let name = anchoredApp?.name ?? read?.app?.name ?? "The app"
                output["requested_app"] = .string(name)
                output["frontmost_app"] = frontmostAppJSON
                output["message"] = .string(
                    "\(name)'s window is minimized. go name:\"\(name)\" front:true brings it back when the task authorizes bringing it forward. "
                    + "Its menu bar still works: mac.act app:\"\(name)\" target:\"File > New\" makes a new window."
                )
            } else if anchoredApp == nil, let front = accessibilitySource(context: context).frontmostApp(),
                      !PersonOnlyWindows.isOwnProcess(front.processIdentifier) {
                // Windowless front apps still take keys, so retain their identity.
                output["frontmost_app"] = front.toJSON()
            } else if let anchoredApp, case .windowGone? = anchor {
                // A vanished captured window says nothing about sibling windows; preserve the act’s exact precondition.
                output["requested_app"] = .string(anchoredApp.name)
                output["frontmost_app"] = frontmostAppJSON
                output["message"] = .string("The requested \(anchoredApp.name) window is gone; no other window was read.")
            } else if let anchoredApp {
                output["requested_app"] = .string(anchoredApp.name)
                output["frontmost_app"] = frontmostAppJSON
                // Observed absence is not read failure or permission to create a window; acts still need their own target.
                output["status"] = .string("ok")
                output.removeValue(forKey: "error")
                output["app"] = .string(anchoredApp.name)
                let running = accessibilitySource(context: context).runningApps().contains { $0.processIdentifier == anchoredApp.processIdentifier }
                output["running"] = .bool(running)
                if running { output["windows"] = .int(0) }
                let menuReading = running ? menuBarReading(pid: anchoredApp.processIdentifier, context: context) : nil
                let menus = menuReading.map { MacMenuBar.topLevelNames($0.items) } ?? []
                if let menuReading { output["menu_coverage"] = MacMenuBar.json(menuReading, statesKnown: false, depth: 1) }
                if !menus.isEmpty { output["menus"] = .array(menus.map(JSONValue.string)) }
                output["message"] = .string(
                    (running ? "\(anchoredApp.name) is running with no readable window. " : "\(anchoredApp.name) is no longer running. ")
                    + (menuReading?.unavailable.map { "Its menu bar is unavailable: \($0). " }
                       ?? (menus.isEmpty ? "" : "Its observed menu bar: " + menus.joined(separator: " · ") + ". "))
                    + "Nothing was opened."
                )
            }
            let emptyObservation = output["status"] == .string("ok")
            return (MacControlResult(
                ok: emptyObservation,
                action: "look",
                output: .object(output),
                error: emptyObservation ? nil : status,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            ), nil)
        }
        seam.merge(read.snapshot.readGapsJSON) { _, gap in gap }
        let secretContext = MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes)
        let percept = (carried == nil ? nil : context.capture?.percept) ?? MacPerceptionCompiler.compile(
            snapshot: read.snapshot,
            secretContext: secretContext,
            app: read.app,
            windowTitle: read.rootTitle,
            // Keep the same read epoch and root anchor as the walk.
            focusPath: read.focusPath,
            maxAffordances: body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances,
            uncapped: body["app_map"] == .bool(true) && grade == "look"
        )
        // Retain the complete action index before page folding; presentation budgets cannot alter identity.
        let fourVerbs = body["app_map"] == .bool(true) && grade == "look"
        let redactedNodes = fourVerbs ? read.snapshot.nodes.map {
            JSONValue.object(MacScreenViewTextRedaction.redactedNodeFields($0, valueChars: .max, context: secretContext))
        } : []
        // A timed-out walk is incomplete; view capture must inspect that window afresh.
        if fourVerbs, read.section == nil, !read.snapshot.truncationReasons.contains("time_budget") {
            context.capture?.walked = (read, seam)
        }
        // Authored senses and native pages share the complete source snapshot rather than another walk.
        let needsMaterial = fourVerbs && (seam["chromium_family"] == .bool(true) || body["sense_material"] == .bool(true))
        let accessibility: [String: JSONValue]? = needsMaterial || (fourVerbs && context.appCapture != nil && read.app?.bundleIdentifier != nil) ? {
            let snapshot = read.snapshot
            return [
                "nodes": .array(redactedNodes), "count": .int(Int64(redactedNodes.count)),
                "truncated": .bool(snapshot.truncated),
                "truncation_reasons": .array(snapshot.truncationReasons.map(JSONValue.string)),
                "skipped_at_least": .int(Int64(snapshot.skippedAtLeast)),
            ]
        }() : nil
        let material = needsMaterial ? accessibility.map { ["accessibility": JSONValue.object($0)] } : nil
        let windowKind = fourVerbs
            ? MacAppMaps.windowKind(role: read.windowIdentity?.role, subrole: read.windowIdentity?.subrole)
            : nil
        // Render before minting handles so byte-trimmed rows cannot remain addressable. Glances mint every affordance and advertise their count despite showing
        // no rows.
        let capturedAt = now()
        let frameId = context.capture?.frameID ?? UUID().uuidString
        context.readContent?.record(.string(frameId), content: .string("<frame>"))
        context.readContent?.depend(on: .object([
            "app": read.app?.toJSON() ?? .null, "window": read.windowIdentity?.toJSON() ?? .null,
        ]))
        if fourVerbs, let capture = context.appCapture, let bundle = read.app?.bundleIdentifier, var tree = accessibility {
            tree["seam"] = .object(seam)
            tree["frame_id"] = .string(frameId)
            tree["app_bundle_id"] = .string(bundle)
            tree["affordances"] = .array(percept.affordances.map { $0.toJSON() })
            tree["window_identity"] = read.windowIdentity?.toJSON()
            tree["renderer_wait_note"] = seam["renderer_wait_note"]
            capture.record(bundleID: bundle, tree: .object(tree))
        }
        let nativePage: NativePage?
        let nativePageJSON: JSONValue?
        let nativePageBlocks: JSONValue?
        do {
            if fourVerbs {
                let compilation = try MacScreenPageCompiler.compile(snapshot: read.snapshot, redactedNodes: redactedNodes,
                    percept: percept, frameID: frameId,
                    isFront: anchoredApp.map { accessibilitySource(context: context).frontmostApp()?.processIdentifier == $0.processIdentifier } ?? true,
                    menuReading: read.app.map { menuBarReading(pid: $0.processIdentifier, context: context) },
                    settableAttributes: { node in node.element.map { accessibilitySource(context: context).settableAttributes(of: $0, context: context) }
                        ?? [] })
                nativePage = compilation.page
                nativePageJSON = try JSONValue.parse(JSONEncoder().encode(compilation.page))
                nativePageBlocks = compilation.blocks
            } else { nativePage = nil; nativePageJSON = nil; nativePageBlocks = nil }
        } catch {
            return (MacControlResult(ok: false, action: "look",
                output: .object(["message": .string("The native screen page could not be compiled: \(error.localizedDescription)")]),
                error: "screen_page_unavailable", durationMs: Int(now().timeIntervalSince(started) * 1000)), nil)
        }
        let captureStamp = JSONValue.string(NativeTimestampFormat.plainZulu(capturedAt))
        let envelope: [String: JSONValue] = {
            context.readContent?.record(.object(["frame_id": .string(frameId), "captured_at": captureStamp]),
                content: .object(["frame_id": .string(frameId)]))
            var output: [String: JSONValue] = [
                "trusted": .bool(true),
                "grade": .string(grade),
                "frame_id": .string(frameId),
                "partial": .bool(percept.truncated),
                "captured_at": captureStamp,
                "frame_ttl_seconds": .int(Int64(MacLookFrameStore.ttlSeconds)),
                "seam": .object(seam),
                // Anchored reads need not be frontmost.
                "front": .bool(
                    anchoredApp.map {
                        accessibilitySource(context: context).frontmostApp()?.processIdentifier == $0.processIdentifier
                    } ?? true
                ),
                "anchored": .bool(anchoredApp != nil),
                // Explicit front acts may restore the previously frontmost app.
                "frontmost_app": frontmostAppJSON,
                // Publish resolved limits so comparisons know whether callers lowered them.
                "limits": .object([
                    "max_nodes": .int(Int64(limits.maxNodes)),
                    "max_depth": .int(Int64(limits.maxDepth)),
                    "hard_max_nodes": .int(Int64(MacAXLimits.hardMaxNodes)),
                    "hard_max_depth": .int(Int64(MacAXLimits.hardMaxDepth)),
                ]),
            ].merging(runningApps) { _, new in new }
            // Coverage must account for areas with no AX elements.
            if let windowFrame = read.windowIdentity?.frame {
                output["window_frame"] = windowFrame.toJSON()
            }
            if let identity = read.windowIdentity { output["window_identity"] = identity.toJSON() }
            if let material {
                for (key, value) in material { output[key] = value }
            }
            if let windowKind { output["window_kind"] = .string(windowKind) }
            if let nativePageJSON { output["native_page"] = nativePageJSON }
            if let nativePageBlocks { output["native_page_blocks"] = nativePageBlocks }
            if grade == "glance" {
                output["glance"] = .string(percept.glanceLine())
                output["addressable_handles"] = .int(Int64(percept.affordances.count))
                output["how_to_read"] = .string(
                    "One summary line; this frame has \(percept.affordances.count) labeled controls. "
                    + "Use app {action:\"mac.look\",args:{part:\"controls\"}} to inspect controls, or mac.read for document text."
                )
            } else if grade == "look" {
                output["glance"] = .string(percept.glanceLine())
                output["how_to_read"] = .string(
                    "`affordances` are the things you can act on, each with a stable `handle` for "
                    + "THIS frame_id; `path` records observed topology. Unknown or drifted handles require a fresh look. `unlabeled` counts the "
                    + "interactive controls the app publishes no name for — they exist, they are "
                    + "just unnamed. `readouts` are the read-only values on screen (a total, a "
                    + "display, a status line) — what you can READ without touching anything. "
                    + "Handles are valid only for the latest frame; take another look "
                    + "if the screen may have changed."
                )
            }
            return output
        }()
        let rendering: JSONValue?
        do {
            rendering = grade == "look"
                ? try percept.lookJSON(byteBudget: fourVerbs ? 1 << 30 : MacPerceptionCompiler.lookByteBudget,
                    envelope: { envelope.merging($0) { _, look in look } })
                : nil
        } catch {
            return (MacControlResult(ok: false, action: "look",
                output: .object(["error": .string("look_encoding_failed"),
                    "message": .string(
                        """
                            The screen reading could not be encoded: \(error.localizedDescription). Read the screen again after repairing the source value; no \
                            frame was published.
                            """)]),
                error: "look_encoding_failed", durationMs: Int(now().timeIntervalSince(started) * 1000)), nil)
        }
        var output = envelope
        if case .object(let rendered)? = rendering { output = rendered }
        let renderedRows: Int? = rendering.map { rendering in
            if case .object(let object) = rendering,
               case .array(let rows)? = object["affordances"] { return rows.count }
            return 0
        }
        // Look mints only retained rows; glance mints all.
        capturedFrame = MacLookFrame.from(
            percept: percept,
            frameId: frameId,
            capturedAt: capturedAt,
            windowTitle: read.rootTitle,
            rendered: renderedRows,
            windowIdentity: read.windowIdentity,
            // Record bounds so cap churn cannot be mistaken for window change.
            caps: MacLookCompileCaps(
                truncated: percept.truncated,
                maxAffordances: fourVerbs ? nil : body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances,
                maxNodes: fourVerbs ? nil : limits.maxNodes,
                maxDepth: fourVerbs ? nil : limits.maxDepth
            ),
            completeWindow: fourVerbs
        )
        if let bundle = read.app?.bundleIdentifier {
            context.appCapture?.augment(bundleID: bundle,
                fields: ["affordances": output["affordances"] ?? .array([])])
        }
        if fourVerbs { context.capture?.percept = percept }
        guard let observedApp = read.app,
              accessibilitySource(context: context).appInfo(pid: observedApp.processIdentifier) == observedApp else {
            return (MacControlResult(ok: false, action: "look", output: .object([
                "frame_id": .null, "message": .string("The observed app is no longer available; no frame was published."),
            ]), error: "app_gone", durationMs: Int(now().timeIntervalSince(started) * 1000)), nil)
        }
        return (MacControlResult(
            ok: true,
            action: "look",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            nativePage: nativePage
        ), capturedFrame)
    }
    /// Shape-check free-text query echoes; AX role constants remain intact because redacting them would obscure the requested role.
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
    func handleAXFind(_ body: [String: JSONValue], context: MacOperationContext) throws -> MacControlResult {
        let started = now()
        let query = MacAXQuery(
            role: body["role"]?.stringValue,
            title: body["title"]?.stringValue,
            value: body["value"]?.stringValue
        )
        if query.isEmpty {
            throw MacControlError.missingField("role|title|value")
        }
        guard accessibilitySource(context: context).isTrusted() else { return axUntrustedResult(action: "ax_find") }
        // Find shares tree caps and truncation reporting so no match cannot imply absence beyond the read boundary.
        let limits = Self.axLimits(from: body)
        let anchored = axSnapshot(limits: limits, context: context)
        if case .selfProcess = anchored {
            return selfInspectionResult(action: "ax_find", started: started, context: context)
        }
        if case .rendererUnavailable(let reason) = anchored {
            return MacControlResult(ok: false, action: "ax_find", output: .object(["message": .string(reason)]),
                error: "renderer_accessibility_unavailable", durationMs: Int(now().timeIntervalSince(started) * 1000))
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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
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
        // Query echoes use the shared secret-shape checks before trace, persistence or sync.
        output["query"] = Self.redactedQueryJSON(query, valueChars: limits.valueChars)
        output["searched"] = .int(Int64(read.snapshot.nodes.count))
        output["count"] = .int(Int64(matches.count))
        output["max_matches"] = .int(Int64(limits.maxMatches))
        // Redact matches with whole-snapshot captions, including labels the query did not match.
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
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
}
