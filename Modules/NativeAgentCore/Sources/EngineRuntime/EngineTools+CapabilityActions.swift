import AppToolRuntime
import Browser
import Foundation
import NativeAgentCore
import NativeAgentShared
import TrustCenter
// Blueprint: | `EngineTools+CapabilityActions.swift` | Mac actions and browser previews use canonical routes and publish their cached state |

extension ToolsFacade {
    public func runNativeAction(_ action: NativeActionRecord, dryRun: Bool, trust: TrustFacade,
        browser: BrowserActionRoutes) async throws -> NativeActionReceipt {
        if dryRun {
            guard action.dryRunAvailable != false else {
                throw PartCallError(code: "dry_run_unavailable", message: "Dry run is unavailable for this action.")
            }
        } else if action.requiresApproval != false {
            let policy = try await trust.load()
            if let reason = CapabilitiesFace.nativeGate(action, fullMac: TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)) {
                throw PartCallError(code: "approval_required", message: reason)
            }
        }
        let turn = Turn().with(\.envelope, .personOnMac("mac_ui:native_action:" + action.id))
        let receipt = try await NativeActionRoutes.runNativeAction(id: action.id, dryRun: dryRun, input: [:], dataRoot: dataRoot,
            browser: browser, turn: turn, execution: .init(invocation: .init(), deadlines: .init(), turnWork: .init()))
        _ = await refreshNativePower()
        return receipt
    }

    public func previewBrowser(using browser: BrowserActionRoutes) async throws -> BrowserRun {
        guard browserDryRunStartedAt == nil else {
            throw PartCallError(code: "already_running", message: "A browser dry run is already running. Wait for its answer.")
        }
        browserDryRunStartedAt = Date()
        browserDryRunError = nil
        await capabilitiesDidChange?()
        do {
            let run = try await browser.runBrowser(url: "https://example.com", dryRun: true,
                captureSource: false, captureScreenshot: false, dataRoot: dataRoot, imageSink: nil)
            browserDryRunPreview = run
            await settle { await self.finishBrowserPreview() }
            return run
        } catch {
            browserDryRunError = error.localizedDescription
            await settle { await self.finishBrowserPreview() }
            throw error
        }
    }

    private func finishBrowserPreview() async {
        browserDryRunStartedAt = nil
        await capabilitiesDidChange?()
    }
}
