// ICloudBridgeConstantsTests.swift — evals for the ios.sync fence's shared
// half: the iCloud wire NAMESPACE that Mac and iOS must resolve identically.
//
// Every surface here fails SILENTLY. A container id that differs by one
// character makes both sides report "iCloud ready" while nothing crosses; a
// KVS key renamed on one side reads nil forever, which looks exactly like
// "the Mac is idle"; a Drive folder written but never scanned accumulates
// messages on disk under a permanent "Sending" status. None of it raises.
//
// The tests below are of two shapes:
//   * VALUE contracts — pure functions over the shared constants.
//   * SOURCE-CONFORMANCE ratchets — the shared module cannot import the two
//     app targets, so the "both sides use the same symbol" invariant is proved
//     by scraping the checked-in sources. These are chokepoint guards: a NEW
//     hardcoded wire literal fails the build even though today's tree is clean.
//
// Ledger rows: shared.icloudConstants.{containerID,mobileSourceKey,macBundleID,
// backgroundTaskIDPrefix,kvsKeys,driveFolders}, shared.deviceSyncError.userStrings,
// shared.cloudkit.isDeviceSyncNotification, shared.mobileDeskSnapshot.models,
// shared.snapshotModels.decodeContracts.

import Foundation
import Testing
@testable import NativeAgentShared

#if canImport(CloudKit) && !os(Linux)
import CloudKit
#endif

// MARK: - Repo access (source-conformance ratchets)

enum ICloudFenceRepo {
    /// Walk up from this test file to the repository root. Anchored on three
    /// paths that only exist together at the root so a nested match cannot
    /// masquerade as the root.
    static func root(from filePath: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let fm = FileManager.default
            if fm.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               fm.fileExists(atPath: directory.appendingPathComponent("iOS/NativeAgentMobile/project.yml").path),
               fm.fileExists(atPath: directory.appendingPathComponent("Modules/NativeAgentShared/Package.swift").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw ICloudFenceError("could not locate the repository root from \(filePath)")
    }

    static func text(_ relativePath: String) throws -> String {
        let url = try root().appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ICloudFenceError("missing or unreadable source: \(relativePath)")
        }
        return text
    }

    /// Every `.swift` file under a repo-relative directory (recursive).
    static func swiftFiles(under relativePath: String) throws -> [(path: String, text: String)] {
        let base = try root().appendingPathComponent(relativePath, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: nil
        ) else {
            throw ICloudFenceError("could not enumerate \(relativePath)")
        }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.path, text))
        }
        guard !out.isEmpty else { throw ICloudFenceError("no swift files under \(relativePath)") }
        return out
    }
}

struct ICloudFenceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - shared.icloudConstants.*

@Suite("iCloud bridge namespace constants")
struct ICloudBridgeConstantsTests {

    /// shared.icloudConstants.containerID — the id the iOS build BAKES (via
    /// xcconfig → Info.plist) must be the same string the Mac falls back to.
    /// A drift here is invisible: each side reports "iCloud ready" against a
    /// different store.
    @Test func iosBakedContainerIDEqualsTheSharedMacDefault() throws {
        let xcconfig = try ICloudFenceRepo.text("iOS/NativeAgentMobile/Config/CanonicalIdentifiers.xcconfig")
        let declared = Self.xcconfigValue("NATIVEAGENT_ICLOUD_CONTAINER_ID", in: xcconfig)
        #expect(declared == NativeAgentICloudBridgeConstants.defaultContainerID)

        // And the Info.plist must actually forward the xcconfig variable —
        // a plist that hardcoded a stale literal would pass the check above
        // while shipping a different container.
        let infoPlist = try ICloudFenceRepo.text("iOS/NativeAgentMobile/Sources/Info.plist")
        #expect(infoPlist.contains("<key>NativeAgentICloudContainerID</key>"))
        #expect(infoPlist.contains("$(NATIVEAGENT_ICLOUD_CONTAINER_ID)"))
    }

