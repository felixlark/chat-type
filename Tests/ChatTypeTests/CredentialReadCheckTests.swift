import Foundation
import LocalAuthentication
import Security
import Testing
@testable import ChatType

@Test
func credentialReadCheckUsesOriginalQueriesAndCannotPrompt() throws {
    var calls = 0
    let report = CredentialReadCheck.read { query in
        let service = CredentialReadCheck.Service.allCases[calls]
        var original = query
        let context = original.removeValue(forKey: kSecUseAuthenticationContext as String) as? LAContext
        #expect(context?.interactionNotAllowed == true)
        #expect(NSDictionary(dictionary: original).isEqual(to: service.query))
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecValueData as String] == nil)
        calls += 1
        return (errSecSuccess, Data("synthetic credential".utf8) as CFData)
    }
    #expect(calls == 4)
    #expect(report.results.map(\.service) == CredentialReadCheck.Service.allCases)
    #expect(report.results.allSatisfy { $0.state == .readable })
    let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    #expect(!json.contains("synthetic credential"))
    for service in CredentialReadCheck.Service.allCases {
        let query = service.query
        #expect(!json.contains(try #require(query[kSecAttrService as String] as? String)))
        #expect(!json.contains(try #require(query[kSecAttrAccount as String] as? String)))
    }
}

@Test
func credentialReadCheckPreservesSyntheticServiceAccountAndReadOptions() {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: "Example.CaseSensitive.Service",
                               kSecAttrAccount as String: "fixture-account",
                               kSecReturnData as String: true,
                               kSecMatchLimit as String: kSecMatchLimitOne]
    let result = CredentialReadCheck.check(service: .doubao, query: query) { received in
        #expect(received[kSecAttrService as String] as? String == "Example.CaseSensitive.Service")
        #expect(received[kSecAttrAccount as String] as? String == "fixture-account")
        #expect(received[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect((received[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        return (errSecSuccess, Data([0xFF]) as CFData)
    }
    #expect(result.state == .readable)
}

@Test
func credentialReadCheckDoesNotTreatMetadataOrAuthenticationFailureAsReadable() {
    let cases: [(OSStatus, CFTypeRef?, CredentialReadCheck.State, OSStatus)] = [
        (errSecItemNotFound, nil, .notFound, errSecItemNotFound),
        (errSecInteractionNotAllowed, nil, .osStatus, errSecInteractionNotAllowed),
        (errSecAuthFailed, nil, .osStatus, errSecAuthFailed),
        (errSecSuccess, nil, .osStatus, errSecDecode),
        (errSecSuccess, ["metadata": true] as CFDictionary, .osStatus, errSecDecode),
    ]
    for (status, value, expectedState, expectedStatus) in cases {
        let result = CredentialReadCheck.check(service: .glm, query: [:]) { _ in (status, value) }
        #expect(result.state == expectedState)
        #expect(result.osStatus == expectedStatus)
    }
}

@Test
func credentialReadCheckRejectsServiceOverridesAndBadOutputBeforeReading() throws {
    for arguments in [[], ["--output", "relative.json"], ["--output", "/tmp/out", "--service", "arbitrary"]] {
        #expect(throws: CredentialReadCheckCommand.CommandError.usage) {
            try CredentialReadCheckCommand.run(arguments: arguments) { _ in
                Issue.record("Invalid CLI arguments reached Keychain")
                return (errSecSuccess, nil)
            }
        }
    }
    #expect(throws: CredentialReadCheckCommand.CommandError.privateDirectoryRequired) {
        try CredentialReadCheckCommand.run(arguments: ["--output", "/tmp/chattype-public-result.json"]) { _ in
            Issue.record("Public output directory reached Keychain")
            return (errSecSuccess, nil)
        }
    }
}

@Test
func credentialReadCheckWritesOnlyPrivateRedactedReportAndKeepsExistingFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("result.json")
    var calls = 0
    try CredentialReadCheckCommand.run(arguments: ["--output", output.path]) { _ in
        calls += 1
        return (errSecSuccess, Data("never serialize this synthetic value".utf8) as CFData)
    }
    #expect(calls == 4)
    let data = try Data(contentsOf: output)
    let report = try JSONDecoder().decode(CredentialReadCheck.Report.self, from: data)
    #expect(report.results.count == 4)
    #expect(!String(decoding: data, as: UTF8.self).contains("never serialize"))
    let mode = try #require(FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)
    #expect(mode.uint16Value & 0o777 == 0o600)
    #expect(throws: CredentialReadCheckCommand.CommandError.outputUnavailable) {
        try CredentialReadCheckCommand.run(arguments: ["--output", output.path]) { _ in
            Issue.record("Existing output reached Keychain")
            return (errSecItemNotFound, nil)
        }
    }
    #expect(try Data(contentsOf: output) == data)
}
