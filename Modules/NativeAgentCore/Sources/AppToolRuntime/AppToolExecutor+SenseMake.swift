import ChatOrchestration
import CryptoKit
import Foundation
import PersistenceCore
import Senses

extension AppToolExecutor {
    /// Her own fix for a place, made in her turn: run her sense.js on the place
    /// she just read and show the page it gives. keep makes it how that place
    /// reads from now on. She judges the page; the sandboxed host and
    /// redaction stay what they always are.
    @MainActor
    func runSenseMake(input: [String: JSONValue]) async -> JSONValue {
        guard let registry = SensesHub.shared.registry as? FileSenseRegistry, let runner = SensesHub.shared.runner else {
            return Self.failure("senses_unavailable", "Senses are not running.")
        }
        let kit = Bundle.main.resourceURL?.appendingPathComponent("Senses").path ?? "NativeAgent.app/Contents/Resources/Senses"
        let showMaterial = Self.inputString(input["show"]) == "material"
        let code = Self.inputString(input["code"]) ?? ""
        let scope = ChatToolSessionContext.verifiedSessionId ?? ""
        if input["trial_id"] != nil || input["digest"] != nil {
            guard let trial = Self.inputString(input["trial_id"]), let digest = Self.inputString(input["digest"]),
                  input["keep"] == .bool(true), !scope.isEmpty,
                  ["code", "place", "why", "show"].allSatisfy({ input[$0] == nil || input[$0] == .null }) else {
                return Self.failure("invalid_args", "Keep a trial with trial_id, digest and keep:true in the conversation that tried it. Omit code, place, why and show; run a fresh trial to change the candidate.")
            }
            do {
                let candidate = try await registry.retainedTrial(id: trial, digest: digest, scope: scope)
                var record = candidate.record
                record.status = .on; record.enabledAt = Date()
                guard let published = try await registry.publishIfNotArchived(record, codeFiles: ["sense.js": Data(candidate.code.utf8)]) else {
                    return Self.failure("switched_off", "This place's sense is switched off on the Senses page.")
                }
                SenseDoorViews.shared.forget(corner: record.corner, scope: scope)
                var result: [String: JSONValue] = ["status": .string("kept"), "place": .string(record.corner.key),
                    "sense_id": .string(published.id), "version": .int(Int64(published.version)), "page": .string(candidate.page),
                    "trial_id": .string(trial), "digest": .string(digest)]
                do { try await registry.removeTrial(id: trial) }
                catch { result["draft_cleanup_error"] = .string("The sense was kept, but its retained trial could not be removed. Do not repeat keep; inspect the Senses page. " + error.localizedDescription) }
                return .object(result)
            } catch {
                return Self.failure("trial_unavailable", "The trial could not be kept. Read the place and run a fresh sense.make trial; nothing was kept. " + error.localizedDescription)
            }
        }
        guard showMaterial || !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.failure("invalid_args", "code is the complete sense.js: define read(request) and publish a page from sense.source.read(). show:\"material\" returns what source.read() gets.",
                                extra: ["kit": .string(kit)])
        }
        let place = Self.inputString(input["place"])
        let views = SenseDoorViews.shared.latest.filter {
            $0.scope == scope && (place == nil || $0.page.address == place || $0.page.corner.key == place)
        }
        let places = Set(views.map { $0.page.address }).sorted()
        guard places.count <= 1 else {
            return Self.failure("ambiguous_place", "Several places were read in this conversation. Set place to the exact sense_place from the read you want to use.",
                                extra: ["places": .array(places.map(JSONValue.string))])
        }
        guard let view = views.last else {
            return Self.failure("no_place", "Read the place first in this conversation (files.read, mac.look, chrome.snapshot, web.read), then make its sense.")
        }
        let corner = view.page.corner
        let keep = input["keep"] == .bool(true)
        // Only the material this conversation's read already admitted; never a re-read.
        guard let material = view.capturedMaterial else {
            return Self.failure("no_material", "\(corner.key) was read by a native reader that keeps no material (readable files, web and browser text); sense.make is for apps, sites and foreign files.")
        }
        if showMaterial {
            // Exactly what sense.source.read() hands her code (file bytes stay on-device).
            let shape: JSONValue = switch material {
            case .accessibility(let tree): .object(["kind": .string("accessibility"), "tree": tree])
            case .file(let path, let bytes): .object(["kind": .string("file"), "path": .string(path), "bytes": .int(Int64(bytes)),
                                                      "data": .string("base64 file bytes, given to the sense at runtime")])
            case .pageSnapshot(let snapshot): .object(["kind": .string("page"), "snapshot": snapshot])
            case .text(let text): .object(["kind": .string("text"), "text": .string(text)])
            }
            return .object(["status": .string("material"), "place": .string(corner.key), "kit": .string(kit), "material": shape])
        }
        do {
            // A place she already made keeps its id and gains a version.
            let existing = try await registry.allChecked().first { $0.corner == corner && $0.origin != .builtIn && $0.language == .javascript }
            let id: String
            if let existing { id = existing.id } else { id = Self.placeID(corner) }
            // Every try runs under its own fresh id, so no notebook or folder is
            // shared with a kept sense or another conversation; it is removed after.
            let trial = "sense-try-" + UUID().uuidString.lowercased().prefix(12)
            let trialRoot = registry.root.appendingPathComponent(trial, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: trialRoot.path) else {
                return Self.failure("sense_failed", "Try folder already exists; call again.")
            }
            defer { try? FileManager.default.removeItem(at: trialRoot) }
            let folder = trialRoot.appendingPathComponent("v1", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(code.utf8).write(to: folder.appendingPathComponent("sense.js"), options: .atomic)
            var record = SenseRecord(id: trial, corner: corner, version: 1, status: .draft, language: .javascript,
                                     mode: .onCall, origin: .grown, entry: "sense.js", createdAt: Date())
            record.grownBecause = Self.inputString(input["why"]) ?? "Agent made it in her turn"
            let outcome = await runner.run(record, request: .read(address: view.page.address),
                                           source: CapturedSenseSource(corner: corner, material: material))
            guard case .page(let page, let provenance) = outcome else {
                let detail: String = if case .failed(let failure) = outcome { failure.message } else { "read() returned no page." }
                return Self.failure("sense_failed", detail, extra: ["place": .string(corner.key), "kit": .string(kit)])
            }
            let shown = SenseDoor.render(page, provenance: provenance)
            record.id = id
            record.verbs = Array(Set(page.things.flatMap(\.verbs))).sorted()
            guard keep else {
                guard !scope.isEmpty else {
                    return Self.failure("no_conversation", "Run sense.make in a chat conversation to retain this trial.", extra: ["page": .string(shown)])
                }
                let candidate = FileSenseRegistry.Trial(id: trial, scope: scope, record: record, code: code, page: shown)
                let digest = try await registry.retainTrial(candidate)
                return .object(["status": .string("tried"), "place": .string(corner.key), "page": .string(shown),
                    "trial_id": .string(trial), "digest": .string(digest),
                    "trial_retention": .string("Available in this conversation for 24 hours, among the 16 most recently retained trials."),
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("sense.make"),
                        "args": .object(["trial_id": .string(trial), "digest": .string(digest), "keep": .bool(true)])])])])
            }
            let versions = existing == nil ? [] : try await registry.versions(id: id)
            record.id = id; record.version = (versions.map(\.version).max() ?? 0) + 1
            record.status = .on; record.enabledAt = Date()
            guard let published = try await registry.publishIfNotArchived(record, codeFiles: ["sense.js": Data(code.utf8)]) else {
                return Self.failure("switched_off", "This place's sense is switched off on the Senses page.")
            }
            SenseDoorViews.shared.forget(corner: corner, scope: scope)
            return .object(["status": .string("kept"), "place": .string(corner.key), "sense_id": .string(published.id),
                            "version": .int(Int64(published.version)), "page": .string(shown)])
        } catch {
            return Self.failure("sense_failed", error.localizedDescription, extra: ["place": .string(corner.key)])
        }
    }

    /// Named for its place and unique to it: site:en.wikipedia.org →
    /// site-en-wikipedia-org-<6 hex of the full key>. Deterministic, so two
    /// places never share an id and no reservation is needed.
    private static func placeID(_ corner: SenseCorner) -> String {
        var slug = String(corner.key.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(90))
        let tag = SHA256.hash(data: Data(corner.key.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        return (slug.isEmpty ? "place" : slug) + "-" + tag
    }
}

/// The material her read already admitted, for this place only.
private struct CapturedSenseSource: SenseSourceProvider {
    let corner: SenseCorner
    let material: SenseMaterial
    func material(for corner: SenseCorner, address: String?) async throws -> SenseMaterial {
        guard corner == self.corner else { throw SenseFailure(code: "source_unavailable", message: "That place is outside this sense.") }
        return material
    }
}
