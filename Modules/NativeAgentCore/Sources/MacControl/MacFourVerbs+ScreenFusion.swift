import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
// Blueprint: | `MacFourVerbs+ScreenFusion.swift` | `MacSightCaptureBinding` and `MacFourVerbs.sight`: call-local compiler percept, complete AX read and pixel fusion bound to window identity and frame generation; preserve redaction and natural target addresses |

/// Call-local proof supplied by the canonical view capture, never
/// by app-name matching. Pixels that cannot bind to this look are discarded.
final class MacSightCaptureBinding: @unchecked Sendable {
    @TaskLocal static var current: MacSightCaptureBinding?
    let frameID: String
    private let lock = NSLock()
    private var validate: (@Sendable () async -> Bool)?
    private var read: (read: MacAXRead, seam: [String: JSONValue])?
    private var compiledPercept: MacLookPercept?
    init(frameID: String) { self.frameID = frameID }
    /// A complete uncapped walk and its seam; replacing it clears its percept.
    var walked: (read: MacAXRead, seam: [String: JSONValue])? {
        get { lock.withLock { read } }
        set { lock.withLock { read = newValue; compiledPercept = nil } }
    }
    /// The compiler's typed result, including its full-context redaction verdicts.
    var percept: MacLookPercept? {
        get { lock.withLock { compiledPercept } }
        set { lock.withLock { compiledPercept = newValue } }
    }
    func confirm(validate: @escaping @Sendable () async -> Bool = { true }) {
        lock.lock(); defer { lock.unlock() }
        self.validate = validate
    }
    func isCurrent() async -> Bool {
        let check = lock.withLock { validate }
        return await check?() ?? false
    }
}

