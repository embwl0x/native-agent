import Foundation
import MCPDispatcher
import ChatOrchestration

extension MCPUIActionAuthority {
    public static func runtime(dataRoot: URL) -> Self {
        Self(
            fullMacYoloAdmitted: { tool, surface in
                await ChatFullMacYoloAdmission.admitted(
                    tool: tool, surface: surface, dataRoot: dataRoot,
                    source: "native_client_direct_action"
                )
            },
            deniedError: { AutonomyGateError.toolDenied(reason: $0) },
            fileApprovalRequest: { tool, surface, payload, reason in
                try await NativeAgentChatApprovalFiler(dataRoot: dataRoot).fileApprovalRequest(
                    toolName: tool, surface: surface, payload: payload, reason: reason
                )
            }
        )
    }
}