    /// The unexpanded `$(...)` form is what the source Info.plist literally
    /// contains. `configuredValue` REJECTS any value containing `$(` so an
    /// unexpanded build variable can never become the live container id — it
    /// falls through to the default instead of addressing a store literally
    /// named "$(NATIVEAGENT_ICLOUD_CONTAINER_ID)".
    @Test func placeholderShapedValuesAreNotUsableContainerIDs() {
        let placeholder = "$(NATIVEAGENT_ICLOUD_CONTAINER_ID)"
        #expect(placeholder.contains("$("))
        // The live resolution never returns a placeholder or an empty string.
        let resolved = NativeAgentICloudBridgeConstants.containerID
        #expect(!resolved.isEmpty)
        #expect(!resolved.contains("$("))
        #expect(resolved.trimmingCharacters(in: .whitespacesAndNewlines) == resolved)
    }

    /// The ubiquity folder name is a pure derivation of the container id.
    /// Drift between the two is the "messages land in a folder nothing scans"
    /// shape, one level up from DriveFolder.
    @Test func mobileDocumentsFolderNameIsTheDotSwappedContainerID() {
        let container = NativeAgentICloudBridgeConstants.containerID
        let folder = NativeAgentICloudBridgeConstants.mobileDocumentsFolderName
        #expect(folder == container.replacingOccurrences(of: ".", with: "~"))
        #expect(!folder.contains("."))
        #expect(folder.contains("~"))
    }

    /// shared.icloudConstants.mobileSourceKey — the routing predicate that
    /// decides whether a Mac reply addressed to "the phone" is delivered or
    /// dropped. Note the ACTUAL contract: nil/empty is NOT accepted here.
    /// Broadcast semantics live at the call site (an empty targetSourceKey is
    /// short-circuited before this is consulted), and the two tests below pin
    /// both halves so a refactor cannot quietly move the boundary.
    @Test func mobileSourceKeyPredicateAcceptsOnlyThisBuildsOwnKey() {
        let own = NativeAgentICloudBridgeConstants.mobileSourceKey
        #expect(!own.isEmpty)
        #expect(NativeAgentICloudBridgeConstants.isMobileSourceKey(own))
        // Whitespace around the same key is tolerated (QR/plist round trips).
        #expect(NativeAgentICloudBridgeConstants.isMobileSourceKey("  \(own)\n"))
        // A foreign addressee is rejected — this is the drop that makes chat
        // look like the Mac never answered.
        #expect(!NativeAgentICloudBridgeConstants.isMobileSourceKey("mobile_app_other"))
        #expect(!NativeAgentICloudBridgeConstants.isMobileSourceKey("iphone:User’s iPhone"))
        // Empty / nil are NOT "mine" at this layer.
        #expect(!NativeAgentICloudBridgeConstants.isMobileSourceKey(nil))
        #expect(!NativeAgentICloudBridgeConstants.isMobileSourceKey(""))
        #expect(!NativeAgentICloudBridgeConstants.isMobileSourceKey("   "))
    }

