import ApprovalInbox
import CognitiveSubstrate
import Cognition
import DreamREMCycle
import Foundation
import NativeAgentShared
import PersonaEngine
import PersistenceCore
import TrustCenter
// Blueprint: | `PersonalityFace.swift` | Personality's one face: checked identity, authored document previews, becoming, dreams and proposal destinations |

extension NativeAgentEngine {
    @MainActor func personalityFace() async throws -> (PartFace, UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        var sections: [PartFace.Section] = []
        var identityCare = [PartFace.Row(id: "edit", title: "Read or edit my identity", open: "page:personality/documents")]
        do {
            let profile = try await persona.loadProfile()
            sections.append(.init(id: "identity", title: "Who I am", style: .values, rows: [
                .init(id: "name", title: "Name", value: profile.name, at: profile.updatedAt, open: "page:personality/documents")
            ]))
        } catch { sections.append(personalityIssue("identity", title: "Identity", error: error)) }
        do {
            let documents = try await persona.loadDocuments()
            if PersonaFacade.hasInitializedIdentity(in: documents) {
                identityCare.append(.init(id: "reset", title: "Reset identity…",
                    detail: "Open the reset sheet to review its backup and confirmation.", open: "page:personality/reset"))
            }
            sections.append(.init(id: "documents", title: "Persona documents", style: .list,
                footer: "Open a document to read or edit it. About you is written from memory and stays read-only here.",
                rows: documents.map { doc in
                    .init(id: "document:" + doc.id, title: doc.title, detail: personalityFirstLine(doc.content),
                        at: doc.updatedAt, open: "page:personality/documents")
                }))
        } catch { sections.append(personalityIssue("documents", title: "Persona documents", error: error)) }
        sections.append(await personalityBecoming())
        sections.append(await personalityMinds())
        sections.append(await personalityDreams())
        do {
            let records = try await approvals.list()
            let proposals = WorkOverviewRead.waitingApprovals(records).filter { $0.action == "self_improvement.apply" }
            sections.append(.init(id: "proposals", title: "Self-improvement proposals", style: .list,
                footer: "Review a proposal in its approval card before deciding.", rows: proposals.isEmpty
                    ? [.init(id: "proposals-empty", title: "No self-improvement proposals are waiting for review.", tone: .quiet)]
                    : proposals.map { record in
                        .init(id: "proposal:" + record.id, title: record.title, detail: record.payloadPreview,
                            at: record.createdAt, tone: .attention, open: "approval:" + record.id)
                    }))
        } catch { sections.append(personalityIssue("proposals", title: "Self-improvement proposals", error: error)) }
        sections.append(.init(id: "identity-care", style: .list, rows: identityCare))
        try Task.checkCancellation()
        return (PartFace(title: "Personality", line: "Who I am, how I express myself, and how I grow.", sections: sections), epoch)
    }

    @MainActor private func personalityBecoming() async -> PartFace.Section {
        guard let runtime = cognitionView.runtime else {
            return .init(id: "becoming", title: "Becoming", style: .note,
                rows: [.init(id: "becoming-unavailable", title: "My self-reading is unavailable while cognition is not running.", tone: .quiet)])
        }
        let reading = await runtime.innerStateReading(windowHours: 6, detail: .compact)
        if let issue = reading.selfKnowledgeIssue {
            return .init(id: "becoming", title: "Becoming", style: .note,
                rows: [.init(id: "becoming-unavailable", title: "My self-reading is unavailable.", detail: issue, tone: .failed)])
        }
        guard let knowledge = reading.selfKnowledge else {
            return .init(id: "becoming", title: "Becoming", style: .note,
                rows: [.init(id: "becoming-unavailable", title: "No self-reading is available yet.", tone: .quiet)])
        }
        let at = NativeTimestampFormat.fractionalZulu(knowledge.writtenAt)
        let traits = knowledge.traits.enumerated().map { index, trait in
            PartFace.Row(id: "trait:\(index)", title: trait.line, at: at)
        }
        let story = knowledge.story.enumerated().map { index, entry in
            PartFace.Row(id: "story:\(index)", title: entry.line, at: at)
        }
        return .init(id: "becoming", title: "Becoming", style: .note, rows: traits + story)
    }

    @MainActor private func personalityDreams() async -> PartFace.Section {
        do {
            let diary = try await cognitionView.dreamDiary(limit: 5)
            var rows = [PartFace.Row(id: "dreams", title: "Dream diary", value: diary.enabled ? "Dream cycle on" : "Dream cycle off",
                open: "page:personality/dreams")]
            rows += diary.entries.map { entry in
                .init(id: "dream:" + entry.date, title: entry.date, detail: entry.content.map(personalityFirstLine),
                    at: entry.modifiedAt, open: "dream:" + entry.date)
            }
            if let unreadable = diary.unreadableEntries, unreadable > 0 {
                rows.append(.init(id: "dreams-unreadable", title: "\(unreadable) diary files could not be read.", tone: .attention))
            }
            return .init(id: "dreams", title: "Dreams", style: .timeline, rows: rows)
        } catch { return personalityIssue("dreams", title: "Dreams", error: error) }
    }

    func personalityFirstLine(_ content: String) -> String {
        content.split(whereSeparator: \.isNewline).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }).map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

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
    /// The editor and reset destination use the same existing SOUL evidence, including an existing empty file's modification time.
    public static func hasInitializedIdentity(in documents: [PersonaDocSpec]) -> Bool {
        documents.contains {
            $0.id.uppercased() == "SOUL"
                && ($0.updatedAt != nil || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
