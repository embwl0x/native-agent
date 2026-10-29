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
// Blueprint: | `MacAXObservation.swift` | Anchored accessibility reading, scoping and search |
extension SwiftNativeMacControl {
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
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
    /// One read epoch anchors the walk and focus path to the same root; outside-root focus is unknown.
    /// - Parameter pid: re-read this process for identity checks, regardless of frontmost app.
    func axSnapshot(
        limits: MacAXLimits,
        pid: Int32? = nil
    ) -> MacAnchoredRead {
        anchoredSnapshot(limits: limits, pid: pid, window: nil)
    }
    /// One vocabulary for the self-refusal across every read tool.
    static let selfInspectionError = "self_inspection_unsupported"
    static let selfInspectionNote =
        "NativeAgent's own UI cannot be read through Accessibility: AppKit re-entry deadlocks it. "
        + "Use app {page:\"current\"} for pages, settings and actions; page.screenshot for an image; "
        + "setting.set for controls; chat.* for drafts, sending, model, Think and cards; page.show to select a page. "
        + "desk.read, mind.inner_state and agent.introspect read NativeAgent's state. mac.look reads other apps."
    func runningAppProjection() -> [String: JSONValue] {
        let front = accessibilitySource.frontmostApp()?.processIdentifier
        let apps = accessibilitySource.runningApps().sorted {
            if ($0.processIdentifier == front) != ($1.processIdentifier == front) { return $0.processIdentifier == front }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return ["running_apps": .array(apps.prefix(24).map {
            .object(["name": .string(String($0.name.prefix(80))), "front": .bool($0.processIdentifier == front)])
        }), "running_apps_omitted": .int(Int64(max(0, apps.count - 24)))]
    }
    func selfInspectionResult(action: String, started: Date) -> MacControlResult {
        MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "trusted": .bool(true),
                "status": .string(Self.selfInspectionError),
                "error": .string(Self.selfInspectionError),
                "message": .string(Self.selfInspectionNote),
                "frontmost_app": accessibilitySource.frontmostApp()?.toJSON() ?? .null,
            ].merging(runningAppProjection()) { _, new in new }),
            error: Self.selfInspectionError,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
    /// The outcome of a WINDOW-ANCHORED read.
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
        /// Refuse self-process AX walks before any read: AppKit re-entry can deadlock the main thread.
        case selfProcess
    }
    /// One read epoch, optionally anchored to a NAMED WINDOW of a named process.
    ///
    /// - `pid` nil ⇒ the frontmost window of the frontmost app (`mac_ax_tree`,
    ///   `mac_ax_find`, the first look).
    /// - `pid` given, `window` nil ⇒ that process's first window.
    /// - `pid` AND `window` given ⇒ the matching composite window identity or a refusal.
    func anchoredSnapshot(
        limits: MacAXLimits,
        pid: Int32?,
        window: MacAXWindowIdentity?,
        complete: Bool = false,
        section: String? = nil
    ) -> MacAnchoredRead {
        // See `MacAnchoredRead.selfProcess` — refusing here, before any element
        // is resolved, is what keeps the in-process AppKit re-entry deadlock
        // structurally unreachable from every snapshot caller.
        if pid == getpid() { return .selfProcess }
        let root: MacAXElementRef
        var identity: MacAXWindowIdentity?
        if let pid, let window {
            let candidates = accessibilitySource.windowRoots(pid: pid)
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
            guard let preferred = accessibilitySource.windowRoot(pid: pid),
                  let attributes = accessibilitySource.attributes(of: preferred) else { return .appGone }
            root = preferred
            identity = MacAXWindowIdentity(
                pid: pid, index: nil, role: attributes.role,
                subrole: attributes.subrole, title: attributes.title, frame: attributes.frame
            )
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
        identity = identity?.retainingWindow(root, in: accessibilitySource)
        var sectionRoot = root
        var sectionPath: [Int] = []
        var ancestors: [MacAXNode] = []
        var capturedSection: String?
        if let section {
            let needle = MacFourVerbs.normalize(section)
            let match = MacAccessibilityReader.findFirst(source: accessibilitySource, root: root,
                maxDepth: MacAXLimits.deepPageMaxDepth, nodeBudget: MacAXLimits.deepPageMaxNodes) { _, attributes in
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
                    guard let attributes = accessibilitySource.attributes(of: ancestor) else { return .windowDrifted("section_changed") }
                    ancestors.append(MacAXNode(attributes: attributes, path: Array(sectionPath.prefix(depth)), element: ancestor))
                    let children = accessibilitySource.children(of: ancestor, limit: index + 1)
                    guard children.indices.contains(index) else { return .windowDrifted("section_changed") }
                    ancestor = children[index]
                }
                guard accessibilitySource.sameElement(ancestor, sectionRoot) else { return .windowDrifted("section_changed") }
            }
        }
        let walk = MacAccessibilityReader.walk(
            source: accessibilitySource,
            root: sectionRoot,
            limits: limits,
            complete: complete
        )
        let snapshot = sectionPath.isEmpty ? walk : MacAXTreeSnapshot(nodes: ancestors + walk.nodes.map {
            MacAXNode(attributes: $0.attributes, path: sectionPath + $0.path, element: $0.element)
        }, truncated: walk.truncated, truncationReasons: walk.truncationReasons, skippedAtLeast: walk.skippedAtLeast)
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
            windowIdentity: identity,
            section: capturedSection
        ))
    }
    /// Chromium/Electron perception compiles from a bounded, read-only web-area search when found.
    /// Browser chrome collapses to one line so it cannot consume the page's walk budget.
    ///
    /// Paths stay WINDOW-RELATIVE: the page walk is re-based onto the web
    /// area's own path, because `mac_act` resolves a child-index chain from the
    /// window root and a page-relative path would address a different element
    /// entirely.
    func pageScoped(
        _ windowRead: MacAXRead,
        limits: MacAXLimits,
        scope: MacLookScope,
        completeWindow: Bool = false
    ) -> (read: MacAXRead, seam: [String: JSONValue]) {
        var seam: [String: JSONValue] = [:]
        if let section = windowRead.section {
            return (windowRead, ["scope": .string("section"), "scope_name": .string(section), "complete_window": .bool(false)])
        }
        if completeWindow {
            // Classification owns renderer activation/readiness, never whether
            // a document or its window-relative action addresses survive.
            seam["scope"] = .string("both")
            seam["complete_window"] = .bool(true)
            seam["web_area_count"] = .int(Int64(windowRead.snapshot.nodes.filter { $0.attributes.role == "AXWebArea" }.count))
            return (windowRead, seam)
        }
        // Electron can expose several sibling web areas (sidebar, overlays,
        // conversation, canvas). Choosing the first shallow, nonempty area
        // hides the rest. Read the complete window after enabling the renderer
        // and retain window-relative paths for every existing mac.act target.
        if scope != .chrome, MacChromiumAccessibility.looksChromium(
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
                    "The app has not exposed readable renderer content yet. This is its current accessibility tree; app changes deliver new content when it becomes available."
                )
            }
            return (MacAXRead(
                snapshot: snapshot, app: windowRead.app, rootTitle: windowRead.rootTitle,
                focusPath: windowRead.focusPath, root: windowRead.root,
                windowIdentity: windowRead.windowIdentity
            ), seam)
        }
        let chromiumFamily = MacChromiumAccessibility.looksChromium(
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
        // Prefer the first web area with content; any web area otherwise.
        let populated = populatedWebArea(under: windowRead.root)
        let search = populated.hit != nil ? populated : MacAccessibilityReader.findFirst(
            role: "AXWebArea",
            source: accessibilitySource,
            root: windowRead.root
        )
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
        var pageWalk = MacAccessibilityReader.walk(
            source: accessibilitySource,
            root: web.ref,
            limits: limits
        )
        // A page the ordinary budget had to cut is walked once more on the
        // deeper page budget, so a pane buried under unnamed groups is in the
        // percept instead of silently missing. A caller that LOWERED the
        // limits keeps them.
        // Only a SIZE cut earns the second walk; an unreadable element does not.
        if pageWalk.truncationReasons.contains(where: { $0 == "node_cap" || $0 == "depth_cap" }),
           limits == MacAXLimits() {
            pageWalk = MacAccessibilityReader.walk(
                source: accessibilitySource,
                root: web.ref,
                limits: .deepPage
            )
            seam["deep_page_walk"] = .bool(true)
        }
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
            + "use app {action:\"mac.look\",args:{part:\"toolbar\"}} to inspect the toolbar"
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
    /// The first `AXWebArea` with content under it. A web area with (almost)
    /// nothing below it is an overlay or a page still loading, not the page:
    /// Claude.app lists an empty one first (the page-first walk read its two
    /// nodes), and after the enhanced-AX flag it shows a hollow web area ~2 s
    /// before the content lands. Live, bounded, read-only probe.
    func populatedWebArea(under root: MacAXElementRef) -> MacAccessibilityReader.FindFirstResult {
        let source = accessibilitySource
        return MacAccessibilityReader.findFirst(
            source: source,
            root: root,
            maxDepth: MacAccessibilityReader.findFirstMaxDepth,
            nodeBudget: MacAccessibilityReader.findFirstNodeBudget
        ) { ref, attributes in
            attributes.role == "AXWebArea"
                && MacAccessibilityReader.walk(
                    source: source, root: ref, limits: MacAXLimits(maxNodes: 3, maxDepth: 4)
                ).nodes.count >= 3
        }
    }
    /// Find a control by NAME past the ordinary walk's caps.
    ///
    /// If the walk has no `seek` match, one bounded read-only breadth-first search locates it.
    /// Re-root near the control to include neighbours, keeping paths window-relative.
    func seekScoped(
        _ read: MacAXRead,
        seek: String,
        limits: MacAXLimits
    ) -> (read: MacAXRead, seam: [String: JSONValue]) {
        func normalized(_ raw: String?) -> String {
            (raw ?? "").lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // Deep descent is for pages that bury their controls: a web read, or a
        // walk the caps cut. A miss in an ordinary native window stays cheap.
        guard MacChromiumAccessibility.hasWebArea(read.snapshot) || read.snapshot.truncated else {
            return (read, [:])
        }
        // "the Attach simulator button" names the control "Attach simulator",
        // and the kind word stays a requirement: a "Save" link is not the
        // "Save button".
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
        // Only an actionable control of the requested kind counts, both for
        // "the walk already has it" and for the deep hit: a static text or a
        // field value carrying the same words must not hide the button.
        func names(_ attributes: MacAXAttributes) -> Bool {
            (normalized(attributes.title) == wanted || normalized(attributes.value) == wanted)
                && MacPerceptionCompiler.isInteractive(attributes)
                && roles.map { $0.contains(attributes.role) } ?? true
        }
        guard !wanted.isEmpty else { return (read, [:]) }
        // Skip only when the control will actually be in the percept: a deep
        // page walk can READ it and the affordance cap still drop it.
        let kept = MacPerceptionCompiler.compile(
            snapshot: read.snapshot, secretContext: MacScreenViewTextRedaction.nodeSecretContext(read.snapshot.nodes),
            app: read.app, windowTitle: read.rootTitle, focusPath: read.focusPath
        ).affordances
        if kept.contains(where: { normalized($0.label) == wanted && (roles?.contains($0.role) ?? true) }) {
            return (read, [:])
        }
        // The root's own path from the window: [] for a window walk, the web
        // area's path for a page walk.
        let rootPath = read.snapshot.nodes.first?.path ?? []
        let hitPath: [Int]
        if let known = read.snapshot.nodes.first(where: { names($0.attributes) }),
           known.path.starts(with: rootPath) {
            hitPath = Array(known.path.dropFirst(rootPath.count))
        } else if let hit = MacAccessibilityReader.findFirst(
            source: accessibilitySource,
            root: read.root,
            maxDepth: MacAXLimits.deepPageMaxDepth,
            nodeBudget: MacAXLimits.deepPageMaxNodes
        ) { _, attributes in names(attributes) }.hit {
            hitPath = hit.path
        } else {
            return (read, ["seek": .string(seek), "seek_found": .bool(false)])
        }
        for up in [3, 1, 0] where up <= hitPath.count {
            let prefix = Array(hitPath.dropLast(up))
            var ancestor: MacAXElementRef? = read.root
            for index in prefix {
                ancestor = ancestor.flatMap {
                    let children = accessibilitySource.children(of: $0, limit: index + 1)
                    return children.count > index ? children[index] : nil
                }
            }
            guard let ancestor else { break }
            let walk = MacAccessibilityReader.walk(source: accessibilitySource, root: ancestor, limits: limits)
            let targetPath = Array(hitPath.suffix(up))
            guard walk.nodes.contains(where: { $0.path == targetPath }) else { continue }
            let base = rootPath + prefix
            return (
                MacAXRead(
                    snapshot: MacAXTreeSnapshot(
                        nodes: walk.nodes.map { MacAXNode(attributes: $0.attributes, path: base + $0.path) },
                        truncated: walk.truncated,
                        truncationReasons: walk.truncationReasons,
                        skippedAtLeast: walk.skippedAtLeast
                    ),
                    app: read.app,
                    rootTitle: read.rootTitle,
                    focusPath: accessibilitySource.focusedElementPath(relativeTo: ancestor).map { base + $0 },
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
