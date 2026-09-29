import Foundation
import NativeAgentCore
import TrustCenter

/// Assembles current-task provenance; TrustCenter alone evaluates authority.
public enum ChatFullMacYoloAdmission {
    public static func admitted(tool: String, surface: String, dataRoot: URL, source: String) async -> Bool {
        let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let remoteSurfaces: Set<String> = [
            "telegram", "slack", "ios", "icloud", "iphone", "ipad", "mobile", "watch", "remote",
        ]
        let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
            tool: tool,
            origin: SecurityOriginContext(
                surface: surface,
                sessionId: ChatToolSessionContext.verifiedSessionId,
                userId: ChatToolSessionContext.verifiedUserId,
                chatId: ChatToolSessionContext.verifiedChatId,
                deviceId: nil,
                source: source,
                isRemote: remoteSurfaces.contains(normalized),
                commandSignatureVerified: ChatToolSessionContext.commandSignatureVerified
            )
        )
        return authority.admitted
    }
}
