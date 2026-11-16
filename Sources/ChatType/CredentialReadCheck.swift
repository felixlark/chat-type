import Darwin
import Foundation
import LocalAuthentication
import Security

/// App-owned read-only probe. The CLI exposes no service/account override.
enum CredentialReadCheck {
    enum Service: String, Codable, CaseIterable {
        case chatGPTSession, doubao, glm, qwen

        var query: [String: Any] {
            switch self {
            case .chatGPTSession: KeychainChatGPTSessionStore().credentialReadQuery
            case .doubao: DoubaoKeychain().credentialReadQuery
            case .glm: KeychainGLMKeyStore().credentialReadQuery
            case .qwen: KeychainQwenKeyStore().credentialReadQuery
            }
        }
    }

    enum State: String, Codable { case readable, notFound, osStatus = "OSStatus" }
    struct Result: Codable {
        let service: Service
        let state: State
        let osStatus: OSStatus
    }
    struct Report: Codable {
        let schemaVersion: Int
        let appVersion: String
        let appBuild: String
        let results: [Result]
    }
    typealias CopyMatching = ([String: Any]) -> (OSStatus, CFTypeRef?)

    static func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }

    static func read(bundle: Bundle = .main, copyMatching: CopyMatching = copyMatching) -> Report {
        let results = Service.allCases.map { service in
            check(service: service, query: service.query, copyMatching: copyMatching)
        }
        return Report(schemaVersion: 1,
                      appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unpackaged",
                      appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unpackaged",
                      results: results)
    }

    static func check(service: Service, query: [String: Any], copyMatching: CopyMatching) -> Result {
        var query = query
        // Never present authentication UI or use metadata-only contains().
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let (status, item) = copyMatching(query)
        if status == errSecItemNotFound {
            return Result(service: service, state: .notFound, osStatus: status)
        }
        guard status == errSecSuccess else {
            return Result(service: service, state: .osStatus, osStatus: status)
        }
        guard item is Data else {
            return Result(service: service, state: .osStatus, osStatus: errSecDecode)
        }
        // Data is deliberately discarded. No decoder, credential or auth manager
        // is retained in the report; successful metadata alone cannot pass.
        return Result(service: service, state: .readable, osStatus: status)
    }
}

enum CredentialReadCheckCommand {
    enum CommandError: Error { case usage, privateDirectoryRequired, outputUnavailable }

    static func run(arguments: [String], copyMatching: CredentialReadCheck.CopyMatching = CredentialReadCheck.copyMatching) throws {
        guard arguments.count == 2, arguments[0] == "--output", arguments[1].hasPrefix("/") else {
            throw CommandError.usage
        }
        let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.uint16Value & 0o077 == 0 else {
            throw CommandError.privateDirectoryRequired
        }
        // Exclusive creation avoids replacing an existing result or following a
        // symlink. Reserve the private output before any Keychain query runs.
        let path = parent.appendingPathComponent(output.lastPathComponent).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CommandError.outputUnavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let report = CredentialReadCheck.read(copyMatching: copyMatching)
        try file.write(contentsOf: encoder.encode(report) + Data([0x0A]))
    }
}
