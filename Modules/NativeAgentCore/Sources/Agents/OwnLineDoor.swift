import AgentConversations
import ChatTurnContracts
import ChatTurnRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import Transcripts
// Blueprint: | `OwnLineDoor.swift` | `OwnLineDoor`: agent.job self runs a turn of the agent's in its own work conversation, admitted like any turn |

/// The agent's own line is a turn like any other: admitted through TurnAdmission in its own work conversation (named by its job), on the chat surface,
/// with the agent's turn part, tools, Trust and present. Written instructions, when the agent gave some, stand in place of its persona text. It carries the
/// starting turn's limits (peer steering, file access) and raises the same cards the agent's turn would, naming its own conversation.
public struct OwnLineDoor: OwnLineRunner {
    // One chat surface for the declaration and every turn, including a resumed line; .builder names the conversation kind.
    private static let surface = "chat"
    let dataRoot: URL
    let clients: any AgentContactClients

    public func start(_ job: AgentJob) async throws -> AsyncThrowingStream<JobEvent, Error> {
        let first = job.brief.split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) } ?? job.id
        do { try await SessionConversation.declare(job.id, kind: .builder, title: "Line: " + first,
            source: ChatThreadKind.transcriptSource(surface: Self.surface), dataRoot: dataRoot) }
        catch { throw JobRefusal("Your line's conversation could not be opened: \(error.localizedDescription). Nothing was started.") }
        return run(job, message: job.brief)
    }

    public func resume(_ job: AgentJob) async throws -> AsyncThrowingStream<JobEvent, Error> {
        run(job, message: """
            The app restarted before you finished this line, so its turn ended early. Pick it up where you left off in this conversation and finish it. \
            The work, as you gave it:

            \(job.brief)
            """)
    }

    /// One turn per stream; ending the stream cancels the turn.
    private func run(_ job: AgentJob, message: String) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(session: job.id))
                do {
                    let response = try await turn(job, message: message)
                    let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.deliverable(JobDeliverable(artifacts: [], report: answer.isEmpty ? nil : answer, model: response.model)))
                    continuation.yield(.ended(Self.outcome(response, conversation: job.id)))
                } catch is CancellationError {
                } catch {
                    continuation.yield(.ended(.failed("Your line's turn failed: \(error.localizedDescription)")))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func turn(_ job: AgentJob, message: String) async throws -> ChatResponse {
        let session = job.id
        var origin = ChatMessageOrigin(surface: Self.surface, agent: "self", authored: .agent)
        origin.peerSources = job.peers
        origin.elevatedPeerSources = job.elevated
        let request = TurnRequest(message: message, sessionID: session, fileAccess: job.fileAccess ?? "auto", surface: Self.surface,
            envelope: TurnEnvelope(surface: Self.surface, agent: "self", declaredRemote: false),
            verifiedSessionID: session, origin: origin, threadKind: .builder)
        let ingress = request.turn().with(\.lineInstructions, job.instructions)
        return try await TurnAdmission.shared.runAlone(dataRoot: dataRoot, sessionID: session, turn: ingress) { admitted in
            try await request.chat(on: clients.lineChatClient(), holding: admitted)
        }
    }

    /// How the turn ended, in the stem's terms. A turn waiting on the person ends this run; answering continues it in its own conversation.
    static func outcome(_ response: ChatResponse, conversation: String) -> JobOutcome {
        let detail = response.statusDetail.map { ": " + $0 } ?? ""
        switch response.terminalState {
        case .completed?: return .finished
        case nil: return .failed("Your line's turn returned without a terminal state; inspect its retained run before continuing.")
        case .failed?: return .failed("Your line's turn failed" + detail)
        case .stopped?, .interrupted?: return .stopped("its turn was \(response.terminalState?.rawValue ?? "stopped")" + detail)
        case .waiting?:
            let card = response.pendingApprovalID.map { " (card \($0))" } ?? ""
            return .stopped("its turn is waiting on you\(card)\(detail); answering it continues the line in its own conversation \(conversation)")
        }
    }
}
