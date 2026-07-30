import Testing
@testable import NativeAgentApp

@Test
func codexDeviceLoginParsesOneTimeCodeNotAuthorization() {
    let output = """
    Welcome to Codex [v0.141.0]
    OpenAI's command-line coding agent

    Follow these steps to sign in with ChatGPT using device code authorization:

    1. Open this link in your browser and sign in to your account
       https://auth.openai.com/codex/device

    2. Enter this one-time code (expires in 15 minutes)
       EJSE-LP1UT

    Device codes are a common phishing target. Never share this code.
    """

    #expect(SwiftCodexDeviceLoginManager.extractCode(from: output) == "EJSE-LP1UT")
}

@Test
func codexDeviceLoginDoesNotTreatAuthorizationAsCode() {
    let output = "Follow these steps to sign in with ChatGPT using device code authorization:"

    #expect(SwiftCodexDeviceLoginManager.extractCode(from: output) == nil)
}