extension MacFourVerbs {
    /// `seek`: a name the caller is about to act on. When the ordinary walk
    /// stops short of it, the look searches deeper and frames it (`seekScoped`).
    func sight(part: String?, app: String? = nil, seek: String? = nil,
               observed: MacSightCaptureBinding? = nil) async -> Sighted {
        let captureBinding = observed ?? MacSightCaptureBinding(frameID: UUID().uuidString)
        let continuation = MacWorkContinuation.current.flatMap { $0.isPending ? $0 : nil }
        let app = continuation?.app?.bundleIdentifier ?? continuation?.app?.name ?? app
        let result: MacControlResult
        do {
            // Named-app looks remain anchored without activation; the percept reports their actual front state.
            var body: [String: JSONValue] = ["grade": .string("look"), "app_map": .bool(true)]
            if let app { body["app"] = .string(app) }
            if let part { body["section"] = .string(part) }
            if let seek = seek ?? part, !seek.isEmpty { body["seek"] = .string(seek) }
            result = try await MacSightCaptureBinding.$current.withValue(captureBinding) {
                try await host.dispatch(action: "look", body: body)
            }
        } catch {
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "I can't see the screen right now: \(error).",
                detail: ["error": .string("\(error)")]
            ))
        }
        let output = Self.object(result.output)
        if result.error == "self_inspection_unsupported" {
            let route = Self.ownAppRoute()
            return .blind(MacFourVerbsReply(ok: route.ok, text: route.text,
                detail: route.detail.merging(["frontmost_app": output["frontmost_app"] ?? .null,
                    "running_apps": output["running_apps"] ?? .null,
                    "running_apps_omitted": output["running_apps_omitted"] ?? .int(0)]) { current, _ in current }))
        }
        guard result.ok, let frameId = Self.string(output["frame_id"]), let percept = captureBinding.percept else {
            let why = Self.string(output["message"])
                ?? Self.string(output["note"])
                ?? (result.ok ? "The look returned no typed percept for this call."
                    : Self.lookRefusalWords(result.error ?? Self.string(output["status"]) ?? "unknown"))
            return .blind(MacFourVerbsReply(
                ok: false,
                text: Self.runningAppsLine(output) + "I can't see the screen right now. " + why,
                // The refusal's own words, unwrapped. A caller with a different
                // lead sentence (the cross-app drag: "I can't drop into Mail")
                // must not have to strip this one's off the front.
                detail: Self.operationDetail(result).merging([
                    "error": .string(result.error ?? "look_failed"),
                    "message": .string(why),
                ]) { _, new in new }.merging(output["frontmost_app"].map { ["frontmost_app": $0] } ?? [:]) { current, _ in current }
                    .merging(output["requested_app"].map { ["requested_app": $0] } ?? [:]) { current, _ in current }
            ))
        }

        if percept.app?.bundleIdentifier == MacWakeGuard.loginWindowBundleID {
            return .blind(MacFourVerbsReply(
                ok: false,
                text: MacScreenLock.reply,
                detail: ["error": .string("display_obstructed")]
            ))
        }

        // Unanchored looks describe the front app; anchored looks use the host's front verdict, with true for hosts that omit it.
        let isFront = Self.bool(output["front"]) ?? true
        let (rows, controls) = Self.partition(percept)
        var targets: [ActTarget] = []
        var rowRoleOrdinals: [String: Int] = [:]
        // Render limits keep the model's reply bounded; they must never become
        // an input limit. A control or row revealed by a prior zoom remains a
        // valid natural target even when the next full-screen render elides it.
        for (index, row) in rows.enumerated() {
            let kind = MacScreenRender.kindName(role: row.role)
            let roleOrdinal = (rowRoleOrdinals[kind] ?? 0) + 1
            rowRoleOrdinals[kind] = roleOrdinal
            targets.append(ActTarget(
                handle: row.handle,
                label: MacScreenText(row.label, redacted: row.labelJSON).display,
                kind: kind,
                secret: row.secret,
                ordinal: index + 1,
                roleOrdinal: roleOrdinal,
                enabled: row.enabled,
                frame: row.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: row.path
            ))
            targets[targets.count - 1].placeholder = MacPerceptionCompiler.displayText(row.placeholder, json: row.placeholderJSON)
        }
        let controlOrdinals = MacScreenRender.controlRoleOrdinals(for: controls)
        for control in controls {
            let kind = MacScreenRender.kindName(role: control.role)
            let display = MacScreenText(control.label, redacted: control.labelJSON).display
            let roleOrdinal = controlOrdinals[control.handle]
            targets.append(ActTarget(
                handle: control.handle,
                label: display,
                kind: kind,
                secret: control.secret,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: control.enabled,
                frame: control.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: control.path
            ))
            targets[targets.count - 1].placeholder = MacPerceptionCompiler.displayText(control.placeholder, json: control.placeholderJSON)
        }

        // Structural regions address scroll, move and hover destinations without making their centres click targets.
        var landmarkRoleOrdinals: [String: Int] = [:]
        for landmark in percept.landmarks {
            guard let frame = landmark.frame, frame.w > 0, frame.h > 0 else { continue }
            let label = MacScreenText(
                landmark.label ?? landmark.kind,
                redacted: landmark.labelJSON ?? .string(landmark.kind)
            ).display
            let roleOrdinal = (landmarkRoleOrdinals[landmark.kind] ?? 0) + 1
            landmarkRoleOrdinals[landmark.kind] = roleOrdinal
            targets.append(ActTarget(
                handle: "",
                label: label,
                kind: landmark.kind,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: true,
                frame: frame,
                regionOnly: true,
                sourceAXPath: landmark.path
            ))
        }

        var visibleFrame: MacAXFrame?
        var pointer: MacPointerPosition?
        var pointerFrame: MacAXFrame?
        var supplementalDiagnostics: [String: JSONValue] = [:]
        var nativeAXSupplement: MacFourVerbsSupplement?
        var mergedAXPaths: Set<[Int]> = []
        let supplement = await MacSightCaptureBinding.$current.withValue(captureBinding) {
            await supplementalSource?.observe(app: app)
        }
        if let detail = supplement?.diagnostics, detail["remedy"] != nil {
            return .blind(MacFourVerbsReply(ok: false, text: Self.string(detail["message"]) ?? "The requested screen capture failed.", detail: detail))
        }
        if let supplement, await captureBinding.isCurrent(),
           Self.sameApp(percept: percept, supplement: supplement) {
            visibleFrame = supplement.visibleFrame
            pointer = supplement.pointer
            pointerFrame = supplement.pointerFrame ?? supplement.visibleFrame
            supplementalDiagnostics = supplement.diagnostics
            nativeAXSupplement = supplement
            for candidate in supplement.targets {
                let display = candidate.label?.display
                let duplicateIndex = Self.supplementalDuplicateIndex(candidate, among: targets)
                if let duplicateIndex {
                    if let path = candidate.sourceAXPath { mergedAXPaths.insert(path) }
                    // Enrich the semantic handle with the fused frame and mark
                    // so a named target also retains its physical address.
                    let existing = targets[duplicateIndex]
                    let mergedLabel = existing.label ?? display
                    let mergedFrame = existing.frame ?? candidate.frame
                    // A containing row and its filename are one named item,
                    // but their marks still address DIFFERENT AX elements.
                    // Keep the semantic leaf handle; never donate the row mark.
                    let sameAXElement = existing.sourceAXPath == nil || candidate.sourceAXPath == nil
                        || existing.sourceAXPath == candidate.sourceAXPath
                    let mergedViewId = existing.viewId ?? (sameAXElement ? candidate.viewId : nil)
                    let mergedMark = existing.mark ?? (sameAXElement ? candidate.mark : nil)
                    var enriched = ActTarget(
                        handle: existing.handle,
                        label: mergedLabel,
                        aliases: (existing.aliases + candidate.aliases).reduce(into: []) {
                            if !$0.contains($1) { $0.append($1) }
                        },
                        kind: existing.kind,
                        secret: existing.secret || candidate.secret,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: mergedFrame,
                        observedFrame: existing.observedFrame ?? candidate.observedFrame,
                        excludedFrames: existing.excludedFrames + candidate.excludedFrames,
                        viewId: mergedViewId,
                        mark: mergedMark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly || candidate.physicalOnly,
                        motionUncertain: candidate.motionUncertain,
                        sourceAXPath: existing.sourceAXPath ?? candidate.sourceAXPath,
                        actions: sameAXElement ? candidate.actions : existing.actions,
                        settableAttributes: sameAXElement ? candidate.settableAttributes : existing.settableAttributes
                    )
                    enriched.placeholder = existing.placeholder
                    targets[duplicateIndex] = enriched
                    continue
                }
                let roleOrdinal = candidate.ordinal ?? Self.nextRoleOrdinal(
                    for: candidate.kind, among: targets
                )
                targets.append(ActTarget(
                    handle: "",
                    label: display,
                    aliases: candidate.aliases,
                    kind: candidate.kind,
                    secret: candidate.secret,
                    ordinal: rows.isEmpty ? candidate.ordinal : nil,
                    roleOrdinal: roleOrdinal,
                    enabled: candidate.enabled,
                    frame: candidate.frame,
                    observedFrame: candidate.observedFrame,
                    excludedFrames: candidate.excludedFrames,
                    viewId: candidate.viewId,
                    mark: candidate.mark,
                    regionOnly: candidate.regionOnly,
                    physicalOnly: candidate.physicalOnly,
                    motionUncertain: candidate.motionUncertain,
                    sourceAXPath: candidate.sourceAXPath,
                    actions: candidate.actions,
                    settableAttributes: candidate.settableAttributes
                ))
            }
        } else if supplement != nil {
            // Not this look's own window: nothing from that capture may leave.
            supplementalSource?.rejected()
        }

        // Expose the look frame's existing handle for an empty focused editor as a role ordinal.
        var focusedControl: (label: String, kind: String)?
        if let focus = percept.focus, let handle = focus.handle {
            let kind = MacScreenRender.kindName(role: focus.role)
            let label = focus.displayLabel ?? "focused \(kind)"
            if let index = targets.firstIndex(where: { $0.handle == handle }) {
                // Give an unnamed focused editable control a natural name and aliases on its existing handle.
                if targets[index].label == nil {
                    focusedControl = (label, kind)
                    targets[index].label = label
                    targets[index].aliases = Self.editableKinds.contains(kind)
                        ? Self.focusedEditableAliases(kind: kind)
                        : []
                } else if Self.editableKinds.contains(kind) {
                    targets[index].aliases = Self.focusedEditableAliases(kind: kind)
                }
            } else {
                focusedControl = (label, kind)
                targets.append(ActTarget(
                    handle: handle,
                    label: label,
                    aliases: Self.editableKinds.contains(kind)
                        ? Self.focusedEditableAliases(kind: kind)
                        : [],
                    kind: kind,
                    secret: MacScreenViewBuilder.isSecretField(role: focus.role, subrole: nil, label: focus.label),
                    ordinal: nil,
                    roleOrdinal: Self.nextRoleOrdinal(for: kind, among: targets),
                    enabled: true,
                    frame: nil,
                    viewId: nil,
                    mark: nil,
                    sourceAXPath: focus.path
                ))
            }
        }

        let zoom = Self.zoom(percept, supplement: nativeAXSupplement,
                             mergedAXPaths: mergedAXPaths, focusedControl: focusedControl, part: part)
        let pointerLine: String? = {
            guard let pointer else { return nil }
            guard let frame = pointerFrame else { return "POINTER: observed; surface position unavailable." }
            guard pointer.isInside(frame) else { return "POINTER: outside the observed surface." }
            let x = Int(((pointer.x - frame.x) / frame.w * 100).rounded())
            let y = Int(((pointer.y - frame.y) / frame.h * 100).rounded())
            return "POINTER: \(x)%,\(y)% of the observed surface (system position)."
        }()
        let windowKind = Self.string(output["window_kind"])
        // A walk its caps cut must not read as the whole window: say so, and
        // how to reach the rest (a named act searches past the cut).
        let cutLine: String? = !percept.truncated ? nil
            : percept.truncationReasons.contains("ax_error")
            ? "partial: the app didn't answer every accessibility read; this is only the content read so far."
            : percept.truncationReasons.contains(where: { ["depth_cap", "node_cap", "time_budget"].contains($0) })
            ? "partial: budget reached; this is only the accessibility content read so far."
            : nil
        let rendererNote = Self.string(Self.object(output["seam"])["renderer_wait_note"])
        // Native blocks own AX presentation; the pixel renderer adds only
        // independently recognized regions and canvas evidence.
        guard var nativePage = result.nativePage else {
            return .blind(MacFourVerbsReply(ok: false,
                text: "raw view · accessibility · The look reader did not return a native screen page.",
                detail: ["error": .string("screen_page_unavailable")]))
        }
        // Resolve the names and presses the native page actually offers,
        // rather than a same-named decorative element from the raw percept.
        for thing in nativePage.things {
            guard let address = try? JSONValue.parse(Data(thing.address.utf8)),
                  let handle = Self.string(Self.object(address)["handle"]),
                  let index = targets.firstIndex(where: { $0.handle == handle }) else { continue }
            targets[index].label = thing.name
            if thing.verbs.contains("press") { targets[index].actions = ["AXPress"] }
        }
        var nativeBlocks = Self.array(output["native_page_blocks"]).map(Self.object)
        if let nativeAXSupplement {
            do { try Self.addingNativeAX(nativeAXSupplement, to: &nativePage, blocks: &nativeBlocks, targets: targets, frameID: frameId) }
            catch {
                return .blind(MacFourVerbsReply(ok: false,
                    text: "raw view · accessibility · The supplemental native surfaces could not be compiled: \(error.localizedDescription)",
                    detail: ["error": .string("screen_page_unavailable")]))
            }
        }
        let fullNativeText = nativePage.text
        var nativeZoomNote: String?
        if let part, Self.string(Self.object(output["seam"])["scope_name"]) == part {
            nativeZoomNote = "Read the named native section; its action addresses are unchanged."
        } else if let part {
            var page = nativePage
            let blocks = nativeBlocks
            var scopePaths: [[Int]] = []
            var scopeAddresses: Set<String> = []
            if case .hit(let target) = Self.resolve(part, among: targets) {
                if let path = target.sourceAXPath { scopePaths = [path] }
                else if let ordinal = target.roleOrdinal {
                    let selector = "\(target.kind) \(ordinal)"
                    for block in blocks where Self.string(block["target"]) == selector {
                        if let address = Self.string(block["address"]) { scopeAddresses.insert(address) }
                    }
                }
            } else {
                scopePaths = zoom.paths
            }
            if scopePaths.isEmpty {
                let needle = Self.normalize(part)
                scopePaths = blocks.compactMap { block in
                    guard let text = Self.string(block["text"]),
                          Self.normalize(text.trimmingCharacters(in: CharacterSet(charactersIn: "# \n"))) == needle else { return nil }
                    return Self.path(block["path"])
                }
            }
            if !scopePaths.isEmpty || !scopeAddresses.isEmpty {
                let selected = blocks.enumerated().filter { index, block in
                    if index < 2 { return true }
                    if let address = Self.string(block["address"]), scopeAddresses.contains(address) { return true }
                    let path = Self.path(block["path"])
                    return !path.isEmpty && scopePaths.contains { path.starts(with: $0) || $0.starts(with: path) }
                }.compactMap { Self.string($0.element["text"]) }
                page.text = selected.joined(separator: "\n")
                page.things = page.things.filter { page.text.contains("[" + SenseScreenThings.printed($0.address) + "]") }
                nativePage = page
                nativeZoomNote = "Read the named native section; its action addresses are unchanged."
            } else {
                if zoom.visual {
                    page.text = blocks.prefix(2).compactMap { Self.string($0["text"]) }.joined(separator: "\n")
                    page.things = []
                    nativePage = page
                    nativeZoomNote = "Read the observed visual surface; its existing name and region targets are unchanged."
                } else {
                    nativeZoomNote = "No native section is named \"\(part)\"; this is the whole page."
                }
            }
        }
        let pixelText = zoom.pixelText
        let fullPixelText = zoom.fullPixelText
        let pageText = (nativeZoomNote.map { $0 + "\n" } ?? "") + nativePage.text + pixelText
        let renderedText = (rendererNote.map { $0 + "\n" } ?? "")
            + Self.runningAppsLine(output)
            + pageText
            + (cutLine.map { $0 + "\n" } ?? "") + (pointerLine.map { "\n" + $0 } ?? "")
        var pageDetail: [String: JSONValue] = [:]
        do {
            var page = nativePage
            page.text = renderedText
            do { pageDetail["native_page"] = try JSONValue.parse(JSONEncoder().encode(page)) }
            catch {
                return .blind(MacFourVerbsReply(ok: false,
                    text: "raw view · accessibility · The native screen page could not be encoded: \(error.localizedDescription)",
                    detail: ["error": .string("screen_page_unavailable")]))
            }
        }
        if let name = percept.app?.name {
            // Scroll-bar positions are raw state, excluded from home readouts.
            sightRecorder?.record(app: name, kind: windowKind,
                                  readouts: percept.readouts.filter { $0.role != "AXValueIndicator" }.compactMap(\.displayText))
        }
        return .seen(Sighting(
            render: renderedText,
            effectRender: ([MacScreenPageCompiler.actLine(frameID: frameId), SenseScreenThings.accessibilityReadLine]
                .reduce(fullNativeText) { $0.replacingOccurrences(of: "\n" + $1, with: "") } + fullPixelText)
                .replacingOccurrences(of: frameId, with: "<frame>"),
            pointer: pointer,
            place: Self.place(percept),
            appName: percept.app?.name,
            bundleIdentifier: percept.app?.bundleIdentifier,
            pid: percept.app.map(\.processIdentifier).flatMap { $0 == 0 ? nil : $0 },
            isFront: isFront,
            visibleFrame: visibleFrame,
            windowFrame: Self.frame(output["window_frame"]),
            targets: targets,
            frameId: frameId,
            zoomNote: nativeZoomNote,
            controls: .object([
                "frame_id": .string(frameId),
                "app": output["app"] ?? .null,
                "front": output["front"] ?? .bool(false),
                "affordances": output["affordances"] ?? .array([]),
                "affordances_truncated": output["affordances_truncated"] ?? .bool(false),
                "affordances_omitted": output["affordances_omitted"] ?? .int(0),
            ]),
            detail: [
                "frame_id": .string(frameId),
                "partial": .bool(cutLine != nil),
                "truncation_reasons": .array(percept.truncationReasons.map(JSONValue.string)),
                "bytes": .int(Int64(renderedText.utf8.count)),
                "rows_dropped": .int(0),
                "controls_dropped": .int(0),
                "semantic_targets_omitted": .int(Int64(percept.affordancesOmitted)),
            ].merging(pageDetail) { _, new in new }
                .merging(rendererNote.map { ["renderer_wait_note": JSONValue.string($0)] } ?? [:]) { current, _ in current }
                .merging(supplementalDiagnostics) { current, _ in current },
            frontmostApp: {
                let front = Self.object(output["frontmost_app"])
                guard let name = Self.string(front["name"]),
                      let pid = Self.int(front["pid"]).flatMap(Int32.init(exactly:)), pid > 0 else { return nil }
                return (name, pid, front["window"])
            }(),
            windowKind: windowKind,
            focusPath: percept.focus?.path,
            editableHandles: {
                // Password fields never count, whatever their role says.
                let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
                let secure = Set(percept.affordances.filter {
                    $0.role == "AXSecureTextField" || $0.subrole == "AXSecureTextField"
                }.map(\.handle))
                var editable = Set(percept.affordances.filter {
                    fieldRoles.contains($0.role) || $0.subrole == "AXSearchField"
                }.map(\.handle)).subtracting(secure)
                if let focus = percept.focus, let handle = focus.handle,
                   fieldRoles.contains(focus.role), !secure.contains(handle) { editable.insert(handle) }
                return editable
            }(),
            focusSecure: {
                guard let focus = percept.focus else { return true }
                let read = percept.affordances.first { $0.path == focus.path }
                // A text field whose subrole this read never saw may be a password field.
                if read == nil, ["AXTextField", "AXComboBox"].contains(focus.role) { return true }
                return MacScreenViewBuilder.isSecretField(role: focus.role, subrole: nil, label: focus.label)
                    || read.map {
                        $0.secret || MacScreenViewBuilder.isSecretField(role: $0.role, subrole: $0.subrole, label: $0.label)
                    } == true
            }(),
            obstructions: nativeAXSupplement?.obstructions ?? [],
            percept: percept
        ))
    }

    /// Discard supplements from another app; separate captures cannot manufacture one mixed screen.
    static func sameApp(percept: MacLookPercept, supplement: MacFourVerbsSupplement) -> Bool {
        if let lookID = percept.app?.bundleIdentifier, let viewID = supplement.bundleIdentifier {
            return lookID == viewID
        }
        guard let lookName = percept.app?.name, let viewName = supplement.appName else { return false }
        return normalize(lookName) == normalize(viewName)
    }

}
