import Foundation
import CryptoKit
import PersistenceCore
import Senses
import AgentWorkspace
import ChatOrchestration
import MacControl
import Dispatcher
import ChromeControl
import NativeAgentCore

extension ExistingCornersSourceProvider {
    /// Bind the same raw tool chain used by the app, not a second dispatcher.
    /// The raw read bypasses sense lookup only; Trust remains in that chain.
    public init(
        rawRead: @escaping @Sendable (String, [String: JSONValue]) async throws -> JSONValue,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        chrome: (@Sendable () -> ChromeControlRuntime)? = nil
    ) {
        self.init(readMaterial: { corner, address in
            let (tool, input) = try ExistingCornersReaders.route(corner, address)
            let readerInput = input.filter { !$0.key.hasPrefix("__sense_") }
            if case .fileKind = corner, input["__sense_reader"] == .string("read") {
                let preflight = try await rawRead("read", input.filter { !$0.key.hasPrefix("__") })
                if case .object(let fields) = preflight, fields["ok"] == .bool(false), fields["error"] != .string("unsupported_document_type") {
                    throw SenseFailure(code: "source_unavailable", message: "The original document reader refused this read under the current policy.")
                }
            }
            switch corner {
            case .app:
                var appInput = readerInput
                appInput["__sense_app_material"] = .bool(true)
                appInput["__sense_app_observation"] = MacObservationMode.current == .passive
                    || SensesHub.passiveObservation
                    ? .bool(true) : input["__sense_app_observation"]
                let result = try await rawRead(tool, appInput)
                try ExistingCornersReaders.requireReadable(result)
                return .accessibility(result)
            case .fileKind:
                guard let path = ExistingCornersReaders.string(input["path"]) else {
                    throw SenseFailure(code: "source_unavailable", message: "A file sense needs a path.")
                }
                try SenseSandboxProfile.requirePublicPath(path, dataRoot: dataRoot,
                    personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
                // A document address explicitly requests today's MacDocumentRead
                // extract; the ordinary file source is path + byte count.
                if input["document"] == .bool(true) {
                    let result = try await rawRead("read", readerInput)
                    return .text(try ExistingCornersReaders.documentText(result))
                }
                let result = try await FileReadSourceMaterial.$metadataOnly.withValue(true) {
                    try await rawRead("read_file", readerInput)
                }
                guard case .object(let object) = result, object["ok"] == .bool(true),
                      case .string(let resolved)? = object["path"], case .int(let bytes)? = object["bytes"],
                      let count = Int(exactly: bytes), count >= 0 else {
                    throw SenseFailure(code: "source_unavailable", message: try ExistingCornersReaders.outputText(result))
                }
                try SenseSandboxProfile.requirePublicPath(resolved, dataRoot: dataRoot,
                    personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
                return .file(path: resolved, bytes: count)
            case .site(let host):
                if tool == "read_page" {
                    let fetched = try await rawRead(tool, readerInput)
                    try ExistingCornersReaders.requireReadable(fetched)
                    guard case .object(let fields) = fetched, case .object(let coverage)? = fields["coverage"],
                          let requestedURL = ExistingCornersReaders.string(fields["url"]) else {
                        throw SenseFailure(code: "source_unavailable", message: "The web reader did not return its fetched document.")
                    }
                    let observedURL = ExistingCornersReaders.string(coverage["final_url"]) ?? requestedURL
                    guard host == "*" || URL(string: observedURL)?.host?.lowercased() == host.lowercased() else {
                        throw SenseFailure(code: "source_unavailable", message: "The fetched document does not match \(corner.key).")
                    }
                    return .pageSnapshot(fetched)
                }
                // The existing workspace lane keeps the structured snapshot.
                // Match the direct lane's default node limit before selecting
                // it; this does not acquire or navigate a tab.
                var snapshotInput = readerInput
                guard let chrome else { throw SenseFailure(code: "source_unavailable", message: "The Chrome source is not installed.") }
                let address = try await chrome().existingPageAddress(host: host,
                    tabID: ExistingCornersReaders.integer(snapshotInput["tab_id"]))
                snapshotInput.merge(address) { supplied, _ in supplied }
                if snapshotInput["max_nodes"] == nil || snapshotInput["max_nodes"] == .null {
                    snapshotInput["max_nodes"] = .int(150)
                }
                let readInput = snapshotInput
                let snapshot = try await MacLookFrameStore.$source.withValue("workspace") {
                    try await rawRead(tool, readInput)
                }
                guard case .object(let page) = snapshot,
                      ExistingCornersReaders.string(page["snapshotId"]) != nil,
                      case .array? = page["nodes"] else {
                    throw SenseFailure(code: "source_unavailable", message: try ExistingCornersReaders.outputText(snapshot))
                }
                if host != "*", URL(string: ExistingCornersReaders.string(page["url"]) ?? "")?.host?.lowercased() != host.lowercased() {
                    throw SenseFailure(code: "source_unavailable", message: "The Chrome snapshot does not match \(corner.key).")
                }
                return .pageSnapshot(snapshot)
            case .stream(let id) where id == "mac.read":
                return .text(try ExistingCornersReaders.documentText(await rawRead(tool, readerInput)))
            case .stream:
                return .text(try ExistingCornersReaders.outputText(await rawRead(tool, readerInput)))
            case .need:
                throw SenseFailure(code: "unsupported", message: "There is no existing reader for \(corner.key).")
            }
        }, readPage: { corner, address in
            let (tool, input) = try ExistingCornersReaders.route(corner, address)
            let result = try await rawRead(tool, input.filter { !$0.key.hasPrefix("__sense_") })
            if case .app = corner, let page = try SenseScreenThings.page(in: result) {
                return try SenseNativePages.window(page, arguments: input)
            }
            // Keep today's entire reply, including refusal and byte-window
            // envelopes. The existing tool-result pager still owns overflow.
            let text = try ExistingCornersReaders.outputText(result)
            let resolvedAddress = address ?? corner.key
            var things: [NativeThing] = []
            if case .site = corner,
               let page = ChromePageMirror.page(tab: ExistingCornersReaders.integer(input["tab_id"]),
                    session: ChatToolSessionContext.verifiedSessionId), text.hasPrefix(page.text) {
                things = page.rows.map {
                    NativeThing(name: $0.label, kind: $0.role, address: page.url + "#" + $0.node)
                }
            }
            if case .object(let object) = result {
                if case .object(let detail)? = object["detail"],
                   case .object(let controls)? = detail["controls"],
                   case .array(let rows)? = controls["affordances"] {
                    things = rows.compactMap { row in
                        guard case .object(let fields) = row,
                              let name = ExistingCornersReaders.string(fields["name"] ?? fields["label"]),
                              let handle = ExistingCornersReaders.string(fields["handle"]) else { return nil }
                        // These are pointers for the existing mac.act route;
                        // native adapters do not introduce a new action path.
                        return NativeThing(name: name, kind: ExistingCornersReaders.string(fields["role"]) ?? "control",
                            address: resolvedAddress + "#" + handle)
                    }
                }
            }
            if case .app = corner { things = try SenseScreenThings.things(in: result, corner: corner) }
            if things.isEmpty {
                things = [NativeThing(name: resolvedAddress, kind: "source", address: resolvedAddress)]
            }
            var more: String?
            if case .object(let object) = result, case .object(let next)? = object["next"] {
                more = try JSONValue.object(next).serialize(pretty: false)
            }
            var windowInput = input
            var pageCorner = corner
            if case .fileKind(let kind) = corner {
                if case .object(let fields) = result, windowInput["version"] == nil, let version = fields["version"] {
                    windowInput["version"] = version
                }
                if kind == "*", let path = ExistingCornersReaders.string(input["path"]) {
                    pageCorner = .fileKind(URL(fileURLWithPath: path).pathExtension.lowercased())
                }
            }
            if case .app("*") = corner, let app = ExistingCornersReaders.string(input["app"]),
               case .matched(let target) = MacBackgroundSight.resolve(app, among: defaultMacAXElementSource().runningApps()),
               let bundle = target.bundleIdentifier { pageCorner = .app(bundleID: bundle) }
            if case .site("*") = corner, case .object(let fields) = result,
               let url = ExistingCornersReaders.string(fields["url"]), let host = URL(string: url)?.host {
                pageCorner = .site(host: host.lowercased())
            }
            return try SenseNativePages.window(NativePage(corner: pageCorner, address: resolvedAddress,
                title: pageCorner.key, text: text, things: things, more: more), arguments: windowInput)
        }, readChanges: { corner, address in
            if case .site(let host) = corner {
                let (_, input) = try ExistingCornersReaders.route(corner, address)
                guard input["__sense_action"] != .string("web.read") else {
                    throw SenseFailure(code: "unsupported", message: "A fetched web document has no event-backed live source; no Chrome page was substituted.")
                }
                guard let chrome else {
                    throw SenseFailure(code: "source_unavailable", message: "The Chrome change source is not installed.")
                }
                let address = try await chrome().existingPageAddress(host: host, tabID: ExistingCornersReaders.integer(input["tab_id"]))
                guard case .int(let tab)? = address["tab_id"] else {
                    throw SenseFailure(code: "source_unavailable", message: "The site has no existing Chrome tab.")
                }
                let changes = try await chrome().pageChanges(host: host, tabID: tab)
                let pair = AsyncStream<SenseMaterial>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let task = Task.detached(priority: .utility) {
                    defer { pair.continuation.finish() }
                    func report(_ reason: String) async {
                        await chrome().recordCaptureError(reason, tabID: tab)
                    }
                    do {
                        for try await snapshot in changes {
                            guard !Task.isCancelled else { return }
                            if case .object(let fields) = snapshot, case .string(let reason)? = fields["__sense_change_failure"] {
                                await report(reason)
                                continue
                            }
                            pair.continuation.yield(.pageSnapshot(snapshot))
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        await report(error.localizedDescription)
                    }
                }
                pair.continuation.onTermination = { _ in task.cancel() }
                return pair.stream
            }
            guard case .app(let bundleID) = corner, bundleID != "*" else {
                throw SenseFailure(code: "source_unavailable", message: "App observation needs a concrete already-running app.")
            }
            let provider = ExistingCornersSourceProvider(rawRead: rawRead, dataRoot: dataRoot, chrome: chrome)
            // Admit observation under today's policy; every change read re-enters
            // that policy without inheriting the original turn's authority.
            let (_, route) = try ExistingCornersReaders.route(corner, address)
            let observationAddress = try JSONValue.object(route.merging(["__sense_app_observation": .bool(true)]) { _, new in new }).serialize(pretty: false)
            _ = try await provider.material(for: corner, address: observationAddress)
            let events = try MacAppSourceEvents(bundleID: bundleID)
            let pair = AsyncStream<SenseMaterial>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let task = Task.detached(priority: .utility) {
                defer { events.cancel(); pair.continuation.finish() }
                do {
                    for try await _ in events.stream {
                        try Task.checkCancellation()
                        pair.continuation.yield(try await provider.material(for: corner, address: observationAddress))
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await ExistingCornersSourceProvider.postWatchFailure(error, corner: corner,
                        address: address ?? corner.key, observationID: nil, what: "App")
                }
            }
            pair.continuation.onTermination = { _ in task.cancel(); events.cancel() }
            return pair.stream
        })
    }
}

/// The native Chrome reader consumes the same tab-bound event stream as JS
/// site senses. One subscription per tab; takeover/disconnect ends it at source.
actor NativeChromeNews {
    static let shared = NativeChromeNews()
    private struct Watch {
        let id: UUID
        let task: Task<Void, Never>
        var version: String
        var url: String
        var view: String
        var snapshot: [String: JSONValue]
        let chrome: ChromeControlRuntime
    }
    private var watches: [Int64: Watch] = [:]
    private var starting: Set<Int64> = []

    func opened(_ receipt: JSONValue, chrome: ChromeControlRuntime) async {
        guard case .object(let fields) = receipt, case .int(let tab)? = fields["tabId"], watches[tab] == nil else { return }
        do {
            guard let record = try await SenseDoor.selectedRecord(for: .site(host: "*")), record.id == "builtin-chrome", record.status == .on else { return }
            // Register at ownership, before any read can fail. The first successful
            // capture is the new page; an unavailable agent is only status.
            await begin(tab: tab, fields: [:], chrome: chrome)
        } catch { await chrome.recordCaptureError(error.localizedDescription, tabID: tab) }
    }

    func read(_ snapshot: JSONValue, chrome: ChromeControlRuntime) async {
        guard case .object(let fields) = snapshot, case .int(let tab)? = fields["tabId"],
              case .string(let url)? = fields["url"], let host = URL(string: url)?.host else { return }
        do {
            guard let record = try await SenseDoor.selectedRecord(for: .site(host: host)), record.id == "builtin-chrome", record.status == .on,
                  let version = Self.version(snapshot) else { return }
            if watches[tab] != nil {
                // A direct read establishes the newly selected news view. A
                // continuation does not replace the canonical page baseline, and
                // a navigation must still reach news even when readback wins its race.
                if watches[tab]?.url == url, !Self.newDocument(watches[tab]?.snapshot ?? [:], fields),
                   case .object(let reading)? = fields["reading"],
                   reading["cursor"] == nil || reading["cursor"] == .null {
                    watches[tab]?.version = version
                    watches[tab]?.view = Self.view(fields)
                    watches[tab]?.snapshot = fields
                }
                return
            }
            await begin(tab: tab, fields: fields, chrome: chrome)
        } catch { await chrome.recordCaptureError(error.localizedDescription, tabID: tab) }
    }

    private func begin(tab: Int64, fields: [String: JSONValue], chrome: ChromeControlRuntime) async {
        guard watches[tab] == nil, starting.insert(tab).inserted else { return }
        defer { starting.remove(tab) }
        let id = UUID()
        do {
            let changes = try await chrome.pageChanges(host: "*", tabID: tab)
            let task = Task { [weak self] in
                do {
                    for try await changed in changes {
                        guard !Task.isCancelled else { return }
                        await self?.changed(changed, tab: tab, id: id)
                    }
                } catch {
                    if !Task.isCancelled { await self?.unavailable(error.localizedDescription, tab: tab) }
                }
                await self?.ended(tab, id: id)
            }
            watches[tab] = Watch(id: id, task: task, version: Self.version(.object(fields)) ?? "",
                url: ExistingCornersReaders.string(fields["url"]) ?? "", view: Self.view(fields), snapshot: fields, chrome: chrome)
        } catch { await chrome.recordCaptureError(error.localizedDescription, tabID: tab) }
    }

    private static func version(_ snapshot: JSONValue) -> String? {
        guard let text = ChromePageText.render(snapshot),
              case .object(let receipt)? = try? ChromePageText.envelope(snapshot, rendered: text),
              case .string(let version)? = receipt["version"] else { return nil }
        let document = if case .object(let fields) = snapshot { ExistingCornersReaders.string(fields["documentId"]) ?? "" } else { "" }
        return document + ":" + version
    }

    private static func newDocument(_ before: [String: JSONValue], _ after: [String: JSONValue]) -> Bool {
        after["documentId"] != nil && before["documentId"] != after["documentId"]
    }

    private static func view(_ fields: [String: JSONValue]) -> String {
        guard case .object(let reading)? = fields["reading"] else { return "" }
        var view = reading.filter { ["scope", "maxNodes", "maxTextChars", "cursor", "transportByteLimit"].contains($0.key) }
        // Identity is the requested view, not which content or frames fit.
        view["url"] = fields["url"]
        return (try? JSONValue.object(view).serialize(pretty: false)) ?? ""
    }

    private func changed(_ snapshot: JSONValue, tab: Int64, id: UUID) async {
        guard watches[tab]?.id == id, case .object(let fields) = snapshot else { return }
        if case .string(let reason)? = fields["__sense_change_failure"] { await unavailable(reason, tab: tab); return }
        do {
            guard case .string(let url)? = fields["url"], let host = URL(string: url)?.host,
                  let record = try await SenseDoor.selectedRecord(for: .site(host: host)), record.id == "builtin-chrome", record.status == .on,
                  let version = Self.version(snapshot), watches[tab]?.id == id else { return }
            let moved = watches[tab]?.url != url || Self.newDocument(watches[tab]?.snapshot ?? [:], fields)
            let sameView = watches[tab]?.view == Self.view(fields)
            let changed = watches[tab]?.version != version
            let previousVersion = watches[tab]?.version ?? ""
            let previous = watches[tab]?.snapshot ?? [:]
            guard moved || (sameView && changed) else {
                watches[tab]?.version = version
                watches[tab]?.url = url
                watches[tab]?.view = Self.view(fields)
                watches[tab]?.snapshot = fields
                return
            }
            let address = SenseNativePages.chromeAddress(host: ContextSecretContentPolicy.redactedFragment(host),
                url: ContextSecretContentPolicy.redactedFragment(url))
            let summary = try Self.delta(previous, fields)
            // A failed capture/delta never consumes the successful baseline.
            watches[tab]?.version = version
            watches[tab]?.url = url
            watches[tab]?.view = Self.view(fields)
            watches[tab]?.snapshot = fields
            await SenseNewsBoard.shared.post(SenseNews(senseID: record.id, version: record.version, address: address,
                summary: summary, at: Date(), observationID: String(tab), changeID: previousVersion + "→" + version))
        } catch { await unavailable(error.localizedDescription, tab: tab) }
    }

    private static func delta(_ before: [String: JSONValue], _ after: [String: JSONValue]) throws -> String {
        func text(_ value: JSONValue?) -> String {
            if case .string(let text)? = value { return ChromePageText.safe(ContextSecretContentPolicy.redactedFragment(text)) }
            return ""
        }
        if before["url"] != after["url"] || Self.newDocument(before, after) {
            func endpoint(_ value: JSONValue?) -> String {
                let url = text(value)
                return String(url.prefix(300)) + (url.count > 300 ? "…" : "")
            }
            let sections: [String] = if case .object(let reading)? = after["reading"], case .array(let values)? = reading["sections"] {
                Array(values.compactMap { value -> String? in
                    let name = text(value); return name.isEmpty ? nil : String(name.prefix(32))
                }.prefix(3))
            } else { [] }
            return ContextSecretContentPolicy.redactedFragment("Navigation: now \(String(text(after["title"]).prefix(60)))"
                + (sections.isEmpty ? "" : "; top sections: " + sections.joined(separator: ", "))
                + (before["url"] == nil ? "; \(endpoint(after["url"]))" : "; \(endpoint(before["url"])) → \(endpoint(after["url"]))"))
        }
        func rows(_ fields: [String: JSONValue]) -> [String: [String: JSONValue]] {
            guard case .array(let nodes)? = fields["nodes"] else { return [:] }
            var result: [String: [String: JSONValue]] = [:]
            for case .object(let node) in nodes {
                guard case .string(let path)? = node["elementPath"] else { continue }
                result[path] = node.filter { ["role", "name", "text", "value", "url", "actions", "states", "select"].contains($0.key) }
            }
            return result
        }
        let old = rows(before), new = rows(after)
        let added = new.keys.filter { old[$0] == nil }.sorted()
        let removed = old.keys.filter { new[$0] == nil }.sorted()
        let changed = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted()
        func label(_ row: [String: JSONValue]) -> String {
            String((text(row["role"]) + " “" + text(row["name"]) + "” " + text(row["text"]) + " " + text(row["value"])).prefix(120))
        }
        func stateChanges(_ old: [String: JSONValue], _ new: [String: JSONValue]) throws -> String {
            let before: [String: JSONValue] = if case .object(let flags)? = old["states"] { flags } else { [:] }
            let after: [String: JSONValue] = if case .object(let flags)? = new["states"] { flags } else { [:] }
            func value(_ raw: JSONValue?) throws -> String {
                guard let raw else { return "absent" }
                // Redact each string before JSON adds its own prefix/quotes.
                return try raw.mapStrings(ContextSecretContentPolicy.redactedFragment).serialize(pretty: false)
            }
            let changes = try Set(before.keys).union(after.keys).sorted().filter { before[$0] != after[$0] }.map {
                try ContextSecretContentPolicy.redactedFragment($0) + ": " + value(before[$0]) + " → " + value(after[$0])
            }
            return changes.isEmpty ? "" : "; states: " + changes.joined(separator: ", ")
        }
        var details: [String] = []
        for key in added.prefix(3) { details.append("added " + label(new[key]!)) }
        for key in removed.prefix(max(0, 3 - details.count)) { details.append("removed " + label(old[key]!)) }
        for key in changed.prefix(max(0, 3 - details.count)) {
            details.append(try "changed " + label(old[key]!) + " → " + label(new[key]!) + stateChanges(old[key]!, new[key]!))
        }
        func lines(_ fields: [String: JSONValue]) -> [String] {
            guard case .object(let summary)? = fields["summary"] else { return [] }
            // Preserve real line boundaries and multiplicity. The display
            // sanitizer folds whitespace, so it cannot be the diff input.
            guard case .string(let raw)? = summary["text"] else { return [] }
            return ContextSecretContentPolicy.redactedFragment(raw).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        let oldText = lines(before), newText = lines(after)
        let difference = newText.difference(from: oldText)
        let addedText = difference.compactMap { change -> String? in if case .insert(_, let line, _) = change { return line }; return nil }
        let removedText = difference.compactMap { change -> String? in if case .remove(_, let line, _) = change { return line }; return nil }
        if details.isEmpty {
            details += addedText.prefix(2).map { "added text: " + String(text(.string($0)).prefix(120)) }
            details += removedText.prefix(1).map { "removed text: " + String(text(.string($0)).prefix(120)) }
            if before["title"] != after["title"] { details.append("title: \(text(before["title"])) → \(text(after["title"]))") }
        }
        return ContextSecretContentPolicy.redactedFragment(
            "Page: \(added.count) added, \(removed.count) removed, \(changed.count) changed elements; text +\(addedText.count)/−\(removedText.count) lines"
            + (details.isEmpty ? "" : "; " + details.joined(separator: "; ")))
    }

    private func unavailable(_ reason: String, tab: Int64) async {
        await watches[tab]?.chrome.recordCaptureError(reason, tabID: tab)
    }

    private func ended(_ tab: Int64, id: UUID) { if watches[tab]?.id == id { watches.removeValue(forKey: tab) } }
}

private enum ExistingCornersReaders {
    static func integer(_ value: JSONValue?) -> Int64? {
        if case .int(let number)? = value { return number }; return nil
    }
    static func route(_ corner: SenseCorner, _ address: String?) throws -> (String, [String: JSONValue]) {
        var input: [String: JSONValue] = ["raw": .bool(true)]
        // A plain address is a path/app/URL. A JSON object carries the raw
        // route's own arguments unchanged (part, tab_id, offset, version…).
        if let address, address.hasPrefix("{") {
            guard case .object(let fields) = try JSONValue.parse(Data(address.utf8)) else {
                throw SenseFailure(code: "bad_output", message: "A reader address must be an argument object.")
            }
            input.merge(fields) { _, new in new }
            input["raw"] = .bool(true)
        }
        switch corner {
        case .app(let bundleID):
            if bundleID != "*" { input["app"] = .string(bundleID) }
            else if input["app"] == nil, let address, !address.hasPrefix("{") { input["app"] = .string(address) }
            return ("screen", input)
        case .fileKind:
            if input["path"] == nil, let address, !address.hasPrefix("{") { input["path"] = .string(address) }
            guard string(input["path"]) != nil else {
                throw SenseFailure(code: "source_unavailable", message: "A file sense needs a path.")
            }
            return (input["document"] == .bool(true) ? "read" : "read_file", input)
        case .site:
            guard ![.string("browser.text"), .string("browser.links")].contains(input["__sense_action"] ?? .null) else {
                throw SenseFailure(code: "source_unavailable", message: "Visible browser material is supplied by its explicit read door; background work cannot drive the browser or substitute a Chrome tab.")
            }
            if input["__sense_action"] == .string("web.read") {
                guard string(input["url"]) != nil else {
                    throw SenseFailure(code: "source_unavailable", message: "A fetched site read needs its requested URL.")
                }
                return ("read_page", input)
            }
            // Never navigate or acquire a different tab merely to read a site.
            // Chrome resolves the existing tab exactly as today's route does.
            return ("browser.chrome_snapshot", input)
        case .stream(let id) where id == "mac.read":
            if input["path"] == nil, let address, !address.hasPrefix("{") { input["path"] = .string(address) }
            return ("read", input)
        case .stream(let id) where id == "web":
            if input["url"] == nil, let address, !address.hasPrefix("{") { input["url"] = .string(address) }
            return ("read_page", input)
        case .stream(let id) where id == "browser":
            return ("browser.read_text", input)
        case .stream(let id) where id == "connectors":
            if address == nil { return ("app", ["read": .string("connectors"), "raw": .bool(true)]) }
            guard let actionID = string(input.removeValue(forKey: "action")),
                  let action = AppActions.action(actionID), action.read,
                  connectorPages.contains(action.page), !action.tool.isEmpty else {
                throw SenseFailure(code: "unsupported", message: "A connector source needs an existing read action.")
            }
            if let args = input.removeValue(forKey: "args") {
                guard case .object(let fields) = args else {
                    throw SenseFailure(code: "bad_output", message: "Connector read arguments must be an object.")
                }
                input.merge(fields) { _, new in new }
            }
            for (from, to) in action.rename { if let value = input.removeValue(forKey: from) { input[to] = value } }
            input.merge(action.input) { _, new in new }
            input["raw"] = .bool(true)
            return (action.tool, input)
        default:
            throw SenseFailure(code: "unsupported", message: "There is no existing reader for \(corner.key).")
        }
    }

    static let connectorPages: Set<String> = ["mail", "calendar", "reminders", "notes", "contacts", "messages", "github", "slack", "notion", "x", "markets", "music"]

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        return nil
    }

    static func requireReadable(_ result: JSONValue) throws {
        if case .object(let fields) = result,
           fields["ok"] == .bool(false) || fields["status"] == .string("failed") || fields["error"] != nil {
            throw SenseFailure(code: "source_unavailable", message: "The original reader refused this read.")
        }
    }

    static func outputText(_ result: JSONValue) throws -> String {
        if case .string(let text) = result { return text }
        // This is the turn's existing JSON presentation, including receipts,
        // failures and byte-window continuation arguments.
        return try result.serialize(pretty: false)
    }

    static func documentText(_ result: JSONValue) throws -> String {
        guard case .object(let object) = result, object["ok"] == .bool(true) else {
            throw SenseFailure(code: "source_unavailable", message: try outputText(result))
        }
        if case .string(let text)? = object["text"] { return text }
        if case .object(let output)? = object["output"], case .string(let text)? = output["text"] { return text }
        throw SenseFailure(code: "bad_output", message: "The document reader returned no text.")
    }
}
