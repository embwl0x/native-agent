import SwiftUI
import NativeAgentShared
import UIKit
// Blueprint: | `AliveConnection.swift` | Shared Mac connection wording, pairing guidance and snapshot freshness |

/// Shared Mac connection wording for chat, More, Settings and Status only.
enum AliveConnection {
    static let unpaired = "Not paired with your Mac yet"
    static let unreachable = "I can\u{2019}t reach your Mac right now"
    static let noICloud = "No iCloud on this iPhone"
    /// The one reason on every control the phone cannot use yet.
    static let pairToChange = "Pair with your Mac to change this"

    /// The connection's headline: "Here" when all three facts hold, else the
    /// first fact that does not (`NAPhoneConnection.headline`).
    static func line(_ connection: NAPhoneConnection) -> String {
        connection.holds ? "Here" : connection.headline.line
    }
}

/// One fact of the connection: what is true, and the way on when it does not
/// hold. The header popover and Settings › Connection draw facts with this.
struct AliveConnectionFactLine: View {
    let label: String
    let fact: NAPhoneConnection.Fact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(fact.state == .holds ? Color.green : fact.state == .waiting ? Color.orange : Color.red)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.footnote.weight(.semibold)).foregroundStyle(AlivePalette.text)
                Text(fact.line).font(.footnote).foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if fact.state != .holds, let lever = fact.lever {
                    Text(lever).font(.footnote).foregroundStyle(AlivePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one reason on a page whose controls the phone cannot use yet, with
/// the one way on. Every such control wears `aliveUnavailable`, so they all
/// dim the same way and none shows a value the Mac has not sent.
struct AliveUnpairedReason: View {
    var showsAction = true
    @State private var showsPairing = false

    var body: some View {
        if showsAction {
            AliveStatusNote(systemImage: "lock", text: AliveConnection.pairToChange + ".",
                            actionTitle: "Pair with Mac", actionHint: "Connects this iPhone to your Mac") {
                showsPairing = true
            }
            .sheet(isPresented: $showsPairing) {
                PairingView(onSkip: { showsPairing = false }, onPaired: { showsPairing = false })
            }
        } else {
            AliveFootnote(AliveConnection.pairToChange + ".", systemImage: "lock")
        }
    }
}

extension View {
    /// A control the phone cannot use yet: off and dimmed, the same everywhere.
    func aliveUnavailable(_ off: Bool) -> some View {
        disabled(off).opacity(off ? 0.5 : 1)
    }
}

/// Show this group’s stale age once under the header, or pairing guidance when unpaired.
struct AliveFreshnessNote: View {
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var showsPairing = false
    let group: String

    var body: some View {
        let reason = MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: group)
        if !pairingStore.usesICloudTransport {
            AliveNoteAction(title: "Pair with Mac", hint: "Connects this iPhone to your Mac") { showsPairing = true }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheet(isPresented: $showsPairing) {
                    PairingView(onSkip: { showsPairing = false }, onPaired: { showsPairing = false })
                }
        } else {
            MacSnapshotFreshnessBadge(
                // THIS group's last delivery, not the last cache read: a Desk
                // delivery is not evidence that Approvals arrived.
                lastSyncedAt: sync.transportDeliveryAt(screenGroup: group),
                staleGroupReason: reason)
        }
    }
}
