import Testing
@testable import ChatType

@Test
func appIdentityDefaultsUseThePublicNamespace() throws {
    let identity = try AppIdentity(info: [:])
    #expect(identity.chatGPTSessionService == "io.github.felixlark.ChatType.chatgpt-session")
    #expect(identity.doubaoService == "io.github.felixlark.ChatType.doubao")
    #expect(identity.glmService == "io.github.felixlark.ChatType.glm")
    #expect(identity.qwenService == "io.github.felixlark.ChatType.qwen")
}

@Test
func appIdentityKeepsFourExactIndependentServiceValues() throws {
    let values = ["example.ChatGPT.Session", "example.doubao", "EXAMPLE.GLM.Key", "Example.Qwen.Key"]
    let info = Dictionary(uniqueKeysWithValues: zip(AppIdentity.serviceFields, values))
    let identity = try AppIdentity(info: info)
    #expect(identity.chatGPTSessionService == values[0])
    #expect(identity.doubaoService == values[1])
    #expect(identity.glmService == values[2])
    #expect(identity.qwenService == values[3])
}

@Test
func appIdentityRejectsPartialOrInvalidPackagedFields() throws {
    let fields = AppIdentity.serviceFields
    for invalid: Any in ["", "   ", 42] {
        var info: [String: Any] = Dictionary(uniqueKeysWithValues: fields.map { ($0, "example.synthetic") })
        info[fields[1]] = invalid
        #expect(throws: AppIdentity.IdentityError.incompleteServices) { try AppIdentity(info: info) }
    }
    #expect(throws: AppIdentity.IdentityError.incompleteServices) {
        try AppIdentity(info: [fields[0]: "example.synthetic"])
    }
}
