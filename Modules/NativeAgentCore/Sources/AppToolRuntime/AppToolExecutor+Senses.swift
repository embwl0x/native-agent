import ChatOrchestration
import Foundation
import PersistenceCore
import Senses

extension AppActions {
    /// A sense's offered verbs use the same action vocabulary as every page.
    static func senses() -> [AppAction] {
        guard SensesHub.shared.registry != nil else { return [] }
        let scope = ChatToolSessionContext.verifiedSessionId ?? ""
        var seen: Set<String> = []
        return SenseDoorViews.shared.latest.filter { $0.scope == scope && $0.record.verbsEnabled }.flatMap { view in
            view.page.things.flatMap { thing in
                thing.verbs.compactMap { verb -> AppAction? in
                    let id = "sense.\(view.record.id).\(verb)"
                    guard seen.insert(id).inserted else { return nil }
                    return AppAction(id, view.page.corner.key, verb + " " + thing.name, ["address", "args?:object"],
                        tool: "sense_act", input: ["sense_id": .string(view.record.id), "verb": .string(verb)],
                        scriptable: false)
                }
            }
        }
    }
}

extension AppToolExecutor {
    private static func inputInt(_ raw: JSONValue?) -> Int64? {
        if case .int(let value)? = raw, value >= 0 { return value }
        return nil
    }

