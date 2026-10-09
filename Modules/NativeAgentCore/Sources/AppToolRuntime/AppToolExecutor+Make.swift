import Foundation
import PersistenceCore
import Studio

extension AppToolExecutor {
    /// make.add and make.read, in process: the Make studio's refs and their
    /// versions (`MakeStudio`), which the Work pane's Make tab shows.
    @MainActor
    func runMake(verb: String, input: [String: JSONValue]) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let studio = MakeStudio(dataRoot: root)
        let ref = Self.inputString(input["ref"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if verb == "read" {
            guard let meta = (ref.isEmpty ? studio.newestRef() : ref).flatMap(studio.meta) else {
                return Self.failure("unknown_ref", ref.isEmpty ? "Nothing is in Make yet." : "No Make ref is called \(ref).")
            }
            return .object([
                "status": .string("ok"), "ref": .string(meta.ref),
                "versions": .array(meta.versions.map { version in
                    var row: [String: JSONValue] = [
                        "n": .int(Int64(version.n)), "path": .string(studio.url(meta.ref, version).path),
                        "created": .string(version.created),
                    ]
                    if let prompt = version.prompt { row["prompt"] = .string(prompt) }
                    if let model = version.model { row["model"] = .string(model) }
                    return .object(row)
                }),
            ])
        }
        let path = Self.inputString(input["path"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return Self.failure("invalid_input", "Pass path: the file to add to Make.") }
        let fullMac = await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName
        let file: URL
        switch await Self.fencedAttachment(path, fullMac: fullMac, dataRoot: root) {
        case .success(let found): file = found
        case .failure(let refusal): return Self.failure(refusal.reason, refusal.detail)
        }
        do {
            let added = try studio.add(file, ref: ref.isEmpty ? nil : ref)
            return .object(["status": .string("ok"), "ref": .string(added.ref), "version": .int(Int64(added.version.n)),
                            "path": .string(studio.url(added.ref, added.version).path)])
        } catch let refusal as MakeStudio.Refusal {
            return Self.failure(refusal.reason, refusal.message)
        } catch {
            return Self.failure("make_show_failed", error.localizedDescription + " Nothing was added.")
        }
    }
}
