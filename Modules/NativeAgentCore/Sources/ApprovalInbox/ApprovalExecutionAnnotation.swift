import Foundation
import PersistenceCore

/// Execution annotations use the canonical inbox writer on every surface.
public enum ApprovalExecutionAnnotation {
    public static func annotateApprovalExecution(
        id: String,
        executedAction: JSONValue,
        detail: String,
        root: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async throws {
        _ = try await SwiftNativeApprovalInbox(root: root).annotateExecution(
            id,
            executedAction: executedAction,
            detail: detail
        )
    }
}