    /// The broadcast half of the same contract, proved where it actually
    /// lives. The addressing round trip has two ends and each must hold:
    ///   * iOS (receiver) short-circuits an EMPTY targetSourceKey to BROADCAST
    ///     before consulting the predicate above — otherwise every unaddressed
    ///     Mac reply is dropped and chat looks like the Mac never answered.
    ///   * The Mac (sender) addresses a reply with the `sourceKey` the phone
    ///     sent, so the key the phone answers to is the key it is answered on.
    @Test func addressingRoundTripKeepsBroadcastAndPerDeviceRepliesDeliverable() throws {
        let ios = try ICloudFenceRepo.text("iOS/NativeAgentMobile/Sources/iCloudBridge.swift")
        #expect(ios.contains("targetSourceKey"), "the iOS receive path must still filter on targetSourceKey")
        #expect(
            ios.contains("!targetSourceKey.isEmpty"),
            "iOS must short-circuit an empty targetSourceKey (broadcast) before isMobileSourceKey rejects it"
        )
        #expect(
            ios.contains("NativeAgentICloudBridgeConstants.isMobileSourceKey(targetSourceKey)"),
            "iOS must accept its own build's mobileSourceKey, not only the per-device routeKey"
        )

        let mac = try ICloudFenceRepo.text("Sources/NativeAgentApp/iCloudBridge.swift")
        #expect(
            mac.contains("""
            let targetSourceKey = msg.metadata?["sourceKey"] ?? ""
            """.trimmingCharacters(in: .whitespacesAndNewlines)),
            "the Mac must address a reply with the sourceKey the phone sent"
        )
    }

    /// The iOS build bakes the source key too; a drift makes the Mac address
    /// replies to a key the phone will not answer to.
    @Test func iosBakedMobileSourceKeyEqualsTheSharedDefault() throws {
        let xcconfig = try ICloudFenceRepo.text("iOS/NativeAgentMobile/Config/CanonicalIdentifiers.xcconfig")
        let declared = Self.xcconfigValue("NATIVEAGENT_MOBILE_SOURCE_KEY", in: xcconfig)
        #expect(declared == NativeAgentICloudBridgeConstants.defaultMobileSourceKey)
        let infoPlist = try ICloudFenceRepo.text("iOS/NativeAgentMobile/Sources/Info.plist")
        #expect(infoPlist.contains("$(NATIVEAGENT_MOBILE_SOURCE_KEY)"))
    }

    /// shared.icloudConstants.macBundleID — the wake/launch target. Wrong
    /// value = a target that never resolves, with no error surfaced.
    @Test func macBundleIDMatchesTheShippedReleaseIdentity() throws {
        let release = try ICloudFenceRepo.text("script/release.sh")
        let expected = NativeAgentICloudBridgeConstants.defaultMacBundleID
        #expect(
            release.contains("NATIVEAGENT_MAC_BUNDLE_ID:-\(expected)"),
            "release.sh default Mac bundle id must equal the shared default (\(expected))"
        )
        // Same publisher root as the container so one rename cannot split them.
        let containerRoot = NativeAgentICloudBridgeConstants.defaultContainerID
            .replacingOccurrences(of: "iCloud.", with: "")
        #expect(expected.hasPrefix(containerRoot))
    }

    /// shared.icloudConstants.backgroundTaskIDPrefix — the identifiers the
    /// background scheduler registers. A suffix that stops going through
    /// `backgroundTaskIdentifier` drifts out of the namespace and the loop
    /// silently never runs.
    @Test func backgroundTaskIdentifiersAreNamespacedAndDistinct() throws {
        let suffixes = ["rem_cycle", "memory_consolidation", "self_improvement_sweep", "dream_cycle"]
        var seen = Set<String>()
        for suffix in suffixes {
            let id = NativeAgentICloudBridgeConstants.backgroundTaskIdentifier(suffix)
            #expect(id == "\(NativeAgentICloudBridgeConstants.backgroundTaskIDPrefix).\(suffix)")
            #expect(!id.contains("$("))
            #expect(!id.contains(" "))
            #expect(seen.insert(id).inserted, "duplicate background task identifier: \(id)")
        }

        // Chokepoint: no registration site may hardcode the identifier string.
        let scheduler = try ICloudFenceRepo.text("Sources/NativeAgentApp/AppDelegate+BackgroundTasks.swift")
        for suffix in suffixes {
            #expect(
                scheduler.contains("backgroundTaskIdentifier(\"\(suffix)\")"),
                "\(suffix) must be namespaced through backgroundTaskIdentifier(_:)"
            )
            #expect(
                !scheduler.contains("\"\(NativeAgentICloudBridgeConstants.defaultBackgroundTaskIDPrefix).\(suffix)\""),
                "\(suffix) is hardcoded as a full literal; a prefix change would not reach it"
            )
        }
    }

    /// shared.icloudConstants.kvsKeys — a rename on one side reads nil
    /// forever, which is indistinguishable from "the Mac is idle". The only
    /// defence is that no target spells the key itself. Green today; this is
    /// the ratchet that keeps it that way.
    @Test func noProductionSourceHardcodesAKVSKeyString() throws {
        let keys = [
            NativeAgentICloudBridgeConstants.KVSKey.macToIosPrefix,
            NativeAgentICloudBridgeConstants.KVSKey.iosToMacPrefix,
            NativeAgentICloudBridgeConstants.KVSKey.macStatus,
            NativeAgentICloudBridgeConstants.KVSKey.iosStatus,
            NativeAgentICloudBridgeConstants.KVSKey.newMessageInDrive,
            NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest,
        ]
        #expect(Set(keys).count == keys.count, "KVS key values must be distinct")

        var offenders: [String] = []
        for root in ["Sources", "iOS/NativeAgentMobile/Sources", "Modules/NativeAgentShared/Sources"] {
            for file in try ICloudFenceRepo.swiftFiles(under: root) {
                if file.path.hasSuffix("ICloudBridgeConstants.swift") { continue }
                for key in keys where file.text.contains("\"\(key)\"") {
                    offenders.append("\(file.path): \"\(key)\"")
                }
            }
        }
        #expect(offenders.isEmpty, "KVS keys must be referenced via KVSKey, not spelled: \(offenders)")
    }

    /// shared.icloudConstants.driveFolders — the legacy Drive lane. The Mac
    /// creates all four folders; iOS creates only the three it writes or
    /// scans. The one surviving hardcoded folder literal (the Mac's
    /// "already in processing?" check) is pinned here BY VALUE so renaming
    /// DriveFolder.processing without updating it fails loudly instead of
    /// silently re-processing every file.
    @Test func driveFolderNamesAreReferencedThroughTheSharedConstants() throws {
        let folders = NativeAgentICloudBridgeConstants.DriveFolder.self
        #expect(folders.outboxMac == "outbox/mac")
        #expect(folders.outboxIos == "outbox/ios")
        #expect(folders.processing == "processing")
        #expect(folders.processed == "processed")

        let mac = try ICloudFenceRepo.text("Sources/NativeAgentApp/iCloudBridge.swift")
        #expect(
            mac.contains("[DriveFolder.outboxMac, DriveFolder.outboxIos, DriveFolder.processing, DriveFolder.processed]"),
            "the Mac must create every Drive folder it later scans"
        )
        // The known hardcoded site, pinned to the constant's current value.
        #expect(
            mac.contains("!= \"\(folders.processing)\""),
            "Sources/NativeAgentApp/iCloudBridge.swift compares against a hardcoded folder name; it must match DriveFolder.processing"
        )

        let ios = try ICloudFenceRepo.text("iOS/NativeAgentMobile/Sources/iCloudBridge.swift")
        #expect(
            ios.contains("[DriveFolder.outboxMac, DriveFolder.outboxIos, DriveFolder.processed]"),
            "iOS creates the three folders it uses; `processing` is Mac-owned"
        )
        // iOS writes ios outbox, scans mac outbox — both through the constants.
        #expect(ios.contains("DriveFolder.outboxIos"))
        #expect(ios.contains("DriveFolder.outboxMac"))
    }

    private static func xcconfigValue(_ name: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(name) else { continue }
            let rest = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            return rest.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - shared.deviceSyncError.userStrings

@Suite("DeviceSyncError user-facing strings")
struct DeviceSyncErrorUserStringTests {

    /// Every case must produce a sentence the user can act on. A swallowed
    /// case renders as a bare "device sync error: …" with no advice — the
    /// text nothing else tests because nothing else reads it.
    @Test func everyCaseYieldsADistinctNonEmptyActionableSentence() {
        let cases: [DeviceSyncError] = [
            .notConfigured,
            .unauthorized,
            .quotaExceeded,
            .conflict,
            .payloadTooLarge(actualBytes: 900 * 1024, maximumBytes: 800 * 1024),
            .transient(message: "cloudd restarted"),
            .underlying(message: "record decode failed"),
        ]
        var seen = Set<String>()
        for error in cases {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty, "\(error) has no user-facing description")
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == text)
            #expect(seen.insert(text).inserted, "duplicate user string: \(text)")
        }
        // The associated-value cases must carry their message verbatim.
        #expect(DeviceSyncError.transient(message: "cloudd restarted").errorDescription?.contains("cloudd restarted") == true)
        #expect(DeviceSyncError.underlying(message: "record decode failed").errorDescription?.contains("record decode failed") == true)
    }

    /// payloadTooLarge is the only case that computes numbers for the user.
    /// A wrong divisor prints a nonsense limit; a missing floor prints
    /// "0 KB", which reads as "your message is empty and too large".
    @Test func payloadTooLargeNamesBothSizesInKBAndNeverPrintsZero() {
        let overLimit = DeviceSyncError.payloadTooLarge(
            actualBytes: 900 * 1024,
            maximumBytes: 800 * 1024
        ).errorDescription ?? ""
        #expect(overLimit.contains("(900 KB;"), "actual size must be rendered in KB: \(overLimit)")
        #expect(overLimit.contains("limit 800 KB"), "limit must be rendered in KB: \(overLimit)")

        // A sub-kilobyte actual must floor to 1 KB, not truncate to 0 — the
        // divisor with no floor prints "(0 KB; limit 800 KB)", which reads as
        // "your empty message is too large".
        let tiny = DeviceSyncError.payloadTooLarge(
            actualBytes: 500,
            maximumBytes: 800 * 1024
        ).errorDescription ?? ""
        #expect(tiny.contains("(1 KB;"), "sub-KB payloads must floor to 1 KB: \(tiny)")
        #expect(!tiny.contains("(0 KB"), "never tell the user their payload is 0 KB: \(tiny)")

        // And it must tell the user what to DO, not just what failed.
        #expect(overLimit.lowercased().contains("smaller"))
    }

    /// isNotConfigured is the crash-guard signal read by callers that must
    /// not construct a CKContainer. It must match exactly one case.
    @Test func isNotConfiguredMatchesOnlyTheNotConfiguredCase() {
        #expect(DeviceSyncError.notConfigured.isNotConfigured)
        for other: DeviceSyncError in [
            .unauthorized, .quotaExceeded, .conflict,
            .payloadTooLarge(actualBytes: 1, maximumBytes: 2),
            .transient(message: "x"), .underlying(message: "y"),
        ] {
            #expect(!other.isNotConfigured, "\(other) must not report notConfigured")
        }
    }
}

