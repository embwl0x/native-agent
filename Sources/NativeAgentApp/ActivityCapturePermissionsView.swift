import SwiftUI
import ActivityWatch

/// W8 — the Trust Center surface for the ambient activity watcher.
///
/// The copy here is the feature's actual privacy contract, so it is written to
/// the honest limit rather than the flattering one. Three rules it follows,
/// each of which the build plan's review round forced:
///
///  1. **Never imply titles are sanitised.** `MacScreenViewTextRedaction`
///     catches SHAPED secrets — tokens, keys, one-time codes. It does nothing
///     for "Re: Q3 layoffs — Mail" or "patient-notes.pdf — Preview". Saying
///     "titles are redacted" without saying what redaction does not do would
///     be the single most misleading sentence in the app.
///  2. **Never claim private browsing is excluded.** Private-browsing state is
///     not reliably detectable through AX across Safari/Chrome versions. A
///     browser update would turn that claim into a lie without anyone editing
///     a line of code, so the claim is not made.
///  3. **Say what an action does before it does it.** Adding an app to the
///     exclusion list deletes its existing rows. That is the right behaviour
///     and it is destructive, so it is stated in a confirmation, with the
///     count reported afterwards.
struct ActivityCapturePermissionsView: View {
    @State private var controller = ActivityWatchController.shared
    @State private var newExclusion = ""
    @State private var pendingExclusion: String?
    @State private var showWipeConfirm = false

