import Foundation
import PersistenceCore

/// The door's read adapter. The original reader still clears its own fences;
/// its result is retained for a failure or a request for the raw view.
public enum SenseDoor {
    @TaskLocal public static var readingRaw = false
    /// Post-action verification must not enqueue a read behind the sense
    /// entry that is awaiting this same door action's result.
    @TaskLocal public static var verifyingActCorner: SenseCorner?

    public static func read(
        corner: SenseCorner, address: String?, input: [String: JSONValue], scope: String = "",
        nativeCorner: SenseCorner? = nil,
        nativeReadSupported: Bool = true,
        fileAlreadyReadable: Bool = false,
        raw: @escaping @Sendable () async throws -> JSONValue,
        material: @escaping @Sendable (JSONValue) async throws -> SenseMaterial
    ) async throws -> JSONValue {
        let bundle: String? = if case .app(let bundle) = corner { bundle } else { nil }
        let capture = SenseAppReadCapture(bundleID: bundle)
        return try await SenseAppReadCapture.$current.withValue(capture) {
            try await readCaptured(corner: corner, address: address, input: input, scope: scope,
                nativeCorner: nativeCorner, nativeReadSupported: nativeReadSupported, fileAlreadyReadable: fileAlreadyReadable,
                raw: raw, material: material)
        }
    }

    private static func readCaptured(
        corner: SenseCorner, address: String?, input: [String: JSONValue], scope: String,
        nativeCorner: SenseCorner?, nativeReadSupported: Bool, fileAlreadyReadable: Bool,
        raw: @escaping @Sendable () async throws -> JSONValue,
        material: @escaping @Sendable (JSONValue) async throws -> SenseMaterial
    ) async throws -> JSONValue {
        guard !readingRaw, verifyingActCorner != corner else {
            return try await readView(corner: corner, address: address, input: input, scope: scope,
                record: nil, nativeReadSupported: nativeReadSupported, raw: raw, material: material)
        }
        let record: SenseRecord?
        do {
            if case .fileKind = corner, fileAlreadyReadable {
                record = try await SensesHub.shared.registry?.sense(for: nativeCorner ?? BuiltInSenses.fallbackCorner(for: corner) ?? corner)
            } else { record = try await selectedRecord(for: corner, nativeCorner: nativeCorner) }
        } catch {
            return signedRaw(try await $readingRaw.withValue(true) { try await raw() },
                line: "raw view · \(error.localizedDescription)")
        }
        var readInput = input
        if case .app = corner, input["wrong"] == .bool(true) { readInput.removeValue(forKey: "wrong") }
        let result = try await readView(corner: corner, address: address, input: readInput, scope: scope,
            record: record, nativeReadSupported: nativeReadSupported, raw: raw, material: material)
        guard isSuccessfulRaw(result) else { return result }
        if input["wrong"] == .bool(true) {
            if case .fileKind = corner, fileAlreadyReadable {
                return growthReply(result, note: "This file is readable by today's reader; a rejected text view does not grow a file sense.")
            }
            // She fixes it here, in her turn; then it's built.
            return growthReply(result, note: "Noted. Fix it now: write how \(corner.key) should read with app sense.make (it runs on this place and shows you the page; keep:true makes it stay).")
        }
        return result
    }

    private static func growthReply(_ raw: JSONValue, note: String) -> JSONValue {
        if case .string(let text) = raw { return .string(text + "\n" + note) }
        if case .object(var fields) = raw { fields["sense_growth"] = .string(note); return .object(fields) }
        return .object(["raw": raw, "sense_growth": .string(note)])
    }