// MARK: - shared.cloudkit.isDeviceSyncNotification

#if canImport(CloudKit) && !os(Linux)
@Suite("Device-sync push recognition")
struct DeviceSyncNotificationRecognitionTests {

    private func queryPush(subscriptionID: String) -> [AnyHashable: Any] {
        // The shape CKNotification parses out of an APNs payload.
        [
            "ck": [
                "ce": 2,
                "cid": NativeAgentICloudBridgeConstants.defaultContainerID,
                "nid": UUID().uuidString,
                "qry": [
                    "sid": subscriptionID,
                    "dbs": 2,
                    "fo": 1,
                    "rid": "record-\(UUID().uuidString)",
                ],
            ],
        ]
    }

    /// Returning false for a real device-sync push means drainIfDeviceSyncPush
    /// never fires and every message waits for the next foreground activation.
    @Test func recognizesEveryCurrentAndLegacySubscriptionID() throws {
        let ids = DeviceCloudKitSubscriptionID.current + DeviceCloudKitSubscriptionID.legacy
        #expect(ids.count >= 11)
        for id in ids {
            let userInfo = queryPush(subscriptionID: id)
            // Guard the instrument itself: if CKNotification cannot parse the
            // synthetic dictionary the assertion below would be vacuous.
            let parsed = CKNotification(fromRemoteNotificationDictionary: userInfo)
            try #require(parsed != nil, "synthetic push for \(id) did not parse as a CKNotification")
            try #require(parsed?.subscriptionID == id, "synthetic push lost its subscriptionID")
            #expect(
                CloudKitDeviceTransport.isDeviceSyncNotification(userInfo),
                "\(id) must be recognized as a device-sync push"
            )
        }
    }

    /// Returning true for a foreign push is the other half: a drain storm on
    /// every unrelated notification.
    @Test func rejectsForeignAndMalformedPushes() {
        let foreign = CloudKitDeviceTransport.isDeviceSyncNotification(
            queryPush(subscriptionID: "SomeOtherApp.subscription")
        )
        #expect(foreign == false)

        let blankSubscription = CloudKitDeviceTransport.isDeviceSyncNotification(
            queryPush(subscriptionID: "")
        )
        #expect(blankSubscription == false)

        // A plain APNs alert carries no `ck` key at all.
        let plainAlert: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Hi"]],
            "screen": "activity",
        ]
        #expect(CloudKitDeviceTransport.isDeviceSyncNotification(plainAlert) == false)

        let empty: [AnyHashable: Any] = [:]
        #expect(CloudKitDeviceTransport.isDeviceSyncNotification(empty) == false)
    }

    /// The recognizer must not accept a near-miss id — subscription ids are
    /// the only thing separating our pushes from everyone else's.
    @Test func nearMissSubscriptionIDsAreNotRecognized() {
        for near in [
            DeviceCloudKitSubscriptionID.chat + ".v2",
            DeviceCloudKitSubscriptionID.chat.uppercased(),
            " " + DeviceCloudKitSubscriptionID.status,
        ] {
            #expect(
                !DeviceCloudKitSubscriptionID.recognizes(near),
                "\(near) must not be recognized"
            )
        }
    }
}
#endif

