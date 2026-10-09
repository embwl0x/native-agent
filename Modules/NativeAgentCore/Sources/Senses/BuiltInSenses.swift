import Foundation
import PersistenceCore

public enum BuiltInSenses {
    // Specific grown/JS senses win the registry's exact lookup. These records
    // represent today's generic readers, selected only after that lookup misses.
    public static func fallbackCorner(for corner: SenseCorner) -> SenseCorner? {
        switch corner {
        case .app: .app(bundleID: "*")
        case .fileKind: .fileKind("*")
        case .site: .site(host: "*")
        case .stream(let id) where ["mac.read", "connectors", "web", "browser"].contains(id): corner
        default: nil
        }
    }

    /// Call after installing the registry in SensesHub. Missing/malformed kit
    /// resources are launch errors, never an apparently successful empty kit.
    public static func registerAll(dataRoot: URL, resources: URL? = nil) async throws {
        guard let registry = SensesHub.shared.registry else {
            throw SenseFailure(code: "source_unavailable", message: "The senses registry is not installed.")
        }
        let root = resources ?? resourceRoot()
        let entries = try manifest(at: root.appendingPathComponent("builtin.json"))
        let now = Date()
        let native: [(String, SenseCorner)] = [
            ("builtin-screen", .app(bundleID: "*")),
            ("builtin-chrome", .site(host: "*")),
            ("builtin-web", .stream(id: "web")),
            ("builtin-browser", .stream(id: "browser")),
            ("builtin-files", .fileKind("*")),
            ("builtin-document", .stream(id: "mac.read")),
            ("builtin-connectors", .stream(id: "connectors")),
        ]
        for entry in entries where native.contains(where: { $0.0 == entry.id }) {
            throw SenseFailure(code: "bad_output", message: "Built-in sense identity collision: \(entry.id).")
        }
        let existing = try await registry.all()
        for (id, corner) in native {
            let record = existing.first { $0.id == id } ?? SenseRecord(
                id: id, corner: corner, language: .native, origin: .builtIn,
                entry: nil, createdAt: now, enabledAt: now
            )
            guard record.language == .native, record.origin == .builtIn, record.corner == corner else {
                throw SenseFailure(code: "bad_output", message: "Built-in sense identity collision: \(id).")
            }
            if !existing.contains(where: { $0.id == id }) { try await registry.upsert(record) }
            NativeSenseCatalog.shared.register(ExistingCornerSense(record: record))
        }
        for entry in entries {
            var record = SenseRecord(id: entry.id, corner: entry.corner, version: entry.version,
                language: .javascript, mode: entry.mode, origin: .builtIn, entry: entry.entry, verbs: entry.verbs,
                createdAt: now, enabledAt: now)
            let saved = existing.first(where: { $0.id == record.id })
            if let saved {
                guard (saved.origin == .builtIn || (saved.origin == .grown && saved.version > 1)),
                      saved.language == .javascript, saved.corner == record.corner else {
                    throw SenseFailure(code: "bad_output", message: "Built-in sense identity collision: \(record.id).")
                }
                // Versions are immutable. The newest version that came from the
                // bundle tells whether this app ships new code for the sense; if
                // it does, that code becomes the next version above everything,
                // including the lane's own repairs. Unchanged code changes nothing
                // (counters, off-switch and later repairs stay as they are).
                let bundled = try Data(contentsOf: root.appendingPathComponent(entry.entry))
                if let last = lastBundledVersion(id: record.id, entry: entry.entry, upTo: saved.version, dataRoot: dataRoot),
                   last.code == bundled { continue }
                record.version = max(entry.version, saved.version + 1)
            }
            try installKit(root: root, record: record, dataRoot: dataRoot)
            var next = record
            if let saved {
                next.status = saved.status; next.createdAt = saved.createdAt
                next.unavailableReason = saved.unavailableReason
                next.enabledAt = saved.enabledAt; next.lastUsedAt = saved.lastUsedAt
                next.uses = saved.uses; next.corrections = saved.corrections
            }
            try await registry.upsert(next)
        }
    }

    private struct Entry: Decodable {
        let id: String
        let corner: SenseCorner
        let version: Int
        let entry: String
        let verbs: [String]
        let mode: SenseMode

