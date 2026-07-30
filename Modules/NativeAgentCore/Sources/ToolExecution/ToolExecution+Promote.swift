import Foundation
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ToolRegistry

// MARK: - Subsystem #16 ToolExecution — PROMOTE PATH
//
// Ports the daemon's promote_tool flow
// into Swift. Out of scope here: proposal lifecycle (sibling worker) and the
// run sandbox (sibling worker). This file owns:
//   1. validation gate (delegated to caller-supplied closure)
//   2. risky-permission intersection gate
//   3. staged activation (U5 W-B): proposals/<id>/ → active/.staging-<id>-<t>/,
//      sign + fingerprint THERE, then a true atomic exchange
//      (renamex_np RENAME_SWAP) into active/<id> — executed together with
//      the registry upsert under ONE cross-process flock on registry.json,
//      with rollback on any failure + crash-litter sweep on entry
//   4. HMAC manifest signing via SwiftNativeManifestSigner
//   5. codeFingerprint computation
//   6. promoted_payload assembly + atomic upsert to data/tools/registry.json
//
// RISKY_TOOL_PERMISSIONS mirrors the retired daemon's constant verbatim.

public enum ToolPromoteError: Error, LocalizedError {
    case unknownProposal(id: String)
    case validationFailed(errors: [String])
    case riskyWithoutAllowRisky(permissions: [String])
    case sourceDirectoryMissing(path: String)
    case copyFailed(String)
    case signingFailed(String)
    case persistenceFailed(String)
    case swapFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProposal(let id):
            return "unknown proposal: \(id)"
        case .validationFailed(let errors):
            return "validation failed: \(errors.joined(separator: "; "))"
        case .riskyWithoutAllowRisky(let perms):
            return "tool has risky permissions and allowRisky=false: \(perms.joined(separator: ","))"
        case .sourceDirectoryMissing(let p):
            return "source directory missing: \(p)"
        case .copyFailed(let m):
            return "copy failed: \(m)"
        case .signingFailed(let m):
            return "signing failed: \(m)"
        case .persistenceFailed(let m):
            return "persistence failed: \(m)"
        case .swapFailed(let m):
            return "atomic swap failed: \(m)"
        }
    }
}

/// Result of validation. SwiftNative version of the daemon's
/// `validate_tool(promote=False)` return — only the fields promote needs.
public struct ToolValidationResult: Sendable, Equatable {
    public let valid: Bool
    public let errors: [String]
    /// True ⇒ safe enough to promote without explicit risky-acknowledge.
    public let autoPromotable: Bool

    public init(valid: Bool, errors: [String], autoPromotable: Bool) {
        self.valid = valid
        self.errors = errors
        self.autoPromotable = autoPromotable
    }
}

public typealias ToolValidator = @Sendable ([String: JSONValue]) async -> ToolValidationResult

/// TEST-ONLY permissive validator — passes everything as valid +
/// autoPromotable. U5 W-B fix-round (gpt-5.5 NIT): this is NOT the engine's
/// default anymore — a ToolPromoteEngine constructed without an explicit
/// validator now resolves the REAL SwiftToolValidator against the proposal
/// dir at promote time. This hook exists only so unit tests that don't care
/// about validation semantics (signature/fingerprint round-trip pinning,
/// concurrency tests) can opt out without staging a fake tool body; it is
/// deliberately `internal` (reachable via `@testable import ToolExecution`)
/// so no production module can wire it.
let permissivePromoteValidatorForTesting: ToolValidator = { _ in
    ToolValidationResult(valid: true, errors: [], autoPromotable: true)
}

// MARK: - SwiftToolValidator
//
// Partial port of the retired daemon `validate_tool` (L33876-33947).
// Out of scope (still daemon-only): AST-level static scan, sandbox test
// execution. In scope here — the three rules Wave-3 review flagged:
//   (a) tests.json present + non-empty
//   (b) dangerous-import deny via text scan of the entrypoint body
//   (c) permissions are in KNOWN_TOOL_PERMISSIONS; autoPromotable iff
//       valid AND permissions ⊆ SAFE_AUTO_TOOL_PERMISSIONS (matches the
//       daemon's `safe_auto = bool(perms) and perms ⊆ SAFE_AUTO` so an
//       empty-permission tool is NOT autoPromotable, byte-equivalent
//       with Python).
// `risky permissions require allowRisky` already lives in the engine's
// own gate at L150-157 (retired runtime L33956-33958), so it's not
// duplicated here.