// MARK: - shared.mobileDeskSnapshot.models

@Suite("Mobile desk snapshot decode contract")
struct MobileDeskSnapshotDecodeTests {

    /// The Mac's desk.json wire vocabulary, spelled out. A rename on the Mac
    /// makes this Decodable throw, loadSnapshotArrayAsync returns nil, and the
    /// Desk tab renders an empty list that is visually identical to "nothing
    /// on your desk". This test is the tripwire for that rename.
    private static let macWireItem = """
    {
      "handle": "d-1042",
      "alias": "evals",
      "parent": null,
      "kind": "thread",
      "status": "open",
      "project": "NativeAgent",
      "title": "Coverage ledger burn-down",
      "summary": "wave A integration",
      "openedAt": "2026-08-20T14:02:11Z",
      "updatedAt": "2026-08-23T09:41:00Z",
      "closedAt": null,
      "pinned": true,
      "blockedReason": null,
      "waitingOn": null,
      "blockedOn": ["d-1010"],
      "deferUntil": null,
      "origin": "mac",
      "requiresOwnerInput": false,
      "recentNotes": [{"timestamp": "2026-08-23T09:40:00Z", "text": "wave resumed"}]
    }
    """

    @Test func decodesTheMacWireVocabularyWithoutNilCollapse() throws {
        let json = Data("[\(Self.macWireItem)]".utf8)
        let items = try JSONDecoder().decode([MobileDeskItem].self, from: json)
        #expect(items.count == 1)
        let item = try #require(items.first)
        // Non-zero and non-collapsed: the fields the card actually renders.
        #expect(item.handle == "d-1042")
        #expect(item.id == item.handle, "Identifiable id must be the stable handle, not the display alias")
        #expect(item.title == "Coverage ledger burn-down")
        #expect(item.status == "open")
        #expect(item.project == "NativeAgent")
        #expect(item.pinned)
        #expect(item.blockedOn == ["d-1010"])
        #expect(item.recentNotes.count == 1)
        #expect(item.recentNotes.first?.text == "wave resumed")
    }

