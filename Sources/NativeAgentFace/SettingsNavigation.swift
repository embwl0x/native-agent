import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `SettingsNavigation.swift` | SettingsLink routes to canonical pages; ShellPageFrame supplies shared page layout |

/// Open a page and its tab. Simple and Advanced show it in place; any other view shows no pages, so the link opens Advanced first.
@MainActor
enum SettingsLink {
    static func open(_ item: SidebarItem, tab: String? = nil) {
        guard let appModel = ApplicationLifetime.shared.appModel else { return }
        appModel.enqueueWindowAction(.settings(item, tab: tab))
    }

    static func openChecked(_ item: SidebarItem, tab: String?, appModel: AppModel) async throws {
        let view = appModel.facePreference(SimpleViewMode.key, as: String.self)
        if view != SimpleViewMode.simple && view != SimpleViewMode.advanced {
            _ = try await appModel.client.act(.setPreference(key: SimpleViewMode.key, value: .string(SimpleViewMode.advanced))).checkedCommit()
        }
        try Task.checkCancellation()
        ApplicationLifetime.shared.request(.sidebar(item))
        if let tab {
            let key = ShellRailTab.storageKey(item)
            if UserDefaults.standard.string(forKey: key) != tab { UserDefaults.standard.set(tab, forKey: key) }
        }
    }
}

struct ShellPageFrame<Content: View>: View {
    let title: String
    /// A nil page sentence leaves the title alone.
    var subtitle: String?
    /// Wide pages need the full column for two-column controls.
    var wide: Bool = false
    var alive: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if alive {
                AlivePageHeader(title: title, line: subtitle, lineID: "shell.page.subtitle")
            } else {
                Text(title)
                    .font(ShellType.display)
                    .foregroundStyle(NativeAgentShell.text)
                    .padding(.top, 6)
                    .padding(.bottom, subtitle == nil ? 14 : 4)
                    .accessibilityAddTraits(.isHeader)

                if let subtitle {
                    Text(subtitle)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                        .accessibilityIdentifier("shell.page.subtitle")
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Fade scrolled rows over the header gap to avoid a hard clipped edge.
                .aliveTopDissolve(alive ? 20 : 0)
                .pageScrollColumn()
                // Nested pages own their actions; do not duplicate them here.
                .environment(\.shellTabRowHostsActions, false)
        }
        .padding(.horizontal, NativeAgentSpacing.pageInset)
        .padding(.top, alive ? TodayMetrics.topPadding : 20)
        .frame(maxWidth: wide ? .infinity : TodayMetrics.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Lists and Forms paint opaque backgrounds by default; expose the shared room.
        .scrollContentBackground(.hidden)
        // Buttons use text colour; active controls use `hazeTinted`.
        .tint(NativeAgentShell.text)
        // Hide painted navigation chrome while retaining the native back gesture.
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
