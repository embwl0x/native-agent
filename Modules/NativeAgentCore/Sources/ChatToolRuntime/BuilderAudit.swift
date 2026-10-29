import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TurnTrace
import AgentWorkspace
import AuthoredCapabilities
import AppKit
import TrustCenter
import ApprovalInbox
import PersonaEngine
import StandingBots
import ProviderRouting
import Darwin
import CryptoKit
import MemoryV2
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `BuilderAudit.swift` | Redacted builder audits and bounded retention |
extension SwiftToolDispatcher {
    /// Audit failures remain visible in the response envelope.
    @discardableResult
    static func builderWriteAudit(
        runId: String,
        entry: [String: Any],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> (url: URL, error: String?) {
        // Redacted JSON receipts and installer logs: local evidence, excluded
        // from backup/export/phone sync; PrivacyMap: builder_audit.
        let auditDir = dataRoot
            .appendingPathComponent("builder_audit", isDirectory: true)
        let auditURL = auditDir.appendingPathComponent("\(runId).json")
        do {
            try FileManager.default.createDirectory(
                at: auditDir, withIntermediateDirectories: true
            )
            var receipt = TurnTraceRedactor.redactValue(JSONValue(fromFoundation: entry)).mapStrings(builderAuditText)
            if case .object(var fields) = receipt {
                if case .array(let args)? = fields["args"] {
                    var secretValue = false
                    fields["args"] = .array(args.map { arg in
                        guard case .string(let text) = arg else { return arg }
                        if secretValue {
                            secretValue = false
                            return .string("[REDACTED_NAMED_SECRET]")
                        }
                        secretValue = text.hasPrefix("-") && builderAuditSecretName(text.trimmingCharacters(in: CharacterSet(charactersIn: "-")))
                        return arg
                    })
                }
                for (key, cap) in [("stdout", 16_384), ("stderr", 16_384), ("sourcePayload", 4_096)] {
                    if case .string(let text)? = fields[key] { fields[key] = .string(String(text.prefix(cap))) }
                }
                receipt = .object(fields)
            }
            let data = Data(try receipt.serialize(pretty: true).utf8)
            try data.write(to: auditURL)
            let pruneResult = pruneBuilderAuditsIfNeeded(in: auditDir, keeping: builderAuditRetentionLimit)
            if pruneResult.removedCount > 0 {
                nativeLog("SwiftToolDispatcher.builder_audit: pruned %d older audit file(s)", pruneResult.removedCount)
            }
            if let pruneError = pruneResult.error {
                nativeLog("SwiftToolDispatcher.builder_audit: %@", pruneError)
            }
            return (auditURL, pruneResult.error)
        } catch {
            return (auditURL, String(describing: error))
        }
    }
    private static func builderAuditSecretName(_ name: String) -> Bool {
        TurnSecretRedactor.isCredentialName(name) || ["auth", "credential", "cookie"].contains(name.lowercased())
    }
    static func builderAuditText(_ text: String) -> String {
        // Include named shell flags and short assignments; token-shape scrubbing
        // alone cannot recognize an arbitrary password passed as an argument.
        var result = text.replacingOccurrences(
            of: #"\b(?:authorization|proxy-authorization|auth|cookie|set-cookie)\s*:\s*[^\r\n"']+"#,
            with: "[REDACTED_NAMED_SECRET]", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"#,
            with: "[REDACTED_PRIVATE_KEY]", options: .regularExpression)
        let pattern = #"(?<![\w-])((?:--?)?(?:[\w-]*(?:password|passwd|token|secret)|(?:[\w-]*[_-])?(?:api[_-]?key|private[_-]?key)|authorization|auth|credential|cookie))(?![\w-])["']?(\s*=\s*|\s*:\s*|[ \t]+)("(?:\\.|[^"\\])*"|'[^']*'|[^\s;,]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { preconditionFailure("Invalid builder audit redaction pattern") }
        let source = result as NSString
        for match in expression.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if builderAuditSecretName(name) {
                result = (result as NSString).replacingCharacters(in: match.range(at: 3), with: "[REDACTED_NAMED_SECRET]")
            }
        }
        return result
    }
    static let builderAuditRetentionLimit = 500
    struct BuilderAuditPruneResult: Equatable {
        var removedCount: Int
        var error: String?
    }
    static func pruneBuilderAuditsIfNeeded(
        in auditDir: URL,
        keeping: Int = builderAuditRetentionLimit
    ) -> BuilderAuditPruneResult {
        guard keeping >= 0 else { return BuilderAuditPruneResult(removedCount: 0, error: nil) }
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: auditDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return BuilderAuditPruneResult(
                removedCount: 0,
                error: "builder_audit prune could not enumerate receipts: \(error)"
            )
        }
        var receipts: [(url: URL, modified: Date)] = []
        receipts.reserveCapacity(entries.count)
        for url in entries {
            guard url.pathExtension == "json",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            do {
                let values = try url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                )
                guard values.isRegularFile == true else { continue }
                receipts.append((url, values.contentModificationDate ?? .distantPast))
            } catch {
                return BuilderAuditPruneResult(
                    removedCount: 0,
                    error: "builder_audit prune could not inspect \(url.lastPathComponent): \(error)"
                )
            }
        }
        guard receipts.count > keeping else {
            return BuilderAuditPruneResult(removedCount: 0, error: nil)
        }
        receipts.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        var removed = 0
        for victim in receipts.dropFirst(keeping) {
            do {
                // Retire each receipt with its <runId>-*.log sidecars.
                let runId = victim.url.deletingPathExtension().lastPathComponent
                for sidecar in entries
                where sidecar.lastPathComponent.hasPrefix("\(runId)-") {
                    try fm.removeItem(at: sidecar)
                    removed += 1
                }
                try fm.removeItem(at: victim.url)
                removed += 1
            } catch {
                return BuilderAuditPruneResult(
                    removedCount: removed,
                    error: "builder_audit prune failed after removing \(removed) file(s): \(error)"
                )
            }
        }
        return BuilderAuditPruneResult(removedCount: removed, error: nil)
    }
}