    /// A Mac-side field ADDITION must not break the phone (forward compat),
    /// but a REQUIRED field rename must throw rather than decode to an empty
    /// or default-filled card — a silently defaulted card is worse than none.
    @Test func unknownKeysAreToleratedButRenamedRequiredKeysThrow() throws {
        let extended = Self.macWireItem.replacingOccurrences(
            of: "\"origin\": \"mac\"",
            with: "\"origin\": \"mac\", \"macOnlyFutureField\": {\"a\": 1}"
        )
        let tolerated = try JSONDecoder().decode([MobileDeskItem].self, from: Data("[\(extended)]".utf8))
        #expect(tolerated.count == 1)

        for renamed in ["handle", "title", "status", "recentNotes"] {
            let broken = Self.macWireItem.replacingOccurrences(
                of: "\"\(renamed)\":",
                with: "\"\(renamed)_v2\":"
            )
            #expect(throws: (any Error).self, "renaming \(renamed) must throw, not silently default") {
                try JSONDecoder().decode([MobileDeskItem].self, from: Data("[\(broken)]".utf8))
            }
        }
    }

    /// Optional fields must survive a round trip as nil rather than becoming
    /// empty strings — "waiting on ''" renders as a live blocker with no name.
    @Test func optionalFieldsRoundTripAsNilNotEmptyString() throws {
        let item = try JSONDecoder().decode(
            [MobileDeskItem].self,
            from: Data("[\(Self.macWireItem)]".utf8)
        )[0]
        #expect(item.parent == nil)
        #expect(item.closedAt == nil)
        #expect(item.blockedReason == nil)
        #expect(item.waitingOn == nil)
        #expect(item.deferUntil == nil)

        let reencoded = try JSONEncoder().encode(item)
        let again = try JSONDecoder().decode(MobileDeskItem.self, from: reencoded)
        #expect(again == item)
    }
}

