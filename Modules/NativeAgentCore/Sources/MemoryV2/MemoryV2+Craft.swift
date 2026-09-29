import Foundation
import CryptoKit
import PersistenceCore

/// Restricted method vocabulary. No field can carry a captured path, label,
/// document body, control handle, preference, or approval.
public struct CraftMethod: Codable, Sendable, Equatable {
    public enum Intent: String, Codable, Sendable { case textEditReplaceAndSave, finderFolderAndMove, reminderWithDueDate }
    public enum Input: String, Codable, Sendable { case fileURL, expectedUTF8, replacementUTF8, sourceDirectory, folderName, fileNames, listName, title, dueDate }
    public enum Step: String, Codable, Sendable { case inspectDocument, replaceEditor, inspectEditor, saveDocument, verifyFile, inspectFiles, createFolder, moveFiles, verifyDestinationsAndSources, resolveReminderList, inspectReminder, createReminder, verifyReminder }
    public enum Precondition: String, Codable, Sendable {
        case exactOpenDocument, boundedRegularUTF8File, expectedDiskAndEditor, oneSettableEditor, noDialog, englishSaveMenu, currentAuthority
        case regularLocalFiles, absentDestination, exactWritableReminderList, explicitDueDate, noExistingReminder
    }
    public enum Stop: String, Codable, Sendable { case drift, denial, unsupportedState, uncertainEffect, unavailableEvidence }
    public enum Check: String, Codable, Sendable { case exactFileBytes, destinationIdentityAndAbsentSource, exactReminderReadback }
    public enum Recovery: String, Codable, Sendable { case inspectOnceThenStop }
    public enum Idempotence: String, Codable, Sendable { case writeAheadNoRepeat }
    public enum Reason: String, Codable, Sendable {
        case titlesCanCollide, protectConcurrentChanges, replaceWithoutAppending, autosaveCanFinish, saveReceiptIsNotPersistence
        case movesCanPartiallyFinish, bindExactList, creationReceiptIsNotPersistence
    }
    public let version: Int
    public let intent: Intent
    public let inputs: [Input]
    public let steps: [Step]
    public let preconditions: [Precondition]
    public let stopConditions: [Stop]
    public let successCheck: Check
    public let recovery: Recovery
    public let idempotence: Idempotence
    public let reasons: [Reason]

    public static let textEdit = CraftMethod(version: 1, intent: .textEditReplaceAndSave,
        inputs: [.fileURL, .expectedUTF8, .replacementUTF8],
        steps: [.inspectDocument, .replaceEditor, .inspectEditor, .saveDocument, .verifyFile],
        preconditions: [.exactOpenDocument, .boundedRegularUTF8File, .expectedDiskAndEditor, .oneSettableEditor, .noDialog, .englishSaveMenu, .currentAuthority],
        stopConditions: [.drift, .denial, .unsupportedState, .uncertainEffect, .unavailableEvidence],
        successCheck: .exactFileBytes, recovery: .inspectOnceThenStop, idempotence: .writeAheadNoRepeat,
        reasons: [.titlesCanCollide, .protectConcurrentChanges, .replaceWithoutAppending, .autosaveCanFinish, .saveReceiptIsNotPersistence])

    public static let finder = CraftMethod(version: 1, intent: .finderFolderAndMove,
        inputs: [.sourceDirectory, .folderName, .fileNames],
        steps: [.inspectFiles, .createFolder, .moveFiles, .verifyDestinationsAndSources],
        preconditions: [.regularLocalFiles, .absentDestination, .currentAuthority],
        stopConditions: textEdit.stopConditions, successCheck: .destinationIdentityAndAbsentSource,
        recovery: .inspectOnceThenStop, idempotence: .writeAheadNoRepeat,
        reasons: [.protectConcurrentChanges, .movesCanPartiallyFinish])

    public static let reminder = CraftMethod(version: 1, intent: .reminderWithDueDate,
        inputs: [.listName, .title, .dueDate],
        steps: [.resolveReminderList, .inspectReminder, .createReminder, .verifyReminder],
        preconditions: [.exactWritableReminderList, .explicitDueDate, .noExistingReminder, .currentAuthority],
        stopConditions: textEdit.stopConditions, successCheck: .exactReminderReadback,
        recovery: .inspectOnceThenStop, idempotence: .writeAheadNoRepeat,
        reasons: [.bindExactList, .creationReceiptIsNotPersistence])

