import Foundation
import ChatOrchestration
import MacControl
import NativeAgentCore
import PersistenceCore
import TriggerScheduler

enum ExperienceBlueprintInstallOutcome: Equatable, Sendable {
    case installed
    case alreadyPresent
    case repaired
    case failed(String)

    var message: String {
        switch self {
        case .installed: "Blueprint installed."
        case .alreadyPresent: "This blueprint is already active."
        case .repaired: "The blueprint schedule was repaired."
        case .failed(let detail): "Blueprint installation failed: \(detail)"
        }
    }
}

enum ExperienceKitActivationOutcome: Equatable, Sendable {
    case activated(loaded: Int, unavailable: [String])
    case deactivated
    case failed(String)

    var message: String {
        switch self {
        case .activated(let loaded, let unavailable):
            if unavailable.isEmpty { return "Activated \(loaded) capabilities for this conversation." }
            return "Activated \(loaded); \(unavailable.count) unavailable capabilities stayed off."
        case .deactivated:
            return "Capability Kit removed from this conversation."
        case .failed(let detail):
            return "Capability Kit failed: \(detail)"
        }
    }
}

extension NativeClient {
    func installExperienceBlueprint(
        _ blueprint: ExperienceAutomationBlueprint,
        projectSpaceId: String? = nil
    ) async throws -> JSONValue {
        let writer = makeSchedulerJobWriter(connectorActionIDs: Self.connectorActionIDSet())
        return try await writer.installBlueprintJob(
            body: .object(NativeExperienceCatalogs.schedulerBody(
                for: blueprint,
                projectSpaceId: projectSpaceId
            ))
        )
    }

    func trustedRemoteNodes() async throws -> [ExperienceRemoteNode] {
        try await TrustedRemoteEffectNodeStore(root: PersistenceCore.defaultDataRoot()).list()
    }

    func saveTrustedRemoteNode(_ node: ExperienceRemoteNode) async throws -> ExperienceRemoteNode {
        try await TrustedRemoteEffectNodeStore(root: PersistenceCore.defaultDataRoot()).upsert(node)
    }

    func removeTrustedRemoteNode(id: String) async throws {
        try await TrustedRemoteEffectNodeStore(root: PersistenceCore.defaultDataRoot()).remove(id: id)
    }
}

@MainActor
extension AppModel {
    var experienceSessionBranches: [ExperienceSessionBranch] {
        chatSessions.map { session in
            ExperienceSessionBranch(
                id: session.id,
                title: session.displayTitle,
                parentSessionId: session.parentSessionId,
                rootSessionId: session.rootSessionId ?? session.parentSessionId ?? session.id,
                forkedAtMessageId: session.forkedAtMessageId,
                projectSpaceId: session.projectSpaceId,
                worktreePath: session.worktreePath,
                model: session.modelId,
                messageCount: session.messageCount ?? 0,
                createdAt: session.createdAt
            )
        }
    }

    func forkActiveChatSession(
        throughMessageId: String? = nil,
        title: String? = nil
    ) async -> ChatSession? {
        do {
            _ = try? await client.stampChatSessionRoute(
                id: activeChatSessionId,
                providerId: chatProvider,
                modelId: chatModel
            )
            let session = try await client.forkChatSession(
                sourceSessionId: activeChatSessionId,
                throughMessageId: throughMessageId,
                title: title
            )
            chatSessions = try await client.getChatSessions()
            await selectChatSession(session)
            statusText = "Conversation branch created"
            return session
        } catch {
            statusText = "Conversation branch failed: \(error.localizedDescription)"
            return nil
        }
    }

    func associateActiveChat(with workspace: WorkspaceRecord?) async -> Bool {
        do {
            let updated = try await client.associateChatSession(
                id: activeChatSessionId,
                projectSpaceId: workspace?.id,
                worktreePath: nil
            )
            if let index = chatSessions.firstIndex(where: { $0.id == updated.id }) {
                chatSessions[index] = updated
            } else {
                chatSessions = try await client.getChatSessions()
            }
            statusText = workspace == nil
                ? "Conversation removed from Project Space"
                : "Conversation linked to \(workspace?.name ?? "Project Space")"
            return true
        } catch {
            statusText = "Project Space link failed: \(error.localizedDescription)"
            return false
        }
    }

    func compareActiveChat(with sessionID: String) async -> ExperienceSessionComparison? {
        do {
            return try await client.compareChatSessions(left: activeChatSessionId, right: sessionID)
        } catch {
            statusText = "Conversation comparison failed: \(error.localizedDescription)"
            return nil
        }
    }

