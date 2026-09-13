#if DEBUG
import AppKit
import SwiftUI
import ProviderRouting

/// MOCKUPS ONLY — 0.4.12 round, 2026-09-13. Synthetic design material for the
/// two items User sent to mockup-first judgement (Trust and Providers both carry
/// that rule). Nothing here is reachable from a production page: the whole file
/// is DEBUG, every entry point is gated on a `SIMPLICITY_*` env var, and the
/// shipped views are not edited by this commit.
///
///   SIMPLICITY_MOCKUPS_TRUST=1     SIMPLICITY_SNAPSHOT_DIR=<dir> swift test --filter debugOnlySnapshotEntryPoints
///   SIMPLICITY_MOCKUPS_PROVIDERS=1 SIMPLICITY_SNAPSHOT_DIR=<dir> swift test --filter debugOnlySnapshotEntryPoints
///
/// HONESTY ABOUT THE COLUMNS. A "current" column rendered from a clone is a
/// drawing of the page, not the page. So each item renders BOTH:
///   * the REAL shipped view (`trust-real-*`, `providers-real-*`), and
///   * a clone-control column carrying the SHIPPED copy and geometry verbatim,
///     beside the proposal.
/// The clone-control exists so the proposal column is read against a known
/// baseline drawn by the same code path; the real frames are what proves the
/// clone matches. Clone chrome is copied line-for-line from the shipped
/// `TrustPresetButton` / `TrustSection` / `ModelChoiceRow` (both are private to
/// their files, which is why they are cloned rather than called).
@MainActor
enum MockupsSept13 {
    // MARK: - Shared ground

    /// The room the page sits in. No rail on a comparison frame: two or three
    /// page columns side by side, on the shell's own ground.
    private static func ground<V: View>(_ width: CGFloat, _ content: V) -> some View {
        content
            .padding(24)
            .frame(width: width, alignment: .topLeading)
            .background(NativeAgentShell.room)
    }