    public static let supported: [CraftMethod] = [.textEdit, .finder, .reminder]
    public var skillName: String {
        switch intent {
        case .textEditReplaceAndSave: return "craft.textedit.replace-save.v1"
        case .finderFolderAndMove: return "craft.finder.folder-move.v1"
        case .reminderWithDueDate: return "craft.reminders.add-due.v1"
        }
    }

    public var summary: String {
        switch intent {
        case .textEditReplaceAndSave:
            return "Replace and save an open TextEdit UTF-8 .txt file, at most 4096 bytes. Requires current Mac control and file-read authority, a settable editor, and an English Save menu; no rich text, dialogs, or ambiguous editors."
        case .finderFolderAndMove:
            return "Make a new folder in a local source directory with Finder and move 1–16 named regular files into it. Requires current shell and file-read authority plus Finder automation access; no symlinks, overwrites, or cross-volume moves."
        case .reminderWithDueDate:
            return "Add one reminder to an exactly named writable list with an explicit ISO-8601 due timestamp. Requires current Reminders read and write authority; ambiguous lists and existing matching reminders stop the run."
        }
    }

    /// Constructed only from the typed method, never from evidence or a trace.
    public func shareableMethod() throws -> Data {
        guard Self.supported.contains(self) else { throw CraftFailure("Unsupported method version.") }
        if self != Self.textEdit {
            // Only the restricted vocabulary and fixed descriptions ship.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct Export: Encodable {
                let method: CraftMethod
                let summary: String
                let recovery: String
                let partialProgress: String
            }
            return try encoder.encode(Export(method: self, summary: summary,
                recovery: "Inspect the owning system after every uncertain effect. Never automatically repeat an issued effect; stop on drift, denial, or unavailable evidence.",
                partialProgress: self == .finder
                    ? "Journal folder creation and each file move before issuing them. Verify original file identities at destination and absence at source; continue only untouched moves."
                    : "Journal creation before saving and retain the returned reminder identifier locally. Read back the exact list, title, due timestamp, and incomplete state through Reminders; a receipt alone cannot verify creation."))
        }
        struct Export: Encodable {
            let method: CraftMethod
            let summary: String
            let preconditions: [String]
            let reasons: [String]
            let success: String
            let recovery: String
            let partialProgress: String
        }
        let export = Export(method: self, summary: summary,
            preconditions: ["Exact file URL belongs to the open TextEdit window; one editable text area and no sheet.",
                "Disk and editor equal expectedUTF8; regular local UTF-8 .txt file without symlinks.",
                "Fresh controls and current authority are required for every action."],
            reasons: ["Bind the document URL because titles can collide.",
                "Compare complete bytes before editing to avoid overwriting concurrent changes.",
                "Replace the whole editor value so a resumed edit cannot append twice.",
                "Inspect disk before Save because autosave may already have persisted the edit.",
                "Read the saved file because a successful Save action does not prove persistence."],
            success: "The intended file contains exactly replacementUTF8 after the journalled edit, through Save or autosave.",
            recovery: "One fresh inspection after an uncertain effect; never automatically repeat it. Stop on drift, denial, missing evidence, or unsupported state.",
            partialProgress: "Persist edit-issued and save-issued before effects. Resume saving only when the editor proves the replacement. A verified journal is an idempotent receipt, not permission to reapply.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }
}

public struct CraftFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct CraftRunEvidence: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case ready, editIssued, editorVerified, saveIssued, folderIssued, movingFiles, reminderIssued, verified }
    public var phase: Phase = .ready
    public let bindingID: String
    public let path: String
    public let beforeDigest: String
    public let afterDigest: String
    public let sessionID: String
    public var lastReason: String?
    public var method: CraftMethod?
    public var ownerBindings: [String: String]?
    public var issuedFiles: [String]?
    public var verifiedFiles: [String]?
    public init(bindingID: String, path: String, beforeDigest: String, afterDigest: String, sessionID: String) {
        self.bindingID = bindingID; self.path = path; self.beforeDigest = beforeDigest
        self.afterDigest = afterDigest; self.sessionID = sessionID
    }
}