    private static func readView(
        corner: SenseCorner, address: String?, input: [String: JSONValue], scope: String,
        record: SenseRecord?, nativeReadSupported: Bool,
        raw: @escaping @Sendable () async throws -> JSONValue,
        material: @escaping @Sendable (JSONValue) async throws -> SenseMaterial
    ) async throws -> JSONValue {
        if verifyingActCorner == corner {
            return signedRaw(try await raw(), line: "raw view · builtin-chrome · site act verification")
        }
        guard !readingRaw else { return try await raw() }
        let registry = SensesHub.shared.registry
        // The Mac door has already rechecked read authority. A continuation
        // reads the snapshot it names, retaining that snapshot's exact handles
        // instead of applying old offsets to a new window and replacing its frame.
        if case .app = corner, input["raw"] != .bool(true), input["wrong"] != .bool(true),
           case .string(let requested)? = input["__sense_address"],
           requested.hasPrefix("{"), case .object(let cursor) = try JSONValue.parse(Data(requested.utf8)),
           cursor["__sense_screen_frame"] != nil {
            guard let record, record.language == .native, record.status == .on,
                  let served = SenseDoorViews.shared.latest.reversed().first(where: {
               $0.scope == scope && $0.page.corner == corner && $0.record.id == record.id
                   && $0.record.version == record.version && $0.page.more == requested
            }), let fullPage = served.fullPage else {
                throw SenseFailure(code: "screen_snapshot_unavailable", message: "That screen snapshot is no longer available. Read the app again for a current page; the old cursor was not applied to a new window.")
            }
            var page = try SenseNativePages.window(fullPage, arguments: cursor)
            page.address = requested
            if case .app(let bundle) = corner, case .accessibility(let tree)? = served.capturedMaterial {
                SenseAppReadCapture.current?.record(bundleID: bundle, tree: tree)
            }
            try await recordRead(record, registry: registry)
            var provenance = SenseProvenance(record: record); provenance.uses += 1
            SensesHub.shared.didServe(provenance)
            SenseDoorViews.shared.remember(page, record: record, source: served.source, scope: scope,
                materialRef: served.materialRef, readInput: served.readInput, capturedMaterial: served.capturedMaterial, fullPage: fullPage)
            return .string(render(page, provenance: provenance))
        }
        if record?.status != .on { SenseDoorViews.shared.forget(corner: corner, scope: scope) }
        if let record, record.status == .unavailable, input["raw"] != .bool(true) {
            return try await fallback(SenseFailure(code: "sense_unavailable", message: record.unavailableReason ?? "Sense is unavailable; repair it and switch it on to retry."),
                record: record, address: address,
                source: DoorSource(corner: corner, input: input, address: address, raw: raw, material: material))
        }
        if input["raw"] != .bool(true), input["wrong"] != .bool(true),
           !nativeReadSupported, case .fileKind(let ext) = corner,
           record == nil || record?.language == .native {
            SenseDoorViews.shared.forget(corner: corner, scope: scope)
            let result = try await $readingRaw.withValue(true) { try await raw() }
            return rawView(result, reason: "no sense for .\(ext) yet")
        }
        guard input["raw"] != .bool(true), input["wrong"] != .bool(true),
              let record, record.status == .on else {
            let result = try await $readingRaw.withValue(true) { try await raw() }
            if case .fileKind = corner {
                let reason = input["wrong"] == .bool(true) ? "view marked wrong"
                    : input["raw"] == .bool(true) ? "requested"
                    : "no enabled sense for \(corner.key)"
                return rawView(result, reason: reason, reader: input["__sense_reader"] == .string("read") ? "builtin-document" : "builtin-files")
            }
            let reason = input["wrong"] == .bool(true) ? "view reported wrong"
                : input["raw"] == .bool(true) ? "requested" : "sense unavailable or switched off"
            let reader: String = switch corner {
            case .app: input["__sense_reader"] == .string("read") ? "builtin-document" : "builtin-screen"
            case .site: input["__sense_action"] == .string("web.read") ? "builtin-web"
                : [JSONValue.string("browser.text"), .string("browser.links")].contains(input["__sense_action"] ?? .null) ? "builtin-browser" : "builtin-chrome"
            case .stream(id: "web"): "builtin-web"
            case .stream(id: "browser"): "builtin-browser"
            default: corner.key
            }
            return signedRaw(result, line: "raw view · \(reader) · \(reason)")
        }
        let source = DoorSource(corner: corner, input: input, address: address, raw: raw, material: material)
        if record.language == .native {
            // Day-one wrappers retain the existing raw representation and
            // presentation; provenance is outside that payload.
            let result = try await source.rawResult()
            guard isSuccessfulRaw(result) else {
                if case .fileKind = corner { return rawView(result, reason: "today's reader refused this read") }
                return signedRaw(result, line: "raw view · \(record.id) reader refused this read")
            }
            let page = try await source.page(for: corner, address: address)
            if case .site = corner, case .string(let requested)? = input["__sense_address"], requested.hasPrefix("site:"),
               requested.split(separator: "#", maxSplits: 1).first.map(String.init) != page.address {
                return signedRaw(.object(["status": .string("failed"), "error": .string("page_changed"),
                    "effects": .string("none"), "reason": .string("This reading place belongs to a different page; read the held tab again.")]),
                    line: "raw view · captured Chrome page identity disagrees with the requested place; no native page was served")
            }
            try await recordRead(record, registry: registry)
            var provenance = SenseProvenance(record: record)
            provenance.uses += 1
            SensesHub.shared.didServe(provenance)
            let fullPage: NativePage? = if case .app = corner { try await source.fullPage() } else { nil }
            let captured: SenseMaterial?
            if case .app(let bundle) = corner, let tree = SenseAppReadCapture.current?.tree(bundleID: bundle) {
                captured = .accessibility(tree)
            } else if record.id == "builtin-chrome" {
                captured = try await source.material(for: corner, address: address)
            } else { captured = await (source as? DoorSource)?.captured }
            SenseDoorViews.shared.remember(page, record: record, source: source, scope: scope, materialRef: address, readInput: input, capturedMaterial: captured, fullPage: fullPage)
            if let requested = input["__sense_address"], case .string(let address) = requested,
               address.hasPrefix("{"), case .object(let fields) = try JSONValue.parse(Data(address.utf8)),
               fields["__sense_text_offset"] != nil {
                return .string(render(page, provenance: provenance)
                    + (SenseScreenThings.captureStatus(in: result).map { "\n" + $0 } ?? ""))
            }
            if case .string(let text) = result { return .string("Place: \(page.address)\n" + text + "\n" + provenance.line(now: Date())) }
            if case .object(var fields) = result {
                if case .app = corner {
                    if input["structured"] == .bool(true) { fields["things"] = try JSONValue.parse(JSONEncoder().encode(page.things)) }
                    fields["folded"] = .array(page.folded.map(JSONValue.string))
                    if let more = page.more { fields["sense_more"] = .string(more) }
                }
                if SenseScreenThings.text(in: result) != nil {
                    fields["text"] = .string(page.text + screenContinuationText(page)
                        + (SenseScreenThings.captureStatus(in: result).map { "\n" + $0 } ?? ""))
                    if let more = page.more { fields["sense_more"] = .string(more) }
                }
                if case .object(var detail)? = fields["detail"] {
                    detail.removeValue(forKey: "ax_content")
                    detail.removeValue(forKey: "native_page")
                    if input["structured"] != .bool(true) { detail.removeValue(forKey: "controls") }
                    fields["detail"] = .object(detail)
                }
                fields["sense_place"] = .string(page.address)
                fields["sense_provenance"] = .string(provenance.line(now: Date()))
                return .object(fields)
            }
            return .object(["raw": result, "sense_place": .string(page.address), "sense_provenance": .string(provenance.line(now: Date()))])
        }
        do { _ = try await source.material(for: corner, address: address) }
        catch {
            return try await fallback((error as? SenseFailure) ?? SenseFailure(code: "source_unavailable", message: error.localizedDescription),
                record: record, address: address, source: source)
        }
        guard let runner = SensesHub.shared.runner else {
            return try await fallback(SenseFailure(code: "runner_unavailable", message: "The sense runner is unavailable."),
                record: record, address: address, source: source)
        }
        let outcome = await $readingRaw.withValue(true) {
            await SenseActionContext.$perform.withValue(nil) {
                let requested: String? = if case .string(let value)? = input["__sense_address"] { value } else { address }
                return await runner.run(record, request: .read(address: requested), source: source)
            }
        }
        switch outcome {
        case .page(var page, let provenance):
            guard page.corner == corner, page.text.utf8.count <= NativePage.maximumTextBytes else {
                return try await fallback(SenseFailure(code: "bad_output", message: "The sense returned an invalid page."),
                    record: record, address: address, source: source)
            }
            if !record.verbsEnabled || record.origin == .shared {
                for index in page.things.indices {
                    page.things[index].verbs = record.verbsEnabled ? page.things[index].verbs.filter(record.verbs.contains) : []
                }
            }
            SensesHub.shared.didServe(provenance)
            let captured: SenseMaterial? = switch corner {
            case .app, .site: try await source.material(for: corner, address: address)
            // Whatever this read already captured; never a second read.
            default: await (source as? DoorSource)?.captured
            }
            if case .site = corner, let more = page.more,
               case .pageSnapshot(.object(let snapshot))? = captured, let cursor = snapshot["readMore"] {
                _ = SenseNativePages.chromeContinuation(snapshot, cursor: cursor, scope: scope, alias: more)
            }
            SenseDoorViews.shared.remember(page, record: record, source: source, scope: scope, materialRef: address, readInput: input, capturedMaterial: captured)
            if case .site = corner, case .object(var fields) = try await source.rawResult() {
                // Structured Chrome consumers keep the exact snapshot/action
                // proof envelope; the served native view and signature travel
                // alongside it. Direct text callers receive the rendered page.
                let servedText = render(page, provenance: provenance)
                // A place's own sense is its page; don't also hand her the
                // builtin's text and continuations for the same place.
                if record.origin != .builtIn { fields.removeValue(forKey: "text"); fields.removeValue(forKey: "element_more") }
                fields["sense_page"] = .string(servedText)
                fields["source_bytes"] = fields["bytes"]
                fields["bytes"] = .int(Int64(servedText.utf8.count))
                fields["has_more"] = .bool(page.more != nil || !page.folded.isEmpty || fields["has_more"] == .bool(true))
                if let more = page.more { fields["sense_more"] = .string(more) }
                fields["sense_place"] = .string(page.address)
                fields["sense_provenance"] = .string(provenance.line(now: Date()))
                return .object(fields)
            }
            if case .fileKind = corner {
                // Identity comes from the exact material delivered to the sense,
                // never the raw reader's first byte window (or package refusal).
                guard var fields = await source.fileEnvelope() else {
                    return try await fallback(SenseFailure(code: "bad_output", message: "The sense file read has no material receipt."),
                        record: record, address: address, source: source)
                }
                let hasMore = page.more != nil || !page.folded.isEmpty
                fields["has_more"] = .bool(hasMore)
                fields["truncated"] = .bool(hasMore)
                if let more = page.more { fields["next"] = .string(more) }
                fields["sense_page"] = .string(render(page, provenance: provenance))
                fields["sense_place"] = .string(page.address)
                fields["sense_provenance"] = .string(provenance.line(now: Date()))
                return .object(fields)
            }
            return .string(render(page, provenance: provenance))
        case .failed(let failure):
            return try await fallback(failure, record: record, address: address, source: source)
        case .acted:
            return try await fallback(SenseFailure(code: "bad_output", message: "The sense acted instead of returning a page."),
                record: record, address: address, source: source)
        }
    }

