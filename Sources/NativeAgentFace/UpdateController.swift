import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
import Sparkle
// Blueprint: | `UpdateController.swift` | Sparkle's native user driver; the body owns checking, download and installation |

@MainActor
enum UpdateController {
    private static var driver: SPUStandardUserDriver?
    private static var operation: UUID?

    static func request(_ command: UpdateCommand, appModel: AppModel) async throws -> FaceActReply {
        try await appModel.checkedFaceAct(.requestUpdate(command))
    }

    static func present(_ request: UpdatePresentationRequest, appModel: AppModel) async throws -> FaceReply {
        let driver: SPUStandardUserDriver
        if let existing = Self.driver { driver = existing }
        else {
            driver = SPUStandardUserDriver(hostBundle: try await hostBundle(), delegate: nil)
            Self.driver = driver
        }
        let identity = request.operation
        switch request.event {
        case .permission(let data):
            operation = identity
            let value = try await decode(SPUUpdatePermissionRequest.self, data: data)
            driver.show(value) { response in
                send(.permission(automaticChecks: response.automaticUpdateChecks,
                    automaticDownloads: response.automaticUpdateDownloading?.boolValue, systemProfile: response.sendSystemProfile),
                    operation: identity, appModel: appModel)
            }
        case .checking:
            operation = identity
            driver.showUserInitiatedUpdateCheck { send(.cancel, operation: identity, appModel: appModel) }
        case .found(let item, let state):
            operation = identity
            let value = try await decode(SUAppcastItem.self, data: item)
            let stage = try await decode(SPUUserUpdateState.self, data: state)
            driver.showUpdateFound(with: value, state: stage) { choice in
                send(choice, operation: identity, appModel: appModel)
            }
        case .releaseNotes(let data):
            try require(identity)
            driver.showUpdateReleaseNotes(with: try await decode(SPUDownloadData.self, data: data))
        case .releaseNotesFailed(let detail):
            try require(identity)
            driver.showUpdateReleaseNotesFailedToDownloadWithError(
                NSError(domain: "NativeAgent.UpdateReleaseNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]))
        case .notFound(let data):
            operation = identity
            driver.showUpdateNotFoundWithError(try await decode(NSError.self, data: data)) {
                send(.acknowledge, operation: identity, appModel: appModel)
            }
        case .failed(let data):
            operation = identity
            driver.showUpdaterError(try await decode(NSError.self, data: data)) {
                send(.acknowledge, operation: identity, appModel: appModel)
            }
        case .downloading:
            operation = identity
            driver.showDownloadInitiated { send(.cancel, operation: identity, appModel: appModel) }
        case .expectedLength(let value):
            try require(identity)
            driver.showDownloadDidReceiveExpectedContentLength(value)
        case .receivedLength(let value):
            try require(identity)
            driver.showDownloadDidReceiveData(ofLength: value)
        case .extracting:
            try require(identity)
            driver.showDownloadDidStartExtractingUpdate()
        case .extractionProgress(let value):
            try require(identity)
            driver.showExtractionReceivedProgress(value)
        case .ready:
            operation = identity
            driver.showReady { choice in send(choice, operation: identity, appModel: appModel) }
        case .installing(let terminated):
            operation = identity
            driver.showInstallingUpdate(withApplicationTerminated: terminated) {
                send(.retryTermination, operation: identity, appModel: appModel)
            }
        case .installed(let relaunched):
            operation = identity
            driver.showUpdateInstalledAndRelaunched(relaunched) { send(.acknowledge, operation: identity, appModel: appModel) }
        case .dismiss:
            try require(identity)
            operation = nil
            driver.dismissUpdateInstallation()
        case .focus:
            try require(identity)
            driver.showUpdateInFocus()
        }
        return .effect(.init(operation: request.operation, disposition: .completed, reason: nil))
    }

    static func disconnect() {
        operation = nil
        driver?.dismissUpdateInstallation()
        driver = nil
    }

    private static func require(_ identity: UUID) throws {
        guard operation == identity else {
            throw PartCallError(code: "update_presentation_expired", message: "This update presentation has been replaced.")
        }
    }

    private nonisolated static func send(_ choice: SPUUserUpdateChoice, operation: UUID, appModel: AppModel) {
        let action: UpdateInteraction
        switch choice {
        case .install: action = .install
        case .dismiss: action = .dismiss
        case .skip: action = .skip
        @unknown default:
            Task { @MainActor in
                appModel.setFailureStatus(PartCallError(code: "update_choice_invalid", message: "Sparkle returned an unknown update choice."),
                    action: "update software")
            }
            return
        }
        send(action, operation: operation, appModel: appModel)
    }

    private nonisolated static func send(_ action: UpdateInteraction, operation: UUID, appModel: AppModel) {
        Task { @MainActor [weak appModel] in
            guard let appModel, Self.operation == operation else { return }
            do { try await appModel.checkedFaceAct(.updateInteraction(operation: operation, action: action)).checkedAcknowledgement() }
            catch { appModel.setFailureStatus(error, action: "update software") }
        }
    }

    @concurrent private static func hostBundle() async throws -> Bundle {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard url.pathExtension == "app", let bundle = Bundle(url: url) else {
            throw PartCallError(code: "update_host_bundle_missing", message: "The NativeAgent body bundle is unavailable.")
        }
        return bundle
    }

    @concurrent private static func decode<T: NSObject & NSSecureCoding & Sendable>(_ type: T.Type, data: Data) async throws -> T {
        guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data) else {
            throw PartCallError(code: "update_payload_invalid", message: "The body's Sparkle presentation could not be decoded.")
        }
        return value
    }
}
