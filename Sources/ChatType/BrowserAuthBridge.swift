import AppKit
import Foundation

enum BrowserBridgeState: Sendable, Equatable {
    case available
    case waiting
    case connected
    case failed(String)
}

struct BrowserBridgeSnapshot: Sendable, Equatable {
    var state: BrowserBridgeState
    var detail: String
    var userCode: String? = nil

    static let available = BrowserBridgeSnapshot(
        state: .available,
        detail: "Use OpenAI device authorization to connect ChatType."
    )
}

enum BrowserAuthBridgeError: LocalizedError, Equatable {
    case timedOut
    case deviceCodeRequestFailed(String)
    case deviceAuthorizationFailed(String)
    case tokenExchangeFailed(String)
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Device login timed out. Request a new code and try again."
        case .deviceCodeRequestFailed(let message):
            return "ChatGPT device login could not start: \(message)"
        case .deviceAuthorizationFailed(let message):
            return "ChatGPT device authorization failed: \(message)"
        case .tokenExchangeFailed(let message):
            return "ChatGPT OAuth token exchange failed: \(message)"
        case .invalidTokenResponse:
            return "ChatGPT OAuth did not return a usable access token."
        }
    }
}

protocol BrowserAuthBridging: Sendable {
    func snapshot() -> BrowserBridgeSnapshot
    func captureSession(now: Date) async throws -> ChatGPTSession
    func refreshSession(refreshToken: String, now: Date) async throws -> ChatGPTSession
}

final class BrowserAuthBridge: BrowserAuthBridging, @unchecked Sendable {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer = "https://auth.openai.com"
    static let deviceVerificationURL = URL(string: "https://auth.openai.com/codex/device")!
    private static let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"

    private let timeoutNanoseconds: UInt64
    private let opener: @MainActor @Sendable (URL) -> Void
    private let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let sleeper: @Sendable (UInt64) async throws -> Void
    private let nowProvider: @Sendable () -> Date
    private let lock = NSLock()
    private var bridgeSnapshot = BrowserBridgeSnapshot.available

