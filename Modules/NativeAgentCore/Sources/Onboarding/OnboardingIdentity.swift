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
    static func canonicalPath(_ url: URL) -> String {
        // Keep the transaction identity stable even when the target directory
        // did not exist at preparation time. Resolving symlinks can change the
        // string after directory creation and falsely orphan a valid manifest.
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
    /// USER.md is either the onboarding template or a bounded memory projection with an optional preamble.
    /// Its content identifies the writer, never completion.
    enum UserDocShape: Equatable {
        /// No file. Nothing to protect, nothing to prove.
        case absent
        /// Exact autogen body plus optional empty preamble; reproducible from SQLite.
        case generatorProjection
        /// Foreign text or edited preamble; reset must back it up before replacement.
        case authored
    }
    /// Classify only the generator's exact section structure as reproducible.
    /// Foreign headings/comments and malformed markers are authored content.
    /// A file that is there but cannot be read throws: unreadable is not absent.
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
    /// Proof that onboarding FINISHED on this Mac: the `.onboarded` sentinel,
    /// or — for installs that predate it — the complete legacy document set.
    /// USER.md alone and SOUL.md alone are partial state, never completion.
    static func hasCompletionAnchor(
        personaTargets targets: [String: URL],
        fileManager fm: FileManager
    ) -> Bool {
        if fm.fileExists(atPath: targets["sentinel"]!.path) { return true }
        return NativeAgentPublicSafety.hasLegacyCompletionAnchor(
            personaRoot: targets["soul"]!.deletingLastPathComponent(),
            profileURL: targets["profile"]!,
            allowMissingProfile: true
        )
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
    /// Idempotently commit one staged target. Existing intended bytes prove a
    /// previous attempt reached this step. Otherwise only the exact base bytes
    /// observed at transaction preparation may be replaced.
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
    /// UTC stamp: yyyyMMddTHHmmssZ, without fractional seconds.
    static func utcStamp() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1,
                      comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
    }
    /// Create missing parent directories with default permissions.
    func ensureDirectoryExists(_ dir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw OnboardingError.ioFailure("mkdir \(dir.path) failed: \(error.localizedDescription)")
        }
    }
    /// Durable private write shared with the other canonical stores.
    static func atomicWriteText(_ content: String, to path: URL) throws {
        try atomicWriteData(Data(content.utf8), to: path)
    }
    /// Byte-preserving sibling used by reset backups. Persona files are
    /// normally UTF-8, but reset is a safety operation and must preserve the
    /// exact bytes it found rather than normalizing invalid or legacy text.
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
    /// `<dataRoot>/memory/profile.json` → `name`. No file or no name is empty; a file that cannot be
    /// read or parsed throws, so the wizard shows why instead of a blank name.
    static func readPersonaName(at path: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else { return "" }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
                throw OnboardingError.ioFailure("\(path.path) is not a JSON object")
            }
            return obj["name"] as? String ?? ""
        } catch let error as OnboardingError {
            throw error
        } catch {
            throw OnboardingError.ioFailure("read \(path.path) failed: \(error.localizedDescription)")
        }
    }
}
