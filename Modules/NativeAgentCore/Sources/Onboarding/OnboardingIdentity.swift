import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `OnboardingIdentity.swift` | Checked identity and shared manifest/byte writer; profile and USER publication use their domain owners |
extension SwiftNativeOnboardingClient {
    /// Creation and missing-profile repair require both identities explicitly.
    static func nameRefusal(agent: String, user: String) -> OnboardingCompleteResult? {
        if let message = NativeAgentIdentity.nameValidationMessage(agent) {
            return OnboardingCompleteResult(ok: false,
                error: agent.isEmpty ? "missing_agent_name" : "invalid_agent_name", detail: message)
        }
        if user.isEmpty {
            return OnboardingCompleteResult(ok: false, error: "missing_user_name", detail: "Enter your name before saving.")
        }
        return nil
    }
    static func canonicalPath(_ url: URL) -> String {
        // Keep the transaction identity stable even when the target directory did not exist at preparation time. Resolving symlinks can change the string after
        // directory creation and falsely orphan a valid manifest.
        url.standardizedFileURL.path
    }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func identityHash(
        agentName: String,
        personaType: String,
        userName: String,
        personaRoot: URL,
        profilePath: URL
    ) -> String {
        let components = [
            "onboarding-v1",
            agentName,
            personaType,
            userName,
            canonicalPath(personaRoot),
            canonicalPath(profilePath),
        ]
        return sha256(Data(components.joined(separator: "\u{0}").utf8))
    }
    /// USER.md is either the onboarding template or a bounded memory projection with an optional preamble. Its content identifies the writer, never completion.
    enum UserDocShape: Equatable {
        /// No file. Nothing to protect, nothing to prove.
        case absent
        /// Exact autogen body plus optional empty preamble; reproducible from SQLite.
        case generatorProjection
        /// Foreign text or edited preamble; reset must back it up before replacement.
        case authored
    }
    /// Classify only the generator's exact section structure as reproducible. Foreign headings/comments and malformed markers are authored content. A file that
    /// is there but cannot be read throws: unreadable is not absent.
    static func classifyUserDoc(at path: URL) throws -> UserDocShape {
        guard FileManager.default.fileExists(atPath: path.path) else { return .absent }
        let text: String
        do { text = try String(contentsOf: path, encoding: .utf8) }
        catch { throw OnboardingError.ioFailure("read \(path.path) failed: \(error.localizedDescription)") }
        var remainder = text
        guard remainder.components(separatedBy: UserMDAutogenMarkers.bodyStart).count == 2,
              remainder.components(separatedBy: UserMDAutogenMarkers.bodyEnd).count == 2,
              let start = remainder.range(of: UserMDAutogenMarkers.bodyStart),
              let end = remainder.range(of: UserMDAutogenMarkers.bodyEnd),
              start.upperBound <= end.lowerBound else { return .authored }
        remainder.removeSubrange(start.lowerBound..<end.upperBound)
        let preambleStart = UserMDAutogenMarkers.preambleStart
        let preambleEnd = UserMDAutogenMarkers.preambleEnd
        if remainder.contains(preambleStart) || remainder.contains(preambleEnd) {
            guard remainder.components(separatedBy: preambleStart).count == 2,
                  remainder.components(separatedBy: preambleEnd).count == 2,
                  let start = remainder.range(of: preambleStart),
                  let end = remainder.range(of: preambleEnd), start.upperBound <= end.lowerBound,
                  remainder[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .authored }
            remainder.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .generatorProjection : .authored
    }
    static func expectedTargetURLs(
        personaRoot: URL,
        profilePath: URL,
        dataRoot: URL
    ) -> [String: URL] {
        [
            "soul": personaRoot.appendingPathComponent("SOUL.md"),
            "voice": personaRoot.appendingPathComponent("VOICE.md"),
            "user": personaRoot.appendingPathComponent("USER.md"),
            "growth": personaRoot.appendingPathComponent("GROWTH.md"),
            "agents": personaRoot.appendingPathComponent("AGENTS.md"),
            "profile": profilePath,
            "sentinel": dataRoot.appendingPathComponent(".onboarded"),
        ]
    }
    static func writeTransaction<Manifest: Encodable>(
        _ manifest: Manifest,
        to path: URL,
        encodingContext: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw OnboardingError.ioFailure(
                "encode \(encodingContext) failed: \(error.localizedDescription)"
            )
        }
        try atomicWriteData(data, to: path)
    }
    /// Idempotently commit one staged target. Existing intended bytes prove a previous attempt reached this step. Otherwise only the exact base bytes observed
    /// at transaction preparation may be replaced.
    static func ensureCommitted(_ intent: OnboardingTargetIntent, to path: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            let current: Data
            do {
                current = try Data(contentsOf: path)
            } catch {
                throw OnboardingError.ioFailure("read \(path.lastPathComponent) during onboarding recovery failed")
            }
            let currentHash = sha256(current)
            if currentHash == intent.sha256 {
                try SwiftNativePersistenceCore.syncDirectory(path.deletingLastPathComponent())
                return
            }
            guard let base = intent.baseSHA256, currentHash == base else {
                throw OnboardingError.ioFailure("\(path.lastPathComponent) changed outside the pending onboarding transaction")
            }
        } else if intent.baseSHA256 != nil {
            throw OnboardingError.ioFailure("\(path.lastPathComponent) disappeared after onboarding transaction preparation")
        }
        if intent.role == "profile" || intent.role == "user" {
            do {
                if intent.role == "user" {
                    try UserMDGenerator.atomicReplaceIfChanged(intent.content, existingBytes: nil, at: path)
                } else {
                    try SwiftNativePersonaEngine.atomicWriteText(intent.content, to: path)
                }
            }
            catch { throw OnboardingError.ioFailure("write \(path.lastPathComponent) failed: \(error.localizedDescription)") }
        } else {
            try atomicWriteText(intent.content, to: path)
        }
        let committed = try Data(contentsOf: path)
        guard sha256(committed) == intent.sha256 else {
            throw OnboardingError.ioFailure("\(path.lastPathComponent) failed post-write verification")
        }
    }
    static func utcStamp() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1,
                      comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
    }
    func ensureDirectoryExists(_ dir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw OnboardingError.ioFailure("mkdir \(dir.path) failed: \(error.localizedDescription)")
        }
    }
    static func atomicWriteText(_ content: String, to path: URL) throws {
        try atomicWriteData(Data(content.utf8), to: path)
    }
    /// Reset backups must preserve exact bytes, including invalid or differently encoded text, so recovery cannot normalize away authored content.
    static func atomicWriteData(_ data: Data, to path: URL) throws {
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
        } catch {
            throw OnboardingError.ioFailure("write \(path.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }
    static func makeProfileUpdatePlan(
        profilePath: URL, agentName: String, personaType: String, userName: String
    ) throws -> (content: String, baseSHA256: String?) {
        do {
            return try SwiftNativePersonaEngine.onboardingProfileUpdate(
                profilePath: profilePath, agentName: agentName, personaType: personaType, userName: userName)
        } catch let PersonaWriteError.ioFailure(detail) {
            throw OnboardingError.ioFailure(detail)
        }
    }
}
