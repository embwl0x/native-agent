import AppKit
import Foundation
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `SettingsFaceCalls.swift` | Mounted settings presentations, bundle-root references, native pickers and disconnect cancellation |

@MainActor
enum SettingsFaceCalls {
    static func install(on router: FaceCallRouter, appModel: AppModel) {
        router.register({ [weak appModel] request in
            guard let appModel else { throw FaceWireError.disconnected }
            switch request {
            case .replayTour:
                try ApplicationLifetime.shared.replayTour()
                return .acknowledged
            case .showProviderSetup(let provider, let operation):
                _ = try await ProviderSetupWindow.show(provider: provider, operation: operation, appModel: appModel)
                return .acknowledged
            case .showGrokSetup(let contact, let operation):
                _ = try await GrokSecureSetupWindow.show(contact: contact, operation: operation, appModel: appModel)
                return .acknowledged
            case .closeGrokSetup(let contact):
                GrokSecureSetupWindow.close(contact: contact)
                return .acknowledged
            case .showMacControlWorkbench:
                TrustPresentation.showWorkbench(appModel: appModel)
                return .acknowledged
            case .chooseSharedFolder(let operation):
                return try await ConnectorPresentation.chooseSharedFolder(operation: operation)
            case .chooseActivityExclusion(let operation):
                return try await TrustPresentation.chooseActivityExclusion(operation: operation)
            case .chooseSenseDestination(let operation, let suggestedName):
                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggestedName
                panel.allowedContentTypes = [.json]
                guard try await FaceNativePanel.choose(panel) == .OK else { return .cancelled }
                guard let url = panel.url else {
                    throw PartCallError(code: "destination_unavailable", message: "The save picker returned no destination.")
                }
                return .destination(try await FaceNativePanel.resourceGrant(id: operation, url: url, writable: true))
            case .runOAuthSession(let request):
                return try await NativeOAuthPlatform.run(request)
            case .showPermissionGuidance(let capability, let raw):
                guard let url = URL(string: raw), url.isFileURL else {
                    throw PartCallError(code: "permission_bundle_invalid", message: "The grant-holding app bundle is unavailable.")
                }
                SettingsDock.shared.show(capability: capability, bodyBundleURL: url, appModel: appModel)
                return .acknowledged
            case .closePermissionGuidance(let capability):
                SettingsDock.shared.close(capability: capability)
                return .acknowledged
            case .showCardControl(let identity, let presentation):
                try CardControls.shared.show(identity, presentation: presentation)
                return .acknowledged
            case .closeCardControl(let identity):
                CardControls.shared.closeVerifiedControl(identity)
                return .acknowledged
            case .presentUpdate(let request):
                return try await UpdateController.present(request, appModel: appModel)
            case .openBundledReference(let name):
                return try SettingsPresentation.openBundledReference(name: name)
            default: return nil
            }
        }, disconnect: {
            SettingsDock.shared.close()
            ProviderSetupWindow.closeAll()
            GrokSecureSetupWindow.closeAll()
            TrustFaceWindows.closeAll()
            CardControls.shared.disconnect()
            NativeOAuthPlatform.disconnect()
            UpdateController.disconnect()
        })
    }
}

@MainActor
enum SettingsPresentation {
    static func openBundledReference(name: String) throws -> FaceReply {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else {
            throw PartCallError(code: "reference_missing", message: "The reference is missing from this copy of NativeAgent.")
        }
        guard NSWorkspace.shared.open(url) else {
            throw PartCallError(code: "reference_open_failed", message: "macOS could not open the reference.")
        }
        return .acknowledged
    }
}
