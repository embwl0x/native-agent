import SwiftUI
import NativeAgentShared
import UIKit
// Blueprint: | `AliveConnection.swift` | Shared Mac connection wording, pairing guidance and snapshot freshness |

enum AliveConnection {
    static let unpaired = "Not paired with your Mac yet"
    static let unreachable = "I can\u{2019}t reach your Mac right now"
    static let noICloud = "No iCloud on this iPhone"
    static let pairToChange = "Pair with your Mac to change this"

    static func line(_ connection: NAPhoneConnection) -> String {
        connection.holds ? "Here" : connection.headline.line
    }
}

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

/// Unavailable controls share dimming and guidance; never display a value the Mac has not sent.
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
    func aliveUnavailable(_ off: Bool) -> some View {
        disabled(off).opacity(off ? 0.5 : 1)
    }
}

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
                // Freshness belongs to this group's delivery: a Desk delivery says nothing about Approvals.
                lastSyncedAt: sync.transportDeliveryAt(screenGroup: group),
                staleGroupReason: reason)
        }
    }
}