public enum SwiftToolValidator {
    // KEEP IN SYNC with the retired daemon.
    public static let knownToolPermissions: Set<String> = [
        "app_data_read", "app_data_write",
        "network_localhost", "network_public", "network",
        "shell", "computer_files", "arbitrary_file_write",
    ]
    public static let safeAutoToolPermissions: Set<String> = [
        "app_data_read", "app_data_write",
    ]
    // KEEP IN SYNC with daemon L823-831 DANGEROUS_TOOL_IMPORTS.
    public static let dangerousToolImports: Set<String> = [
        "ctypes", "multiprocessing", "pty", "shutil",
        "signal", "socket", "subprocess",
    ]
    // AUDIT FIX (2026-07-21): Swift-shaped dangerous-symbol rules. The scan
    // below was Python-syntax-only, but ToolRunSandbox executes `tool.swift`
    // via /usr/bin/swift with NO sandbox-exec confinement — a Swift
    // entrypoint carrying Foundation.Process / FileManager writes / Darwin /
    // dlopen sailed through validation untouched. Python rules are unchanged.
    /// Swift import roots that hard-fail (direct syscall / FFI surface,
    /// the Swift analogue of Python's `ctypes`).
    public static let dangerousSwiftImports: Set<String> = ["Darwin"]
    /// Swift symbols that hard-fail (no permission makes process spawning or
    /// dynamic loading acceptable in an autonomous tool — mirrors the Python
    /// hard-fail of `subprocess` / `ctypes`).
    public static let dangerousSwiftSymbols: [String] = [
        "dlopen(", "dlsym(", "dlclose(",
        "Process(", "posix_spawn(", "NSTask", "fork(",
    ]
    /// FileManager write verbs — allowed only when the manifest declares a
    /// write permission (mirrors the http/urllib → network-permission gate).
    public static let fileManagerWriteSymbols: [String] = [
        ".removeItem(", ".createFile(", ".moveItem(",
        ".copyItem(", ".replaceItem(", ".createDirectory(",
    ]

    /// Build a ToolValidator closure pinned to `proposalDir`. The closure
    /// reads tests.json + the entrypoint off disk so the validation gate
    /// has the same ground truth Python's `validate_tool` does.
    public static func make(
        proposalDir: URL
    ) -> ToolValidator {
        return { manifest in
            await validate(manifest: manifest, proposalDir: proposalDir)
        }
    }

