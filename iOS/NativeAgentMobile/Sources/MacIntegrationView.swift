// PATCH-2026-06-07: mac-integration-tab-ios — iOS parity for the Mac's
// MacIntegrationView. Per-integration READ / WRITE toggles for Calendar,
// Reminders, Contacts, Mail, Messages, Notes, Music, Notifications (mac +
// mobile), Spotlight, Scheduler. Changes use the same signed action ledger as
// other iOS mutations; KVS only projects the canonical Mac read-back.
//
// Reached from the More tab → "Manage" section. Stays inside the existing 5-
// tab TabView rather than promoting to a 6th primary tab; this is a settings
// surface, not a daily-driver lane.

import SwiftUI

// MARK: - Static row metadata
//
// Mirrors the matrix in MacIntegrationID (Modules/NativeAgentCore). The IDs
// must match byte-for-byte — the Mac runtime's hot-path gate looks them up by
// these strings.

struct MacIntegrationRow: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let icon: String
    let supportsRead: Bool
    let supportsWrite: Bool
    let defaultRead: Bool
    let defaultWrite: Bool
}

enum MacIntegrationCatalog {
    static let rows: [MacIntegrationRow] = [
        .init(id: "calendar",       displayName: "Calendar",             description: "See upcoming events; add and change them.",       icon: "calendar",                         supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "reminders",      displayName: "Reminders",            description: "See what’s due; add reminders and check them off.", icon: "checklist",                        supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "contacts",       displayName: "Contacts",             description: "Look people up; add and edit cards.",             icon: "person.crop.circle",               supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "mail",           displayName: "Mail",                 description: "Read your inbox; file and manage messages.",      icon: "envelope",                         supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "messages",       displayName: "Messages",             description: "Read recent threads; send iMessages.",            icon: "message",                          supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "notes",          displayName: "Notes",                description: "Search your notes; write and update them.",       icon: "note.text",                        supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "music",          displayName: "Music",                description: "Search your library; play and pause.",            icon: "music.note",                       supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "notify_mac",     displayName: "Mac notifications",    description: "Post a notification on the Mac.",                 icon: "bell",                             supportsRead: false, supportsWrite: true,  defaultRead: false, defaultWrite: true),
        .init(id: "notify_mobile",  displayName: "iPhone notifications", description: "Post a notification on this iPhone.",             icon: "iphone.radiowaves.left.and.right", supportsRead: false, supportsWrite: true,  defaultRead: false, defaultWrite: true),
        .init(id: "spotlight",      displayName: "Spotlight",            description: "Search the Mac with Spotlight.",                  icon: "magnifyingglass",                  supportsRead: true,  supportsWrite: false, defaultRead: true,  defaultWrite: false),
        .init(id: "scheduler",      displayName: "Scheduler",            description: "Set things to happen later.",                     icon: "clock",                            supportsRead: false, supportsWrite: true,  defaultRead: false, defaultWrite: true),
    ]
}

/// The copy that tells the truth about where these values came from.
enum MacIntegrationProjectionPresentation {
    static let awaitingMacTitle = "Not yet received from the Mac"
    static let awaitingMacDetail = """
        This iPhone has not received the permission matrix from your Mac yet, \
        so no switches show here: nothing below is confirmed policy. Open the \
        Mac app to publish the real settings.
        """
}

// MARK: - MacIntegrationView

struct MacIntegrationView: View {
    @StateObject private var sync = MacIntegrationPermissionsSync.shared
    @ObservedObject private var identity = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore

    /// Design screenshots show the matrix as the Mac would publish it.
    private var isDesignSample: Bool { MobileDesignSamples.screen != nil }