        enum CodingKeys: String, CodingKey { case id, corner, version, entry, verbs, mode }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            if case .string = try fields.decode(JSONValue.self, forKey: .corner) {
                let key = try fields.decode(String.self, forKey: .corner)
                guard let value = SenseCorner(key: key) else {
                    throw SenseFailure(code: "bad_output", message: "Invalid built-in corner: \(key).")
                }
                corner = value
            } else {
                corner = try fields.decode(SenseCorner.self, forKey: .corner)
            }
            id = try fields.decodeIfPresent(String.self, forKey: .id)
                ?? "builtin-" + corner.key.replacingOccurrences(of: ":", with: "-")
            version = try fields.decodeIfPresent(Int.self, forKey: .version) ?? 1
            entry = try fields.decode(String.self, forKey: .entry)
            verbs = try fields.decodeIfPresent([String].self, forKey: .verbs) ?? []
            let defaultMode: SenseMode = if case .app = corner { .live } else { .onCall }
            mode = try fields.decodeIfPresent(SenseMode.self, forKey: .mode) ?? defaultMode
        }
    }

    private static func manifest(at url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url)
        let value = try JSONValue.parse(data)
        let rows: JSONValue
        if case .object(let object) = value, let senses = object["senses"] { rows = senses }
        else { rows = value }
        let entries = try JSONDecoder().decode([Entry].self, from: JSONEncoder().encode(rows))
        var ids: Set<String> = [], corners: Set<SenseCorner> = []
        for entry in entries {
            guard safeComponent(entry.id), entry.version > 0, safeRelativePath(entry.entry),
                  entry.entry.hasSuffix(".js"), ids.insert(entry.id).inserted,
                  corners.insert(entry.corner).inserted else {
                throw SenseFailure(code: "bad_output", message: "Invalid or duplicate built-in sense: \(entry.id).")
            }
            _ = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(entry.entry))
        }
        return entries
    }

    /// The newest installed version whose folder holds the bundled entry
    /// (lane repairs hold only their own entry), with that entry's code.
    private static func lastBundledVersion(id: String, entry: String, upTo version: Int,
                                           dataRoot: URL) -> (version: Int, code: Data)? {
        let parent = dataRoot.appendingPathComponent("senses").appendingPathComponent(id)
        for candidate in stride(from: version, through: 1, by: -1) {
            let url = parent.appendingPathComponent("v\(candidate)").appendingPathComponent(entry)
            if let code = try? Data(contentsOf: url) { return (candidate, code) }
        }
        return nil
    }

    private static func installKit(root: URL, record: SenseRecord, dataRoot: URL) throws {
        let fm = FileManager.default
        let parent = dataRoot.appendingPathComponent("senses").appendingPathComponent(record.id)
        let version = parent.appendingPathComponent("v\(record.version)")
        // Registry owns lifecycle; this only lays down the bundled entry and
        // its shared JS helpers before making the record visible.
        // A folder left without a registry record (interrupted launch) is
        // completed from the bundle; registered versions are never rewritten.
        if fm.fileExists(atPath: version.path), let entry = record.entry,
           (try? Data(contentsOf: version.appendingPathComponent(entry))) == (try? Data(contentsOf: root.appendingPathComponent(entry))) {
            return
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".builtin-\(UUID().uuidString)")
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        try fm.copyItem(at: root, to: staging)
        if fm.fileExists(atPath: version.path) { _ = try fm.replaceItemAt(version, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: version) }
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        !value.hasPrefix("/") && !value.split(separator: "/", omittingEmptySubsequences: false).isEmpty
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeComponent(String($0)) }
    }

    private static func resourceRoot() -> URL {
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            return resources.appendingPathComponent("Senses")
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Senses")
    }
}

private struct ExistingCornerSense: NativeSense {
    let record: SenseRecord
    var id: String { record.id }
    var corner: SenseCorner { record.corner }

    func run(_ request: SenseRequest, source: SenseSourceProvider) async -> SenseOutcome {
        if id == "builtin-chrome", case .act(let verb, let address, let args) = request {
            do {
                guard ["click", "fill", "select"].contains(verb), let perform = SenseActionContext.perform else {
                    throw SenseFailure(code: "act_denied", message: "Chrome verbs require a served thing and an active app turn.")
                }
                let result = try await perform("chrome." + verb, address, args)
                return .acted(result, SenseProvenance(record: record))
            } catch let failure as SenseFailure { return .failed(failure) }
            catch { return .failed(SenseFailure(code: "act_denied", message: error.localizedDescription)) }
        }
        if case .act(let verb, let address, let args) = request, case .app = corner {
            do {
                guard let perform = SenseActionContext.perform else {
                    throw SenseFailure(code: "act_denied", message: "Screen verbs require an active app turn.")
                }
                let result = try await perform("mac.act", address, SenseScreenThings.selection(address, verb: verb, args: args))
                let saved = try await SensesHub.shared.registry?.sense(for: corner)
                return .acted(result, SenseProvenance(record: saved ?? record))
            } catch let failure as SenseFailure { return .failed(failure) }
            catch { return .failed(SenseFailure(code: "act_denied", message: error.localizedDescription)) }
        }
        guard case .read(let address) = request else {
            return .failed(SenseFailure(code: "unsupported", message: "Use the existing app action for this corner."))
        }
        guard let source = source as? any SenseNativePageSource else {
            return .failed(SenseFailure(code: "source_unavailable", message: "The existing corner readers are not installed."))
        }
        do {
            let page = try await source.page(for: corner, address: address)
            let saved = try await SensesHub.shared.registry?.sense(for: corner)
            let current = saved.flatMap { $0.id == id ? $0 : nil } ?? record
            return .page(page, SenseProvenance(record: current))
        } catch let failure as SenseFailure { return .failed(failure) }
        catch { return .failed(SenseFailure(code: "source_unavailable", message: error.localizedDescription)) }
    }
}