    public static func selectedRecord(for corner: SenseCorner, nativeCorner: SenseCorner? = nil) async throws -> SenseRecord? {
        guard let registry = SensesHub.shared.registry else { return nil }
        let records = try await registry.all()
        if let exact = records.first(where: { $0.corner == corner && $0.status == .on }) { return exact }
        if let unavailable = records.first(where: { $0.corner == corner && $0.status == .unavailable }) { return unavailable }
        // An explicit off-switch for the concrete corner also disables fallback.
        if records.contains(where: { $0.corner == corner && $0.status == .archived }) { return nil }
        guard let generic = nativeCorner ?? BuiltInSenses.fallbackCorner(for: corner), generic != corner else { return nil }
        return records.first { $0.corner == generic && ($0.status == .on || $0.status == .unavailable) }
    }

    public static func signedRaw(_ result: JSONValue, line: String) -> JSONValue {
        if case .string(let text) = result { return .string(text + "\n" + line) }
        if case .object(var fields) = result { fields["sense_provenance"] = .string(line); return .object(fields) }
        return .object(["raw": result, "sense_provenance": .string(line)])
    }

    private static func recordRead(_ record: SenseRecord, registry: (any SenseRegistry)?) async throws {
        if let manager = registry as? any SenseRegistryManaging {
            try await manager.recordUse(senseID: record.id, version: record.version)
        } else { await registry?.recordUse(senseID: record.id) }
    }

