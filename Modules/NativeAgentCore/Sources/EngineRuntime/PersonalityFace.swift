import ApprovalInbox
import AuthoredCapabilities
import CognitiveSubstrate
import Cognition
import DreamREMCycle
import Foundation
import NativeAgentShared
import PersonaEngine
import PersistenceCore
import TrustCenter
// Blueprint: | `PersonalityFace.swift` | Personality's packet for `native-personality` and its page levers (minds, reset) |

extension NativeAgentEngine {
    /// What the Personality page is drawn from: the facts `native-personality` reads, the keys its rows may carry, and the person's page
    /// levers — the Memory-and-mind model and Reset identity when there is an identity to reset — which no face can hide. Every read that
    /// fails is a named unavailable fact; only cancellation throws.
    @concurrent func personalityPacket() async throws -> PartFaces.Packet {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let documentsLink = JSONValue.object(["open": .string("page:personality/documents")])
        var facts: [String: JSONValue] = [:]
        var keys: [String: JSONValue] = ["edit": documentsLink]
        func unavailable(_ error: Error) -> JSONValue {
            .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        do {
            let profile = try await persona.loadProfile()
            facts["profile"] = .object(["state": .string("available"), "name": .string(profile.name), "updatedAt": faceText(profile.updatedAt)])
            keys["name"] = documentsLink
        } catch { facts["profile"] = unavailable(error) }
        var initialized = false
        var documentsUnread: Error?
        do {
            let documents = try await persona.loadDocuments()
            initialized = PersonaFacade.hasInitializedIdentity(in: documents)
            facts["documents"] = .object(["state": .string("available"), "documents": .array(documents.map { doc -> JSONValue in
                keys["document:" + doc.id] = documentsLink
                return .object(["id": .string(doc.id), "title": .string(doc.title), "firstLine": .string(personalityFirstLine(doc.content)),
                    "updatedAt": faceText(doc.updatedAt)])
            })])
        } catch { facts["documents"] = unavailable(error); documentsUnread = error }
        facts["identityInitialized"] = .bool(initialized)
        facts["becoming"] = await personalityBecoming()
        do {
            let diary = try await cognitionView.dreamDiary(limit: 5)
            keys["dreams"] = .object(["open": .string("page:personality/dreams")])
            facts["dreams"] = .object(["state": .string("available"), "enabled": .bool(diary.enabled),
                "unreadable": diary.unreadableEntries.map { JSONValue.int(Int64($0)) } ?? .null,
                "entries": .array(diary.entries.map { entry -> JSONValue in
                    keys["dream:" + entry.date] = .object(["open": .string("dream:" + entry.date)])
                    return .object(["date": .string(entry.date), "firstLine": faceText(entry.content.map(personalityFirstLine)),
                        "modifiedAt": faceText(entry.modifiedAt)])
                })])
        } catch { facts["dreams"] = unavailable(error) }
        var levers = [await personalityMinds()]
        if initialized {
            levers.append(personalityResetLever())
        } else { levers.append(personalityResetUnavailable(documentsUnread)) }
        facts["keys"] = .object(keys)
        try Task.checkCancellation()
        return PartFaces.Packet(facts: .object(facts), epoch: epoch, levers: levers)
    }

    /// The self-reading as cognition holds it: not running, failed with its issue, none yet, or its trait and story lines and when it was written.
    private func personalityBecoming() async -> JSONValue {
        guard let runtime = cognitionView.runtime else { return .object(["state": .string("not_running")]) }
        let reading = await runtime.innerStateReading(windowHours: 6, detail: .compact)
        if let issue = reading.selfKnowledgeIssue { return .object(["state": .string("failed"), "reason": .string(issue)]) }
        guard let knowledge = reading.selfKnowledge else { return .object(["state": .string("none")]) }
        return .object(["state": .string("available"), "writtenAt": .string(NativeTimestampFormat.fractionalZulu(knowledge.writtenAt)),
            "traits": .array(knowledge.traits.map { JSONValue.string($0.line) }), "story": .array(knowledge.story.map { JSONValue.string($0.line) })])
    }

    func personalityFirstLine(_ content: String) -> String {
        content.split(whereSeparator: \.isNewline).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }).map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// A lever the stem could not read names what failed in the stem's words.
    func personalityIssue(_ id: String, title: String, error: Error) -> PartFace.Section {
        .init(id: id, title: title, style: .note, rows: [
            .init(id: id + "-unavailable", title: title + " could not be read.", detail: error.localizedDescription, tone: .failed)
        ])
    }

    @MainActor var personalityPaths: [URL] {
        SwiftNativePersonaEngine.personalityDocSpecsFixed.map { persona.personaRoot.appendingPathComponent($0.filename) }
            + [dataRoot.appendingPathComponent("memory/profile.json"), CognitiveSelfKnowledge.path(dataRoot),
               dataRoot.appendingPathComponent("providers", isDirectory: true), dataRoot.appendingPathComponent("providers/surfaces.json"),
               dataRoot.appendingPathComponent("providers/active.json"), dataRoot.appendingPathComponent("providers/pending-surface-configuration.json"),
               dataRoot.appendingPathComponent("dream_diary", isDirectory: true),
               dataRoot.appendingPathComponent("workflows/approvals/requests.json"), SwiftNativeTrustCenter.policyURL(dataRoot: dataRoot)]
    }

    /// Becoming can become readable after the initial read without changing its saved file.
    @MainActor func watchPersonalityAvailability() {
        let pages = pages, view = cognitionView
        Task { @MainActor in
            let changes = await view.changes()
            for await change in changes {
                guard !Task.isCancelled else { return }
                guard change.reason == "bootstrap" || change.reason.hasPrefix("configuration:") else { continue }
                await pages.refresh(page: "personality")
            }
        }
    }
}

extension PersonaFacade {
    /// The editor and the reset lever use the same existing SOUL evidence, including an existing empty file's modification time.
    public nonisolated static func hasInitializedIdentity(in documents: [PersonaDocSpec]) -> Bool {
        documents.contains {
            $0.id.uppercased() == "SOUL"
                && ($0.updatedAt != nil || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
