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
// Blueprint: | `MacAXObservation.swift` | Anchored AX search retains optional-attribute and action-name gaps |
extension SwiftNativeMacControl {
    func handleAXStatus(context: MacOperationContext) -> MacControlResult {
        let started = now()
        let trusted = accessibilitySource(context: context).isTrusted()
        var output: [String: JSONValue] = ["trusted": .bool(trusted)]
        if !trusted {
            output["note"] = .string(MacAccessibilityReader.notTrustedNote)
            output["grant_path"] = .string("System Settings → Privacy & Security → Accessibility")
        }
        if let app = accessibilitySource(context: context).frontmostApp() {
            output["frontmost_app"] = app.toJSON()
        }
        // Missing permission is a valid status answer; only tree/find reads fail closed.
        return MacControlResult(
            ok: true,
            action: "ax_status",
            output: .object(output),
            error: nil,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
    /// One read epoch anchors the walk and focus path to the same root; outside-root focus is unknown.
    /// - Parameter pid: re-read this process for identity checks, regardless of frontmost app.
    func axSnapshot(
        limits: MacAXLimits,
        pid: Int32? = nil,
        context: MacOperationContext
    ) -> MacAnchoredRead {
        anchoredSnapshot(limits: limits, pid: pid, window: nil, context: context)
    }
    /// Share self-refusal wording so every read gives the same recovery direction.
    static let selfInspectionError = "self_inspection_unsupported"
    static let selfInspectionNote =
        "NativeAgent's own UI is person-only and cannot be read through Accessibility. "
        + "Use app {page:\"current\"} for pages, settings and actions; page.screenshot for an image; "
        + "setting.set for controls; chat.* for drafts, sending, model, Think and cards; page.show to select a page. "
        + "desk.read, mind.inner_state and agent.introspect read NativeAgent's state. mac.look reads other apps."
    func runningAppProjection(context: MacOperationContext) -> [String: JSONValue] {
        let front = accessibilitySource(context: context).frontmostApp()?.processIdentifier
        let apps = accessibilitySource(context: context).runningApps().filter(\.isDockApp).sorted {
            if ($0.processIdentifier == front) != ($1.processIdentifier == front) { return $0.processIdentifier == front }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return ["running_apps": .array(apps.prefix(24).map {
            .object(["name": .string(String($0.name.prefix(80))), "front": .bool($0.processIdentifier == front)])
        }), "running_apps_omitted": .int(Int64(max(0, apps.count - 24)))]
    }
    func selfInspectionResult(action: String, started: Date, context: MacOperationContext) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "trusted": .bool(true),
                "status": .string(Self.selfInspectionError),
                "error": .string(Self.selfInspectionError),
                "message": .string(Self.selfInspectionNote),
                "frontmost_app": accessibilitySource(context: context).frontmostApp()?.toJSON() ?? .null,
            ].merging(runningAppProjection(context: context)) { _, new in new }),
            error: Self.selfInspectionError,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
    /// Distinguish app absence, captured-window absence and ambiguous windows; none authorizes choosing an arbitrary window.
    enum MacAnchoredRead {
        case read(MacAXRead)
        case appGone
        case windowGone
        case windowDrifted(String)
        case rendererUnavailable(String)
        /// Refuse person-only UI before resolving an AX root.
        case selfProcess
    }
    /// Anchor optional PID/window requests to the named process and composite identity; missing selectors use the frontmost app or first process window.
    func anchoredSnapshot(
        limits: MacAXLimits,
        pid: Int32?,
        window: MacAXWindowIdentity?,
        complete: Bool = false,
        section: String? = nil,
        context: MacOperationContext
    ) -> MacAnchoredRead {
        #if canImport(ApplicationServices) && os(macOS)
        do { return try MacAXAttributeRead.checked(context: context) { context in
            anchoredSnapshotRead(limits: limits, pid: pid, window: window, complete: complete, section: section, context: context)
        } } catch { return .rendererUnavailable(error.localizedDescription) }
        #else
        return anchoredSnapshotRead(limits: limits, pid: pid, window: window, complete: complete, section: section, context: context)
        #endif
    }
    private func anchoredSnapshotRead(limits: MacAXLimits, pid: Int32?, window: MacAXWindowIdentity?,
        complete: Bool, section: String?, context: MacOperationContext) -> MacAnchoredRead {
        // The body and its window share the person-only boundary.
        if PersonOnlyWindows.isOwnProcess(pid) { return .selfProcess }
        #if canImport(ApplicationServices) && os(macOS)
        if accessibilitySource(context: context) is SystemMacAXElementSource,
           let target = pid ?? accessibilitySource(context: context).frontmostApp()?.processIdentifier, !PersonOnlyWindows.isOwnProcess(target) {
            do { try SystemMacAXElementSource.ensureRenderer(AXUIElementCreateApplication(target), refresh: true, context: context) }
            catch { return .rendererUnavailable(error.localizedDescription) }
        }
        #endif
        let root: MacAXElementRef
        var identity: MacAXWindowIdentity?
        if let pid, let window {
            let candidates = accessibilitySource(context: context).windowRoots(pid: pid, context: context)
            guard !candidates.isEmpty else { return .appGone }
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
        } else if let pid {
            // A named glance needs only its preferred window, not every window's attributes.
            guard let preferred = accessibilitySource(context: context).windowRoot(pid: pid, context: context),
                  let attributes = accessibilitySource(context: context).attributes(of: preferred, context: context) else { return .appGone }
            root = preferred
            identity = MacAXWindowIdentity(
                pid: pid, index: nil, role: attributes.role,
                subrole: attributes.subrole, title: attributes.title, frame: attributes.frame,
                attributeGaps: attributes.attributeGaps
            )
        } else {
            if let front = accessibilitySource(context: context).frontmostApp(),
               PersonOnlyWindows.isOwnProcess(front.processIdentifier) {
                return .selfProcess
            }
            guard let front = accessibilitySource(context: context).frontmostApp(),
                  let frontmost = accessibilitySource(context: context).windowRoot(pid: front.processIdentifier, context: context) else { return .appGone }
            root = frontmost
            // Frontmost reads retain window identity for later acts; an unknown index stays nil so a guessed position cannot boost the wrong match.
            if let attributes = accessibilitySource(context: context).attributes(of: root, context: context) {
                identity = MacAXWindowIdentity(
                    pid: front.processIdentifier,
                    index: nil,
                    role: attributes.role,
                    subrole: attributes.subrole,
                    title: attributes.title,
                    frame: attributes.frame,
                    attributeGaps: attributes.attributeGaps
                )
            }
        }
        identity = identity?.retainingWindow(root, in: accessibilitySource(context: context))
        var sectionRoot = root
        var sectionPath: [Int] = []
        var ancestors: [MacAXNode] = []
        var capturedSection: String?
        if let section {
            let needle = MacFourVerbs.normalize(section)
            let match = MacAccessibilityReader.findFirst(source: accessibilitySource(context: context), root: root,
                maxDepth: MacAXLimits.deepPageMaxDepth, nodeBudget: MacAXLimits.deepPageMaxNodes, context: context) { _, attributes in
                guard MacPerceptionCompiler.landmarkKinds[attributes.role] != nil || attributes.role == "AXGroup"
                    || attributes.subrole?.hasPrefix("AXLandmark") == true else { return false }
                let raw = attributes.displayTitle ?? attributes.title ?? attributes.value
                let redacted = raw.flatMap { value -> String? in
                    if case .string(let text) = MacScreenViewTextRedaction.redactedLegendString(value, valueChars: value.count) { return text }
                    return nil
                }
                let name = MacScreenPageCompiler.ownName(attributes, text: redacted)
                return [name, MacScreenPageCompiler.sectionName(attributes, name: name),
                        MacScreenRender.kindName(role: attributes.role)].compactMap { $0 }.contains { MacFourVerbs.normalize($0) == needle }
            }
            if let hit = match.hit {
                capturedSection = section
                sectionRoot = hit.ref
                sectionPath = hit.path
                var ancestor = root
                for (depth, index) in sectionPath.enumerated() {
                    guard let attributes = accessibilitySource(context: context).attributes(of: ancestor, context: context) else { return .windowDrifted(
                        "section_changed") }
                    ancestors.append(MacAXNode(attributes: attributes, path: Array(sectionPath.prefix(depth)), element: ancestor))
                    let children = accessibilitySource(context: context).children(of: ancestor, limit: index + 1, context: context)
                    guard children.indices.contains(index) else { return .windowDrifted("section_changed") }
                    ancestor = children[index]
                }
                guard accessibilitySource(context: context).sameElement(ancestor, sectionRoot) else { return .windowDrifted("section_changed") }
            }
        }
        let walk = MacAccessibilityReader.walk(
            source: accessibilitySource(context: context),
            root: sectionRoot,
            limits: limits,
            complete: complete
        , context: context)
        let snapshot = sectionPath.isEmpty ? walk : MacAXTreeSnapshot(nodes: ancestors + walk.nodes.map {
            MacAXNode(attributes: $0.attributes, path: sectionPath + $0.path, element: $0.element)
        }, truncated: walk.truncated, truncationReasons: walk.truncationReasons, skippedAtLeast: walk.skippedAtLeast,
            readFailures: walk.readFailures)
        guard let ownerPID = identity?.pid ?? pid,
              let app = accessibilitySource(context: context).appInfo(pid: ownerPID) else { return .appGone }
        let focusPath = accessibilitySource(context: context).focusedElementPath(in: snapshot, relativeTo: root, context: context)
        return .read(MacAXRead(
            snapshot: snapshot,
            app: app,
            rootTitle: snapshot.nodes.first?.attributes.title,
            focusPath: focusPath,
            root: root,
            windowIdentity: identity,
            section: capturedSection
        ))
    }
    /// Browser chrome must not consume the page budget. Rebase page paths to the window root because acts resolve window-relative child chains.
    func pageScoped(
        _ windowRead: MacAXRead,
        limits: MacAXLimits,
        scope: MacLookScope,
        completeWindow: Bool = false,
        context: MacOperationContext
    ) throws -> (read: MacAXRead, seam: [String: JSONValue]) {
        var seam: [String: JSONValue] = [:]
        if let section = windowRead.section {
            return (windowRead, ["scope": .string("section"), "scope_name": .string(section), "complete_window": .bool(false)])
        }
        if completeWindow {
            // Classification owns renderer activation/readiness, never whether a document or its window-relative action addresses survive.
            seam["scope"] = .string("both")
            seam["complete_window"] = .bool(true)
            seam["web_area_count"] = .int(Int64(windowRead.snapshot.nodes.filter { $0.attributes.role == "AXWebArea" }.count))
            return (windowRead, seam)
        }
        // Electron can expose sibling web areas; read the complete window so sidebars, overlays and canvases remain reachable by window-relative paths.
        if scope != .chrome, try MacChromiumAccessibility.looksChromium(
            bundleId: windowRead.app?.bundleIdentifier,
            pid: windowRead.app?.processIdentifier,
            snapshot: windowRead.snapshot
        ) {
            let snapshot = windowRead.snapshot
            let webAreas = snapshot.nodes.filter { $0.attributes.role == "AXWebArea" }
            let hasContent = snapshot.nodes.contains { node in
                webAreas.contains { node.path.count > $0.path.count && node.path.starts(with: $0.path) }
                    && [node.attributes.title, node.attributes.value].contains {
                        !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    }
            }
            seam["scope"] = .string("both")
            seam["web_area_count"] = .int(Int64(webAreas.count))
            if !webAreas.isEmpty {
                seam["enhanced_ax_content"] = .string(hasContent ? "available" : "pending")
            }
            if !webAreas.isEmpty, !hasContent {
                seam["scope_reason"] = .string("enhanced_ax_pending")
                seam["scope_note"] = .string(
                    """
                        The app has not exposed readable renderer content yet. This is its current accessibility tree; app changes deliver new content when \
                        it becomes available.
                        """
                )
            }
            return (MacAXRead(
                snapshot: snapshot, app: windowRead.app, rootTitle: windowRead.rootTitle,
                focusPath: windowRead.focusPath, root: windowRead.root,
                windowIdentity: windowRead.windowIdentity
            ), seam)
        }
        let chromiumFamily = try MacChromiumAccessibility.looksChromium(
            bundleId: windowRead.app?.bundleIdentifier,
            pid: windowRead.app?.processIdentifier,
            snapshot: windowRead.snapshot
        ) || MacChromiumAccessibility.hasWebArea(windowRead.snapshot)
        guard scope != .chrome, chromiumFamily else {
            seam["scope"] = .string(scope == .page && !chromiumFamily ? "chrome" : scope.rawValue)
            if scope == .page, !chromiumFamily {
                seam["scope_reason"] = .string("not_a_chromium_window")
            }
            return (windowRead, seam)
        }
        let populated = populatedWebArea(under: windowRead.root, context: context)
        let search = populated.hit != nil ? populated : MacAccessibilityReader.findFirst(
            role: "AXWebArea",
            source: accessibilitySource(context: context),
            root: windowRead.root
        , context: context)
        guard let web = search.hit else {
            // Chrome scope must distinguish a missing web area from an incomplete search.
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
            // Whole-window walks share one node budget between page and chrome; report that scope so truncation is not mistaken for a complete page.
            seam["scope"] = .string("both")
            seam["web_area_path"] = .array(web.path.map { .int(Int64($0)) })
            seam["scope_note"] = .string(
                "the page shares the node budget with the browser chrome in this scope — use "
                + "scope:\"page\" to spend the whole budget on the page"
            )
            return (windowRead, seam)
        }
        var pageWalk = MacAccessibilityReader.walk(
            source: accessibilitySource(context: context),
            root: web.ref,
            limits: limits
        , context: context)
        // Only a size cut earns a deeper page walk; unreadable elements do not. Preserve any caller-lowered limits.
        if pageWalk.truncationReasons.contains(where: { $0 == "node_cap" || $0 == "depth_cap" }),
           limits == MacAXLimits() {
            pageWalk = MacAccessibilityReader.walk(
                source: accessibilitySource(context: context),
                root: web.ref,
                limits: .deepPage
            , context: context)
            seam["deep_page_walk"] = .bool(true)
        }
        let rebased = MacAXTreeSnapshot(
            nodes: pageWalk.nodes.map { MacAXNode(attributes: $0.attributes, path: web.path + $0.path) },
            truncated: pageWalk.truncated,
            truncationReasons: pageWalk.truncationReasons,
            skippedAtLeast: pageWalk.skippedAtLeast,
            readFailures: pageWalk.readFailures
        )
        let pageFocus = accessibilitySource(context: context).focusedElementPath(in: pageWalk, relativeTo: web.ref, context: context).map { web.path + $0 }
        let chromeControls = windowRead.snapshot.nodes.filter { node in
            MacPerceptionCompiler.isInteractive(node.attributes)
                && !node.path.starts(with: web.path)
        }.count
        seam["scope"] = .string("page")
        seam["web_area_path"] = .array(web.path.map { .int(Int64($0)) })
        seam["chrome"] = .string(
            "browser chrome: toolbar + bookmarks bar, \(chromeControls) control(s) — "
            + "use app {action:\"mac.look\",args:{part:\"toolbar\"}} to inspect the toolbar"
        )
        seam["chrome_controls"] = .int(Int64(chromeControls))
        return (
            MacAXRead(
                snapshot: rebased,
                app: windowRead.app,
                // The WINDOW's title, not the web area's: it is what names the window in every other channel, and dropping it here would make the page look
                // like it belonged to nothing.
                rootTitle: windowRead.rootTitle,
                focusPath: pageFocus,
                root: web.ref,
                // The page walk is still a walk OF THAT WINDOW — the frame it mints has to be re-findable, and the web area is not a window.
                windowIdentity: windowRead.windowIdentity
            ),
            seam
        )
    }
    /// Skip hollow web areas: overlays and loading renderers can precede the real page. Probe read-only within the shared budget.
    func populatedWebArea(under root: MacAXElementRef, context: MacOperationContext) -> MacAccessibilityReader.FindFirstResult {
        let source = accessibilitySource(context: context)
        return MacAccessibilityReader.findFirst(
            source: source,
            root: root,
            maxDepth: MacAccessibilityReader.findFirstMaxDepth,
            nodeBudget: MacAccessibilityReader.findFirstNodeBudget
        , context: context) { ref, attributes in
            attributes.role == "AXWebArea"
                && MacAccessibilityReader.walk(
                    source: source, root: ref, limits: MacAXLimits(maxNodes: 3, maxDepth: 4)
                , context: context).nodes.count >= 3
        }
    }
    /// Find a control by NAME past the ordinary walk's caps. If the walk has no `seek` match, one bounded read-only breadth-first search locates it. Re-root
    /// near the control to include neighbours, keeping paths window-relative.
    func seekScoped(
        _ read: MacAXRead,
        seek: String,
        limits: MacAXLimits,
        context: MacOperationContext
    ) -> (read: MacAXRead, seam: [String: JSONValue]) {
        func normalized(_ raw: String?) -> String {
            (raw ?? "").lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // Deep descent is for pages that bury their controls: a web read, or a walk the caps cut. A miss in an ordinary native window stays cheap.
        guard MacChromiumAccessibility.hasWebArea(read.snapshot) || read.snapshot.truncated else {
            return (read, [:])
        }
        // Keep the requested kind as a requirement so a Save link cannot answer Save button.
        var words = normalized(seek).split(separator: " ").map(String.init)
        if words.first == "the" { words.removeFirst() }
        let kindRoles: [String: Set<String>] = [
            "button": ["AXButton", "AXMenuButton", "AXPopUpButton"],
            "link": ["AXLink"],
            "tab": ["AXRadioButton", "AXTab"],
            "field": ["AXTextField", "AXSecureTextField", "AXTextArea", "AXComboBox", "AXSearchField"],
            "checkbox": ["AXCheckBox"],
            "menu": ["AXMenuButton", "AXPopUpButton", "AXMenuItem"],
            "icon": [],
        ]
        var kindWord: Set<String>?
        if words.count > 1, let kind = kindRoles[words.last ?? ""] {
            words.removeLast()
            kindWord = kind.isEmpty ? nil : kind
        }
        let roles = kindWord
        let wanted = words.joined(separator: " ")
        // Only an actionable control of the requested kind counts, both for "the walk already has it" and for the deep hit: a static text or a field value
        // carrying the same words must not hide the button.
        func names(_ attributes: MacAXAttributes) -> Bool {
            (normalized(attributes.title) == wanted || normalized(attributes.value) == wanted)
                && MacPerceptionCompiler.isInteractive(attributes)
                && roles.map { $0.contains(attributes.role) } ?? true
        }
        guard !wanted.isEmpty else { return (read, [:]) }
        // Skip only when the control will actually be in the percept: a deep page walk can READ it and the affordance cap still drop it.
        let kept = MacPerceptionCompiler.compile(
            snapshot: read.snapshot, secretContext: MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes),
            app: read.app, windowTitle: read.rootTitle, focusPath: read.focusPath
        ).affordances
        if kept.contains(where: { normalized($0.label) == wanted && (roles?.contains($0.role) ?? true) }) {
            return (read, [:])
        }
        let rootPath = read.snapshot.nodes.first?.path ?? []
        let hitPath: [Int]
        if let known = read.snapshot.nodes.first(where: { names($0.attributes) }),
           known.path.starts(with: rootPath) {
            hitPath = Array(known.path.dropFirst(rootPath.count))
        } else if let hit = MacAccessibilityReader.findFirst(
            source: accessibilitySource(context: context),
            root: read.root,
            maxDepth: MacAXLimits.deepPageMaxDepth,
            nodeBudget: MacAXLimits.deepPageMaxNodes
        , context: context) { _, attributes in names(attributes) }.hit {
            hitPath = hit.path
        } else {
            return (read, ["seek": .string(seek), "seek_found": .bool(false)])
        }
        for up in [3, 1, 0] where up <= hitPath.count {
            let prefix = Array(hitPath.dropLast(up))
            var ancestor: MacAXElementRef? = read.root
            for index in prefix {
                ancestor = ancestor.flatMap {
                    let children = accessibilitySource(context: context).children(of: $0, limit: index + 1, context: context)
                    return children.count > index ? children[index] : nil
                }
            }
            guard let ancestor else { break }
            let walk = MacAccessibilityReader.walk(source: accessibilitySource(context: context), root: ancestor, limits: limits, context: context)
            let targetPath = Array(hitPath.suffix(up))
            guard walk.nodes.contains(where: { $0.path == targetPath }) else { continue }
            let base = rootPath + prefix
            return (
                MacAXRead(
                    snapshot: MacAXTreeSnapshot(
                        nodes: walk.nodes.map { MacAXNode(attributes: $0.attributes, path: base + $0.path) },
                        truncated: walk.truncated,
                        truncationReasons: walk.truncationReasons,
                        skippedAtLeast: walk.skippedAtLeast,
                        readFailures: walk.readFailures
                    ),
                    app: read.app,
                    rootTitle: read.rootTitle,
                    focusPath: accessibilitySource(context: context).focusedElementPath(in: walk, relativeTo: ancestor, context: context).map { base + $0 },
                    root: ancestor,
                    windowIdentity: read.windowIdentity
                ),
                ["seek": .string(seek), "seek_found": .bool(true),
                 "seek_path": .array((rootPath + hitPath).map { .int(Int64($0)) })]
            )
        }
        return (read, ["seek": .string(seek), "seek_found": .bool(false)])
    }
    static func axTruncationJSON(_ snapshot: MacAXTreeSnapshot, limits: MacAXLimits) -> [String: JSONValue] {
        let output: [String: JSONValue] = [
            "truncated": .bool(snapshot.truncated),
            "partial": .bool(snapshot.truncated),
            "truncation_reasons": .array(snapshot.truncationReasons.map { .string($0) }),
            "read_failures": .array(snapshot.readFailures.map(JSONValue.string)),
            "skipped_at_least": .int(Int64(snapshot.skippedAtLeast)),
            "max_nodes": .int(Int64(limits.maxNodes)),
            "max_depth": .int(Int64(limits.maxDepth)),
        ]
        return output.merging(snapshot.readGapsJSON) { _, gap in gap }
    }
    func handleAXTree(_ body: [String: JSONValue], context: MacOperationContext) -> MacControlResult {
        let started = now()
        guard accessibilitySource(context: context).isTrusted() else { return axUntrustedResult(action: "ax_tree") }
        let limits = Self.axLimits(from: body)
        let anchored = axSnapshot(limits: limits, context: context)
        if case .selfProcess = anchored {
            return selfInspectionResult(action: "ax_tree", started: started, context: context)
        }
        if case .rendererUnavailable(let reason) = anchored {
            return MacControlResult(ok: false, action: "ax_tree", output: .object(["message": .string(reason)]),
                error: "renderer_accessibility_unavailable", durationMs: Int(now().timeIntervalSince(started) * 1000))
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
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            )
        }
        var output: [String: JSONValue] = Self.axTruncationJSON(read.snapshot, limits: limits)
        output["trusted"] = .bool(true)
        output["app"] = read.app?.toJSON() ?? .null
        // Redact AX text/title at serialization with the view's rules; leave the shared walk unchanged.
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
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
}