    init(
        timeoutSeconds: TimeInterval = 900,
        now: @escaping @Sendable () -> Date = Date.init,
        opener: @escaping @MainActor @Sendable (URL) -> Void = { url in
            if let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: chromeURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            } else {
                NSWorkspace.shared.open(url)
            }
        },
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        },
        sleeper: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        timeoutNanoseconds = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
        nowProvider = now
        self.opener = opener
        self.dataLoader = dataLoader
        self.sleeper = sleeper
    }

    func snapshot() -> BrowserBridgeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return bridgeSnapshot
    }

    func captureSession(now: Date = Date()) async throws -> ChatGPTSession {
        do {
            let deviceCode = try await requestDeviceCode()
            setSnapshot(
                .waiting,
                "Enter this one-time code in the OpenAI page. It expires in 15 minutes.",
                userCode: deviceCode.userCode
            )
            await opener(Self.deviceVerificationURL)
            let authorization = try await pollForDeviceAuthorization(deviceCode)
            let response = try await exchangeAuthorizationCode(
                authorization.authorizationCode,
                codeVerifier: authorization.codeVerifier,
                redirectURI: Self.deviceRedirectURI
            )
            let session = makeSession(from: response, now: nowProvider())
            setSnapshot(.connected, "ChatType connected to ChatGPT via OpenAI device authorization.")
            return session
        } catch {
            setSnapshot(.failed(error.localizedDescription), error.localizedDescription)
            throw error
        }
    }

    func refreshSession(refreshToken: String, now: Date) async throws -> ChatGPTSession {
        let response = try await refreshTokens(refreshToken)
        return makeSession(from: response, now: now)
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "\(Self.issuer)/api/accounts/deviceauth/usercode")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeviceCodeRequest(clientID: Self.clientID))

        let (data, response) = try await dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BrowserAuthBridgeError.deviceCodeRequestFailed("Invalid HTTP response.")
        }
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw BrowserAuthBridgeError.deviceCodeRequestFailed(Self.failureDetail(data: data, response: httpResponse))
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func pollForDeviceAuthorization(_ deviceCode: DeviceCodeResponse) async throws -> DeviceAuthorizationResponse {
        let intervalNanoseconds = max(1, deviceCode.interval) * 1_000_000_000
        let maximumAttempts = max(1, Int(timeoutNanoseconds / intervalNanoseconds) + 1)

        for attempt in 0..<maximumAttempts {
            var request = URLRequest(url: URL(string: "\(Self.issuer)/api/accounts/deviceauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(DeviceAuthorizationRequest(
                deviceAuthID: deviceCode.deviceAuthID,
                userCode: deviceCode.userCode
            ))

            let (data, response) = try await dataLoader(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BrowserAuthBridgeError.deviceAuthorizationFailed("Invalid HTTP response.")
            }
            if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                return try JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data)
            }
            if Self.isDeviceAuthorizationPending(data: data, response: httpResponse) == false {
                throw BrowserAuthBridgeError.deviceAuthorizationFailed(Self.failureDetail(data: data, response: httpResponse))
            }
            if attempt + 1 < maximumAttempts {
                try await sleeper(intervalNanoseconds)
            }
        }

        throw BrowserAuthBridgeError.timedOut
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> OAuthTokenResponse {
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.clientID,
            "code_verifier": codeVerifier,
        ])
    }

    private func refreshTokens(_ refreshToken: String) async throws -> OAuthTokenResponse {
        try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
    }

    private func requestToken(_ parameters: [String: String]) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(parameters).data(using: .utf8)

        let (data, response) = try await dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BrowserAuthBridgeError.invalidTokenResponse
        }
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            let body = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw BrowserAuthBridgeError.tokenExchangeFailed("\(httpResponse.statusCode) \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard tokenResponse.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BrowserAuthBridgeError.invalidTokenResponse
        }
        return tokenResponse
    }

    private func makeSession(from response: OAuthTokenResponse, now: Date) -> ChatGPTSession {
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatGPTSession(
            accessToken: accessToken,
            accessTokenExpiresAt: response.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
                ?? Self.parseJWTExpiry(accessToken),
            refreshToken: response.refreshToken,
            idToken: response.idToken,
            userEmail: Self.parseUserEmail(accessToken: accessToken, idToken: response.idToken),
            updatedAt: now
        )
    }

    private static func failureDetail(data: Data, response: HTTPURLResponse) -> String {
        if response.value(forHTTPHeaderField: "cf-mitigated") == "challenge" {
            return "Cloudflare returned an HTML challenge instead of JSON."
        }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let body, body.isEmpty == false, body.first != "<" {
            return "\(response.statusCode) \(body)"
        }
        return "HTTP \(response.statusCode)"
    }

    private static func isDeviceAuthorizationPending(data: Data, response: HTTPURLResponse) -> Bool {
        if response.statusCode == 403 || response.statusCode == 404 {
            return true
        }

        guard response.statusCode == 400 || response.statusCode == 429,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let error = object["error"]
        let errorCode = (error as? String)
            ?? (error as? [String: Any])?["code"] as? String
        return errorCode == "authorization_pending"
            || errorCode == "deviceauth_authorization_pending"
            || errorCode == "slow_down"
    }

    private static func parseUserEmail(accessToken: String, idToken: String?) -> String? {
        if let email = JWTClaimDecoder.payload(from: idToken)?["email"] as? String, !email.isEmpty {
            return email
        }
        let profile = JWTClaimDecoder.payload(from: accessToken)?["https://api.openai.com/profile"] as? [String: Any]
        return profile?["email"] as? String
    }

    private static func parseJWTExpiry(_ token: String) -> Date? {
        guard let exp = JWTClaimDecoder.payload(from: token)?["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .map { key, value in
                "\(Self.percentEncode(key))=\(Self.percentEncode(value))"
            }
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func setSnapshot(_ state: BrowserBridgeState, _ detail: String, userCode: String? = nil) {
        lock.lock()
        bridgeSnapshot = BrowserBridgeSnapshot(state: state, detail: detail, userCode: userCode)
        lock.unlock()
        NotificationCenter.default.post(name: .chatGPTAuthStateDidChange, object: nil)
    }
}

private struct DeviceCodeRequest: Encodable, Sendable, Equatable {
    var clientID: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct DeviceCodeResponse: Decodable, Sendable, Equatable {
    var deviceAuthID: String
    var userCode: String
    var interval: UInt64

    private enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case interval
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
        userCode = try container.decode(String.self, forKey: .userCode)
        if let value = try? container.decode(UInt64.self, forKey: .interval) {
            interval = value
        } else if let value = try? container.decode(String.self, forKey: .interval),
                  let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            interval = parsed
        } else {
            interval = 5
        }
    }
}

private struct DeviceAuthorizationRequest: Encodable, Sendable, Equatable {
    var deviceAuthID: String
    var userCode: String

    private enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct DeviceAuthorizationResponse: Decodable, Sendable, Equatable {
    var authorizationCode: String
    var codeChallenge: String
    var codeVerifier: String

    private enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }
}

private struct OAuthTokenResponse: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}