// MARK: - shared.snapshotModels.decodeContracts

@Suite("Mobile snapshot group manifest")
struct MobileSnapshotGroupManifestTests {

    /// The manifest is the routing table between the Mac's snapshot writer and
    /// every iOS screen. If a filename appears in no group, the Mac never
    /// bundles it and the screen that reads it is permanently empty; if it
    /// appears in two, one group's write silently clobbers the other's.
    @Test func manifestIsAPartitionWithNoEmptyGroups() {
        var owner: [String: NAMobileSnapshotGroup] = [:]
        for group in NAMobileSnapshotGroup.allCases {
            #expect(!group.filenames.isEmpty, "\(group.rawValue) carries no files")
            #expect(group.statusKey == "mobile_snapshot_\(group.rawValue)_v1")
            for name in group.filenames {
                #expect(name.hasSuffix(".json"))
                #expect(!name.contains("/"), "\(name) must be a bare filename")
                #expect(owner[name] == nil, "\(name) is claimed by both \(String(describing: owner[name])) and \(group.rawValue)")
                owner[name] = group
            }
        }
        // 24 → 23 on 2026-08-28: command_palette.json retired (E8 audit) —
        // Mac writer deleted, retired-file sweep in place, no iOS reader.
        // 23 → 24 on 2026-09-01: snapshot_staleness.json added (sweep item 2) —
        // the per-group staleness marker the phone badges Memory and Knowledge
        // Graph with.
        // 24 → 25 on 2026-09-06: chat_anchor.json added in 7df7a4cd (Fable 5.1
        // sweep wave 2) — the conversation anchor pin. Mac writer:
        // MacSyncEngine+Snapshots.swift write(anchor, to: "chat_anchor.json");
        // iOS readers: iCloudSyncEngine+Snapshots.swift loads it as
        // ConversationAnchorPin. Both ends present, so the partition holds.
        // 25 → 26 on 2026-09-12: desk_bounds.json added — the Mac's explicit
        // Desk omission metadata (omittedCount / truncated). Mac writer:
        // MacSyncEngine+Snapshots.swift write(MobileDeskProjectionReport…);
        // iOS reader: iCloudSyncEngine+Snapshots.swift loads it as
        // MobileDeskProjectionReport and DeskView shows the boundary from it.
        #expect(owner.count == 26, "manifest size changed — confirm every consumer was updated (was 26)")
        // groups(containingAny:) must resolve each filename to exactly its owner.
        for (name, group) in owner {
            #expect(NAMobileSnapshotGroup.groups(containingAny: [name]) == [group])
        }
        #expect(NAMobileSnapshotGroup.groups(containingAny: ["not_a_snapshot.json"]).isEmpty)
    }