    var body: some View {
        let paired = pairingStore.isPaired
        // Only values the Mac published; a design screenshot stands in for
        // them on a paired phone. Never a built-in default dressed as policy.
        let showsValues = sync.hasMacProjection || (isDesignSample && paired)
        AlivePage(title: "Mac Integration", line: "What I may read or change on your Mac.") {
            if !paired {
                AliveUnpairedReason()
            }
            if let projectionError = sync.projectionError {
                AliveSection("Permission sync unavailable") {
                    Text(projectionError)
                        .font(.subheadline)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .aliveRow()
                }
            }

            // Sweep 2026-09-01 item 36. Before this, a phone that had never
            // received a projection rendered the eleven hardcoded defaults as
            // a live, editable, authoritative matrix with no error anywhere.
            if case .awaitingMac = sync.projectionState, !isDesignSample, paired {
                AliveCalmState(
                    title: MacIntegrationProjectionPresentation.awaitingMacTitle,
                    line: MacIntegrationProjectionPresentation.awaitingMacDetail
                )
            }

            AliveSection(
                "Apps",
                footer: "Your Mac owns these. Each change is signed, applied there, and read back before it counts."
            ) {
                ForEach(Array(MacIntegrationCatalog.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { AliveDivider() }
                    MacIntegrationRowView(
                        row: row,
                        sync: sync,
                        showsValues: showsValues,
                        locked: !paired || !showsValues
                    )
                }
            }
        }
        .macSyncErrorBanner()
        .refreshable {
            await refreshMacIntegrationProjection()
        }
        .task {
            await refreshMacIntegrationProjection()
        }
    }

    private func refreshMacIntegrationProjection() async {
        sync.refreshProjection()
        await identity.refreshTrustSnapshot()
    }
}

// MARK: - Per-integration row

private struct MacIntegrationRowView: View {
    let row: MacIntegrationRow
    @ObservedObject var sync: MacIntegrationPermissionsSync
    /// False while the Mac has published nothing readable: no switch then,
    /// because a switch would show a value nobody sent.
    var showsValues = true
    /// Unpaired or unpublished: switches are off and dimmed. Editing a value
    /// the Mac never sent would write policy against a matrix nobody has seen.
    var locked = false
    @State private var isSaving = false
    @State private var saveError: String?

    // Mirror the supported axes via Binding<Bool> so the Toggle drives the
    // KVS write through the sync store. Only supported axes get a switch.
    private var readBinding: Binding<Bool> {
        Binding(
            get: { sync.get(id: row.id, mode: "read") },
            set: { newValue in
                update(read: newValue, write: sync.get(id: row.id, mode: "write"))
            }
        )
    }

    private var writeBinding: Binding<Bool> {
        Binding(
            get: { sync.get(id: row.id, mode: "write") },
            set: { newValue in
                update(read: sync.get(id: row.id, mode: "read"), write: newValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.displayName)
                        .font(.body)
                        .foregroundStyle(AlivePalette.text)
                    Text(row.description)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A single-axis app is one switch beside its name.
                if showsValues && row.supportsRead != row.supportsWrite {
                    Toggle(row.displayName, isOn: row.supportsRead ? readBinding : writeBinding)
                        .labelsHidden()
                        .hazeTinted()
                        .disabled(isSaving)
                        .aliveUnavailable(locked)
                }
            }
            // Both axes: two labelled switches under the name.
            if showsValues && row.supportsRead && row.supportsWrite {
                HStack(spacing: 28) {
                    axisToggle("Read", isOn: readBinding).fixedSize()
                    axisToggle("Change", isOn: writeBinding).fixedSize()
                    Spacer(minLength: 0)
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .aliveRow()
    }

    private func axisToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AlivePalette.text)
        }
        .toggleStyle(.switch)
        .hazeTinted()
        .disabled(isSaving)
        .aliveUnavailable(locked)
        .accessibilityLabel("\(row.displayName): \(title)")
    }

    private func update(read: Bool, write: Bool) {
        // Never write a "change" measured against a matrix the Mac never sent.
        guard !isSaving, !locked else { return }
        let previousRead = sync.get(id: row.id, mode: "read")
        let previousWrite = sync.get(id: row.id, mode: "write")
        sync.applyProjection(
            id: row.id,
            read: row.supportsRead ? read : nil,
            write: row.supportsWrite ? write : nil
        )
        isSaving = true
        saveError = nil
        Task { @MainActor in
            do {
                let recovered = try await iCloudSyncEngine.shared.setMacIntegrationPermission(
                    id: row.id,
                    read: read,
                    write: write
                )
                sync.applyProjection(
                    id: row.id,
                    read: row.supportsRead ? recovered.read : nil,
                    write: row.supportsWrite ? recovered.write : nil
                )
            } catch {
                sync.applyProjection(
                    id: row.id,
                    read: row.supportsRead ? previousRead : nil,
                    write: row.supportsWrite ? previousWrite : nil
                )
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

#if DEBUG
struct MacIntegrationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            MacIntegrationView()
        }
    }
}
#endif