    /// A corner is read through its existing action, so the original gate and
    /// raw reader remain authoritative. The sense adapter lives behind it.
    @MainActor
    func doorSenseRead(corner: SenseCorner, item: String, input: [String: JSONValue]) async throws -> JSONValue? {
        guard try await SenseDoor.selectedRecord(for: corner) != nil else { return nil }
        guard let perform = AppDoorReentry.perform else {
            return Self.failure("door_unavailable", "Read this corner from a chat turn.")
        }
        var args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
        if item.hasPrefix("{"), case .object(let fields) = try JSONValue.parse(Data(item.utf8)) {
            args.merge(fields.filter { !$0.key.hasPrefix("__sense_") }) { _, new in new }
        }
        let scope = ChatToolSessionContext.verifiedSessionId ?? ""
        let siteFailureEvidence: [String: JSONValue] = ["effects": .string("none"),
            "provenance": .string("raw view · Chrome conversation page and reading-place bindings; no page was read")]
        let servedView = SenseDoorViews.shared.latest.reversed().first {
            $0.scope == scope && $0.page.corner == corner && ($0.page.address == item || $0.page.more == item
                || $0.page.things.contains { $0.address == item })
        }
        let independentSiteRead = servedView.map {
            [JSONValue.string("web.read"), .string("browser.text"), .string("browser.links")]
                .contains($0.readInput["__sense_action"] ?? .null)
        } ?? false
        let siteURL: String?
        if case .site = corner, independentSiteRead {
            siteURL = servedView?.materialRef
        } else if case .site(let host) = corner, item.hasPrefix("site:\(host)/"), item.contains("?read=more") {
            let continuation = try SenseNativePages.chromeContinuationArguments(item, scope: scope, tab: Self.inputInt(args["tab_id"]))
            args.merge(continuation) { _, saved in saved }
            guard let more = Self.inputString(continuation["more"]), case .object(let cursor) = try JSONValue.parse(Data(more.utf8)),
                  let url = Self.inputString(cursor["url"]), URL(string: url)?.host?.lowercased() == host else {
                return Self.failure("invalid_address", "Read this corner with a URL on its host.", extra: siteFailureEvidence)
            }
            siteURL = url
        } else if case .site(let host) = corner, item.hasPrefix("site:\(host)/") {
            let matches = SenseDoorViews.shared.latest.reversed().filter {
                $0.scope == scope && $0.page.corner == corner
                    && ($0.page.address == item || $0.page.more == item || $0.page.things.contains { $0.address == item }
                        || ($0.materialRef.map { SenseNativePages.chromeAddress(host: host, url: $0) == item.split(separator: "#", maxSplits: 1).first.map(String.init) } ?? false))
            }
            if let url = matches.first?.materialRef { siteURL = url }
            else {
                let status = await chrome().conversationTabStatus(ChatToolSessionContext.verifiedSessionId)
                let matches: [[String: JSONValue]] = if case .array(let tabs)? = status["tabs"] {
                    tabs.compactMap { value in
                        guard case .object(let tab) = value, let url = Self.inputString(tab["url"]),
                              SenseNativePages.chromeAddress(host: host, url: url) == item,
                              Self.inputInt(args["tab_id"]).map({ tab["tab_id"] == .int($0) }) ?? true else { return nil }
                        return tab
                    }
                } else { [] }
                guard matches.count == 1, let tab = matches.first, let url = Self.inputString(tab["url"]) else {
                    return Self.failure("invalid_address", "This site place has not been read in this conversation; read its held tab first.", extra: siteFailureEvidence)
                }
                args["tab_id"] = tab["tab_id"]
                siteURL = url
            }
        } else if case .site(let host) = corner, let more = Self.inputString(args["more"]),
                  case .object(let cursor) = try JSONValue.parse(Data(more.utf8)),
                  let url = Self.inputString(cursor["url"]), URL(string: url)?.host?.lowercased() == host {
            // Independent control continuations are not the page's single
            // `more` pointer. Their exact cursor owns the URL and element.
            siteURL = url
        } else { siteURL = nil }
        let view = independentSiteRead ? servedView : SenseDoorViews.shared.latest.reversed().first {
            $0.scope == scope && $0.page.corner == corner && ($0.page.address == item || $0.page.more == item
                || $0.page.things.contains { $0.address == item } || (siteURL != nil && $0.materialRef == siteURL))
        }
        let action: String
        switch corner {
        case .app(let bundleID):
            action = "mac.look"; args["app"] = .string(bundleID)
            if !item.isEmpty, view == nil { args["part"] = .string(item) }
        case .fileKind(let ext):
            action = "files.read"
            let named = item.isEmpty || item.hasPrefix("{") ? Self.doorText(args["path"]) : item
            let path = view?.materialRef ?? (URL(string: named)?.isFileURL == true ? URL(string: named)!.path : named)
            guard ext == "*" || URL(fileURLWithPath: path).pathExtension.lowercased() == ext else {
                return Self.failure("invalid_address", "Read this corner with a file path of its kind.")
            }
            args["path"] = .string(path)
        case .site(let host):
            let url = siteURL ?? view?.materialRef ?? (item.isEmpty ? Self.doorText(args["url"]) : item)
            guard item.isEmpty || URL(string: url)?.host?.lowercased() == host else {
                return Self.failure("invalid_address", "Read this corner with a URL on its host.", extra: siteFailureEvidence)
            }
            if let view, let reader = Self.inputString(view.readInput["__sense_action"]), let entry = AppActions.action(reader) {
                action = reader
                let names = Set(entry.argSpecs.flatMap(\.names))
                args = view.readInput.filter { names.contains($0.key) }.merging(args) { _, new in new }
            } else {
                action = "chrome.snapshot"
                if Self.inputInt(args["tab_id"]) == nil {
                    let address = try await chrome().existingPageAddress(host: host)
                    args = address.merging(args) { _, supplied in supplied }
                }
                args.removeValue(forKey: "url")
            }
            if let view, view.record.language == .native, !item.contains("?read=more"),
               let thing = view.page.things.first(where: { $0.address == item }),
               case .pageSnapshot(.object(let captured))? = view.capturedMaterial,
               case .array(let nodes)? = captured["nodes"],
               case .object(let node)? = nodes.first(where: { value in
                   guard case .object(let node) = value, let fragment = Self.inputString(node["addressFragment"]) else { return false }
                   return thing.address == SenseNativePages.chromeAddress(host: host, url: url, fragment: fragment)
               }), let path = Self.inputString(node["elementPath"]), case .int(let frame)? = node["frameId"] {
                let framePrefix = "frame/\(frame)/"
                guard path.hasPrefix(framePrefix) else { return Self.failure("invalid_address", "This site place has no captured frame route; read its held tab again.", extra: siteFailureEvidence) }
                let frameURL: JSONValue? = if case .array(let frames)? = captured["frames"] {
                    frames.first { if case .object(let row) = $0 { return row["frameId"] == .int(frame) }; return false }
                        .flatMap { if case .object(let row) = $0 { return row["url"] }; return nil }
                } else { nil }
                let cursor: [String: JSONValue] = ["url": .string(url), "frameURL": frameURL ?? .string(url),
                    "frameId": .int(frame), "elementPath": .string(String(path.dropFirst(framePrefix.count))),
                    "addressFragment": node["addressFragment"] ?? .null, "textOffset": node["textOffset"] ?? .int(0),
                    "name": node["sectionName"] ?? node["name"] ?? .string(thing.name)]
                args["tab_id"] = captured["tabId"]
                args["more"] = .string(try JSONValue.object(cursor).serialize(pretty: false))
            }
        case .stream(let id) where id == "web":
            action = "web.read"
            if let view { args = view.readInput.filter { !$0.key.hasPrefix("__") }.merging(args) { _, new in new } }
            if !item.isEmpty, !item.hasPrefix("{"), view == nil { args["url"] = .string(item) }
        case .stream(let id) where id == "browser":
            action = view.flatMap { Self.inputString($0.readInput["__sense_action"]) } == "browser.links" ? "browser.links" : "browser.text"
            if let view { args = view.readInput.filter { !$0.key.hasPrefix("__") }.merging(args) { _, new in new } }
        case .stream(let id) where id == "mac.read":
            action = "mac.read"
            if let view { args = view.readInput.filter { !$0.key.hasPrefix("__") }.merging(args) { _, new in new } }
            if !item.isEmpty, !item.hasPrefix("{"), args["path"] == nil { args["path"] = .string(item) }
        default: return nil
        }
        var call: [String: JSONValue] = ["action": .string(action), "args": .object(args)]
        if case .site = corner, item.isEmpty {
            return Self.doorRefusal("action_route", "Read this site's held Chrome tab with the corrected app call. Nothing was read.",
                remedy: "correct_route", "Make next_call to read the page.", next: call)
        }
        call["__session_id"] = input["__session_id"]
        if case .site = corner {
            // Page URL and structural element paths survive fresh captures;
            // focus and folded cursors resolve in the current page's material.
            if siteURL != nil || view != nil { call["__sense_address"] = .string(item) }
        } else if view != nil || item.hasPrefix("{") { call["__sense_address"] = .string(item) }
        return try await perform("app", call)
    }