    /// THE dominant silent-zero of this fence, guarded at the seam: every
    /// snapshot file an iOS screen loads must be carried by some group. A file
    /// iOS reads but the Mac never bundles is an empty screen forever, with no
    /// error anywhere.
    @Test func everySnapshotFileIOSLoadsIsCarriedByAGroup() throws {
        var loaded = Set<String>()
        for file in try ICloudFenceRepo.swiftFiles(under: "iOS/NativeAgentMobile/Sources") {
            for name in Self.snapshotFilenames(in: file.text) { loaded.insert(name) }
        }
        #expect(loaded.count >= 20, "filename scrape found only \(loaded.count) — the `named:` idiom changed")

        let carried = Set(NAMobileSnapshotGroup.allCases.flatMap(\.filenames))
        let orphans = loaded.subtracting(carried).sorted()
        #expect(orphans.isEmpty, "iOS loads snapshot files no group bundles: \(orphans)")

        // The other direction is a payload-waste ratchet, not a correctness
        // bug: the Mac compresses and ships these on every sync. E8 retired
        // command_palette.json (the last unread one, 2026-08-28); any NEW
        // bundled-but-never-read file fails here.
        let unread = carried.subtracting(loaded).sorted()
        #expect(
            unread.isEmpty,
            "the set of Mac-bundled-but-never-read snapshots changed: \(unread)"
        )
    }

    /// The status codec is the envelope those files travel in. A group
    /// mismatch must be rejected rather than decoded into the wrong cache.
    @Test func statusEnvelopeRejectsCrossGroupAndTamperedPayloads() throws {
        let files = ["desk.json": Data(#"[{"handle":"d-1"}]"#.utf8)]
        let encoded = try NAMobileSnapshotStatusCodec.encode(group: .desk, files: files)

        let roundTripped = try NAMobileSnapshotStatusCodec.decode(encoded, expectedGroup: .desk)
        #expect(roundTripped == files)

        // Same bytes, wrong group → must throw, never return an empty dict.
        #expect(throws: (any Error).self) {
            try NAMobileSnapshotStatusCodec.decode(encoded, expectedGroup: .activity)
        }

        // A flipped digest character must be caught, not silently decoded.
        let tampered = encoded.replacingOccurrences(
            of: "\"payloadSHA256\":\"",
            with: "\"payloadSHA256\":\"0"
        )
        #expect(tampered != encoded, "digest field shape changed — this test would be vacuous")
        #expect(throws: (any Error).self) {
            try NAMobileSnapshotStatusCodec.decode(tampered, expectedGroup: .desk)
        }
    }

    private static func snapshotFilenames(in text: String) -> [String] {
        var out: [String] = []
        var search = text[...]
        let marker = "named: \""
        while let start = search.range(of: marker) {
            let rest = search[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let name = String(rest[..<end])
            if name.hasSuffix(".json") { out.append(name) }
            search = rest[end...]
        }
        return out
    }
}