    private static func isSuccessfulRaw(_ result: JSONValue) -> Bool {
        if case .object(let fields) = result {
            return fields["ok"] != .bool(false) && fields["status"] != .string("failed")
                && ["error", "error_code"].allSatisfy { fields[$0] == nil || fields[$0] == .null }
        }
        return true
    }

    private static func rawView(_ result: JSONValue, reason: String, reader: String = "builtin-files") -> JSONValue {
        signedRaw(result, line: "raw view · " + reader + " · " + reason)
    }

    public static func render(_ page: NativePage, provenance: SenseProvenance) -> String {
        if SenseScreenThings.isNativeScreenPage(page) {
            // Screen things are already inline, in their document position.
            // Continuations retain that one representation and action index.
            // The built-in screen sense supplies the reader attribution.
            // Preserve exceptional raw-view reasons, but don't also print the
            // compiler's ordinary accessibility attribution beneath it.
            let text = provenance.senseID == "builtin-screen"
                ? page.text.components(separatedBy: "\n").filter { $0 != SenseScreenThings.accessibilityReadLine }.joined(separator: "\n")
                : page.text
            var lines = ["Place: \(page.address)", text + screenContinuationText(page)]
            lines.append(provenance.line(now: Date()))
            return lines.joined(separator: "\n")
        }
        var lines = ["Place: \(page.address)", page.title + " [" + page.address + "]", page.text]
        let normalizedText = page.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let itemNames = Set(page.things.map(\.name))
        let bodyText = page.text.split(separator: "\n").filter { !itemNames.contains(String($0)) }
            .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        lines += page.things.map { thing in
            "\(thing.name) [\(thing.address)]"
                + (thing.detail.flatMap {
                    let detail = $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    guard !detail.isEmpty else { return nil }
                    return normalizedText.contains(detail) || bodyText.contains(detail) ? nil : ": " + $0
                } ?? "")
                + (thing.verbs.isEmpty ? "" : " · " + thing.verbs.joined(separator: ", "))
        }
        // One line per thing; the act syntax once per page.
        if page.things.contains(where: { !$0.verbs.isEmpty }) {
            lines.append("Act: app {action: \"sense.\(provenance.senseID).<verb>\", args: {address: \"<thing's [address]>\"}}")
        }
        if !page.folded.isEmpty { lines.append("Folded: " + page.folded.joined(separator: ", ")) }
        if let more = page.more { lines.append("More: " + more) }
        lines.append("Read: app {page: \"\(page.corner.key)\", item: \"\(page.address)\"}")
        let provenanceLine = provenance.line(now: Date())
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return text + "\n" + provenanceLine
    }