    static func validate(
        manifest: [String: JSONValue],
        proposalDir: URL
    ) async -> ToolValidationResult {
        var errors: [String] = []

        // Rule (c1): permissions must all be known.
        var perms: [String] = []
        if case .array(let arr)? = manifest["permissions"] {
            for v in arr {
                if case .string(let s) = v { perms.append(s) }
            }
        }
        let permSet = Set(perms)
        let unknownPerms = permSet.subtracting(knownToolPermissions)
        if !unknownPerms.isEmpty {
            errors.append(
                "Manifest includes unknown permissions: \(unknownPerms.sorted().joined(separator: ","))"
            )
        }

        // Rule (a): tests.json present + non-empty array.
        let testsURL = proposalDir.appendingPathComponent("tests.json")
        if !FileManager.default.fileExists(atPath: testsURL.path) {
            errors.append("No tests.json cases were provided.")
        } else {
            do {
                let data = try Data(contentsOf: testsURL)
                let parsed = (try? JSONValue.parse(data)) ?? .null
                if case .array(let cases) = parsed {
                    if cases.isEmpty {
                        errors.append("No tests.json cases were provided.")
                    }
                } else {
                    errors.append("tests.json must be a JSON array.")
                }
            } catch {
                errors.append("tests.json unreadable: \(error.localizedDescription)")
            }
        }

        // Rule (b): scan entrypoint for dangerous imports + entrypoint safety.
        var entrypointName = "tool.swift"
        if case .string(let s)? = manifest["entrypoint"], !s.isEmpty {
            entrypointName = s
        }
        let parts = entrypointName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if entrypointName.hasPrefix("/") || parts.contains(where: { $0 == ".." || $0.isEmpty }) {
            errors.append("Entrypoint path is unsafe.")
        } else {
            let entryURL = proposalDir.appendingPathComponent(entrypointName)
            if !FileManager.default.fileExists(atPath: entryURL.path) {
                errors.append("Entrypoint is missing.")
            } else if let body = try? String(contentsOf: entryURL, encoding: .utf8) {
                let networkAllowed = !permSet.intersection(
                    ["network_localhost", "network_public", "network"]
                ).isEmpty
                // Audit fix 2026-07-21: FileManager write verbs are gated on
                // a declared write permission (app-data or arbitrary).
                let writeAllowed = !permSet.intersection(
                    ["app_data_write", "arbitrary_file_write"]
                ).isEmpty
                for line in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Strip line comments — '#' to EOL.
                    let codeOnly: String = {
                        var t = trimmed
                        if let hash = t.firstIndex(of: "#") {
                            t = String(t[..<hash]).trimmingCharacters(in: .whitespaces)
                        }
                        // Swift line comments (audit fix 2026-07-21) — the
                        // old '#' -only strip left `// import socket` and
                        // `// Process()` live in the scan.
                        if let slashes = t.range(of: "//") {
                            t = String(t[..<slashes.lowerBound]).trimmingCharacters(in: .whitespaces)
                        }
                        return t
                    }()
                    if codeOnly.isEmpty { continue }
                    // Match `import X[.Y][, Z]` and `from X[.Y] import ...`.
                    let importNames = extractImportRoots(line: codeOnly)
                    for root in importNames {
                        if dangerousToolImports.contains(root) {
                            errors.append("Import '\(root)' is not allowed in autonomous tools.")
                        }
                        if dangerousSwiftImports.contains(root) {
                            errors.append("Import '\(root)' is not allowed in autonomous tools.")
                        }
                        if (root == "http" || root == "urllib") && !networkAllowed {
                            errors.append("Import '\(root)' requires a network permission.")
                        }
                    }
                    // Swift-shaped dangerous symbols (audit fix 2026-07-21).
                    for symbol in dangerousSwiftSymbols where containsSymbol(codeOnly, symbol) {
                        errors.append("Symbol '\(symbol)' is not allowed in autonomous tools.")
                    }
                    if writeAllowed == false {
                        for symbol in fileManagerWriteSymbols where containsSymbol(codeOnly, symbol) {
                            errors.append("FileManager write '\(symbol)' requires a write permission.")
                        }
                    }
                }
            }
        }

