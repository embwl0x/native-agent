import AppKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import Privacy
import Sparkle
// Blueprint: | `BodyUpdateUserDriver.swift` | Sparkle user-driver events and person replies held by their originating renderer |

@MainActor
final class BodyUpdateUserDriver: NSObject, SPUUserDriver {
    private final class Remote {
        let presentation: BodyFacePresentation
        let first = ScopedWaiter()
        var operation = UUID()
        var action: ((UpdateInteraction) throws -> Void)?
        var cancellation: (() -> Bool)?
        var tail: Task<Void, Never>?
        var failure: Error?
        var mounted = false
        var confirmed = Set<UUID>()
        var installationInProgress = false
        var closed = false
        init(_ presentation: BodyFacePresentation) { self.presentation = presentation }
    }

    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    private let failed: (String, Bool) -> Void
    private var remote: Remote?
    private var permissionPending = false

    init(failed: @escaping (String, Bool) -> Void) { self.failed = failed; super.init() }

    func bind(_ presentation: BodyFacePresentation, sessionInProgress: Bool) throws -> Bool {
        if let remote {
            guard remote.presentation.connection == presentation.connection, !remote.closed else {
                throw PartCallError(code: "update_owned_by_window", message: "The update belongs to the window that started it.")
            }
            return true
        }
        guard !sessionInProgress, !permissionPending else {
            throw PartCallError(code: "update_owned_by_body", message: "Finish the update already open in the original window first.")
        }
        remote = Remote(presentation)
        return false
    }

    func focus() async throws {
        guard let remote, !remote.closed else { throw FaceWireError.disconnected }
        enqueue(.focus)
        await remote.tail?.value
        if let failure = remote.failure { throw failure }
        guard !remote.closed else { throw FaceWireError.disconnected }
    }

    func confirmPresentation() async throws {
        guard let remote else { throw FaceWireError.disconnected }
        await remote.first.park()
        try Task.checkCancellation()
        if let failure = remote.failure { throw failure }
        guard remote.mounted else { throw FaceWireError.disconnected }
    }

    func interact(operation: UUID, action: UpdateInteraction, renderer: UUID) throws {
        guard let remote, !remote.closed, remote.presentation.connection == renderer,
              remote.operation == operation, let receive = remote.action else {
            throw PartCallError(code: "update_action_expired", message: "That update control is no longer waiting for this action.")
        }
        try receive(action)
    }

    func disconnect(renderer: UUID?) {
        guard let remote, remote.presentation.connection == renderer else { return }
        close(remote, error: FaceWireError.disconnected)
    }

    private func close(_ remote: Remote, error: Error) {
        guard !remote.closed else { return }
        remote.closed = true
        remote.failure = error
        remote.action = nil
        let cancel = remote.cancellation
        remote.cancellation = nil
        remote.first.resume()
        let settled = cancel?() == true
        failed("Software update presentation failed: " + error.localizedDescription, !settled && !remote.installationInProgress)
    }

    private func callback(_ action: @escaping (UpdateInteraction) throws -> Void, cancellation: (() -> Bool)?) {
        guard let remote else { return }
        if remote.closed {
            if cancellation?() != true, !remote.installationInProgress {
                failed("The update's window closed before Sparkle's next interaction.", true)
            }
            return
        }
        remote.operation = UUID()
        remote.action = action
        remote.cancellation = cancellation
    }

    private func enqueue(_ makeEvent: @escaping @MainActor () async throws -> UpdatePresentationEvent) {
        guard let remote, !remote.closed else { return }
        let operation = remote.operation
        let previous = remote.tail
        remote.tail = Task { [weak self] in
            await previous?.value
            guard let self, !remote.closed else { return }
            do {
                let event = try await makeEvent()
                let reply = try await remote.presentation.call(.presentUpdate(.init(operation: operation, event: event)))
                guard case .effect(let receipt) = reply, receipt.operation == operation, receipt.disposition == .completed else {
                    try BodyInboxCardActionEffects.requirePresentation(reply)
                    throw PartCallError(code: "update_presentation_unconfirmed", message: "The window did not confirm Sparkle's presentation.")
                }
                remote.mounted = true
                remote.confirmed.insert(operation)
                remote.first.resume()
            } catch { self.close(remote, error: error) }
        }
    }

    private func enqueue(_ event: UpdatePresentationEvent) { enqueue { event } }

    private func choice(_ reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void, informationOnly: Bool = false) {
        callback({ [weak self] action in
            let selected: SPUUserUpdateChoice
            switch action {
            case .install where !informationOnly: selected = .install
            case .dismiss: selected = .dismiss
            case .skip: selected = .skip
            default: throw PartCallError(code: "update_action_invalid", message: "That action is unavailable for this update.")
            }
            self?.remote?.action = nil
            self?.remote?.cancellation = nil
            reply(selected)
        }, cancellation: { reply(.dismiss); return true })
    }

