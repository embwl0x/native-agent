import Testing
@testable import TrustCenter

@Test func conversationSurfaceProfileClassifiesEveryRemoteAliasFromOneOwner() {
    for id in ConversationSurfaceProfile.remoteSurfaceIDs {
        #expect(ConversationSurfaceProfile(id).isRemote)
    }
    #expect(ConversationSurfaceProfile("  i_phone  ").isRemote)
    #expect(ConversationSurfaceProfile("CHAT").isRemote == false)
    #expect(ConversationSurfaceProfile("codex_bridge").isRemote == false)
}

@Test func iosRemoteIsStrictSubsetOfRemote() {
    for id in ConversationSurfaceProfile.iosRemoteSurfaceIDs {
        let profile = ConversationSurfaceProfile(id)
        #expect(profile.isIOSRemote)
        #expect(profile.isRemote)
    }
    #expect(ConversationSurfaceProfile("telegram").isIOSRemote == false)
    #expect(ConversationSurfaceProfile("slack").isIOSRemote == false)
}
