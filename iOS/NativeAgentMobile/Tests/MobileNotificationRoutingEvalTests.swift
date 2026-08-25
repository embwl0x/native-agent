import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`, row
/// `ios.content.notificationScreenRouting`.
///
/// Silent-failure class: WRONG VALUE. `ContentView.tab(forNotificationScreen:)`
/// defaults EVERY unrecognised screen to `.activity`. A push aimed at Skills or
/// Chat therefore lands on the wrong tab and nothing anywhere reports it — the
/// user just taps a notification and finds the wrong screen.
///
/// The routing switch is private to the view, so this reads the emitted-vs-routed
/// vocabulary off the real sources on both sides of the wire: every `screen`
/// value the Mac or the phone actually PUTS in a notification payload must have
/// an EXPLICIT case in the router, never the silent default.
final class MobileNotificationRoutingEvalTests: XCTestCase {

    func test_everyEmittedNotificationScreenHasAnExplicitRouteNotTheSilentDefault() throws {
        let contentView = try MobileEvalSources.mobileSource("ContentView.swift")
        guard let switchStart = contentView.range(of: "func tab(forNotificationScreen screen: String) -> Tab {"),
              let switchEnd = contentView.range(
                of: "default: return .activity", range: switchStart.upperBound..<contentView.endIndex
              ) else {
            return XCTFail("could not locate tab(forNotificationScreen:) — the notification router moved or was renamed")
        }
        let routerBody = String(contentView[switchStart.upperBound..<switchEnd.lowerBound])
        let routed = Set(MobileEvalSources.matches(#""([a-z_\-]+)""#, in: routerBody))
        XCTAssertGreaterThan(routed.count, 3, "parsed almost no routed screens — parser drift, not app drift")

        // Everything that writes a `screen` into a notification payload, on
        // either side of the wire.
        let emitters = [
            "Sources/NativeAgentApp",
            "iOS/NativeAgentMobile/Sources",
        ]
        let root = try MobileEvalSources.repoRoot()
        var emitted: Set<String> = []
        for relative in emitters {
            let directory = root.appendingPathComponent(relative)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            XCTAssertFalse(files.isEmpty, "no sources found under \(relative)")
            for name in files where name.hasSuffix(".swift") {
                let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
                emitted.formUnion(MobileEvalSources.matches(#""screen":\s*"([a-z_\-]+)""#, in: text))
            }
        }
        XCTAssertFalse(emitted.isEmpty, "found no notification screen emitters at all — the scan, not the app, is broken")

        let unrouted = emitted.subtracting(routed)
        XCTAssertTrue(
            unrouted.isEmpty,
            """
            \(unrouted.sorted()) are emitted in notification payloads but have no explicit case in
            tab(forNotificationScreen:). They silently fall through to the Activity tab, so tapping
            those notifications opens the wrong screen with no error anywhere.
            """
        )
    }

    func test_theLaunchArgumentTabVocabularyCoversTheSameScreensAsTheRouter() throws {
        // `-initialTab` (used by the ui-walk tier) and the notification router
        // are two independent switches over the same screen names. If they
        // diverge, an automated walk verifies a tab a real push can never reach.
        let contentView = try MobileEvalSources.mobileSource("ContentView.swift")
        guard let argsStart = contentView.range(of: "private static func initialTabFromLaunchArgs() -> Tab {"),
              let argsEnd = contentView.range(
                of: "default: return .chat", range: argsStart.upperBound..<contentView.endIndex
              ) else {
            return XCTFail("could not locate initialTabFromLaunchArgs()")
        }
        let argsBody = String(contentView[argsStart.upperBound..<argsEnd.lowerBound])
        let launchNames = Set(MobileEvalSources.matches(#""([a-z_\-]+)""#, in: argsBody))

        guard let routerStart = contentView.range(of: "func tab(forNotificationScreen screen: String) -> Tab {"),
              let routerEnd = contentView.range(
                of: "default: return .activity", range: routerStart.upperBound..<contentView.endIndex
              ) else {
            return XCTFail("could not locate tab(forNotificationScreen:)")
        }
        let routed = Set(MobileEvalSources.matches(
            #""([a-z_\-]+)""#, in: String(contentView[routerStart.upperBound..<routerEnd.lowerBound])
        ))

        XCTAssertFalse(launchNames.isEmpty)
        XCTAssertTrue(
            routed.subtracting(launchNames).isEmpty,
            "\(routed.subtracting(launchNames).sorted()) can be reached by a push but not by -initialTab, so the ui-walk tier cannot open them"
        )
    }

    /// Coverage-ledger fence `ios.screens`, row
    /// `ios.content.initialTabFromLaunchArgs`.
    ///
    /// These are the actual launch arguments used by the simulator/UI-walk
    /// path. Exercise the production parser through its injected argument
    /// seam rather than changing process-global arguments, which would race
    /// the rest of the iOS test bundle.
    func test_initialTabLaunchArgumentsRouteEveryAcceptedAliasAndFallbackToChat() {
        let expectedRoutes: [(alias: String, tab: ContentView.Tab)] = [
            ("chat", .chat),
            ("activity", .activity),
            ("approvals", .activity),
            ("inbox", .activity),
            ("memory", .memories),
            ("memories", .memories),
            ("skills", .skills),
            ("missions", .more),
            ("workshop", .more),
            ("more", .more),
            ("advanced", .more),
            ("settings", .more),
            ("mac_integration", .more),
            ("macintegration", .more),
            ("mac-integration", .more),
        ]

        for route in expectedRoutes {
            XCTAssertEqual(
                ContentView.initialTab(fromLaunchArguments: ["NativeAgentMobile", "-initialTab", route.alias]),
                route.tab,
                "-initialTab \(route.alias) landed on the wrong tab"
            )
        }

        XCTAssertEqual(
            ContentView.initialTab(fromLaunchArguments: ["NativeAgentMobile", "-initialTab", "retired_surface"]),
            .chat,
            "unknown launch tabs must fail safely to Chat"
        )
    }

    /// Coverage-ledger fence `ios.screens`, row `ios.desk.addItem`.
    ///
    /// The iOS creation picker owns a deliberately smaller catalog than the
    /// canonical Desk store may eventually accept. It must never offer a kind
    /// that the store rejects after the user has filled in the sheet.
    func test_mobileDeskAddItemKindsAreAcceptedByTheCanonicalDeskKindEnum() throws {
        let mobileKinds = Set(MobileDeskItemKind.allCases.map(\.rawValue))
        XCTAssertFalse(mobileKinds.isEmpty, "the mobile Desk picker must offer at least one kind")

        let deskModels = try MobileEvalSources.repoFile(
            "Modules/NativeAgentCore/Sources/PersistenceCore/DeskModels.swift"
        )
        guard let deskKindBody = MobileEvalSources.blockBody(
            named: "DeskKind", keyword: "public enum", in: deskModels
        ) else {
            return XCTFail("could not locate canonical DeskKind enum")
        }

        let canonicalKinds = Set(deskKindBody
            .split(whereSeparator: \.isNewline)
            .flatMap { line -> [String] in
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("case ") else { return [] }
                return trimmed
                    .dropFirst("case ".count)
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            })
        XCTAssertFalse(canonicalKinds.isEmpty, "parsed no canonical DeskKind cases")
        XCTAssertTrue(
            mobileKinds.isSubset(of: canonicalKinds),
            "iOS offers \(mobileKinds.subtracting(canonicalKinds).sorted()) as Desk kinds, but the canonical store rejects them"
        )
    }
}
