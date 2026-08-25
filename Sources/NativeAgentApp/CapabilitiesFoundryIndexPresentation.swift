import Foundation

/// Presentation boundary for the native capability-records catalog. A catalog
/// summary is a receipt: its aggregate counts must agree with the actual rows
/// before Foundry Index can display it as a useful inventory.
enum CapabilitiesFoundryIndexPresentation {
    enum State: Equatable {
        case unavailable
        case empty
        case inconsistent(String)
        case populated(CapabilitySummaryResponse)
    }

    static func state(summary: CapabilitySummaryResponse?) -> State {
        guard let summary else { return .unavailable }
        guard !summary.records.isEmpty else {
            guard summary.summary.total == 0,
                  summary.summary.active == 0,
                  summary.summary.review == 0,
                  summary.summary.autoloaded == 0 else {
                return .inconsistent("the catalog has no rows but its counts are nonzero")
            }
            return .empty
        }

        guard summary.records.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .inconsistent("one or more catalog rows have no stable identifier")
        }
        guard Set(summary.records.map(\.id)).count == summary.records.count else {
            return .inconsistent("the catalog contains duplicate identifiers")
        }

        let counts = summary.summary
        guard counts.total == summary.records.count else {
            return .inconsistent("the declared total does not match the catalog rows")
        }
        guard counts.active >= 0, counts.review >= 0, counts.autoloaded >= 0,
              counts.active <= counts.total,
              counts.review <= counts.total,
              counts.autoloaded <= counts.total else {
            return .inconsistent("one or more declared counts are outside the catalog bounds")
        }

        let activeStatuses: Set<String> = ["active", "installed", "ready", "configured"]
        let reviewStatuses: Set<String> = ["review", "proposal", "draft", "drafted", "needs_setup"]
        let actualActive = summary.records.filter { activeStatuses.contains(($0.status ?? "").lowercased()) }.count
        let actualReview = summary.records.filter { reviewStatuses.contains(($0.status ?? "").lowercased()) }.count
        let actualAutoloaded = summary.records.filter { $0.autoload == true }.count
        guard counts.active == actualActive,
              counts.review == actualReview,
              counts.autoloaded == actualAutoloaded else {
            return .inconsistent("the declared status counts do not match the catalog rows")
        }

        if let byKind = counts.byKind {
            var actualByKind: [String: Int] = [:]
            for record in summary.records {
                actualByKind[record.kind, default: 0] += 1
            }
            guard byKind == actualByKind else {
                return .inconsistent("the declared kind counts do not match the catalog rows")
            }
        }

        return .populated(summary)
    }

    static var unavailableDetail: String {
        "The native capability catalog has not loaded. Refresh when the runtime is available."
    }

    static var emptyDetail: String {
        "The native capability catalog returned no indexed capabilities."
    }

    static func inconsistentDetail(_ reason: String) -> String {
        "The native capability catalog receipt is inconsistent (\(reason)). Refresh before relying on this index."
    }
}
