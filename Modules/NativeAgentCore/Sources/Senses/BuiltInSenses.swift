import Foundation
import PersistenceCore
// Blueprint: | `BuiltInSenses.swift` | Bundle-owned native adapters and JavaScript defaults read once per resource root under a lock, with failures uncached; one schemaVersion-1 object manifest requires every identity, string corner, version, mode, entry and verbs; file overrides win and accounting lives in AbilityStore state; bundled records have built-in origin and no creation/enable placeholders |

public enum BuiltInSenses {
    private static let defaultsLock = NSLock()
    nonisolated(unsafe) private static var defaultsByRoot: [String: [FileSenseRegistry.Version]] = [:]
    fileprivate static let native: [(String, SenseCorner)] = [
        ("builtin-screen", .app(bundleID: "*")),
        ("builtin-chrome", .site(host: "*")),
        ("builtin-web", .stream(id: "web")),
        ("builtin-browser", .stream(id: "browser")),
        ("builtin-files", .fileKind("*")),
        ("builtin-document", .stream(id: "mac.read")),
        ("builtin-connectors", .stream(id: "connectors")),
    ]

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
        let defaults = try defaults(resources: resources)
        let existing = try await registry.all()
        for version in defaults {
            let record = version.record
            guard let saved = existing.first(where: { $0.id == record.id }),
                  saved.language == record.language, saved.corner == record.corner else {
                throw SenseFailure(code: "bad_output", message: "Built-in sense identity collision: \(record.id).")
            }
        }
    }

    static func defaults(resources: URL? = nil) throws -> [FileSenseRegistry.Version] {
        try defaultsLock.withLock {
            let root = (resources ?? resourceRoot()).standardizedFileURL
            if let known = defaultsByRoot[root.path] { return known }
            let versions = try readDefaults(root)
            defaultsByRoot[root.path] = versions
            return versions
        }
    }

    private static func readDefaults(_ root: URL) throws -> [FileSenseRegistry.Version] {
        let entries = try manifest(at: root.appendingPathComponent("builtin.json"))
        for entry in entries where native.contains(where: { $0.0 == entry.id }) {
            throw SenseFailure(code: "bad_output", message: "Built-in sense identity collision: \(entry.id).")
        }
        var versions = native.map { id, corner in
            FileSenseRegistry.Version(record: SenseRecord(
                id: id, corner: corner, language: .native, origin: .builtIn,
                entry: nil
            ), files: [])
        }
        for entry in entries {
            let record = SenseRecord(id: entry.id, corner: entry.corner, version: entry.version,
                language: .javascript, mode: entry.mode, origin: .builtIn, entry: entry.entry, verbs: entry.verbs)
            versions.append(FileSenseRegistry.Version(record: record, files: [entry.entry]))
        }
        return versions
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
            let key = try fields.decode(String.self, forKey: .corner)
            guard let value = SenseCorner(key: key) else {
                throw SenseFailure(code: "bad_output", message: "Invalid built-in corner: \(key).")
            }
            corner = value
            id = try fields.decode(String.self, forKey: .id)
            version = try fields.decode(Int.self, forKey: .version)
            entry = try fields.decode(String.self, forKey: .entry)
            verbs = try fields.decode([String].self, forKey: .verbs)
            mode = try fields.decode(SenseMode.self, forKey: .mode)
        }
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let senses: [Entry]
    }

    private static func manifest(at url: URL) throws -> [Entry] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1 else {
            throw SenseFailure(code: "bad_output", message: "Unsupported built-in senses schema: \(manifest.schemaVersion).")
        }
        let entries = manifest.senses
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

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        !value.hasPrefix("/") && !value.split(separator: "/", omittingEmptySubsequences: false).isEmpty
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeComponent(String($0)) }
    }

    static func resourceRoot() -> URL {
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            return resources.appendingPathComponent("Senses")
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Senses")
    }
}

struct ExistingCornerSense: Sendable {
    let record: SenseRecord

    init?(record: SenseRecord) {
        guard BuiltInSenses.native.contains(where: { $0.0 == record.id && $0.1 == record.corner }) else { return nil }
        self.record = record
    }
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
                return .acted(result, SenseProvenance(record: record))
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
            return .page(page, SenseProvenance(record: record))
        } catch let failure as SenseFailure { return .failed(failure) }
        catch { return .failed(SenseFailure(code: "source_unavailable", message: error.localizedDescription)) }
    }
}