    @MainActor
    func runSenseAct(input: [String: JSONValue]) async -> JSONValue {
        let id = Self.doorText(input["sense_id"]), verb = Self.doorText(input["verb"])
        let address = Self.doorText(input["address"])
        let scope = ChatToolSessionContext.verifiedSessionId ?? ""
        let view = SenseDoorViews.shared.latest.reversed().first(where: {
            $0.scope == scope && $0.record.id == id && $0.page.things.contains { $0.address == address && $0.verbs.contains(verb) }
        })
        let selected: SenseRecord?
        do {
            if let view { selected = try await SenseDoor.selectedRecord(for: view.page.corner) }
            else { selected = nil }
        }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
        guard let view, let registry = SensesHub.shared.registry,
           let record = selected, record.id == id,
           record.version == view.record.version, record.verbsEnabled,
           record.origin != .shared || record.verbs.contains(verb),
           let runner = SensesHub.shared.runner, let perform = AppDoorReentry.perform else {
            if id == "builtin-chrome", verb == "click" {
                return Self.doorRefusal("sense_verb_unavailable", "This Chrome thing is no longer available to this sense. Nothing ran.",
                    remedy: "read_page", "Read next_call, then use chrome.click with node_id set to a row number or label from that page.",
                    next: ["action": .string("chrome.snapshot"), "args": .object(view?.readInput.filter {
                        ["tab_id", "expected_user_sequence"].contains($0.key)
                    } ?? [:])])
            }
            return Self.failure("sense_verb_unavailable", "Read the corner again before acting on this thing.")
        }
        // Read authority can have changed since this thing was served. Re-enter
        // the raw reader under today's policy before handing its material over.
        let freshSource: SenseActSource
        let siteBoundary: SiteSenseActionBoundary?
        do {
            guard let source = SensesHub.shared.source else { throw SenseFailure(code: "source_unavailable", message: "The source provider is unavailable.") }
            var arguments = view.readInput.filter { (!$0.key.hasPrefix("__") || $0.key == "__sense_reader") && !["raw", "wrong", "why"].contains($0.key) }
            if case .fileKind = view.page.corner, let path = view.materialRef { arguments["path"] = .string(path) }
            if case .app(let id) = view.page.corner, arguments["app"] == nil { arguments["app"] = .string(id) }
            if case .site = view.page.corner {
                guard case .pageSnapshot(.object(let served))? = view.capturedMaterial,
                      case .int(let tab)? = served["tabId"], tab >= 0,
                      case .int(let sequence)? = served["userSequence"] else {
                    throw SenseFailure(code: "source_unavailable", message: "Read this site again before acting; the served Chrome snapshot is unavailable.")
                }
                arguments["tab_id"] = .int(tab)
                arguments["expected_user_sequence"] = .int(sequence)
            }
            let readAddress = try JSONValue.object(arguments).serialize(pretty: false)
            // Native screen verbs retain the served frame. mac.act rechecks
            // current Trust and target drift without replacing that frame.
            let material: SenseMaterial?
            if case .app = view.page.corner {
                // A new look would invalidate the served frame's handles.
                // Translate the exact selection Agent saw; mac.act owns the
                // current Trust, window drift and target re-observation gates.
                material = view.capturedMaterial
                if record.language != .native, material == nil {
                    throw SenseFailure(code: "source_unavailable", message: "Read this app again before acting; its served AX snapshot is unavailable.")
                }
            } else { material = try await source.material(for: view.page.corner, address: readAddress) }
            if case .site(let host) = view.page.corner {
                guard let material else {
                    throw SenseFailure(code: "source_unavailable", message: "The site snapshot is unavailable.")
                }
                guard let original = view.capturedMaterial else {
                    throw SenseFailure(code: "source_unavailable", message: "Read this site again before acting; the served Chrome snapshot is unavailable.")
                }
                siteBoundary = try SiteSenseActionBoundary(host: host, address: address, verb: verb,
                    original: original, fresh: material)
                // The sense translates the thing Agent actually saw. The action
                // boundary separately binds it to that same element in the
                // fresh policy-checked snapshot, never to its row number.
                freshSource = SenseActSource(corner: view.page.corner, address: readAddress, source: source, material: original)
            } else {
                siteBoundary = nil
                freshSource = SenseActSource(corner: view.page.corner, address: readAddress, source: source, material: material)
            }
        } catch {
            return Self.senseAttributed(ChatToolOutcome.failure(error: error, tool: "app"), record: record)
        }
        let dataRoot = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let outcome = await SenseActionContext.$perform.withValue({ actionID, target, value in
            guard let action = AppActions.action(actionID), action.tool != "sense_act", case .object(var args) = value else {
                throw SenseFailure(code: "invalid_action", message: "A sense act must name an existing app action with object arguments.")
            }
            if let siteBoundary {
                args = try siteBoundary.arguments(for: action, target: target, supplied: args)
            }
            if case .app(let bundle) = view.page.corner, record.language != .native {
                guard action.id == "mac.act", target == address,
                      case .object(let selection) = try JSONValue.parse(Data(address.utf8)),
                      selection["app"] == .string(bundle), args["app"] == selection["app"],
                      selection["frame_id"] != nil, args["frame_id"] == selection["frame_id"],
                      selection["handle"] != nil, args["handle"] == selection["handle"],
                      args["verb"] == .string(verb == "press" ? "click" : verb),
                      args.keys.allSatisfy({ ["app", "frame_id", "handle", "verb", "text", "mode"].contains($0) }) else {
                    throw SenseFailure(code: "act_denied", message: "An app sense may only translate this served AX selection to mac.act under Trust.")
                }
            }
            // The address names the thing; the action's schema names the slot.
            let names = Set(action.argSpecs.flatMap(\.names))
            if args["handle"] == nil, let key = ["address", "path", "target", "node_id"].first(where: names.contains), args[key] == nil {
                args[key] = .string(target)
            }
            try Self.requireSenseActionPublic(action, args: args, target: target, dataRoot: dataRoot, personaRoot: personaRoot)
            let result = try await SenseDoor.$verifyingActCorner.withValue(siteBoundary == nil ? nil : record.corner) {
                try await perform("app", ["action": .string(action.id), "args": .object(args)])
            }
            await freshSource.invalidate()
            return result
        }) {
            await runner.run(record, request: .act(verb: verb, address: address, args: input["args"] ?? .object([:])), source: freshSource)
        }
        switch outcome {
        case .acted(let result, let provenance):
            SensesHub.shared.didServe(provenance)
            if case .object(var fields) = result {
                fields["provenance"] = .string(provenance.line(now: Date()))
                return .object(fields)
            }
            return .object(["status": .string(ChatToolOutcome.outputLooksSuccessful(result) ? "ok" : "failed"),
                "result": result, "provenance": .string(provenance.line(now: Date()))])
        case .page(var page, let provenance):
            guard page.corner == record.corner, page.text.utf8.count <= NativePage.maximumTextBytes else {
                return Self.senseAttributed(Self.failure("bad_output", "The sense returned an invalid page after its act."), record: record)
            }
            if !record.verbsEnabled || record.origin == .shared {
                for index in page.things.indices { page.things[index].verbs = page.things[index].verbs.filter(record.verbs.contains) }
            }
            SensesHub.shared.didServe(provenance)
            let captured: SenseMaterial? = if case .site = view.page.corner {
                try? await freshSource.material(for: view.page.corner, address: nil)
            } else { nil }
            SenseDoorViews.shared.remember(page, record: record, source: freshSource, scope: scope,
                materialRef: view.materialRef, readInput: view.readInput, capturedMaterial: captured)
            return .string(SenseDoor.render(page, provenance: provenance))
        case .failed(let failure):
            return Self.senseAttributed(Self.failure(failure.code, failure.message + " Check the corner before repeating the act."), record: record)
        }
    }

