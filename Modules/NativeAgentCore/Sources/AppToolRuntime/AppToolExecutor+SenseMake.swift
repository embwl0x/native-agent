import AuthoredCapabilities
import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter

extension AppToolExecutor {
    @MainActor
    func runSenseLifecycle(input: [String: JSONValue]) async throws -> JSONValue {
        guard let registry = SensesHub.shared.registry as? FileSenseRegistry,
              let id = Self.inputString(input["sense_id"]), let verb = Self.inputString(input["verb"]) else {
            return Self.failure("sense_unavailable", "Read Senses for the sense's current identity.")
        }
        let records = try await registry.allChecked()
        guard let current = records.first(where: { $0.id == id }) else {
            let matches = AppActions.matchingSenses(id, records: records)
            return Self.failure("sense_unavailable", "No sense has id \(id). " + (matches.isEmpty
                ? "Read Senses for the sense's current identity."
                : "Matching sense ids: \(matches.map(\.id).joined(separator: ", ")). Call sense.versions with one of these sense_id values."),
                extra: ["matches": .array(matches.map { .object(["sense_id": .string($0.id), "corner": .string($0.corner.key),
                    "next_call": .object(["action": .string("sense.versions"), "args": .object(["sense_id": .string($0.id)])])]) })])
        }
        if verb == "versions" {
            return try await registry.lifecycleRead(id: id)
        }
        if verb == "quarantine", Int(Self.doorText(input["version"])) != current.version {
            return Self.failure("stale_version", "Sense changed; read sense.versions and use its current version.")
        }
        let preview = input["preview"] == .bool(true)
        if preview, verb == "restore" {
            let fullMac = await Self.freshQuietPosture(dataRoot: registry.root.deletingLastPathComponent())?.name == Self.fullMacModeName
            do { try CapabilityLifecycle.requireKeep(ownerAuthorized: fullMac || PeerDataTaint.ownerAuthorized) }
            catch { return Self.failure("owners_call", error.localizedDescription) }
        }
        let record: SenseRecord
        switch verb {
        case "drop": record = try await registry.drop(id: id, version: current.version, preview: preview, ownerAuthorized: PeerDataTaint.ownerAuthorized)
        case "rollback":
            guard let version = Int(Self.doorText(input["version"])) else {
                return Self.failure("invalid_args", "Choose a retained version from sense.versions.")
            }
            record = try await registry.rollback(id: id, version: version, preview: preview)
        case "quarantine": record = try await registry.setStatus(id: id, version: current.version, status: .off, preview: preview)
        case "restore":
            do {
                record = try await registry.setStatus(id: id, version: current.version, status: .on, preview: preview)
            } catch let refusal as SenseFailure where refusal.code == "owners_call" {
                return Self.failure(refusal.code, refusal.message)
            } catch let refusal as NSError where refusal.domain == "CapabilityLifecycle" {
                return Self.failure("owners_call", refusal.localizedDescription)
            }
        default: return Self.failure("invalid_args", "Unknown sense lifecycle action.")
        }
        if !preview, verb != "restore" { await (SensesHub.shared.runner as? HelperSenseRunner)?.stop(id) }
        if verb == "drop" {
            return .object(["status": .string(preview ? "would" : "ok"), "effects": .string(preview ? "none" : "occurred"),
                            "detail": .string(preview ? "Would delete \(id)'s ability files and run statistics." : "\(id)'s ability files and run statistics were deleted.")])
        }
        if preview {
            return .object(["status": .string("would"), "effects": .string("none"),
                            "would_status": .string(record.status.rawValue),
                            "detail": .string("Would \(verb) \(id); its status is \(record.status.rawValue).")])
        }
        return .object(["status": .string(preview ? "preview" : "ok"), "effects": .string(preview ? "none" : "occurred"),
                        "sense": try .fromEncodable(record)])
    }

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
                  (["code", "place", "why", "show", "apps"] + Array(AbilityStore.partKeys)).allSatisfy({ input[$0] == nil || input[$0] == .null }) else {
                return Self.failure("invalid_args", "Keep a trial with trial_id, digest and keep:true in the conversation that tried it. Omit code, place, why and show; run a fresh trial to change the candidate.")
            }
            do {
                let candidate = try registry.programs.load(id: trial, digest: digest)
                let key = try await SwiftNativeManifestSigner(dataRoot: registry.root.deletingLastPathComponent()).loadOrCreateSigningKey()
                let (published, page) = try await registry.keep(candidate, key: key, scope: scope)
                SenseDoorViews.shared.forget(corner: published.corner, scope: scope)
                return .object(["status": .string("kept"), "place": .string(published.corner.key),
                    "sense_id": .string(published.id), "version": .int(Int64(published.version)), "page": .string(page),
                    "trial_id": .string(trial), "digest": .string(digest)])
            } catch let error as NSError where error.domain == "CapabilityLifecycle" {
                return Self.failure("owners_call", error.localizedDescription)
            } catch {
                return Self.failure("trial_unavailable", "The trial could not be kept. Read the place and run a fresh sense.make trial; nothing was kept. " + error.localizedDescription, extra: ["effects": .string("unknown")])
            }
        }
        guard showMaterial || !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.failure("invalid_args", "code is the complete sense.js: define read(request) and publish a page from sense.source.read(). show:\"material\" returns what source.read() gets.",
                                extra: ["kit": .string(kit)])
        }
        let place = Self.inputString(input["place"]).map(SenseDoorViews.placeIdentity)
        let views = SenseDoorViews.shared.latest.filter {
            $0.scope == scope && (place == nil || SenseDoorViews.placeIdentity($0.page.address) == place
                || $0.page.corner.key == place || $0.materialRef.map(SenseDoorViews.placeIdentity) == place)
        }
        let places = Set(views.map { SenseDoorViews.placeIdentity($0.page.address) }).sorted()
        guard places.count <= 1 else {
            return Self.failure("ambiguous_place", "Several places were read in this conversation. Set place to the exact sense_place from the read you want to use.",
                                extra: ["places": .array(places.map(JSONValue.string))])
        }
        guard let view = views.last else {
            return Self.failure("no_place", "Read the place first in this conversation (files.read, mac.look, chrome.snapshot, web.read), then make its sense.")
        }
        if !showMaterial, let refusal = view.growthRefusal {
            return ChatToolOutcome.failure(error: AutonomyGateError.toolDenied(reason: refusal), tool: "app")
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
            case .file(let path, let bytes, _): .object(["kind": .string("file"), "path": .string(path), "bytes": .int(Int64(bytes)),
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
            var record = SenseRecord(id: id, corner: corner, status: .draft, language: .javascript,
                                     mode: .onCall, origin: .grown, entry: "sense.js", createdAt: Date())
            if let apps = input["apps"] {
                guard case .array(let values) = apps, values.allSatisfy({ Self.inputString($0) != nil }) else {
                    return Self.failure("invalid_args", "apps declares a list of bundle ids for read-only app reach.")
                }
                record.reach.apps = values.compactMap { Self.inputString($0) }
            }
            let part = try AbilityStore.partHeader(input.merging(["reach": try .fromEncodable(record.reach)]) { first, _ in first })
            record.reach = try JSONDecoder().decode(SenseReach.self, from: part["reach"]!.serializedData(pretty: false))
            record.grownBecause = Self.inputString(input["why"]) ?? "Agent made it in her turn"
            guard !scope.isEmpty else { return Self.failure("no_conversation", "Run sense.make in a chat conversation to retain this trial.") }
            let candidate = try await registry.candidate(record, codeFiles: ["sense.js": Data(code.utf8)], scope: scope, header: part)
            record = try FileSenseRegistry.record(candidate)
            let outcome = await runner.run(record, request: .read(address: view.page.address),
                                           source: CapturedSenseSource(corner: corner, material: material))
            guard case .page(let page, let provenance) = outcome else {
                let detail: String = if case .failed(let failure) = outcome { failure.message } else { "read() returned no page." }
                try registry.programs.discard(candidate)
                return Self.failure("sense_failed", detail, extra: ["place": .string(corner.key), "kit": .string(kit), "effects": .string("unknown")])
            }
            let shown = SenseDoor.render(page, provenance: provenance)
            let key = try await SwiftNativeManifestSigner(dataRoot: registry.root.deletingLastPathComponent()).loadOrCreateSigningKey()
            do {
                _ = try registry.programs.bind(candidate, receipts: [.object(["status": .string("ok"), "page": try .fromEncodable(page)])],
                    key: key, captured: .array([.object(["input": .object(["address": .string(view.page.address)]), "expected": try .fromEncodable(page)])]))
            } catch {
                try registry.programs.discard(candidate)
                throw error
            }
            guard keep else {
                return .object(["status": .string("tried"), "place": .string(corner.key), "page": .string(shown),
                    "trial_id": .string(id), "digest": .string(candidate.digest),
                    "trial_retention": .string("Available in this conversation until another candidate for this sense replaces it or its selected version changes."),
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("sense.make"),
                        "args": .object(["trial_id": .string(id), "digest": .string(candidate.digest), "keep": .bool(true)])])])])
            }
            let (published, keptPage) = try await registry.keep(candidate, key: key, scope: scope)
            SenseDoorViews.shared.forget(corner: corner, scope: scope)
            return .object(["status": .string("kept"), "place": .string(corner.key), "sense_id": .string(published.id),
                            "version": .int(Int64(published.version)), "page": .string(keptPage)])
        } catch let error as NSError where error.domain == "CapabilityLifecycle" {
            return Self.failure("owners_call", error.localizedDescription)
        } catch {
            return Self.failure("sense_failed", error.localizedDescription, extra: ["place": .string(corner.key), "effects": .string("unknown")])
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