        // autoPromotable preserves retired semantics: bool(perms) AND perms ⊆ SAFE_AUTO.
        let safeAuto = !permSet.isEmpty && permSet.isSubset(of: safeAutoToolPermissions)
        let valid = errors.isEmpty
        return ToolValidationResult(
            valid: valid,
            errors: errors,
            autoPromotable: valid && safeAuto
        )
    }

    /// True when `symbol` appears in `line` — when the symbol starts with an
    /// identifier character, the match must NOT be immediately preceded by
    /// one, so `Subprocess(` does not match `Process(` while
    /// `Foundation.Process(` still does. Dot-prefixed symbols (e.g.
    /// `.removeItem(`) carry their own boundary (audit fix 2026-07-21).
    static func containsSymbol(_ line: String, _ symbol: String) -> Bool {
        let boundarySensitive = symbol.first.map {
            $0.isLetter || $0.isNumber || $0 == "_"
        } ?? false
        var searchStart = line.startIndex
        while let range = line.range(of: symbol, range: searchStart..<line.endIndex) {
            if !boundarySensitive || range.lowerBound == line.startIndex { return true }
            let before = line[line.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_") { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Pull root module names out of an `import` / `from ... import` line.
    /// Text-based (no AST) — best-effort: handles the common single-line
    /// import shapes Python tools actually use. Returns the first dotted
    /// segment of each imported module (mirrors `name.split(".", 1)[0]`).
    static func extractImportRoots(line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("from ") {
            // `from X.Y import Z` → root = "X"
            let rest = t.dropFirst("from ".count)
            let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if let mod = parts.first {
                let root = mod.split(separator: ".").first.map(String.init) ?? String(mod)
                return [root]
            }
            return []
        }
        if t.hasPrefix("import ") {
            // `import A, B as C, D.E` → roots = ["A","B","D"]
            let rest = t.dropFirst("import ".count)
            var roots: [String] = []
            for chunk in rest.split(separator: ",") {
                let mod = chunk.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                if mod.isEmpty { continue }
                let root = mod.split(separator: ".").first.map(String.init) ?? mod
                roots.append(root)
            }
            return roots
        }
        return []
    }
}

public actor ToolPromoteEngine {
    private let signer: SwiftNativeManifestSigner
    private let dataRoot: URL
    /// nil ⇒ the SAFE default: SwiftToolValidator pinned per-promote to
    /// proposals/<id> (U5 W-B fix-round — permissive is no longer the
    /// public default; see `permissivePromoteValidatorForTesting`).
    private let validatorOverride: ToolValidator?
    private let persistence: SwiftNativePersistenceCore
    private let clock: @Sendable () -> Date
    private var mutationTail: Task<Void, Never>? = nil

    /// Mirrors the retired daemon `RISKY_TOOL_PERMISSIONS`. KEEP IN SYNC.
    public static let riskyToolPermissions: Set<String> = [
        "app_data_write", "shell", "network_public",
        "calendar_write", "contacts_write", "location", "mac_control",
    ]

    /// `validator`: pass nil (the default) to validate with the REAL
    /// SwiftToolValidator, resolved per-promote against the proposal dir.
    /// Tests inject explicit validators to isolate other machinery.
    public init(
        signer: SwiftNativeManifestSigner,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        validator: ToolValidator? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.signer = signer
        self.dataRoot = dataRoot
        self.validatorOverride = validator
        self.persistence = SwiftNativePersistenceCore()
        self.clock = clock
    }

    // MARK: paths

    private var toolsRoot: URL {
        dataRoot.appendingPathComponent("tools", isDirectory: true)
    }
    private var proposalsRoot: URL {
        toolsRoot.appendingPathComponent("proposals", isDirectory: true)
    }
    private var activeRoot: URL {
        toolsRoot.appendingPathComponent("active", isDirectory: true)
    }
    private var registryPath: URL {
        toolsRoot.appendingPathComponent("registry.json")
    }

    // MARK: promote

    @discardableResult
    public func promote(
        proposalId: String,
        allowRisky: Bool = false,
        approvedBy: String = ""
    ) async throws -> [String: JSONValue] {
        // 0. Id-shape guard (defense in depth — SwiftNativeToolExecution
        //    gates this too): the id becomes the active/<id> dir name, and
        //    the `.staging-`/`.retired-` prefixes are reserved for swap
        //    machinery — a tool named like litter would be swept/restored
        //    by the entry sweep below.
        guard Self.isSafePromoteId(proposalId) else {
            throw ToolPromoteError.validationFailed(errors: [
                "tool id must be a single safe path component and may not use the reserved \(Self.stagingPrefix)/\(Self.retiredPrefix) prefixes"
            ])
        }
        let proposalDir = proposalsRoot.appendingPathComponent(proposalId, isDirectory: true)
        let manifestURL = proposalDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ToolPromoteError.unknownProposal(id: proposalId)
        }

        // 1. Read the proposal manifest — serves as `record` for the merge.
        let manifestRaw = await persistence.readJSON(manifestURL, defaultValue: .object([:]))
        guard case .object(let manifest) = manifestRaw, !manifest.isEmpty else {
            throw ToolPromoteError.unknownProposal(id: proposalId)
        }

        // 2. Validate. Default (no injected validator) = the REAL
        //    SwiftToolValidator pinned to this proposal dir, so a bare
        //    ToolPromoteEngine(signer:dataRoot:) is safe by construction.
        let validator = validatorOverride ?? SwiftToolValidator.make(proposalDir: proposalDir)
        let validation = await validator(manifest)
        if !validation.valid {
            throw ToolPromoteError.validationFailed(errors: validation.errors)
        }

        // 3. Risky-permission intersection.
        var perms: [String] = []
        if case .array(let arr)? = manifest["permissions"] {
            for v in arr {
                if case .string(let s) = v { perms.append(s) }
            }
        }
        let riskyHits = perms.filter { Self.riskyToolPermissions.contains($0) }
        let risky = !riskyHits.isEmpty
        if !validation.autoPromotable && !(allowRisky && risky) {
            throw ToolPromoteError.riskyWithoutAllowRisky(permissions: riskyHits)
        }
        if risky && !allowRisky {
            throw ToolPromoteError.riskyWithoutAllowRisky(permissions: riskyHits)
        }

        // 4. Compute swap identities, then run the ENTIRE mutation sequence
        //    (sweep → stage → sign → fingerprint → swap → registry upsert)
        //    inside the actor's serialized mutation chain. Pre-U5 only the
        //    registry upsert was serialized, so two same-id promotes could
        //    interleave dir writes and registry writes — leaving the
        //    registry fingerprint describing a DIFFERENT dir than the one
        //    on disk (= fingerprintMismatch quarantine on next run).
        //
        //    The actor chain only serializes callers sharing THIS instance.
        //    Production constructs a fresh engine per promote call
        //    (SwiftNativeToolExecution.promote), so the real cross-instance/
        //    cross-process serializer is the registry flock in step 7+8,
        //    which spans the directory swap AND the registry write.
        let stamp = Self.isoTimestamp(clock())
        let now = clock()
        let token = Self.swapToken(now)
        let activeRoot = self.activeRoot
        let registryPath = self.registryPath
        let activeDir = activeRoot.appendingPathComponent(proposalId, isDirectory: true)
        let stagingDir = activeRoot.appendingPathComponent(
            Self.stagingPrefix + proposalId + "-" + token, isDirectory: true
        )
        let signer = self.signer
        let persistence = self.persistence

        let work: @Sendable () async throws -> [String: JSONValue] = {
            let fm = FileManager.default
            try fm.createDirectory(at: activeRoot, withIntermediateDirectories: true)

            // 5. Sweep crash litter a prior promote left behind when the
            //    process died mid-flight (age-gated; see the helper doc).
            Self.sweepStaleSwapLitter(activeRoot: activeRoot, now: now)

            // 6. Stage proposals/<id>/ → active/.staging-<id>-<token>/ and
            //    sign + fingerprint THERE. The live active/<id> dir is not
            //    touched until the staged copy is fully promote-shaped, so a
            //    failure anywhere in this step leaves the previously-active
            //    tool intact. (Pre-U5 this was remove-then-copy: the old
            //    tool was already destroyed before signing could fail.)
            defer {
                // Cleanup of whatever occupies the staging path on exit:
                //   - throw BEFORE the swap → the never-swapped-in staged
                //     copy (garbage);
                //   - successful EXCHANGE → the displaced old tool body
                //     (renamex_np parks it here) — deleting it is the old
                //     "drop the retired copy" success step;
                //   - registry-failure rollback → the staged copy, after the
                //     rollback exchanged it back out of active/<id>;
                //   - first-promote rename path → nothing (no-op).
                // Crash-path litter is handled by the entry sweep on the
                // NEXT promote.
                if fm.fileExists(atPath: stagingDir.path) {
                    try? fm.removeItem(at: stagingDir)
                }
            }
            do {
                try fm.copyItem(at: proposalDir, to: stagingDir)
            } catch {
                throw ToolPromoteError.copyFailed(error.localizedDescription)
            }

            // 6a. Re-read manifest from the staging dir, sign in place.
            let stagedManifestURL = stagingDir.appendingPathComponent("manifest.json")
            let stagedManifestRaw = await persistence.readJSON(stagedManifestURL, defaultValue: .object([:]))
            guard case .object(var activeManifest) = stagedManifestRaw else {
                throw ToolPromoteError.persistenceFailed("staged manifest unparseable")
            }
            let signedManifest: [String: JSONValue]
            do {
                signedManifest = try await signer.sign(activeManifest)
            } catch {
                throw ToolPromoteError.signingFailed(error.localizedDescription)
            }
            activeManifest = signedManifest
            do {
                try await persistence.writeJSON(.object(activeManifest), to: stagedManifestURL)
            } catch {
                throw ToolPromoteError.persistenceFailed("write signed manifest: \(error.localizedDescription)")
            }

            // 6b. codeFingerprint over the STAGED tool body. The fingerprint
            //     hashes file NAMES + bytes (never absolute paths), so the
            //     value is identical after the rename swap in step 7.
            let fingerprint: String
            do {
                fingerprint = try Self.computeToolCodeFingerprintForPromote(
                    toolDir: stagingDir, manifest: activeManifest
                )
            } catch {
                throw ToolPromoteError.persistenceFailed("fingerprint: \(error.localizedDescription)")
            }

            // 6c. Build promoted payload (record merged with signed manifest
            //     + promote-side overrides). Mirrors Python
            //     `{**record, **manifest, ...}`. activePath points at the
            //     FINAL active dir, not the staging dir.
            var promoted: [String: JSONValue] = manifest
            for (k, v) in activeManifest { promoted[k] = v }
            promoted["codeFingerprint"] = .string(fingerprint)
            promoted["status"] = .string("active")
            promoted["phase"] = .string("active")
            promoted["activePath"] = .string(activeDir.path)
            promoted["quarantinePath"] = .null
            promoted["quarantineReason"] = .null
            promoted["validationStatus"] = .string("valid")
            promoted["validationErrors"] = .array([])
            promoted["promotedAt"] = .string(stamp)
            if risky {
                promoted["autoRun"] = .bool(false)
                promoted["autoPromote"] = .bool(false)
                promoted["manualApprovalRequired"] = .bool(false)
                promoted["riskAcknowledgedAt"] = .string(stamp)
                promoted["riskAcknowledgedBy"] = .string(
                    approvedBy.isEmpty ? "manual_review" : approvedBy
                )
                promoted["userRequestedActivation"] = .bool(approvedBy == "user_requested")
            }

            // Ensure id/name/createdAt anchor fields exist (mirror the
            // registry's ToolRecord contract). If the manifest didn't carry
            // createdAt, stamp now.
            if promoted["id"] == nil {
                promoted["id"] = .string(proposalId)
            }
            if promoted["name"] == nil {
                promoted["name"] = .string(proposalId)
            }
            if promoted["createdAt"] == nil {
                promoted["createdAt"] = .string(stamp)
            }
            promoted["updatedAt"] = .string(stamp)

            // 7+8. Directory swap AND registry upsert under ONE cross-process
            //    flock on registry.json (U5 W-B fix-round, gpt-5.5 NEEDS_FIX).
            //    Pre-fix the swap ran BEFORE the lock, and production builds a
            //    fresh engine per promote, so two real concurrent promotes
            //    could interleave swap/registry and leave registry fingerprint
            //    A pointing at active dir B. Taking the lock before the swap
            //    means no other promote (any engine instance, any process —
            //    ToolRegistry.quarantine and the daemon's file_lock.py share
            //    this lock file) can slot in between our swap and our write.
            //
            //    The swap itself is renamex_np(RENAME_SWAP): a TRUE atomic
            //    exchange — there is no instant where active/<id> is absent
            //    or half-written. The displaced old tool body lands at the
            //    staging path (cleaned by the defer above on success, and the
            //    rollback medium on registry failure). First-ever promote has
            //    no live dir to exchange; a single same-volume rename is
            //    equally windowless. Registry mutators all resolve through
            //    this same flock, so even the lock-internal half-states
            //    (swapped but not yet upserted) are unobservable to them; a
            //    CRASH in that window leaves disk=new/registry=old, which the
            //    fingerprint-mismatch quarantine catches on next run and the
            //    entry sweep's age-gated litter collection tidies after.
            let promotedSnapshot = promoted
            let lockedSwapAndUpsert: @Sendable () async throws -> Void = {
                let fm = FileManager.default
                // --- swap (inside the lock) ---
                var exchangedOldIntoStaging = false
                if fm.fileExists(atPath: activeDir.path) {
                    try Self.atomicExchangeDirectories(stagingDir, activeDir)
                    // Old tool body now parked at stagingDir (rollback copy).
                    exchangedOldIntoStaging = true
                } else {
                    do {
                        try fm.moveItem(at: stagingDir, to: activeDir)
                    } catch {
                        throw ToolPromoteError.swapFailed(error.localizedDescription)
                    }
                }

                // --- registry upsert (same lock) ---
                do {
                    let raw = await persistence.readJSON(registryPath, defaultValue: .array([]))
                    var items: [JSONValue] = []
                    if case .array(let arr) = raw { items = arr }
                    var foundIdx: Int? = nil
                    for (idx, item) in items.enumerated() {
                        if case .object(let obj) = item,
                           case .string(let rid) = obj["id"] ?? .null,
                           rid == proposalId {
                            foundIdx = idx
                            break
                        }
                    }
                    if let idx = foundIdx {
                        // FINDING #3 fix — preserve registry-only fields the
                        // manifest doesn't carry (useCount/proposalPath/autoCreated/
                        // sourceRunId/requestSource/...). Mirrors daemon's
                        // upsert_tool_record: `merged = dict(item); merged.update(record)`.
                        if case .object(let existing) = items[idx] {
                            var merged = existing
                            for (k, v) in promotedSnapshot { merged[k] = v }
                            items[idx] = .object(merged)
                        } else {
                            items[idx] = .object(promotedSnapshot)
                        }
                    } else {
                        items.append(.object(promotedSnapshot))
                    }
                    do {
                        try await persistence.writeJSON(.array(items), to: registryPath)
                    } catch {
                        throw ToolPromoteError.persistenceFailed("registry write: \(error.localizedDescription)")
                    }
                } catch {
                    // Roll the swap back — still inside the lock, so no
                    // registry consumer can observe the half-state. Disk and
                    // registry stay consistent: previously-active tool
                    // restored, registry untouched.
                    if exchangedOldIntoStaging {
                        try? Self.atomicExchangeDirectories(stagingDir, activeDir)
                    } else {
                        try? fm.removeItem(at: activeDir)
                    }
                    throw error
                }
            }
            try await persistence.withFileLock(registryPath, lockedSwapAndUpsert)
            return promoted
        }
        return try await runSerialized(work)
    }

    private func runSerialized<T: Sendable>(
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prior = mutationTail
        let task = Task<T, Error> {
            _ = await prior?.value
            return try await body()
        }
        mutationTail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - atomic directory exchange (U5 W-B fix-round)

    /// True atomic exchange of two same-volume directory entries via
    /// renamex_np(2) with RENAME_SWAP (APFS). All-or-nothing: on success the
    /// two paths' contents are swapped with NO window where either path is
    /// absent; on failure neither entry has moved. Both paths must exist.
    nonisolated static func atomicExchangeDirectories(_ a: URL, _ b: URL) throws {
        let rc = a.path.withCString { ap in
            b.path.withCString { bp in
                renamex_np(ap, bp, UInt32(RENAME_SWAP))
            }
        }
        guard rc == 0 else {
            let e = errno
            throw ToolPromoteError.swapFailed(
                "renamex_np(RENAME_SWAP) \(a.lastPathComponent) <-> \(b.lastPathComponent): \(String(cString: strerror(e)))"
            )
        }
    }

    // MARK: - staged-swap litter management (U5 W-B)

    static let stagingPrefix = ".staging-"
    static let retiredPrefix = ".retired-"

    /// Litter younger than this is skipped by the entry sweep. A SECOND
    /// engine instance (SwiftNativeToolExecution builds one engine per
    /// promote call, so the Task chain doesn't serialize across them) may
    /// have a promote in flight — tearing down its live staging dir would
    /// corrupt that promote. Crash litter is, by definition, at least one
    /// process-death old (minutes-to-days in practice), so the age gate
    /// costs recovery no meaningful latency. Promotes themselves complete
    /// in seconds, far under this threshold.
    static let swapLitterMinAge: TimeInterval = 600

    /// Sweep crash litter left under tools/active/ by a promote that died
    /// mid-flight (power loss, kill -9 — throw paths clean up inline; this
    /// handles the windows no defer can reach). Policy per entry older than
    /// `swapLitterMinAge`:
    ///   - `.staging-<id>-<token>`: never was the live tool — delete.
    ///   - `.retired-<id>-<token>` with active/<id> PRESENT: the swap
    ///     completed before the crash; the retired copy is a stale backup —
    ///     delete.
    ///   - `.retired-<id>-<token>` with active/<id> MISSING: the crash hit
    ///     between move-aside and move-in — restore the retired dir to
    ///     active/<id> so the previously-active tool comes back.
    static func sweepStaleSwapLitter(activeRoot: URL, now: Date) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: activeRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            let isStaging = name.hasPrefix(stagingPrefix)
            let isRetired = name.hasPrefix(retiredPrefix)
            if !isStaging && !isRetired { continue }
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) < swapLitterMinAge { continue }
            if isStaging {
                try? fm.removeItem(at: entry)
                continue
            }
            guard let id = toolId(fromSwapDirName: name, prefix: retiredPrefix) else {
                try? fm.removeItem(at: entry)
                continue
            }
            let activeDir = activeRoot.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: activeDir.path) {
                try? fm.removeItem(at: entry)
            } else {
                try? fm.moveItem(at: entry, to: activeDir)
            }
        }
    }

    /// Single safe path component, not dot-dirs, not swap-machinery names.
    /// Mirrors SwiftNativeToolExecution.isSafeToolId + the reserved-prefix
    /// rule (kept engine-local because the engine is public API and mutates
    /// paths derived from the id).
    nonisolated static func isSafePromoteId(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        if id.contains("/") || id.contains("\\") || id.contains("\0") { return false }
        if id.hasPrefix(stagingPrefix) || id.hasPrefix(retiredPrefix) { return false }
        return true
    }

    /// Parse the tool id back out of ".staging-<id>-<token>" /
    /// ".retired-<id>-<token>". Tokens never contain "-" (base-36
    /// alphanumerics only — see `swapToken`), while ids MAY contain dashes —
    /// so the id is everything between the prefix and the LAST dash.
    static func toolId(fromSwapDirName name: String, prefix: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let lastDash = rest.lastIndex(of: "-"), lastDash > rest.startIndex else { return nil }
        let id = String(rest[..<lastDash])
        return id.isEmpty ? nil : id
    }

    /// Millis-since-epoch + random suffix, both base-36 — NO dashes, so
    /// `toolId(fromSwapDirName:)` can split on the last dash unambiguously.
    nonisolated static func swapToken(_ date: Date) -> String {
        let millis = UInt64(max(0, date.timeIntervalSince1970) * 1000)
        let rand = UInt32.random(in: 0...UInt32.max)
        return String(millis, radix: 36) + String(rand, radix: 36)
    }

    /// Mirror of Python's `datetime.now(timezone.utc).isoformat()`. Duplicates
    /// `SwiftNativeManifestSigner.isoTimestamp` (which is internal to its
    /// module) so this file stays self-contained — byte-identical algorithm.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let ti = date.timeIntervalSince1970
        let frac = ti - floor(ti)
        var micros = Int((frac * 1_000_000.0).rounded())
        if micros < 0 { micros = 0 }
        if micros > 999_999 { micros = 999_999 }
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
            comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0
        )
        if micros == 0 { return base + "+00:00" }
        return base + String(format: ".%06d", micros) + "+00:00"
    }

    // MARK: - codeFingerprint helper
    //
    // Local port of daemon's `tool_code_fingerprint`. The sibling RunSandbox
    // worker is expected to land a module-level `computeToolCodeFingerprint`
    // helper; until that lands we expose this engine-private static so the
    // promote path is self-contained. When the sibling helper arrives, this
    // can be deleted and calls forwarded — the byte semantics are identical.

    /// Mirror of the retired daemon. Hashes:
    ///   filename || 0x00 || file-bytes || 0x00
    /// in the order [manifest.json, entrypoint, tests.json]. Missing files
    /// contribute the filename + two NULs only.
    public static func computeToolCodeFingerprintForPromote(
        toolDir: URL, manifest: [String: JSONValue]
    ) throws -> String {
        var entrypointName = "tool.swift"
        if case .string(let s)? = manifest["entrypoint"], !s.isEmpty {
            entrypointName = s
        }
        // Safety gate — preserves "no absolute, no '..' parts, no empty
        // parts" check. URLs split path components differently from Python's
        // pathlib so we split on "/" by hand to match.
        let parts = entrypointName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isAbsolute = entrypointName.hasPrefix("/")
        if isAbsolute || parts.contains(where: { $0 == ".." || $0.isEmpty }) {
            throw ToolPromoteError.persistenceFailed("Unsafe tool entrypoint: \(entrypointName)")
        }

        // Resolve entrypoint and confirm it lives inside toolDir.
        let toolDirResolved = URL(fileURLWithPath: toolDir.path).standardizedFileURL.resolvingSymlinksInPath()
        let entrypointURL = toolDirResolved
            .appendingPathComponent(entrypointName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let toolDirPath = toolDirResolved.path
        if !entrypointURL.path.hasPrefix(toolDirPath + "/") && entrypointURL.path != toolDirPath {
            throw ToolPromoteError.persistenceFailed(
                "Tool entrypoint escapes tool directory: \(entrypointName)"
            )
        }

        let manifestURL = toolDir.appendingPathComponent("manifest.json")
        let testsURL = toolDir.appendingPathComponent("tests.json")
        let paths: [URL] = [manifestURL, entrypointURL, testsURL]

        var hasher = SHA256()
        let nul = Data([0])
        for p in paths {
            hasher.update(data: Data(p.lastPathComponent.utf8))
            hasher.update(data: nul)
            if let bytes = try? Data(contentsOf: p) {
                hasher.update(data: bytes)
            }
            hasher.update(data: nul)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