    private static func senseAttributed(_ result: JSONValue, record: SenseRecord) -> JSONValue {
        let provenance = SenseProvenance(record: record).line(now: Date())
        if case .object(var fields) = result { fields["provenance"] = .string(provenance); return .object(fields) }
        return .object(["result": result, "provenance": .string(provenance)])
    }

    /// The sandbox denies the entire private app/persona stores even when
    /// ordinary Trust would permit a read. The sole sense action path does too.
    private static func requireSenseActionPublic(_ action: AppAction, args: [String: JSONValue], target: String,
                                                 dataRoot: URL, personaRoot: URL) throws {
        let privatePages: Set<String> = ["shell", "pairing", "memories", "personality", "trust", "settings", "senses", "diagnostics", "today", "chat", "inbox", "approvals", "providers"]
        let privatePrefixes = ["persona.", "memory.", "mind.", "agent.", "trust.", "sense.", "senses.", "secret.", "provider.", "approval."]
        let executableTools: Set<String> = ["run", "run_shell", "python", "script", "scripts", "script_run", "workshop", "workshop_run", "skill_run"]
        var refused = privatePages.contains(action.page) || privatePrefixes.contains(where: action.id.hasPrefix)
            || executableTools.contains(action.tool) || action.id.hasPrefix("script.") || action.id.hasPrefix("skill.")
        func inspect(_ value: JSONValue) {
            switch value {
            case .object(let fields): fields.values.forEach(inspect)
            case .array(let values): values.forEach(inspect)
            case .string(let text):
                var path = NSString(string: text).expandingTildeInPath
                if path.hasPrefix("file:"), let decoded = path.dropFirst(5).split(separator: "#", maxSplits: 1).first {
                    path = String(decoded).removingPercentEncoding ?? String(decoded)
                    if path.hasPrefix("//"), let url = URL(string: text), url.isFileURL { path = url.path }
                }
                if !path.isEmpty, !path.hasPrefix("/") {
                    path = dataRoot.deletingLastPathComponent().appendingPathComponent(path).path
                }
                if path.hasPrefix("/") {
                    do { try SenseSandboxProfile.requirePublicPath(path, dataRoot: dataRoot, personaRoot: personaRoot) }
                    catch { refused = true }
                }
            default: break
            }
        }
        inspect(.object(args)); inspect(.string(target))
        if refused { throw SenseFailure(code: "private_store", message: "A sense cannot reach private app stores, persona, memories, credentials, approvals or sense notebooks through an action.") }
    }
}

