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
// Blueprint: | `MacSemanticObservation.swift` | Semantic look capture and exact-node search |
extension SwiftNativeMacControl {
    /// The Chromium/Electron live seam. Runs BEFORE the walk that matters.
    ///
    /// Identify the running app's renderer frameworks, enable both renderer
    /// AX flags on its application element, then read the newly exposed tree.
    /// A cold renderer is awaited on its own AX notifications in this read.
    /// Native AX windows return immediately. Only renderer content growth
    /// renews the stall window; notifications merely trigger another read.
    ///
    /// The flag is left set (see `MacChromiumAccessibility` for the lifetime
    /// rule) and cleared lazily here when the frontmost app changed or the last
    /// frame expired — never by a background timer.
    ///
    /// - Parameters anchorPid/anchorWindow: every post-act walk, including renderer re-reads,
    ///   targets the acted window or carries its anchor failure; never publish another window's frame.
    func lookSnapshot(
        limits: MacAXLimits,
        scope: MacLookScope = .page,
        anchorPid: Int32? = nil,
        anchorWindow: MacAXWindowIdentity? = nil,
        completeWindow: Bool = false,
        section: String? = nil
    ) async -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
        var seam: [String: JSONValue] = [
            "chromium_family": .bool(false),
            "enhanced_ax_set": .bool(false),
            "rewalked": .bool(false),
        ]
        // Resolve the application before walking a window. An AXWebArea is
        // an effect of Chromium activation, never its prerequisite.
        let pid = anchorPid ?? anchorWindow?.pid ?? accessibilitySource.frontmostApp()?.processIdentifier
        if pid == getpid() { return (nil, seam, .selfProcess) }
        let app = pid.flatMap { accessibilitySource.appInfo(pid: $0) }
        let chromium = MacChromiumAccessibility.looksChromium(bundleId: app?.bundleIdentifier, pid: pid, snapshot: nil)
        #if canImport(ApplicationServices) && os(macOS)
        var rendererEvents: MacAppSourceEvents?
        var observationError: Error?
        defer { rendererEvents?.cancel() }
        if MacObservationMode.current == .passive, chromium, let pid {
            seam["chromium_family"] = .bool(true)
            seam["complete_window"] = .bool(true)
            let before = SystemMacAXElementSource.enhancedAccessibilityFlags(pid: pid)
            seam["enhanced_ax_set"] = .bool(before.values.contains(true))
        }
        if MacObservationMode.current != .passive, accessibilitySource is SystemMacAXElementSource {
            let previous = await MacChromiumAccessibilityState.shared.current()
            let frameExpired = await lookFrameStore.isExpired(now: now())
            for (previousPID, flags) in previous where (previousPID != pid || frameExpired) && !MacAppSourceEvents.isWatching(pid: previousPID) {
                let readsBack = SystemMacAXElementSource.setEnhancedAccessibility(pid: previousPID, flags: flags, enabled: false)
                let remaining = flags.filter { readsBack[$0] != false }
                await MacChromiumAccessibilityState.shared.note(pid: previousPID, flags: remaining)
                if remaining.isEmpty { seam["enhanced_ax_cleared_pid"] = .int(Int64(previousPID)) }
            }
            if chromium, let pid {
                seam["chromium_family"] = .bool(true)
                seam["complete_window"] = .bool(true)
                let ours = await MacChromiumAccessibilityState.shared.current()[pid] ?? []
                let before = SystemMacAXElementSource.enhancedAccessibilityFlags(pid: pid)
                let alreadyOn = Set(before.filter(\.value).keys)
                let flags = Set(MacChromiumAccessibility.Flag.allCases)
                let missing = flags.subtracting(alreadyOn)
                // Subscribe before the first enable so population events are
                // retained. Every read asserts both modes before its tree walk.
                if !missing.isEmpty {
                    do { rendererEvents = try MacAppSourceEvents(pid: pid) }
                    catch { observationError = error }
                }
                let readsBack = SystemMacAXElementSource.setEnhancedAccessibility(pid: pid, flags: flags, enabled: true)
                seam["enhanced_ax_set"] = .bool(flags.contains { readsBack[$0] == true })
                if !flags.contains(where: { readsBack[$0] == true }) {
                    seam["renderer_wait_note"] = .string("raw view · accessibility · Both Chromium accessibility modes were requested, but neither could be confirmed enabled. This is the app's exposed tree.")
                }
                let unverified = flags.filter { readsBack[$0] == nil }.sorted { $0.rawValue < $1.rawValue }
                if !unverified.isEmpty { seam["enhanced_ax_unverified"] = .array(unverified.map { .string($0.rawValue) }) }
                seam["enhanced_ax_preexisting"] = .bool(!alreadyOn.subtracting(ours).isEmpty)
                await MacChromiumAccessibilityState.shared.note(pid: pid, flags: ours.union(missing.filter { readsBack[$0] != false }))
            }
        }
        #endif
        func anchoredRead() -> MacAnchoredRead {
            anchoredSnapshot(limits: limits, pid: pid, window: anchorWindow, complete: completeWindow || chromium, section: section)
        }
        let firstAnchor = anchoredRead()
        // A self-process target is a refusal on BOTH the anchored and the
        // unanchored path — the caller needs the reason, not a generic
        // "no window" (the walk was refused, not absent).
        if case .selfProcess = firstAnchor { return (nil, seam, firstAnchor) }
        let read: MacAXRead? = {
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
        /// Page-first descent works on any source; only enhanced-AX activation requires a live app.
        func scoped(
            _ candidate: (read: MacAXRead?, seam: [String: JSONValue])
        ) -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
            guard let value = candidate.read else { return (nil, candidate.seam, nil) }
            let outcome = pageScoped(value, limits: limits, scope: scope, completeWindow: completeWindow)
            var merged = candidate.seam
            for (key, item) in outcome.seam { merged[key] = item }
            return (outcome.read, merged, nil)
        }
        #if canImport(ApplicationServices) && os(macOS)
        // The seam only exists for the LIVE source. A synthetic/unavailable
        // source has no app element to flag, and pretending otherwise would be
        // a stub that reports work it did not do.
        guard accessibilitySource is SystemMacAXElementSource else { return scoped((read, seam)) }
        // A minimized window can expose only an empty shell. Report that state
        // after owned-flag cleanup, before Chromium wake/scoping.
        if let read, let source = accessibilitySource as? SystemMacAXElementSource,
           let window = source.element(read.root),
           MacAXAttributeRead.copyBool(window, kAXMinimizedAttribute) == true {
            seam["window_minimized"] = .bool(true)
            return (read, seam, nil)
        }
        guard let pid, chromium
        else { return scoped((read, seam)) }
        let rendererWindow = read?.windowIdentity
        func rendererRead() -> MacAnchoredRead {
            anchoredSnapshot(limits: limits, pid: pid, window: rendererWindow, complete: true, section: section)
        }
        var result = scoped((read, seam))
        func rendererReady(_ inspected: (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?)) -> Bool {
            guard let read = inspected.read else { return false }
            let areas = read.snapshot.nodes.filter { $0.attributes.role == "AXWebArea" }
            // A Chromium app's native windows have no renderer to await.
            guard !areas.isEmpty else { return true }
            // Each renderer supplies its own load state. A ready sidebar does
            // not certify a hollow sibling, and a loaded blank document is not
            // mistaken for a still-loading one. AXLoaded is Chromium's tree
            // load state; AXElementBusy also covers dynamic document work.
            guard let source = accessibilitySource as? SystemMacAXElementSource else { return false }
            return areas.allSatisfy { area in
                // Existing content is readable immediately, even while the
                // document is busy. A sibling's text cannot certify this area.
                if read.snapshot.nodes.contains(where: { node in
                    node.path.count > area.path.count && node.path.starts(with: area.path)
                        && [node.attributes.title, node.attributes.value].contains {
                            !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        }
                }) { return true }
                guard let ref = area.element else { return false }
                let state: (loaded: Bool?, busy: Bool?) = MacAXExecutionLane.sync {
                    guard let element = source.element(ref) else { return (nil, nil) }
                    return (MacAXAttributeRead.copyBool(element, "AXLoaded"),
                            MacAXAttributeRead.copyBool(element, kAXElementBusyAttribute))
                }
                return state.loaded == true && state.busy != true
            }
        }
        // Track each renderer's subtree, excluding window/chrome changes and
        // the web area's own loading title. Live AX identity survives path
        // changes; rearranging existing nodes is not content growth. A sibling
        // shrinking must not hide growth in another renderer.
        func rendererContent(_ inspected: (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?)) -> [(element: AXUIElement, nodes: Int, textBytes: Int)] {
            guard let read = inspected.read,
                  let source = accessibilitySource as? SystemMacAXElementSource else { return [] }
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
        // Use the SAME complete window walk/readiness as the returned page,
        // not a shallow web-area probe or a count of empty grouping nodes.
        func readyResult(_ ready: (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?)) -> (read: MacAXRead?, seam: [String: JSONValue], anchor: MacAnchoredRead?) {
            guard let read = ready.read else { return ready }
            if !MacChromiumAccessibility.hasWebArea(read.snapshot) {
                // No renderer exists in this observed window tree. Do not call
                // that proof of a loaded document: native Electron windows
                // remain immediate, and a shell-only read names its boundary.
                var native = ready
                native.seam["enhanced_ax_content"] = .string("no_renderer_tree")
                if MacObservationMode.current == .passive, native.seam["enhanced_ax_set"] != .bool(true) {
                    native.seam["renderer_wait_note"] = .string("raw view · passive observation · Renderer accessibility is not enabled; observation waits for the app's exposed content.")
                }
                // A native window is a complete immediate read, not a failed
                // renderer read. Its ordinary screen provenance names AX.
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
        if MacAXLimits.readDeadline.map({ Date() >= $0 }) == true {
            return unavailable("time_budget", "partial: budget reached; this is only the accessibility content read so far.")
        }
        if rendererEvents == nil {
            // Some renderers expose notification support only after AX is
            // enabled. Complete that same registration transaction now and
            // close its race with the stream's initial reread.
            do { rendererEvents = try MacAppSourceEvents(pid: pid) }
            catch { observationError = error }
        }
        guard let rendererEvents else {
            return unavailable("observation_unavailable",
                "The renderer's content could not be awaited because app accessibility notifications are unavailable: \(observationError?.localizedDescription ?? "no observer").")
        }
        var previousContent = rendererContent(result)
        rendererEvents.watchContentStall(seconds: MacChromiumAccessibility.rendererStallSeconds)
        return await withTaskCancellationHandler {
            do {
                // Registration itself yields once: this reread closes the install
                // race. Further reads follow AX callbacks or the stall boundary.
                for try await _ in rendererEvents.stream {
                    try Task.checkCancellation()
                    if MacAXLimits.readDeadline.map({ Date() >= $0 }) == true {
                        return unavailable("time_budget", "partial: budget reached; this is only the accessibility content read so far.")
                    }
                    let changedAnchor = rendererRead()
                    guard case .read(let changed) = changedAnchor else { return (nil, seam, changedAnchor) }
                    result = scoped((changed, seam))
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
                            "The renderer did not expose ready content and its accessibility subtree gained no nodes or text for \(Int(MacChromiumAccessibility.rendererStallSeconds)) seconds. This is its current accessibility tree.")
                    }
                }
                throw CancellationError()
            } catch is CancellationError {
                return unavailable("cancelled", "The renderer read was cancelled before ready content arrived. This is its current accessibility tree.")
            } catch {
                return unavailable("observation_unavailable",
                    "The renderer's accessibility observation stopped before ready content arrived: \(error.localizedDescription). This is its current accessibility tree.")
            }
        } onCancel: {
            rendererEvents.cancel()
        }
        #else
        return scoped((read, seam))
        #endif
    }
    /// `mac_look` — the perception compiler's tool surface.
    ///
    /// Three grades of attention over ONE walk. `stare` is DELEGATED to
    /// `handleAXTree` rather than reimplemented, so the full-tree payload can
    /// never drift from `mac_ax_tree`'s.
    func handleLook(_ body: [String: JSONValue]) async -> MacControlResult {
        await lookFrameStore.read { await self.captureLook(body) }
    }
    private func captureLook(_ body: [String: JSONValue]) async -> (MacControlResult, MacLookFrame?) {
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
        guard accessibilitySource.isTrusted() else { return (axUntrustedResult(action: "look"), nil) }
        // Read a named running app's front window without focusing, launching or raising it.
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
                among: accessibilitySource.runningApps()
            )
            guard case .matched(let app) = resolution else {
                let words = MacBackgroundSight.words(for: resolution, requested: requested)
                    ?? "I couldn't find a running app called \"\(requested)\"."
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
        // After a background act, restore only enhanced-AX flags this module set; no walk.
        if body["release_enhanced_ax"] == .bool(true) {
            guard MacObservationMode.current != .passive else {
                return (MacControlResult(ok: false, action: "look",
                    output: .object(["message": .string("raw view · passive observation · renderer accessibility flags were left unchanged")]),
                    error: "passive_observation", durationMs: 0), nil)
            }
            var released = false
            var stillOn = false
            #if canImport(ApplicationServices) && os(macOS)
            if let pid = anchorPid, !MacAppSourceEvents.isWatching(pid: pid), accessibilitySource is SystemMacAXElementSource,
               let owned = await MacChromiumAccessibilityState.shared.current()[pid] {
                // Only a confirmed off read clears ownership. On or unknown
                // keeps the record for the next release or lazy clear.
                let readsBack = SystemMacAXElementSource.setEnhancedAccessibility(
                    pid: pid, flags: owned, enabled: false
                )
                let remaining = owned.filter { readsBack[$0] != false }
                stillOn = !remaining.isEmpty
                await MacChromiumAccessibilityState.shared.note(pid: pid, flags: remaining)
                released = !stillOn
            }
            #endif
            return (MacControlResult(
                ok: true,
                action: "look",
                output: .object([
                    "released_enhanced_ax": .bool(released),
                    "enhanced_ax_still_on": .bool(stillOn),
                ]),
                error: nil,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            ), nil)
        }
        if grade == "stare" {
            // The SAME payload mac_ax_tree returns, from the same handler.
            let tree = handleAXTree(body)
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
        let continuation = MacObservationMode.current == .passive ? nil
            : MacWorkContinuation.current.flatMap { $0.isPending ? $0 : nil }
        if let continuation {
            if let refusal = continuation.refusal() {
                return (MacControlResult(ok: false, action: "look",
                    output: .object(["message": .string(refusal)]), error: "continuation_unavailable",
                    durationMs: 0), nil)
            }
            anchorPid = continuation.app?.processIdentifier
            anchoredApp = continuation.app
        }
        // A look replying to an act reads the window its owner re-read after
        // the effect, while that is still the window this look anchors to.
        let carried = MacSightCaptureBinding.current?.walked.flatMap { observed -> (read: MacAXRead, seam: [String: JSONValue])? in
            guard continuation == nil, body["section"] == nil, body["app_map"] == .bool(true), grade == "look",
                  let pid = anchorPid ?? accessibilitySource.frontmostApp()?.processIdentifier,
                  observed.read.app?.processIdentifier == pid, let window = accessibilitySource.windowRoot(pid: pid),
                  accessibilitySource.sameElement(window, observed.read.root) else { return nil }
            return observed
        }
        // Clear rejected carried reads before replacement, so a timeout cannot expose the old window.
        if carried == nil { MacSightCaptureBinding.current?.walked = nil }
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
            )
        }
        var read = snapshotted.read
        var seam = snapshotted.seam
        let anchor = snapshotted.anchor
        if case .selfProcess? = anchor {
            return (selfInspectionResult(action: "look", started: started), nil)
        }
        let minimized = seam["window_minimized"] == .bool(true)
        if body["app_map"] != .bool(true), !minimized, let seek = body["seek"]?.stringValue, let current = read {
            let found = seekScoped(current, seek: seek, limits: limits)
            read = found.read
            for (key, item) in found.seam { seam[key] = item }
        }
        // For an anchored look, record WHO is in front (pid) and
        // its key window, so an act that brings its app forward can put exactly that back —
        // with or without a window to read.
        // Never an AX read of our own process.
        let frontmostAppJSON: JSONValue = {
            guard anchoredApp != nil, let front = accessibilitySource.frontmostApp(),
                  case .object(var object) = front.toJSON() else { return .null }
            if front.processIdentifier != getpid(),
               let window = accessibilityActSource.focusedWindow(pid: front.processIdentifier) {
                object["window"] = window.identity.toJSON()
            }
            return .object(object)
        }()
        let runningApps = runningAppProjection()
        guard let read, !minimized else {
            // An anchored read that found nothing is a DIFFERENT fact from "no
            // frontmost window": the app is running but has no readable window
            // (minimized, or all windows closed). Saying the frontmost thing
            // would describe a window that was never asked about.
            // The session flag also covers a passwordless saver. Only the
            // shared wake owner can report a remaining login window as locked.
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
            if MacAXLimits.readDeadline.map({ Date() >= $0 }) == true {
                output["message"] = .string("partial: budget reached; no readable accessibility content arrived within the read budget.")
                return (MacControlResult(ok: false, action: "look", output: .object(output), error: "time_budget",
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
            } else if anchoredApp == nil, let front = accessibilitySource.frontmostApp(),
                      front.processIdentifier != getpid() {
                // The windowless front app still takes keys: say which one it is.
                output["frontmost_app"] = front.toJSON()
            } else if let anchoredApp {
                output["requested_app"] = .string(anchoredApp.name)
                output["frontmost_app"] = frontmostAppJSON
                let menus = menuBarTitles(pid: anchoredApp.processIdentifier)
                if !menus.isEmpty { output["menus"] = .array(menus.map(JSONValue.string)) }
                output["message"] = .string(
                    "\(anchoredApp.name) is running with no window to read (minimized, or every window closed); a look needs a window. "
                    + (menus.isEmpty ? "" : "Its menu bar: " + menus.joined(separator: " · ") + ". ")
                    + "mac.menu app:\"\(anchoredApp.name)\" reads the menus whole; "
                    + "mac.act app:\"\(anchoredApp.name)\" target:\"File > New\" makes a new window, "
                    + "and go name:\"\(anchoredApp.name)\" front:true requests reopening it when the task authorizes bringing it forward."
                )
            }
            return (MacControlResult(
                ok: false,
                action: "look",
                output: .object(output),
                error: status,
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            ), nil)
        }
        let secretContext = MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes)
        let percept = (carried == nil ? nil : MacSightCaptureBinding.current?.percept) ?? MacPerceptionCompiler.compile(
            snapshot: read.snapshot,
            secretContext: secretContext,
            app: read.app,
            windowTitle: read.rootTitle,
            // Same read epoch as the walk, anchored to the walked root.
            focusPath: read.focusPath,
            maxAffordances: body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances,
            uncapped: body["app_map"] == .bool(true) && grade == "look"
        )
        // Four-verb sight keeps the complete action index. Native page windows
        // fold presentation later; a page budget never changes target identity.
        let fourVerbs = body["app_map"] == .bool(true) && grade == "look"
        let redactedNodes = fourVerbs ? read.snapshot.nodes.map {
            JSONValue.object(MacScreenViewTextRedaction.redactedNodeFields($0, valueChars: .max, context: secretContext))
        } : []
        // A walk that ran out of time is not the whole window: the view reads that one afresh.
        if fourVerbs, read.section == nil, !read.snapshot.truncationReasons.contains("time_budget") {
            MacSightCaptureBinding.current?.walked = (read, seam)
        }
        // Authored senses receive the same complete source snapshot. The
        // native screen page is compiled from that read, not a second walk.
        let needsMaterial = fourVerbs && (seam["chromium_family"] == .bool(true) || body["sense_material"] == .bool(true))
        let accessibility: [String: JSONValue]? = needsMaterial || (fourVerbs && SenseAppReadCapture.current != nil && read.app?.bundleIdentifier != nil) ? {
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
        // Render FIRST, so the frame mints handles only for the rows she will
        // actually see (the byte budget may trim the tail) — "handles valid for
        // this frame_id" means the handles in THIS payload. A glance shows no
        // rows, so it mints every affordance and says how many are addressable.
        let capturedAt = now()
        let frameId = MacSightCaptureBinding.current?.frameID ?? UUID().uuidString
        OwnedProgramRunner.ReadContent.current?.record(.string(frameId), content: .string("<frame>"))
        OwnedProgramRunner.ReadContent.current?.depend(on: .object([
            "app": read.app?.toJSON() ?? .null, "window": read.windowIdentity?.toJSON() ?? .null,
        ]))
        if fourVerbs, let capture = SenseAppReadCapture.current, let bundle = read.app?.bundleIdentifier, var tree = accessibility {
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
                    isFront: anchoredApp.map { accessibilitySource.frontmostApp()?.processIdentifier == $0.processIdentifier } ?? true,
                    menuTitles: read.app.map { menuBarTitles(pid: $0.processIdentifier) } ?? [],
                    settableAttributes: { node in node.element.map { accessibilitySource.settableAttributes(of: $0) } ?? [] })
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
            OwnedProgramRunner.ReadContent.current?.record(.object(["frame_id": .string(frameId), "captured_at": captureStamp]),
                content: .object(["frame_id": .string(frameId)]))
            var output: [String: JSONValue] = [
                "trusted": .bool(true),
                "grade": .string(grade),
                "frame_id": .string(frameId),
                "captured_at": captureStamp,
                "frame_ttl_seconds": .int(Int64(MacLookFrameStore.ttlSeconds)),
                "seam": .object(seam),
                // Anchored reads need not be frontmost.
                "front": .bool(
                    anchoredApp.map {
                        accessibilitySource.frontmostApp()?.processIdentifier == $0.processIdentifier
                    } ?? true
                ),
                "anchored": .bool(anchoredApp != nil),
                // A front:true act can restore the app that was in front.
                "frontmost_app": frontmostAppJSON,
                // Callers may lower the read limits; publish their resolved bounds.
                "limits": .object([
                    "max_nodes": .int(Int64(limits.maxNodes)),
                    "max_depth": .int(Int64(limits.maxDepth)),
                    "hard_max_nodes": .int(Int64(MacAXLimits.hardMaxNodes)),
                    "hard_max_depth": .int(Int64(MacAXLimits.hardMaxDepth)),
                ]),
            ].merging(runningApps) { _, new in new }
            // Window coverage includes areas that publish no AX elements.
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
                    + "THIS frame_id and its `path` as the fallback. `unlabeled` counts the "
                    + "interactive controls the app publishes no name for — they exist, they are "
                    + "just unnamed. `readouts` are the read-only values on screen (a total, a "
                    + "display, a status line) — what you can READ without touching anything. "
                    + "Handles are valid only for the latest frame; take another look "
                    + "if the screen may have changed."
                )
            }
            return output
        }()
        let rendering = grade == "look"
            ? percept.lookJSON(byteBudget: fourVerbs ? 1 << 30 : MacPerceptionCompiler.lookByteBudget,
                envelope: { envelope.merging($0) { _, look in look } })
            : nil
        var output = envelope
        if case .object(let rendered)? = rendering { output = rendered }
        let renderedRows: Int? = rendering.map { rendering in
            if case .object(let object) = rendering,
               case .array(let rows)? = object["affordances"] { return rows.count }
            return 0
        }
        // Both grades mint handles; look includes only the retained rows.
        capturedFrame = MacLookFrame.from(
            percept: percept,
            frameId: frameId,
            capturedAt: capturedAt,
            windowTitle: read.rootTitle,
            rendered: renderedRows,
            windowIdentity: read.windowIdentity,
            // Recorded so the NEXT act can tell "the window changed" from "the
            // recompile ran under different bounds and lost rows".
            caps: MacLookCompileCaps(
                truncated: percept.truncated,
                maxAffordances: fourVerbs ? nil : body["max_affordances"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacPerceptionCompiler.maxAffordances,
                maxNodes: fourVerbs ? nil : limits.maxNodes,
                maxDepth: fourVerbs ? nil : limits.maxDepth
            ),
            completeWindow: fourVerbs
        )
        if let bundle = read.app?.bundleIdentifier {
            SenseAppReadCapture.current?.augment(bundleID: bundle,
                fields: ["affordances": output["affordances"] ?? .array([])])
        }
        if fourVerbs { MacSightCaptureBinding.current?.percept = percept }
        return (MacControlResult(
            ok: true,
            action: "look",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000),
            nativePage: nativePage
        ), capturedFrame)
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
            role: body["role"]?.stringValue,
            title: body["title"]?.stringValue,
            value: body["value"]?.stringValue
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
