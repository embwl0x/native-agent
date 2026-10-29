import Foundation
import NativeAgentCore

// Blueprint: | `MacFourVerbs+AppMap.swift` | `MacFourVerbs` app-map integration: remember verified named controls; control-scoped pointer hypotheses retain contrary and uncertain outcomes, match fresh live evidence and never block background Accessibility |

// Per-app maps live in `MacAppMaps.swift`.
// Record only verified named-control acts; reuse only when the live element at the remembered path matches kind, label and request.
// A mismatch weakens or evicts the entry; stale memory must never redirect a click.
extension MacFourVerbs {
    static func appMapFailure(_ error: Error, after reply: MacFourVerbsReply? = nil) -> MacFourVerbsReply {
        var detail = reply?.detail ?? ["effects": .string("none")]
        detail["app_map_error"] = .string(error.localizedDescription)
        detail["app_map_saved"] = .bool(false)
        return MacFourVerbsReply(ok: reply?.ok ?? false,
            text: (reply.map { $0.text + "\n" } ?? "") + "App-map learning failed: " + error.localizedDescription,
            detail: detail)
    }

    /// Controls, never content: a row or a field's label can be someone's
    /// file name, subject line or typed text.
    static let mappableKinds: Set<String> = [
        "button", "menu", "popup", "checkbox", "radio", "tab", "menu item", "disclosure", "stepper", "slider",
    ]

    /// The name as a map key, or nil for an address that is positional
    /// (`row 3`, `button 2 Remove`) or aimed inside a thing (`top of …`).
    static func mapName(_ target: String) -> String? {
        let whole = normalize(target)
        guard !whole.isEmpty, labeledOrdinalAddress(in: target) == nil,
              stripWithinTargetAimQualifier(target) == whole else { return nil }
        if !isExactOnlyName(normalize(stripRoleWords(target))), ordinalAddress(in: target) != nil { return nil }
        return whole
    }

    /// A verified act on a named control: remember where it lives.
    func rememberVerified(_ target: String, _ candidate: ActTarget, in sighting: Sighting) async throws {
        guard let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
              let asked = Self.mapName(target), let path = candidate.sourceAXPath, !path.isEmpty,
              let label = candidate.label, !label.isEmpty,
              !candidate.isSupplemental, !candidate.regionOnly, !candidate.physicalOnly,
              Self.mappableKinds.contains(candidate.kind),
              // By its LABEL — an alias (focus) or an ordinal is not a name.
              Self.answers(target, ActTarget(handle: candidate.handle, label: label, kind: candidate.kind,
                                             ordinal: nil, enabled: true)) else { return }
        let store = MacAppMapStore.shared
        // App chrome only. A label already vetted when it was first stored is
        // not re-checked; a new one must be a stable system label or appear in
        // the app's own menu bar. Anything else could be content: not stored.
        if !(try await store.has(bundle: bundle, window: window, asked: asked, label: label)) {
            if !MacAppMaps.isStableSystemLabel(label) {
                guard await inMenuBar(label, app: sighting.appName) else { return }
            }
        }
        try await store.record(bundle: bundle, window: window, asked: asked, label: label,
                           kind: candidate.kind, path: path)
    }

    /// Identity is the live control in its window kind, including path and
    /// label. A success on another same-kind control says nothing about it.
    private static func pressControl(_ pressed: ActTarget, in sighting: Sighting) -> String? {
        guard let window = sighting.windowKind, let path = pressed.sourceAXPath, !path.isEmpty,
              let label = pressed.label, !label.isEmpty, mappableKinds.contains(pressed.kind),
              !pressed.isSupplemental, !pressed.regionOnly, !pressed.physicalOnly else { return nil }
        return CausalTransitionEvidence.opaqueIdentity(
            [window, pressed.kind, normalize(label), path.map(String.init).joined(separator: ".")].joined(separator: "\u{0}"))
    }