private actor SenseActSource: SenseSourceProvider {
    let corner: SenseCorner
    let address: String
    let source: any SenseSourceProvider
    var captured: SenseMaterial?

    init(corner: SenseCorner, address: String, source: any SenseSourceProvider, material: SenseMaterial?) {
        self.corner = corner; self.address = address; self.source = source; captured = material
    }

    func invalidate() { captured = nil }

    func material(for corner: SenseCorner, address: String?) async throws -> SenseMaterial {
        guard corner == self.corner else { throw SenseFailure(code: "source_unavailable", message: "That corner is outside this act.") }
        // Once an action has returned, verification reads obtain today's
        // material through today's Trust policy instead of the earlier view.
        if let captured { return captured }
        return try await source.material(for: corner, address: self.address)
    }
}

/// A site's generated code can translate a served verb, never select its own
/// tab, snapshot, element or action family. Element identity comes from Chrome
/// itself and survives node renumbering; old extensions cannot grant this proof.
private struct SiteSenseActionBoundary: Sendable {
    let address: String
    let verb: String
    let tool: String
    let proof: [String: JSONValue]
    let node: [String: JSONValue]

    init(host: String, address: String, verb: String, original: SenseMaterial, fresh: SenseMaterial) throws {
        guard case .pageSnapshot(.object(let before)) = original,
              case .pageSnapshot(.object(let after)) = fresh,
              case .int(let tab)? = before["tabId"], tab >= 0, after["tabId"] == .int(tab),
              Self.string(before["snapshotId"]) != nil,
              let currentSnapshot = Self.string(after["snapshotId"]),
              let url = Self.string(before["url"]), url == Self.string(after["url"]),
              URL(string: url)?.host?.lowercased() == host.lowercased(),
              case .int(let sequence)? = before["userSequence"], sequence >= 0,
              after["userSequence"] == .int(sequence),
              case .array(let oldNodes)? = before["nodes"],
              case .array(let newNodes)? = after["nodes"] else {
            throw SenseFailure(code: "stale_source", message: "The served site tab or page changed; read the site again before acting.")
        }
        let matched = oldNodes.compactMap { value -> [String: JSONValue]? in
            guard case .object(let fields) = value, let fragment = Self.string(fields["addressFragment"]),
                  address == SenseNativePages.chromeAddress(host: host, url: url, fragment: fragment) else { return nil }
            return fields
        }
        guard matched.count == 1, let old = matched.first,
              let identity = Self.string(old["elementIdentity"]) else {
            throw SenseFailure(code: "node_identity_unavailable", message: "The served thing has no Chrome element identity; reload the updated Chrome extension and read the site again.")
        }
        let candidates = newNodes.compactMap { value -> [String: JSONValue]? in
            guard case .object(let fields) = value, Self.string(fields["elementIdentity"]) == identity else { return nil }
            return fields
        }
        guard candidates.count == 1, let current = candidates.first, let nodeID = Self.string(current["nodeId"]),
              ["elementPath", "kind", "role", "name", "text", "value", "url", "frameId", "select"].allSatisfy({ old[$0] == current[$0] }) else {
            throw SenseFailure(code: "node_identity_changed", message: "The served control changed or disappeared; read the site again before acting.")
        }
        let action: String
        switch verb {
        case "click": action = "click"; tool = "browser.chrome_click"
        case "open link":
            guard old["role"] == .string("link"), Self.string(old["url"]) != nil else {
                throw SenseFailure(code: "act_denied", message: "Only a source-grounded link can offer open link.")
            }
            action = "click"; tool = "browser.chrome_click"
        case "fill": action = "fill"; tool = "browser.chrome_fill"
        case "select": action = "select"; tool = "browser.chrome_select"
        default: throw SenseFailure(code: "act_denied", message: "This site verb has no authorized Chrome action.")
        }
        for fields in [old, current] {
            guard case .array(let actions)? = fields["actions"], actions.contains(.string(action)) else {
                throw SenseFailure(code: "act_denied", message: "The Chrome source does not offer this action on the served control.")
            }
            if case .object(let states)? = fields["states"],
               states["disabled"] == .bool(true) || states["blockedByModal"] == .bool(true) {
                throw SenseFailure(code: "act_denied", message: "The served control is disabled or blocked by a dialog.")
            }
        }
        self.address = address; self.verb = verb; node = current
        proof = ["tab_id": .int(tab), "snapshot_id": .string(currentSnapshot),
                 "expected_user_sequence": .int(sequence), "node_id": .string(nodeID)]
    }