    var body: some View {
        NativePanel(
            title: "Activity Capture",
            systemImage: "clock.arrow.circlepath",
            tint: controller.isCapturing ? .orange : .secondary
        ) {
            VStack(alignment: .leading, spacing: 12) {
                masterToggle
                Divider()
                titleControls
                Divider()
                modelAccessControl
                Divider()
                exclusionList
                Divider()
                retentionAndWipe
                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .alert("Exclude this app and delete what was recorded?", isPresented: exclusionAlertBinding) {
            Button("Exclude and Delete", role: .destructive) {
                if let bundleID = pendingExclusion {
                    Task { await controller.addExclusion(bundleID: bundleID) }
                }
                pendingExclusion = nil
                newExclusion = ""
            }
            Button("Cancel", role: .cancel) { pendingExclusion = nil }
        } message: {
            // The destructive half is stated FIRST, because it is the half a
            // user would not expect from a control labelled "exclude".
            Text("""
            Every activity row already recorded for \(pendingExclusion ?? "this app") will be deleted \
            immediately and permanently — not hidden, deleted, including from the database's \
            write-ahead log. Answers about past days will no longer include it.

            From now on this app is skipped before anything is read about it: no window title, \
            no app name, no row at all.
            """)
        }
        .alert("Delete all recorded activity?", isPresented: $showWipeConfirm) {
            Button("Delete Everything", role: .destructive) {
                Task { await controller.wipeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Every recorded span is deleted permanently. Your settings on this page are kept, \
            so capture stays on if it is on — turn the switch above off first if you want it \
            to stop as well.
            """)
        }
    }

    // MARK: - Master toggle

    private var masterToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    "Record which apps I use",
                    isOn: Binding(
                        get: { controller.policy.captureEnabled },
                        set: { controller.setCaptureEnabled($0) }
                    )
                )
                .help("Off by default. Nothing is recorded until you turn this on, and nothing was recorded before you did.")
                EffectTimingTag(timing: .now)
                Spacer()
                if controller.isCapturing {
                    Label("Recording", systemImage: "record.circle")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.orange)
                }
            }

            // WHAT IS RECORDED / WHAT IS NOT. Two lists, both concrete. A
            // single paragraph of reassurance would be easier to write and
            // worth nothing to someone deciding whether to trust this.
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Recorded: the name of the app in front, and how long it was in front.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
                Label(
                    "Recorded only if you switch it on below: the window's title, with obvious secrets (tokens, keys, one-time codes) stripped out.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
                Label(
                    "Never recorded: what you type, the contents of any field, any text inside a window, and any screenshot. Not while locked or asleep either.",
                    systemImage: "xmark.circle"
                )
                .foregroundStyle(.secondary)
                Label(
                    "The store never leaves this Mac: no iCloud, backup, export, or iPhone sync. Sending an answer to your selected AI provider is a separate, default-off choice below.",
                    systemImage: "lock.circle"
                )
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            // INSTANT PAUSE. Its own control rather than "just use the switch":
            // a user who wants to stop recording NOW should not have to reason
            // about whether a settings toggle takes effect immediately.
            HStack {
                Button("Pause Recording Now", systemImage: "pause.circle") {
                    controller.setCaptureEnabled(false)
                }
                .disabled(!controller.isCapturing)
                Text(controller.isCapturing
                     ? "Stops immediately and closes the span in progress — not at the next restart."
                     : "Not recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var modelAccessControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Access")
                .font(.subheadline.weight(.semibold))
            Toggle(
                "Let the agent answer from activity history",
                isOn: Binding(
                    get: { controller.policy.allowModelAccess },
                    set: { controller.setModelAccessEnabled($0) }
                )
            )
            .disabled(!controller.policy.captureEnabled)
            Text("Off by default. When on, an activity answer requested in chat is sent to the AI provider selected for that chat so the agent can discuss it. The database and full history remain local; only the bounded answer leaves the Mac. Turn this off to keep every activity answer on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Title controls

    private var titleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window Titles")
                .font(.subheadline.weight(.semibold))

            HStack {
                Toggle(
                    "Also record window titles",
                    isOn: Binding(
                        get: { controller.policy.captureTitles },
                        set: { controller.setCaptureTitles($0) }
                    )
                )
                .disabled(controller.policy.appNameOnlyMode)
                EffectTimingTag(timing: .now)
                Spacer()
            }
            // THE HONEST LIMIT. This paragraph is the reason the whole feature
            // is defensible, and it must not be softened into "titles are
            // redacted for your privacy".
            Text("""
            Titles are checked for shaped secrets — API keys, tokens, one-time codes — and those \
            are stripped. That is all the stripping does. A title like "Re: Q3 layoffs — Mail", \
            "patient-notes.pdf — Preview", or a client's name in a file path is recorded as-is. \
            If that is not acceptable for an app, exclude the app below.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Toggle(
                    "Include browser window titles",
                    isOn: Binding(
                        get: { controller.policy.browserTitlesEnabled },
                        set: { controller.setBrowserTitlesEnabled($0) }
                    )
                )
                .disabled(!controller.policy.captureTitles || controller.policy.appNameOnlyMode)
                EffectTimingTag(timing: .now)
                Spacer()
            }
            // NO PRIVATE-BROWSING CLAIM. Stated as a limitation, not buried.
            Text("""
            Off by default, and worth leaving off: a browser title is usually the page title. \
            NativeAgent cannot reliably tell whether a window is a private/incognito one — macOS \
            does not expose that dependably, and a browser update could change it without \
            warning — so private browsing is NOT excluded from this. Turn it on only if you are \
            comfortable with every page title you visit being recorded.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Toggle(
                    "App names only (never record any title)",
                    isOn: Binding(
                        get: { controller.policy.appNameOnlyMode },
                        set: { controller.setAppNameOnlyMode($0) }
                    )
                )
                .help("Overrides both switches above. The strictest setting that still records anything.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
        }
    }

    // MARK: - Exclusions

    private var exclusionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Excluded Apps")
                .font(.subheadline.weight(.semibold))
            Text("""
            An excluded app is skipped before anything is read about it — no title, no app name, \
            no row. Password managers, Keychain Access, Health, Messages and several finance apps \
            are excluded out of the box. Adding one here also deletes what was already recorded \
            for it.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Bundle identifier, e.g. com.apple.Notes", text: $newExclusion)
                    .textFieldStyle(.roundedBorder)
                Button("Exclude", systemImage: "minus.circle") {
                    let trimmed = newExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    pendingExclusion = trimmed
                }
                .disabled(newExclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let purged = controller.lastPurgedRowCount {
                Label(
                    purged == 0
                        ? "No recorded rows needed deleting."
                        : "Deleted \(purged) recorded row\(purged == 1 ? "" : "s").",
                    systemImage: "trash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(controller.removableExclusions, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                        .font(NativeAgentFont.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle") {
                        controller.removeExclusion(bundleID: bundleID)
                    }
                    .buttonStyle(.borderless)
                }
                .textSelection(.enabled)
            }
            // The non-overridable exclusions are shown as a fact, not as a
            // control, because they cannot be removed and a disabled row that
            // looks removable is a lie about who is in charge.
            Text("NativeAgent never records its own windows, and never records the lock screen. Those two cannot be turned off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Retention + wipe

    private var retentionAndWipe: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep History For")
                .font(.subheadline.weight(.semibold))
            Picker("Keep history for", selection: Binding(
                get: { controller.policy.retentionDays },
                set: { controller.setRetentionDays($0) }
            )) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Anything older is deleted automatically. Shortening this deletes the excess at the next cleanup.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Delete All Recorded Activity", systemImage: "trash") {
                    showWipeConfirm = true
                }
                .foregroundStyle(.red)
                EffectTimingTag(timing: .now)
                Spacer()
            }
        }
    }

    private var exclusionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingExclusion != nil },
            set: { if !$0 { pendingExclusion = nil } }
        )
    }
}