    func rememberSessionMessages(sessionID: String, messageIDs: Set<String>) async -> Int {
        guard !messageIDs.isEmpty else { return 0 }
        do {
            let messages = try await client.getChatMessages(sessionId: sessionID)
            var stored = 0
            for message in messages where messageIDs.contains(message.id) {
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, message.role != "tool" else { continue }
                _ = try await client.addMemory(
                    text: text,
                    source: "mac.session-lineage",
                    metadata: .object([
                        "kind": .string("user_selected_session_learning"),
                        "session_id": .string(sessionID),
                        "message_id": .string(message.id),
                        "role": .string(message.role),
                        "observed_at": .string(message.createdAt),
                    ])
                )
                stored += 1
            }
            statusText = "Retained \(stored) selected learning\(stored == 1 ? "" : "s")"
            return stored
        } catch {
            statusText = "Selected learning could not be retained: \(error.localizedDescription)"
            return 0
        }
    }

    func sessionLineageExport(sessionID: String) async -> String? {
        do {
            let sessions = try await client.getChatSessions()
            guard let session = sessions.first(where: { $0.id == sessionID }) else {
                throw SessionLineageError.sessionNotFound
            }
            let messages = try await client.getChatMessages(sessionId: sessionID)
            var lines = [
                "# \(session.displayTitle)",
                "",
                "- Session: `\(session.id)`",
                "- Root: `\(session.rootSessionId ?? session.parentSessionId ?? session.id)`",
                "- Parent: `\(session.parentSessionId ?? "none")`",
                "- Fork point: `\(session.forkedAtMessageId ?? "root")`",
                "- Project Space: `\(session.projectSpaceId ?? "none")`",
                "- Worktree: `\(session.worktreePath ?? "none")`",
                "- Provider/model: `\(session.providerId ?? "unknown")` / `\(session.modelId ?? "unknown")`",
                "- Created: \(session.createdAt)",
                "",
                "## Transcript",
                "",
            ]
            for message in messages {
                lines.append("### \(message.role.capitalized) · \(message.createdAt) · `\(message.id)`")
                lines.append("")
                lines.append(message.content)
                lines.append("")
            }
            return lines.joined(separator: "\n")
        } catch {
            statusText = "Conversation export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func installExperienceBlueprint(
        _ blueprint: ExperienceAutomationBlueprint,
        projectSpaceId: String? = nil
    ) async -> ExperienceBlueprintInstallOutcome {
        do {
            let result = try await client.installExperienceBlueprint(
                blueprint,
                projectSpaceId: projectSpaceId
            )
            guard case .object(let object) = result,
                  case .string(let status)? = object["status"] else {
                throw NSError(domain: "NativeExperience", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "scheduler returned an invalid install receipt"
                ])
            }
            _ = await refreshSchedulerJobs()
            let outcome: ExperienceBlueprintInstallOutcome
            switch status {
            case "installed": outcome = .installed
            case "already_present": outcome = .alreadyPresent
            case "repaired": outcome = .repaired
            default: outcome = .failed("unknown scheduler status \(status)")
            }
            statusText = outcome.message
            return outcome
        } catch {
            let outcome = ExperienceBlueprintInstallOutcome.failed(error.localizedDescription)
            statusText = outcome.message
            return outcome
        }
    }

    func activateCapabilityKit(_ kit: ExperienceCapabilityKit) async -> ExperienceKitActivationOutcome {
        if chatToolCatalog == nil { await refreshChatToolCatalog() }
        guard let catalog = chatToolCatalog else {
            return .failed("the canonical tool catalog is unavailable")
        }
        let available = Set(catalog.tools.compactMap { tool in
            tool.availableNow == false ? nil : tool.name
        })
        let selected = kit.toolNames.intersection(available)
        let unavailable = kit.toolNames.subtracting(selected).sorted()
        guard !selected.isEmpty else {
            return .failed("none of this kit's capabilities are currently ready")
        }
        do {
            _ = try await ActiveToolsStore.shared.addLoaded(
                sessionId: activeChatSessionId,
                names: selected
            )
            await refreshChatToolCatalog()
            let outcome = ExperienceKitActivationOutcome.activated(
                loaded: selected.count,
                unavailable: unavailable
            )
            statusText = outcome.message
            return outcome
        } catch {
            let outcome = ExperienceKitActivationOutcome.failed(error.localizedDescription)
            statusText = outcome.message
            return outcome
        }
    }

    func deactivateCapabilityKit(_ kit: ExperienceCapabilityKit) async -> ExperienceKitActivationOutcome {
        do {
            _ = try await ActiveToolsStore.shared.removeLoaded(
                sessionId: activeChatSessionId,
                names: kit.toolNames
            )
            await refreshChatToolCatalog()
            let outcome = ExperienceKitActivationOutcome.deactivated
            statusText = outcome.message
            return outcome
        } catch {
            let outcome = ExperienceKitActivationOutcome.failed(error.localizedDescription)
            statusText = outcome.message
            return outcome
        }
    }
}