    private static func screenContinuationText(_ page: NativePage) -> String {
        var lines: [String] = []
        if !page.folded.isEmpty { lines.append("Folded: " + page.folded.joined(separator: ", ")) }
        if let more = page.more {
            lines.append("More: " + more)
            lines.append("Continue: app {action: \"mac.look\", args: " + more + "}")
            let item = (try? JSONValue.string(more).serialize(pretty: false)) ?? "\"\""
            lines.append("Or: app {page: \"\(page.corner.key)\", item: " + item + "}")
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }

    private static func fallback(_ failure: SenseFailure, record: SenseRecord, address: String?, source: DoorSource) async throws -> JSONValue {
        let result = try await $readingRaw.withValue(true) { try await source.rawResult() }
        return signedRaw(.object(["ok": .bool(false), "status": .string("failed"),
            "error_code": .string(failure.code), "error": .string(failure.message), "raw": result]),
            line: "raw view · sense \(record.id) v\(record.version) unavailable: \(failure.code); no sense page served")
    }
}

private actor DoorSource: SenseNativePageSource, SenseSourceWatchingProvider, SenseFileReadReporting {
    let corner: SenseCorner
    let input: [String: JSONValue]
    let address: String?
    let raw: @Sendable () async throws -> JSONValue
    let convert: @Sendable (JSONValue) async throws -> SenseMaterial
    var result: Task<JSONValue, Error>?
    var captured: SenseMaterial?
    var fileRead: [String: JSONValue]?
    var completePage: NativePage?

    init(corner: SenseCorner, input: [String: JSONValue], address: String?, raw: @escaping @Sendable () async throws -> JSONValue,
         material: @escaping @Sendable (JSONValue) async throws -> SenseMaterial) {
        self.corner = corner; self.input = input; self.address = address; self.raw = raw; convert = material
    }

    nonisolated func fresh() -> DoorSource { DoorSource(corner: corner, input: input, address: address, raw: raw, material: convert) }

    func didReadFile(path: String, bytes: Int, version: String) {
        guard fileRead == nil else { return }
        fileRead = ["ok": .bool(true), "status": .string("ok"), "path": .string(path),
            "bytes": .int(Int64(bytes)), "version": .string(version), "offset": .int(0), "returned_bytes": .int(Int64(bytes))]
    }

    func fileEnvelope() -> [String: JSONValue]? { fileRead }

    func changes(for corner: SenseCorner, address: String?) async throws -> AsyncStream<SenseMaterial> {
        guard input["__sense_action"] != .string("web.read") else {
            throw SenseFailure(code: "unsupported", message: "A fetched web document has no event-backed live source; no Chrome page was substituted.")
        }
        guard ![.string("browser.text"), .string("browser.links")].contains(input["__sense_action"] ?? .null) else {
            throw SenseFailure(code: "unsupported", message: "A visible browser read has no passive event source; no Chrome page was substituted.")
        }
        guard corner == self.corner, let source = SensesHub.shared.source as? any SenseSourceWatchingProvider else {
            throw SenseFailure(code: "unsupported", message: "This corner has no event-backed source watch.")
        }
        return try await source.changes(for: corner, address: readAddress())
    }

    nonisolated func readAddress() throws -> String {
        var arguments = input.filter { (!$0.key.hasPrefix("__") || ["__sense_reader", "__sense_action"].contains($0.key)) && !["raw", "wrong", "why"].contains($0.key) }
        if case .fileKind = corner, arguments["path"] == nil, let address { arguments["path"] = .string(address) }
        if case .app(let id) = corner, arguments["app"] == nil { arguments["app"] = .string(id) }
        if case .stream(id: "web") = corner, arguments["url"] == nil, let address { arguments["url"] = .string(address) }
        return try JSONValue.object(arguments).serialize(pretty: false)
    }

    func page(for corner: SenseCorner, address: String?) async throws -> NativePage {
        let result = try await rawResult()
        let text = if case .site = corner, case .object(let fields) = result, case .string(let content)? = fields["text"] { content }
            else if let content = SenseScreenThings.text(in: result) { content }
            else if case .string(let text) = result { text } else { try result.serialize(pretty: false) }
        var more: String?
        if case .object(let fields) = result, let next = fields["next"] { more = try next.serialize(pretty: false) }
        var arguments = input
        if case .string(let requested)? = input["__sense_address"], requested.hasPrefix("{"),
           case .object(let fields) = try JSONValue.parse(Data(requested.utf8)) {
            arguments.merge(fields) { _, new in new }
        }
        if case .fileKind = self.corner, case .object(let fields) = result,
           arguments["version"] == nil, let version = fields["version"] { arguments["version"] = version }
        if arguments["path"] == nil, case .fileKind = self.corner, let address { arguments["path"] = .string(address) }
        if case .app = self.corner, var entire = try SenseScreenThings.page(in: result) {
            entire.corner = self.corner
            completePage = entire
            return try SenseNativePages.window(entire, arguments: arguments)
        }
        let things: [NativeThing]
        var pageAddress = try (address ?? readAddress())
        let chromeRead = !["web.read", "browser.text", "browser.links"].contains({ if case .string(let action)? = input["__sense_action"] { action } else { "" } }())
        if case .site = corner, chromeRead, case .pageSnapshot(let snapshot) = try await material(for: corner, address: address) {
            things = try SenseNativePages.chromeThings(snapshot)
            if case .object(let fields) = snapshot, case .string(let url)? = fields["url"], let host = URL(string: url)?.host {
                pageAddress = SenseNativePages.chromeAddress(host: host, url: url)
            }
            if case .object(let fields) = result, case .object(let next)? = fields["next"], case .string(let place)? = next["more"] {
                more = place
            }
        } else { things = try SenseScreenThings.things(in: result, corner: self.corner) }
        let entire = NativePage(corner: self.corner, address: pageAddress,
            title: self.corner.key, text: text, things: things, more: more)
        completePage = entire
        if case .site = corner { return entire }
        return try SenseNativePages.window(entire, arguments: arguments)
    }

    func fullPage() async throws -> NativePage {
        if let completePage { return completePage }
        _ = try await page(for: corner, address: address)
        guard let completePage else { throw SenseFailure(code: "source_unavailable", message: "The native screen snapshot is unavailable.") }
        return completePage
    }

    func rawResult() async throws -> JSONValue {
        if let result { return try await result.value }
        let task = Task { try await SenseDoor.$readingRaw.withValue(true) { try await raw() } }
        result = task
        return try await task.value
    }

    func material(for corner: SenseCorner, address: String?) async throws -> SenseMaterial {
        guard corner == self.corner else { throw SenseFailure(code: "source_unavailable", message: "That corner is outside this read.") }
        // Addresses returned by a sense select its things, never another file,
        // app or tab. The converter retains this call's authorized material.
        if let captured { return captured }
        let material: SenseMaterial
        if case .fileKind = corner {
            guard let provider = SensesHub.shared.source else {
                throw SenseFailure(code: "source_unavailable", message: "The admitted file source is unavailable.")
            }
            material = try await provider.material(for: corner, address: readAddress())
        } else { material = try await convert(rawResult()) }
        if case .app(let bundle) = corner, case .accessibility(let tree) = material {
            SenseAppReadCapture.current?.record(bundleID: bundle, tree: tree)
        }
        captured = material
        return material
    }
}

/// Only served things can be acted on. This bounded, in-memory index grants no
/// authority: the door rechecks the current registry version and every request
/// an act makes passes through the normal tool chain.
public final class SenseDoorViews: @unchecked Sendable {
    public static let shared = SenseDoorViews()
    private let lock = NSLock()
    public struct View: Sendable {
        public let page: NativePage
        public let record: SenseRecord
        fileprivate let makeSource: @Sendable () -> any SenseSourceProvider
        public var source: any SenseSourceProvider { makeSource() }
        public let scope: String
        public let materialRef: String?
        public let readInput: [String: JSONValue]
        public let capturedMaterial: SenseMaterial?
        public let fullPage: NativePage?
    }
    private var views: [View] = []

    public var latest: [View] { lock.withLock { views } }

    public func forget(senseID: String, scope: String) {
        lock.withLock { views.removeAll { $0.record.id == senseID && $0.scope == scope } }
    }

    public func forget(senseID: String) {
        lock.withLock { views.removeAll { $0.record.id == senseID } }
    }

    public func forget(corner: SenseCorner, scope: String) {
        lock.withLock { views.removeAll { $0.page.corner == corner && $0.scope == scope } }
    }

    public func remember(_ page: NativePage, record: SenseRecord, source: any SenseSourceProvider, scope: String,
                         materialRef: String?, readInput: [String: JSONValue], capturedMaterial: SenseMaterial? = nil, fullPage: NativePage? = nil) {
        let makeSource: @Sendable () -> any SenseSourceProvider = {
            if let door = source as? DoorSource { return door.fresh() }
            return source
        }
        lock.withLock {
            views.removeAll { $0.page.address == page.address && $0.record.id == record.id && $0.scope == scope }
            views.append(View(page: page, record: record, makeSource: makeSource, scope: scope, materialRef: materialRef, readInput: readInput, capturedMaterial: capturedMaterial, fullPage: fullPage))
            if views.count > 32 { views.removeFirst(views.count - 32) }
        }
    }
}