    /// A hypothesis for this control, never an exclusive capability claim.
    func pressesByPointer(_ pressed: ActTarget, in sighting: Sighting) async throws -> Bool {
        guard let bundle = sighting.bundleIdentifier,
              let control = Self.pressControl(pressed, in: sighting) else { return false }
        return try await MacAppMapStore.shared.pressRoute(bundle: bundle, control: control)?.suggestsPointer == true
    }

    func learnRoute(pointer: Bool, pressed: ActTarget, reply: MacFourVerbsReply, in sighting: Sighting) async throws {
        guard let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
              let label = pressed.label, let control = Self.pressControl(pressed, in: sighting) else { return }
        let store = MacAppMapStore.shared
        // Apply the same chrome-only privacy boundary as remembered controls.
        let knownChrome: Bool
        if MacAppMaps.isStableSystemLabel(label) { knownChrome = true }
        else {
            knownChrome = try await store.entries(bundle: bundle, window: window).contains {
                $0.path == pressed.sourceAXPath && $0.label == label && $0.kind == pressed.kind
            }
        }
        guard knownChrome else { return }
        let verification = Self.string(reply.detail["verification"])
        let outcome = reply.ok && verification == MotorVerificationState.satisfied.rawValue
            && Self.string(reply.detail["verification_scope"]) != MacActClosedLoop.ActClassification.readoutOnlyScope
            ? "satisfied" : verification == MotorVerificationState.failed.rawValue ? "failed" : "unverified"
        try await store.recordPress(bundle: bundle, control: control, pointer: pointer, outcome: outcome)
    }

    /// Whether the app's own menu bar has an item with exactly this label
    /// (menus only, never a window walk).
    private func inMenuBar(_ label: String, app: String?) async -> Bool {
        guard let app else { return false }
        guard let result = try? await host.dispatch(action: "menu", body: [
            "find": .string(label), "app": .string(app),
        ]), result.ok else { return false }
        let wanted = Self.normalize(label)
        return Self.array(Self.object(result.output)["found"]).contains { row in
            guard let path = Self.string(Self.object(row)["path"]),
                  let last = MacMenuBar.components(path).last else { return false }
            return Self.normalize(last) == wanted
        }
    }

    /// The fresh read has no match for `target`. A remembered control is used
    /// only when the live element at its path still is that control. Two or
    /// more remembered controls answering is a question, never a pick.
    func mapResolve(_ target: String, in sighting: Sighting) async throws -> Resolution? {
        guard let bundle = sighting.bundleIdentifier, let window = sighting.windowKind,
              let asked = Self.mapName(target) else { return nil }
        let bare = Self.normalize(Self.stripRoleWords(target))
        // A role named in the request ("Save menu item") binds: a remembered
        // Save BUTTON does not answer it.
        let namedKind = Self.trailingRoleQualifier(in: target)?.kind ?? Self.roleHint(in: target)
        let store = MacAppMapStore.shared
        let entries = try await store.entries(bundle: bundle, window: window)
            .filter { ($0.asked == asked || Self.normalize($0.label) == bare)
                && (namedKind == nil || $0.kind == namedKind) }
        let live = sighting.targets
        var verified: [ActTarget] = []
        for entry in entries {
            guard let element = live.first(where: { $0.sourceAXPath == entry.path && !$0.isSupplemental }) else {
                // Not in this read at all: maybe gone, maybe past the read's
                // caps. Weaken, don't guess.
                try await store.penalize(bundle: bundle, window: window, path: entry.path, evict: false)
                continue
            }
            if element.kind == entry.kind, !element.regionOnly,
               Self.normalize(element.label ?? "") == Self.normalize(entry.label),
               Self.answers(target, element) {
                if !verified.contains(where: { $0.sourceAXPath == element.sourceAXPath }) { verified.append(element) }
                continue
            }
            // Something else lives at that path now.
            try await store.penalize(bundle: bundle, window: window, path: entry.path, evict: true)
        }
        if verified.count > 1 { return .ambiguous(verified) }
        return verified.first.map { .hit($0) }
    }

}