    func arguments(for action: AppAction, target: String, supplied: [String: JSONValue]) throws -> [String: JSONValue] {
        guard action.tool == tool, target == address else {
            throw SenseFailure(code: "act_denied", message: "A site sense can only act on the served thing through its grounded Chrome verb.")
        }
        var args = proof
        // Routing arguments are runtime proof, never authored or user input.
        let allowed: Set<String>
        switch verb {
        case "click", "open link": allowed = []
        case "fill":
            allowed = ["value"]
            guard case .string? = supplied["value"] else {
                throw SenseFailure(code: "invalid_value", message: "fill requires a string value.")
            }
            args["value"] = supplied["value"]
        case "select":
            allowed = ["values"]
            guard case .array(let values)? = supplied["values"],
                  case .object(let select)? = node["select"], case .array(let options)? = select["options"],
                  values.allSatisfy({ value in
                      guard case .string = value else { return false }
                      return options.contains { option in
                          if case .object(let fields) = option { return fields["value"] == value && fields["disabled"] != .bool(true) }
                          return false
                      }
                  }) else {
                throw SenseFailure(code: "invalid_values", message: "select requires values from the served control's enabled options.")
            }
            args["values"] = .array(values)
        default: throw SenseFailure(code: "act_denied", message: "The site verb is unavailable.")
        }
        guard Set(supplied.keys).isSubset(of: allowed) else {
            throw SenseFailure(code: "act_denied", message: "A site sense cannot override the captured Chrome tab, snapshot, node or action proof.")
        }
        return args
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        return nil
    }
}