    private static func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(ShellType.captionSemibold)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(NativeAgentShell.tertiary)
    }

    /// Cloned from the private `TrustPalette` in TrustCenterView.swift.
    private enum ClonePalette {
        struct AdaptiveColor: ShapeStyle {
            let light: Color
            let dark: Color
            func resolve(in environment: EnvironmentValues) -> Color {
                environment.colorScheme == .dark ? dark : light
            }
        }
        static let secondary = AdaptiveColor(
            light: Color(.sRGB, red: 0.28, green: 0.30, blue: 0.34),
            dark: Color(.sRGB, red: 0.80, green: 0.82, blue: 0.85)
        )
        static let card = TodayPalette.cardFill
        static let border = TodayPalette.cardStroke
    }

    /// Cloned from the private `TrustPresetButton`.
    private struct PresetCardClone: View {
        let title: String
        let subtitle: String
        let isSelected: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(subtitle)
                    .font(ShellType.caption)
                    .foregroundStyle(ClonePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(ClonePalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? NativeAgentShell.text : ClonePalette.border,
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
    }

    /// Cloned from the private `TrustSection`.
    private struct SectionClone<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(ShellType.labelSemibold)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(ClonePalette.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(ClonePalette.card, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 2)
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                            .fill(ClonePalette.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                            .strokeBorder(ClonePalette.border, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Item 1 · Developer Mode folded into the presets

    /// The four preset subtitles, shipped and proposed. Safe and Work mode are
    /// unchanged on purpose: the only claims that move are the two that today
    /// depend on the `developerMode` field.
    private struct PresetCopy {
        let title: String
        let shipped: String
        let proposed: String
    }

    private static let presetCopy = [
        PresetCopy(title: "Safe",
                   shipped: "Read files; no changes or Mac control",
                   proposed: "Read files; no changes or Mac control"),
        PresetCopy(title: "Work mode",
                   shipped: "Edit approved workspaces; no outside writes or shell",
                   proposed: "Edit approved workspaces; no shell, no outside writes"),
        PresetCopy(title: "Builder",
                   shipped: "Edit workspaces; ask to write outside; no shell",
                   proposed: "Your workspace, fully: edit, shell commands, move files. Asks before writing outside."),
        PresetCopy(title: "Full Mac",
                   shipped: "Files anywhere, shell, system control, move or trash",
                   proposed: "The whole Mac: files anywhere, shell, system control, move or trash."),
    ]

    private static func presetGrid(proposed: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
            ForEach(presetCopy, id: \.title) { copy in
                PresetCardClone(title: copy.title,
                                subtitle: proposed ? copy.proposed : copy.shipped,
                                isSelected: copy.title == "Builder")
            }
        }
    }

    /// The shipped Shell Commands panel, rebuilt on the real `NativePanel` with
    /// the real `EffectTimingTag`: a warning pair, a caption that sends the
    /// reader to a concept the page never shows, and a live toggle.
    private struct ShellPanelShipped: View {
        @State private var shellAllowed = false
        var body: some View {
            NativePanel(title: "Shell Commands", systemImage: "terminal", tint: .red) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Powerful - use with care")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                    Text("Allows arbitrary shell execution. Keep this off unless Developer Mode is intentionally enabled for the operator session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Toggle("Enable Shell Commands", isOn: $shellAllowed)
                        EffectTimingTag(timing: .restart)
                        Spacer()
                    }
                }
            }
        }
    }

    /// The proposal: no switch, no Developer Mode, no restart tag. One line
    /// that names which preset grants shell, and a link back to the cards.
    private struct ShellPanelProposed: View {
        var body: some View {
            NativePanel(title: "Shell Commands", systemImage: "terminal", tint: .red) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Builder and Full Mac run shell commands. Safe and Work mode do not.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Builder runs them inside your workspace; Full Mac anywhere.")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose a preset") {}
                        .buttonStyle(.link)
                        .font(ShellType.label)
                }
            }
        }
    }

    private static func trustColumn(proposed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            columnLabel(proposed ? "Proposed · presets carry it" : "Today · Developer Mode behind the page")
            SectionClone(title: "Access and policy") {
                presetGrid(proposed: proposed)
                // The shipped status line, verbatim from the real page. It is
                // not part of the proposal, so both columns say the same thing.
                Text("Builder · Saved")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create backup now") {}
            }
            if proposed { ShellPanelProposed() } else { ShellPanelShipped() }
            Spacer(minLength: 0)
        }
    }

    static func renderTrust(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let columnWidth: CGFloat = 874
        let height: CGFloat = 560
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try BotsShelfSnapshots.write(ground(columnWidth, trustColumn(proposed: false)),
                name: "trust-before-\(suffix)", size: CGSize(width: columnWidth, height: height),
                scheme: scheme, directory: directory, scale: 1)
            try BotsShelfSnapshots.write(ground(columnWidth, trustColumn(proposed: true)),
                name: "trust-after-\(suffix)", size: CGSize(width: columnWidth, height: height),
                scheme: scheme, directory: directory, scale: 1)
            try BotsShelfSnapshots.write(
                HStack(spacing: 0) {
                    ground(columnWidth, trustColumn(proposed: false))
                    ground(columnWidth, trustColumn(proposed: true))
                },
                name: "trust-pair-\(suffix)", size: CGSize(width: columnWidth * 2, height: height),
                scheme: scheme, directory: directory, scale: 1)
        }
        try renderTrustRealPages(to: directory)
    }

    /// Ground truth: the REAL Trust page and the REAL Mac Control page, both on
    /// the shipped views, with the Builder preset written into an isolated
    /// temporary data root. The clone columns above are read against these.
    private static func renderTrustRealPages(to directory: URL) throws {
        let plan = TrustPolicyPreset.builder.plan
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mockups-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let body: [String: Any] = [
            "permissionLevel": plan.permissionLevel,
            "autonomyDefault": plan.autonomyDefault,
            "developerMode": plan.developerMode,
            "filePolicy": [
                "requireBackupBeforeWrite": plan.requireBackups,
                "outsideWorkspaceDefault": plan.outsideDefault,
                "allowDestructiveActions": plan.developerMode,
            ],
            "macControlPolicy": NativeClient.macControlPolicyForAccessMode(
                plan.agentAccessMode, remoteFromIosAllowed: false, developerMode: plan.developerMode
            ),
        ]
        let policy = try JSONDecoder().decode(
            TrustPolicy.self, from: JSONSerialization.data(withJSONObject: body))
        app.trustPolicy = policy
        app.chatFileAccess = plan.agentAccessMode
        // The shipped Shell Commands panel lives inside the Mac Control
        // Advanced fold; a collapsed fold would render no ground truth for it.
        UserDefaults.standard.set(true, forKey: MacControlAdvancedDisclosurePresentation.preferenceKey)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                ShellSidebarRail(selection: .constant(.trust), botsPreviewOverride: false)
            } detail: {
                ShellPageFrame(title: "Trust", showsBack: false) {
                    TrustCenterView(snapshotPolicy: policy, expanded: false).environment(app)
                }
            }, name: "trust-real-page-\(suffix)", size: CGSize(width: 1280, height: 1200),
               scheme: scheme, directory: directory, scale: 1)
            try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                ShellSidebarRail(selection: .constant(.trust), botsPreviewOverride: false)
            } detail: {
                ShellPageFrame(title: "Trust", showsBack: false) {
                    ScrollView { MacControlPermissionsView(loadsOnAppear: false).environment(app) }
                }
            }, name: "trust-real-maccontrol-\(suffix)", size: CGSize(width: 1280, height: 2600),
               scheme: scheme, directory: directory, scale: 1)
        }
    }

    // MARK: - Item 2 · Providers override density

    private struct GroupFixture {
        let title: String
        let origin: String?
        let caption: String
        let members: String
        let model: String
        let think: String
        let fast: Bool
    }

    /// The same three groups, the same values, as the shipped Providers
    /// fixture in SimplicitySnapshots.renderProviders.
    private static let groups = [
        GroupFixture(title: "Chat", origin: "Mixed",
                     caption: "Showing Chat's choice; iPhone, Telegram and Slack differ. Choosing here sets all four.",
                     members: "Chat, iPhone, Telegram and Slack",
                     model: "GPT-6-Astra", think: "Medium", fast: false),
        GroupFixture(title: "Work", origin: "Explicit override",
                     caption: "Desk, Task execution, Independent tasks, Coordinated tasks, Skill practice, Background check-ins and Diagnostics",
                     members: "Desk, Task execution, Independent tasks, Coordinated tasks, Skill practice, Background check-ins and Diagnostics",
                     model: "GPT-6-Astra", think: "High", fast: false),
        GroupFixture(title: "Memory and mind", origin: "Built-in default",
                     caption: "Memory, Dreams, REM, Reflection, Conversation summaries, Learning and Creative exploration",
                     members: "Memory, Dreams, REM, Reflection, Conversation summaries, Learning and Creative exploration",
                     model: "GPT-6-Astra", think: "Medium", fast: false),
    ]

    private static let account = "ChatGPT (OAuth)"

    // Controls, drawn as the shipped page draws them: real menus, a real
    // picker, a real switch. Values are fixed; nothing is written.
    private static func providerMenu() -> some View {
        Menu { Button(account) {} } label: { Text(account).lineLimit(1) }
    }
    private static func modelMenu(_ model: String) -> some View {
        Menu { Button(model) {} } label: { Text(model).lineLimit(1) }
    }
    private static func thinkMenu(_ think: String) -> some View {
        Menu { Button(think) {} } label: { Text(think).lineLimit(1) }
    }
    private static func fastSwitch(_ on: Bool) -> some View {
        Toggle("Fast", isOn: .constant(on))
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Cloned from the shipped `ModelChoiceRow` + its `field`, numbers verbatim:
    /// 180/150/90 widths, 8pt gaps, a 10pt secondary field label 3pt above its
    /// control.
    private struct ChoiceRowClone<P: View, M: View, T: View, F: View>: View {
        var labelSize: CGFloat = 10
        var labelGap: CGFloat = 3
        @ViewBuilder var provider: () -> P
        @ViewBuilder var model: () -> M
        @ViewBuilder var think: () -> T
        @ViewBuilder var fast: () -> F
        var body: some View {
            HStack(alignment: .bottom, spacing: 8) {
                field("Provider", content: provider).frame(width: 180)
                field("Model", content: model).frame(width: 150)
                field("Think", content: think).frame(width: 90)
                fast().frame(minHeight: 24)
            }
            .font(.system(size: 12, weight: .medium))
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
            VStack(alignment: .leading, spacing: labelGap) {
                Text(title).font(.system(size: labelSize))
                    .foregroundStyle(NativeAgentShell.secondary)
                content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// TODAY. One font, one size, one colour above the controls; 6pt inside the
    /// row, 7pt of padding top and bottom, and the capability caption under it.
    private static func currentRow(_ group: GroupFixture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NativeAgentShell.text)
                if let origin = group.origin {
                    Text(origin).font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                }
                Spacer(minLength: 0)
                Button("Use default") {}.controlSize(.small)
            }
            Text(group.caption)
                .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ChoiceRowClone(provider: providerMenu, model: { modelMenu(group.model) },
                           think: { thinkMenu(group.think) }, fast: { fastSwitch(group.fast) })
        }
        .padding(.vertical, 7)
    }

    /// OPTION A. Real hierarchy — 16pt semibold name, 13pt secondary members,
    /// 11pt origin — and a tighter rhythm: 4pt inside the row, 2pt under each
    /// field label, 4pt of padding, one hairline between groups.
    private static func optionARow(_ group: GroupFixture) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                if let origin = group.origin {
                    Text(origin).font(ShellType.caption).foregroundStyle(NativeAgentShell.tertiary)
                }
                Spacer(minLength: 0)
                Button("Use default") {}.controlSize(.small)
            }
            Text(group.members)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(1).truncationMode(.tail)
            ChoiceRowClone(labelGap: 2, provider: providerMenu, model: { modelMenu(group.model) },
                           think: { thinkMenu(group.think) }, fast: { fastSwitch(group.fast) })
        }
        .padding(.vertical, 4)
    }

    /// OPTION B. One table: the four column headings said once, three rows of
    /// controls on their own baseline, and the memberships as a footnote.
    private static func optionBTable() -> some View {
        let columns = [GridItem(.fixed(150), alignment: .leading),
                       GridItem(.fixed(180), alignment: .leading),
                       GridItem(.fixed(150), alignment: .leading),
                       GridItem(.fixed(92), alignment: .leading),
                       GridItem(.fixed(60), alignment: .leading)]
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(["Activity", "Provider", "Model", "Think", "Fast"], id: \.self) { heading in
                    Text(heading).font(.system(size: 10))
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
                ForEach(groups, id: \.title) { group in
                    Text(group.title).font(ShellType.labelSemibold)
                        .foregroundStyle(NativeAgentShell.text).lineLimit(1)
                    providerMenu().labelsHidden().controlSize(.small).font(ShellType.label)
                    modelMenu(group.model).labelsHidden().controlSize(.small).font(ShellType.label)
                    thinkMenu(group.think).labelsHidden().controlSize(.small).font(ShellType.label)
                    fastSwitch(group.fast).labelsHidden()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups, id: \.title) { group in
                    Text("\(group.title) — \(group.members)")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Work carries an explicit override; Memory and mind follows Chat. Use default restores inheritance.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func card<V: View>(_ content: V) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(TodayPalette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
            )
    }

    private enum DensityVariant: String, CaseIterable {
        case current, optionA, optionB
        var label: String {
            switch self {
            case .current: "Today · one font, one size, one colour"
            case .optionA: "Option A · hierarchy, tighter rhythm"
            case .optionB: "Option B · one compact table"
            }
        }
    }

    @ViewBuilder
    private static func densityBody(_ variant: DensityVariant) -> some View {
        switch variant {
        case .current:
            card(VStack(alignment: .leading, spacing: 0) { ForEach(groups, id: \.title) { currentRow($0) } })
        case .optionA:
            card(VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    optionARow(group)
                }
            })
        case .optionB:
            card(optionBTable())
        }
    }

    private static func densityColumn(_ variant: DensityVariant) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            columnLabel(variant.label)
            densityBody(variant)
            Spacer(minLength: 0)
        }
    }

    static func renderProvidersDensity(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let columnWidth: CGFloat = 874
        let height: CGFloat = 470
        var measurements: [String] = ["# Providers override density · measured at \(Int(columnWidth - 48))pt card width, the shipped column measure",
                                      "", "variant\tcard height\tone group row"]
        for variant in DensityVariant.allCases {
            let cardHeight = measuredHeight(densityBody(variant), width: columnWidth - 48)
            let rowHeight: CGFloat
            switch variant {
            case .current: rowHeight = measuredHeight(currentRow(groups[0]), width: columnWidth - 80)
            case .optionA: rowHeight = measuredHeight(optionARow(groups[0]), width: columnWidth - 80)
            case .optionB: rowHeight = 0
            }
            measurements.append("\(variant.rawValue)\t\(round(cardHeight * 10) / 10)\t\(rowHeight == 0 ? "n/a (table)" : String(describing: round(rowHeight * 10) / 10))")
        }
        try measurements.joined(separator: "\n").appending("\n")
            .write(to: directory.appendingPathComponent("measurements.txt"), atomically: true, encoding: .utf8)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for variant in DensityVariant.allCases {
                try BotsShelfSnapshots.write(ground(columnWidth, densityColumn(variant)),
                    name: "providers-\(variant.rawValue)-\(suffix)",
                    size: CGSize(width: columnWidth, height: height),
                    scheme: scheme, directory: directory, scale: 1)
            }
            try BotsShelfSnapshots.write(
                HStack(spacing: 0) { ForEach(DensityVariant.allCases, id: \.self) { ground(columnWidth, densityColumn($0)) } },
                name: "providers-triple-\(suffix)",
                size: CGSize(width: columnWidth * 3, height: height),
                scheme: scheme, directory: directory, scale: 1)
        }
    }

    /// Intrinsic height of a view laid out at a fixed width, from the same
    /// AppKit hosting path the snapshots rasterise through. No window.
    private static func measuredHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
#endif
