import XCTest
@testable import NativeAgentApp

/// Badge visibility for a ChatGPT sign-in adopted from the shared Codex CLI
/// home (stabilization item from the 0.3.8 public test: an adopted
/// `~/.codex/auth.json` session looked identical to an in-app sign-in).
/// These tests cover the pure, path-injected pieces; the shared-home path
/// comparison itself is exercised only through its inputs because the
/// resolver reads the real home directory.
final class OAuthCLISessionAdoptionTests: XCTestCase {

    private func tempAuthFile(json: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        return url
    }

    /// Unsigned JWT with the given payload (header/signature are ignored by
    /// the display-only parser).
    private func fakeJWT(payload: [String: Any]) throws -> String {
        let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        let body = try JSONSerialization.data(withJSONObject: payload)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(body).sig"
    }

    func testEmailFromIdTokenClaim() throws {
        let jwt = try fakeJWT(payload: ["email": "person@example.com"])
        let url = try tempAuthFile(json: ["tokens": ["id_token": jwt]])
        XCTAssertEqual(NativeOAuthFlow.openAIAccountEmail(at: url), "person@example.com")
    }

    func testEmailFromAccessTokenProfileClaim() throws {
        let jwt = try fakeJWT(payload: [
            "https://api.openai.com/profile": ["email": "profile@example.com"],
        ])
        let url = try tempAuthFile(json: ["tokens": ["access_token": jwt]])
        XCTAssertEqual(NativeOAuthFlow.openAIAccountEmail(at: url), "profile@example.com")
    }

    func testIdTokenEmailWinsOverAccessTokenProfile() throws {
        let idJWT = try fakeJWT(payload: ["email": "id@example.com"])
        let accessJWT = try fakeJWT(payload: [
            "https://api.openai.com/profile": ["email": "access@example.com"],
        ])
        let url = try tempAuthFile(json: [
            "tokens": ["id_token": idJWT, "access_token": accessJWT],
        ])
        XCTAssertEqual(NativeOAuthFlow.openAIAccountEmail(at: url), "id@example.com")
    }

    func testNoEmailClaimReturnsNil() throws {
        let jwt = try fakeJWT(payload: ["sub": "user-123"])
        let url = try tempAuthFile(json: ["tokens": ["id_token": jwt]])
        XCTAssertNil(NativeOAuthFlow.openAIAccountEmail(at: url))
    }

    func testMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-missing-\(UUID().uuidString)")
            .appendingPathComponent("auth.json")
        XCTAssertNil(NativeOAuthFlow.openAIAccountEmail(at: url))
    }

    func testMalformedTokenReturnsNilNotCrash() throws {
        let url = try tempAuthFile(json: ["tokens": ["id_token": "not-a-jwt"]])
        XCTAssertNil(NativeOAuthFlow.openAIAccountEmail(at: url))
    }

    // MARK: - Adoption detection (injected paths — never the real home)

    /// A CLI home whose auth.json carries a usable token and an email claim.
    private func makeCLIHome(email: String? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var tokens: [String: Any] = ["access_token": "usable-token"]
        if let email {
            tokens["id_token"] = try fakeJWT(payload: ["email": email])
        }
        let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens])
        try data.write(to: home.appendingPathComponent("auth.json"))
        return home
    }

    func testAdoptedCLISessionYieldsLabelWithEmail() throws {
        let home = try makeCLIHome(email: "person@example.com")
        let detail = NativeOAuthFlow.openAIAdoptedCLISessionDetail(
            activeAuthPath: home.appendingPathComponent("auth.json"),
            sharedCLIHome: home
        )
        XCTAssertEqual(detail, "using your Codex CLI sign-in (person@example.com)")
    }

    func testAdoptedCLISessionWithoutEmailFallsBackToPathLabel() throws {
        let home = try makeCLIHome(email: nil)
        let detail = NativeOAuthFlow.openAIAdoptedCLISessionDetail(
            activeAuthPath: home.appendingPathComponent("auth.json"),
            sharedCLIHome: home
        )
        XCTAssertEqual(detail, "using your Codex CLI sign-in (~/.codex)")
    }

    func testAppOwnedPathIsNotLabeledAdopted() throws {
        let cliHome = try makeCLIHome(email: "person@example.com")
        let appOwnedHome = try makeCLIHome(email: "person@example.com")
        let detail = NativeOAuthFlow.openAIAdoptedCLISessionDetail(
            activeAuthPath: appOwnedHome.appendingPathComponent("auth.json"),
            sharedCLIHome: cliHome
        )
        XCTAssertNil(detail)
    }

    func testUnusableTokensAtSharedPathYieldNil() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": ""]])
        try data.write(to: home.appendingPathComponent("auth.json"))
        let detail = NativeOAuthFlow.openAIAdoptedCLISessionDetail(
            activeAuthPath: home.appendingPathComponent("auth.json"),
            sharedCLIHome: home
        )
        XCTAssertNil(detail)
    }

    /// Reviewer-required case: an explicit CODEX_HOME override pointing at an
    /// unusable path must report NOT signed in even while a usable CLI
    /// session exists elsewhere — execution will use the override and fail,
    /// so the badge must not claim credentials execution won't read.
    func testEnvOverrideUnusableBeatsUsableCLIHome() throws {
        let usableCLIHome = try makeCLIHome(email: "person@example.com")
        let emptyOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyOverride, withIntermediateDirectories: true)
        let active = NativeOAuthFlow.openAIActiveAuthPath(
            environment: ["CODEX_HOME": emptyOverride.path],
            userCodexHome: usableCLIHome
        )
        XCTAssertNil(active)
    }

    // MARK: - Consent offer (injected consent — never the live record)

    func testOfferShownWithEmailWhenNoDecisionRecorded() throws {
        let home = try makeCLIHome(email: "person@example.com")
        XCTAssertEqual(
            NativeOAuthFlow.codexCLISessionOffer(sharedCLIHome: home, consentState: .missing),
            .available(email: "person@example.com", alreadyDeclined: false)
        )
    }

    func testOfferStaysVisibleButMarkedAfterDecline() throws {
        let home = try makeCLIHome(email: "person@example.com")
        XCTAssertEqual(
            NativeOAuthFlow.codexCLISessionOffer(sharedCLIHome: home, consentState: .declined),
            .available(email: "person@example.com", alreadyDeclined: true)
        )
    }

    func testOfferHiddenOnceAllowed() throws {
        let home = try makeCLIHome(email: "person@example.com")
        XCTAssertNil(NativeOAuthFlow.codexCLISessionOffer(sharedCLIHome: home, consentState: .allowed))
    }

    func testNoOfferWithoutUsableCLISession() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-nooffer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(NativeOAuthFlow.codexCLISessionOffer(sharedCLIHome: empty, consentState: .missing))
    }

    func testCorruptConsentIsVisibleEvenWithoutUsableCLISession() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(
            NativeOAuthFlow.codexCLISessionOffer(
                sharedCLIHome: empty,
                consentState: .corrupt(reason: "fixture corrupt authority")
            ),
            .unavailable(reason: "fixture corrupt authority")
        )
    }

    func testSymlinkedActivePathStillDetectedAsAdopted() throws {
        let home = try makeCLIHome(email: "person@example.com")
        let linkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthCLIAdoptionTests-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: home.appendingPathComponent("auth.json")
        )
        let detail = NativeOAuthFlow.openAIAdoptedCLISessionDetail(
            activeAuthPath: link,
            sharedCLIHome: home
        )
        XCTAssertEqual(detail, "using your Codex CLI sign-in (person@example.com)")
    }
}
