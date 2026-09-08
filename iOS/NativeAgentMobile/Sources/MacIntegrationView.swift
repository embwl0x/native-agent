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
        .init(id: "calendar",       displayName: "Calendar",            description: "Read upcoming events + create/modify events",                       icon: "calendar",                              supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "reminders",      displayName: "Reminders",           description: "Read due reminders + create/check off",                              icon: "checklist",                             supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "contacts",       displayName: "Contacts",            description: "Look up contacts + create/edit (write OFF by default)",              icon: "person.crop.circle",                    supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "mail",           displayName: "Mail",                description: "Read inbox + manage messages (write OFF by default)",                icon: "envelope",                              supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "messages",       displayName: "Messages",            description: "Read recent threads + send iMessage (write OFF by default)",         icon: "message",                               supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "notes",          displayName: "Notes",               description: "Search + create/update Apple Notes (write OFF by default)",          icon: "note.text",                             supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "music",          displayName: "Music",               description: "Search library + control playback (write OFF by default)",           icon: "music.note",                            supportsRead: true,  supportsWrite: true,  defaultRead: true,  defaultWrite: false),
        .init(id: "notify_mac",     displayName: "Mac Notifications",   description: "Send Mac notifications",                                             icon: "bell",                                  supportsRead: false, supportsWrite: true,  defaultRead: false, defaultWrite: true),
        .init(id: "notify_mobile",  displayName: "iPhone Notifications", description: "Send notifications to paired iPhone",                              icon: "iphone.radiowaves.left.and.right",      supportsRead: false, supportsWrite: true,  defaultRead: false, defaultWrite: true),
        .init(id: "spotlight",      displayName: "Spotlight Search",    description: "Search via Spotlight",                                               icon: "magnifyingglass",                       supportsRead: true,  supportsWrite: false, defaultRead: true,  defaultWrite: false),
        .init(id: "scheduler",      displayName: "Scheduler",           description: "Schedule future-firing jobs",                                        icon: "clock",                                 supportsRead: false, supportsWrite: true,  defaultRead: false, defaultWrite: true),
    ]
}

/// The copy that tells the truth about where these values came from.
enum MacIntegrationProjectionPresentation {
    static let awaitingMacTitle = "Not yet received from the Mac"
    static let awaitingMacDetail = """
        This iPhone has not received the permission matrix from your Mac yet, \
        so nothing below is confirmed policy. The rows show NativeAgent's \
        built-in defaults as a placeholder only; open the Mac app (and check \
        pairing) to publish the real settings.
        """
    static let placeholderRowNote = "Placeholder default \u{00b7} not confirmed by the Mac"
}

// MARK: - MacIntegrationView

struct MacIntegrationView: View {
    @StateObject private var sync = MacIntegrationPermissionsSync.shared
    @ObservedObject private var identity = iCloudSyncEngine.shared

    var body: some View {
        List {
            Section {
                Text("These toggles control what \(identity.agentDisplayName) can do on your Mac when you ask. Each change is signed, applied by the Mac, and read back before it is accepted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("Mac Integration", systemImage: "macbook.and.iphone")
                    .font(.headline)
            }

            if let projectionError = sync.projectionError {
                Section {
                    Text(projectionError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Label("Mac Permission Sync Unavailable", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                }
            }

            // Sweep 2026-09-01 item 36. Before this, a phone that had never
            // received a projection rendered the eleven hardcoded defaults as
            // a live, editable, authoritative matrix with no error anywhere.
            if case .awaitingMac = sync.projectionState {
                Section {
                    Text(MacIntegrationProjectionPresentation.awaitingMacDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Label(
                        MacIntegrationProjectionPresentation.awaitingMacTitle,
                        systemImage: "icloud.slash"
                    )
                    .font(.headline)
                }
            }

            ForEach(MacIntegrationCatalog.rows) { row in
                Section {
                    MacIntegrationRowView(
                        row: row,
                        sync: sync,
                        isPlaceholder: !sync.hasMacProjection
                    )
                }
            }

            Section {
                Text("The Mac owns these settings and publishes the current result through iCloud. The Mac runtime checks them before reading from or writing to any surface above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("About", systemImage: "info.circle")
                    .font(.headline)
            }
        }
        .mobileReadingScreen()
        .navigationTitle("Mac Integration")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
                MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
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
    /// True while the Mac has published nothing readable. The toggles then
    /// show the built-in default, labelled as such, and cannot be moved —
    /// editing a value the Mac never sent would write policy against a matrix
    /// nobody has seen.
    var isPlaceholder: Bool = false
    @State private var isSaving = false
    @State private var saveError: String?

    // Mirror the supported axes via Binding<Bool> so the Toggle drives the
    // KVS write through the sync store. Toggles for unsupported axes render
    // disabled with their default-false state.
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
        VStack(alignment: .leading, spacing: 12) {
            MobileAdaptiveRow(spacing: 12) {
                Image(systemName: row.icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.displayName)
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text(row.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider()
                .padding(.vertical, 2)

            MobileAdaptiveRow(spacing: 16) {
                Toggle(isOn: readBinding) {
                    Label("Read", systemImage: "eye")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .tint(NativeAgentMobileTheme.Colors.accentText)
                .disabled(!row.supportsRead || isSaving || isPlaceholder)
                .opacity(row.supportsRead ? 1.0 : 0.4)

                Toggle(isOn: writeBinding) {
                    Label("Write", systemImage: "pencil")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .tint(NativeAgentMobileTheme.Colors.accentText)
                .disabled(!row.supportsWrite || isSaving || isPlaceholder)
                .opacity(row.supportsWrite ? 1.0 : 0.4)
            }
            if isPlaceholder {
                Label(
                    MacIntegrationProjectionPresentation.placeholderRowNote,
                    systemImage: "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func update(read: Bool, write: Bool) {
        // Never write a "change" measured against a matrix the Mac never sent.
        guard !isSaving, !isPlaceholder else { return }
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
