import Foundation
import ScreenVision
import Testing
@testable import NativeAgentApp

@Suite("app.runtimes · client cutover seams", .serialized)
struct CutoverSeamsScreenCaptureEvalTests {
    @Test("screen capture preserves a typed denial and never succeeds with empty attachment bytes")
    @MainActor
    func screenCapturePermissionAndAttachmentContract() async throws {
        let client = NativeClient(baseURL: "")

        do {
            _ = try await client.captureScreenForChat {
                throw ScreenVisionError.permissionDenied
            }
            Issue.record("permission denial must reach the chat caller as an error")
        } catch let error as ScreenVisionError {
            guard case .permissionDenied = error else {
                Issue.record("expected ScreenVisionError.permissionDenied, got \(error)")
                return
            }
        }

        let image = try await client.captureScreenForChat {
            Data([0x89, 0x50, 0x4E, 0x47])
        }
        #expect(image == Data([0x89, 0x50, 0x4E, 0x47]))

        do {
            _ = try await client.captureScreenForChat { Data() }
            Issue.record("empty capture bytes must not become a successful attachment")
        } catch let error as ScreenVisionError {
            guard case .captureFailed = error else {
                Issue.record("empty capture must fail as ScreenVisionError.captureFailed")
                return
            }
        }
    }
}