public struct CraftCandidate: Codable, Sendable {
    public let method: CraftMethod
    public var evidenceRefs: [String]
    public var verifiedInputDigests: [String]
}

/// The executable branch of the existing procedural lane. Its local evidence
/// is separate from the enum-only method and partitioned by invoking persona.
public struct ProceduralCraftStore: Sendable {
    public static let skillName = "craft.textedit.replace-save.v1"
    private let directory: URL
    public init(dataRoot: URL, agentID: String) {
        directory = dataRoot.appendingPathComponent("procedural_lane/agents/\(Self.digest(agentID))/craft", isDirectory: true)
    }
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(value), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func candidateName(_ method: CraftMethod) -> String {
        method == .textEdit ? "candidate.json" : method.skillName + ".json"
    }
    public func candidate(_ method: CraftMethod = .textEdit) throws -> CraftCandidate? {
        guard CraftMethod.supported.contains(method) else { throw CraftFailure("Unsupported craft method.") }
        let candidate = try read(candidateName(method), as: CraftCandidate.self)
        if let candidate, candidate.method != method { throw CraftFailure("Unsupported saved craft method.") }
        return candidate
    }
    public func evidence(_ id: String) throws -> CraftRunEvidence? {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw CraftFailure("Invalid craft binding.") }
        return try read("\(id).json", as: CraftRunEvidence.self)
    }
    public func record(_ run: CraftRunEvidence) throws {
        guard run.bindingID.count == 64, run.bindingID.allSatisfy({ $0.isHexDigit }) else { throw CraftFailure("Invalid craft binding.") }
        try write(run, name: "\(run.bindingID).json")
    }
    public func retainVerified(_ run: CraftRunEvidence) throws {
        guard run.phase == .verified else { throw CraftFailure("Craft outcome is not verified.") }
        try record(run)
        let method = run.method ?? .textEdit
        var saved = try candidate(method) ?? CraftCandidate(method: method, evidenceRefs: [], verifiedInputDigests: [])
        let ref = "\(run.bindingID).json"
        if !saved.evidenceRefs.contains(ref) { saved.evidenceRefs.append(ref) }
        let input = Self.digest(run.path + "\u{0}" + run.beforeDigest + "\u{0}" + run.afterDigest)
        if !saved.verifiedInputDigests.contains(input) { saved.verifiedInputDigests.append(input) }
        saved.evidenceRefs = Array(saved.evidenceRefs.suffix(32))
        saved.verifiedInputDigests = Array(saved.verifiedInputDigests.suffix(32))
        try write(saved, name: candidateName(method))
    }
    public func hint(for request: String) throws -> String? {
        let text = request.lowercased()
        let method: CraftMethod
        let scope: String
        if text.contains("textedit"), text.contains("save"), text.contains("replace") || text.contains("edit") {
            method = .textEdit; scope = "open UTF-8 .txt only, ≤4096 bytes"
        } else if text.contains("finder"), text.contains("folder"), text.contains("move") {
            method = .finder; scope = "new local folder, 1–16 named regular files"
        } else if text.contains("reminder"), text.contains("due"), text.contains("add") || text.contains("create") {
            method = .reminder; scope = "exact list and explicit due timestamp"
        } else { return nil }
        guard let saved = try candidate(method) else { return nil }
        let confidence = saved.verifiedInputDigests.count > 1 ? "verified with different inputs" : "one verified input; transfer unproven"
        return "Craft: \(method.skillName) — \(scope); \(confidence). read_skill for limits; craft_run if it fits."
    }
}

extension ProceduralLane {
    /// Authoritative owner-system proof is supplied by the craft runner; generic
    /// argument-key repetition cannot promote an executable candidate.
    public func retainCraft(_ run: CraftRunEvidence, dataRoot: URL, agentID: String) throws {
        try ProceduralCraftStore(dataRoot: dataRoot, agentID: agentID).retainVerified(run)
    }
}
