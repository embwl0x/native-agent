import Foundation
import NativeAgentCore
import CryptoKit
import Darwin
// Blueprint: | `CapabilityLifecycle+FileAdmission.swift` | CapabilityLifecycle file-write admission, peer-content protection and owner-off reconciliation |

extension CapabilityLifecycle {
    private static let offStatuses = ["off", "disabled", "trashed", "archived", "quarantined", "dormant", "rejected"]
    private static let retirementFields = ["trashedAt", "droppedAt", "archivedAt", "archivedStatus", "archiveReason",
                                           "quarantinedAt", "quarantinedStatus", "quarantineReason", "quarantinePath",
                                           "unavailableReason", "retired", "suspended"]

    /// Raw file mutations cannot bypass the ability lifecycle, including by
    /// replacing a parent folder. Other protected stores recheck the turn's steer.
    public static func requireFileMutation(_ path: URL, dataRoot: URL, personaRoot: URL? = nil) throws {
        let path = path.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        func reaches(_ store: URL) -> Bool {
            let store = store.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            return NativeAgentWorkspaceRoot.relativePath(path, under: store) != nil
                || NativeAgentWorkspaceRoot.relativePath(store, under: path) != nil
        }
        let abilities = [dataRoot, libraryAppSupportFallback(appBundleIdentifier: canonicalPublicBundleIdentifier)]
            .flatMap { root in Store.allCases.map { $0.directory(in: root) } + [root.appendingPathComponent("abilities")] }
        if abilities.contains(where: reaches) || protectedStores.contains(where: { reaches(dataRoot.appendingPathComponent($0)) })
            || reaches(personaRoot ?? PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)) {
            try requireWrite()
        }
        if abilities.contains(where: reaches) {
            throw PersistenceCoreError.ioFailure("Ability stores require lifecycle actions; use the sense, tool or skill action for this change.")
        }
    }

    public static func requiresOwnerToEnable(_ row: [String: JSONValue]) -> Bool {
        return requiresOwnerToEnable(isOff: offStatuses.contains((row["state"] ?? row["status"])?.stringValue ?? ""),
                                     disabledBy: row["disabledBy"]?.stringValue)
    }

    /// Reconcile under the registry lock. Off ownership belongs to the ability,
    /// not its selected version or the snapshot an upgrade was assembled from.
    public static func preservingOwnerOff(_ proposed: [String: JSONValue], before current: [String: JSONValue]?,
                                          ownerAuthorized: Bool = false, enabling: Bool = false, preview: Bool = false) throws -> [String: JSONValue] {
        let key = proposed["state"] == nil ? "status" : "state"
        if let attribution = current?["disabledBy"], attribution != .null,
           !offActors.contains(attribution.stringValue ?? "") {
            let name = current?["id"]?.stringValue ?? "The ability"
            throw PersistenceCoreError.ioFailure("\(name)'s off ownership is unreadable: its registry entry says disabledBy \((try? attribution.serialize(pretty: false)) ?? "?"). "
                + "Set disabledBy to who switched it off (owner, hers or peer; owner when unsure) before changing it. Nothing changed.")
        }
        let ownerOff = current.map(requiresOwnerToEnable) ?? false
        var row = proposed
        if ownerOff, !ownerAuthorized {
            if enabling {
                let name = current?["name"]?.stringValue ?? current?["id"]?.stringValue ?? "this ability"
                let id = current?["id"]?.stringValue ?? name
                let tap = current?["inputSchema"] != nil ? "Tools > \(name) > Approve"
                    : current?["corner"] != nil ? "Senses > \(name) > switch (senses.switch.\(id))"
                    : "Skills > \(name) > Review > Install"
                throw ToolFailureError("\(name)'s retained record has disabledBy=owner. Only the person can turn it back on at \(tap).",
                    effects: .none, owner: "abilities/\(id) > record.disabledBy=owner", tap: tap, personDecides: true)
            }
            for field in [key, "phase", "enabledAt"] + retirementFields {
                row[field] = current?[field]
            }
            row["disabledBy"] = .string("owner")
        } else {
            // Off belongs to the owner when he acts, else the recorded non-owner actor, else hers.
            let recorded = row["disabledBy"]?.stringValue.flatMap { offActors.contains($0) && $0 != "owner" ? $0 : nil }
            row["disabledBy"] = offStatuses.contains(row[key]?.stringValue ?? "") ? .string(ownerAuthorized ? "owner" : recorded ?? "hers") : nil
            if enabling, !offStatuses.contains(row[key]?.stringValue ?? "") {
                for field in retirementFields { row.removeValue(forKey: field) }
            }
        }
        if !preview, abilityContents(.object(row)) != abilityContents(current.map(JSONValue.object) ?? .null) { try requireWrite() }
        return row
    }

    public static func preservingOwnerOff<Record: Codable>(_ proposed: Record, before current: Record?,
                                                           ownerAuthorized: Bool = false, enabling: Bool = false, preview: Bool = false) throws -> Record {
        let row = try preservingOwnerOff(JSONRow(JSONValue.fromEncodable(proposed)).fields,
            before: current.map { try JSONRow(JSONValue.fromEncodable($0)).fields }, ownerAuthorized: ownerAuthorized, enabling: enabling, preview: preview)
        return try JSONDecoder().decode(Record.self, from: JSONValue.object(row).serializedData(pretty: false))
    }

    /// Selected part/sense rows share one rule; a new sense id retains its corner's owner-off attribution.
    public static func preservingOwnerOff(_ proposed: JSONValue, before current: JSONValue,
                                          ownerAuthorized: Bool = false, enabling: Bool = false, senseRecords: Bool = false) throws -> JSONValue {
        if abilityContents(proposed) != abilityContents(current) { try requireWrite() }
        if case .array(let rows) = proposed {
            let previous = current.arrayValue ?? current.objectValue?["tools"]?.arrayValue ?? current.objectValue?["skills"]?.arrayValue ?? []
            return .array(try rows.map { value in
                guard let row = value.objectValue else { return value }
                let old = previous.first { $0.objectValue?["id"] == row["id"] }?.objectValue
                    ?? previous.first { $0.objectValue?["id"] == row["replaces"]?.objectValue?["id"] }?.objectValue
                    ?? (!senseRecords || previous.contains { $0.objectValue?["corner"] == row["corner"] && $0.objectValue?["status"] == .string("on") } ? nil
                        : previous.compactMap(\.objectValue).first { $0["corner"] == row["corner"] && requiresOwnerToEnable($0) })
                if old == row { return value }
                return .object(try preservingOwnerOff(row, before: old, ownerAuthorized: ownerAuthorized,
                    enabling: enabling))
            })
        }
        return proposed
    }

    /// Usage evidence is not an ability edit. Only these existing row fields
    /// are accounting; unknown fields and all program/fixture bytes stay protected.
    private static func abilityContents(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let rows): return .array(rows.map(abilityContents))
        case .object(var fields):
            for key in ["tools", "skills"] {
                if let rows = fields[key] { fields[key] = abilityContents(rows) }
            }
            if let original = fields["builtIn"] { fields["builtIn"] = abilityContents(original) }
            for field in ["uses", "useCount", "lastUsedAt", "lastRunVersion", "lastRun",
                          "lastCleanCode", "lastCleanVersion", "runs"] { fields.removeValue(forKey: field) }
            return .object(fields)
        default: return value
        }
    }
}