    private func acknowledgement(_ acknowledgement: @escaping @Sendable () -> Void) {
        let remote = remote
        remote?.installationInProgress = false
        callback({ [weak self] action in
            guard action == .acknowledge else {
                throw PartCallError(code: "update_action_invalid", message: "Acknowledge the displayed update message.")
            }
            self?.remote?.action = nil
            self?.remote?.cancellation = nil
            acknowledgement()
        }, cancellation: nil)
        let operation = remote?.operation
        remote?.cancellation = {
            guard let remote, let operation, remote.confirmed.contains(operation) else { return false }
            acknowledgement()
            return true
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        guard remote != nil else {
            permissionPending = true
            standard.show(request) { [weak self] response in
                Task { @MainActor in self?.permissionPending = false; reply(response) }
            }
            return
        }
        callback({ [weak self] action in
            guard case .permission(let checks, let downloads, let profile) = action else {
                throw PartCallError(code: "update_action_invalid", message: "Choose update permissions in the update window.")
            }
            self?.remote?.action = nil
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: checks,
                automaticUpdateDownloading: downloads.map(NSNumber.init(value:)), sendSystemProfile: profile))
        }, cancellation: nil)
        enqueue { .permission(request: try await Self.archive(request)) }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping @Sendable () -> Void) {
        guard remote != nil else { standard.showUserInitiatedUpdateCheck(cancellation: cancellation); return }
        callback({ [weak self] action in
            guard action == .cancel else { throw PartCallError(code: "update_action_invalid", message: "Cancel the current update check.") }
            self?.remote?.action = nil
            self?.remote?.cancellation = nil
            cancellation()
        }, cancellation: { cancellation(); return true })
        enqueue(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        guard remote != nil else { standard.showUpdateFound(with: appcastItem, state: state, reply: reply); return }
        choice(reply, informationOnly: appcastItem.isInformationOnlyUpdate)
        enqueue { .found(item: try await Self.archive(appcastItem), state: try await Self.archive(state)) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard remote != nil else { standard.showUpdateReleaseNotes(with: downloadData); return }
        enqueue { .releaseNotes(try await Self.archive(downloadData)) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        guard remote != nil else { standard.showUpdateReleaseNotesFailedToDownloadWithError(error); return }
        enqueue(.releaseNotesFailed(detail: NativeAppSecretRedactor.redactText(error.localizedDescription)))
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping @Sendable () -> Void) {
        guard remote != nil else { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement); return }
        self.acknowledgement(acknowledgement)
        let value = Self.presentationError(error)
        enqueue { .notFound(error: try await Self.archive(value)) }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping @Sendable () -> Void) {
        guard remote != nil else { standard.showUpdaterError(error, acknowledgement: acknowledgement); return }
        self.acknowledgement(acknowledgement)
        let value = Self.presentationError(error)
        enqueue { .failed(error: try await Self.archive(value)) }
    }

    func showDownloadInitiated(cancellation: @escaping @Sendable () -> Void) {
        guard remote != nil else { standard.showDownloadInitiated(cancellation: cancellation); return }
        callback({ [weak self] action in
            guard action == .cancel else { throw PartCallError(code: "update_action_invalid", message: "Cancel the update download.") }
            self?.remote?.action = nil
            self?.remote?.cancellation = nil
            cancellation()
        }, cancellation: { cancellation(); return true })
        enqueue(.downloading)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard remote != nil else { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength); return }
        enqueue(.expectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard remote != nil else { standard.showDownloadDidReceiveData(ofLength: length); return }
        enqueue(.receivedLength(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        guard let remote else { standard.showDownloadDidStartExtractingUpdate(); return }
        remote.action = nil
        remote.cancellation = nil
        remote.installationInProgress = true
        enqueue(.extracting)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard remote != nil else { standard.showExtractionReceivedProgress(progress); return }
        enqueue(.extractionProgress(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        guard remote != nil else { standard.showReady(toInstallAndRelaunch: reply); return }
        choice(reply)
        enqueue(.ready)
    }

    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping @Sendable () -> Void) {
        guard remote != nil else {
            standard.showInstallingUpdate(withApplicationTerminated: terminated, retryTerminatingApplication: retryTerminatingApplication)
            return
        }
        remote?.installationInProgress = true
        callback({ action in
            guard !terminated, action == .retryTermination else {
                throw PartCallError(code: "update_action_invalid", message: "That installation is not waiting for termination.")
            }
            retryTerminatingApplication()
        }, cancellation: nil)
        enqueue(.installing(applicationTerminated: terminated))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping @Sendable () -> Void) {
        guard remote != nil else { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement); return }
        self.acknowledgement(acknowledgement)
        enqueue(.installed(relaunched: relaunched))
    }

    func dismissUpdateInstallation() {
        guard let remote else { standard.dismissUpdateInstallation(); return }
        remote.action = nil
        remote.cancellation = nil
        enqueue(.dismiss)
        let tail = remote.tail
        Task { [weak self] in
            await tail?.value
            if self?.remote === remote { self?.remote = nil }
        }
    }

    func showUpdateInFocus() {
        guard remote != nil else { standard.showUpdateInFocus(); return }
        enqueue(.focus)
    }

    private static func presentationError(_ error: Error) -> NSError {
        let source = error as NSError
        var values: [String: String] = [NSLocalizedDescriptionKey: NativeAppSecretRedactor.redactText(source.localizedDescription)]
        values[NSLocalizedFailureReasonErrorKey] = source.localizedFailureReason.map(NativeAppSecretRedactor.redactText)
        values[NSLocalizedRecoverySuggestionErrorKey] = source.localizedRecoverySuggestion.map(NativeAppSecretRedactor.redactText)
        return NSError(domain: source.domain, code: source.code, userInfo: values)
    }

    @concurrent private static func archive<T: NSObject & NSSecureCoding & Sendable>(_ value: T) async throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
    }
}
