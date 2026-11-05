import AppToolRuntime
import EngineRuntime
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `SettingsNavigation.swift` | SettingsLink routes to canonical pages; ShellPageFrame supplies shared page layout |

/// Open canonical rail pages; Simple and Agent routes switch to Advanced because they have no rail.
@MainActor
enum SettingsLink {
    static func open(_ item: SidebarItem, tab: String? = nil) {
        let mode = SimpleViewMode.resolved(UserDefaults.standard.string(forKey: SimpleViewMode.key) ?? "")
        if mode != SimpleViewMode.advanced {
            UserDefaults.standard.set(SimpleViewMode.advanced, forKey: SimpleViewMode.key)
        }
        ApplicationLifetime.shared.request(.sidebar(item))
        // Routing resets to the first tab synchronously; apply the requested tab afterward.
        if let tab { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(item)) }
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

    @State private var aliveLine: AlivePageLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if alive {
                AlivePageHeader(title: title, line: aliveLine?.text ?? subtitle,
                                lineID: aliveLine?.id ?? "shell.page.subtitle")
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
        .onPreferenceChange(AlivePageLineKey.self) { aliveLine = $0 }
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
