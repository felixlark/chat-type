import Foundation

struct TextPolishMessage: Sendable, Equatable {
    let role: String
    let content: String
}

struct TextPolishEstimate: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let summary: String
}

struct TextPolishProviderSelection: Sendable, Equatable {
    let id: TextPolishProviderID
}

struct TextPolishResult: Sendable, Equatable {
    let text: String
    let provider: TextPolishProviderID?
    let applied: Bool
    let estimatedInputTokens: Int
    let estimatedOutputTokens: Int
}

protocol TextPolishing: Sendable {
    func polish(
        text: String,
        terminologyEntries: [TerminologyEntry],
        hintTerms: [String]
    ) async throws -> TextPolishResult
}

enum TextPolishError: LocalizedError {
    case providerUnavailable
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "No text polish provider is configured."
        case .invalidResponse:
            return "Text polish provider returned an empty response."
        case .requestFailed(let message):
            return "Text polish failed: \(message)"
        }
    }
}

private struct TextPolishHTTPError: LocalizedError {
    let statusCode: Int
    let message: String
    let contentType: String?
    let server: String?
    let bodyPrefix: String?

    var shouldRefreshAuthToken: Bool {
        statusCode == 401 || statusCode == 403
    }

    var errorDescription: String? {
        var parts = ["Text polish failed: status \(statusCode)", message]
        if let contentType {
            parts.append("content-type=\(contentType)")
        }
        if let server {
            parts.append("server=\(server)")
        }
        if let bodyPrefix, !bodyPrefix.isEmpty {
            parts.append("body=\(bodyPrefix)")
        }
        return parts.joined(separator: "; ")
    }
}

struct TextPolishProviderSelector: Sendable {
    func selectProvider(
        config: TextPolishConfig,
        chatGPTAuthAvailable: Bool
    ) -> TextPolishProviderSelection? {
        guard config.mode != .disabled else {
            return nil
        }

        if config.chatGPTAuthEnabled && chatGPTAuthAvailable {
            return TextPolishProviderSelection(id: .chatGPTAuth)
        }

        return nil
    }
}

struct TextPolishPromptBuilder: Sendable {
    func buildMessages(
        transcript: String,
        terminologyEntries: [TerminologyEntry],
        config: TextPolishConfig,
        locale: String = Locale.preferredLanguages.first ?? "zh-CN"
    ) -> [TextPolishMessage] {
        let glossary = clippedGlossary(
            transcript: transcript,
            terminologyEntries: terminologyEntries,
            budget: config.glossaryBudgetCharacters
        )
        var systemLines = [
            "You are ChatType's post-ASR rewrite engine for agent-facing dictation.",
            "Goal: return directly usable Chinese or mixed Chinese/English text; output only the final text.",
            "Do not summarize away requirements. Preserve every request, constraint, correction, acceptance point, and exact literal.",
            "Later self-corrections win / 后面为主; remove superseded wording.",
            "Remove filler words and口头禅 when they add no meaning.",
            "Keep short commands to one sentence. For multiple spoken goals or steps, use concise 分点 in the original sequence; never invent steps.",
            "Preserve URLs, file paths, commands, flags, version numbers, emails, filenames, code symbols, and exact quoted literals.",
            "Use glossary spelling and casing for likely ASR mistakes. Locale: \(locale).",
        ]

        if !glossary.isEmpty {
            systemLines.append("Glossary terms and aliases:")
            systemLines.append(contentsOf: glossary.map { "- \($0)" })
        }

        return [
            TextPolishMessage(role: "system", content: systemLines.joined(separator: "\n")),
            TextPolishMessage(role: "user", content: transcript),
        ]
    }

    private func clippedGlossary(
        transcript: String,
        terminologyEntries: [TerminologyEntry],
        budget: Int
    ) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        var count = 0
        let transcriptKey = looseMatchKey(for: transcript)

        for entry in terminologyEntries {
            let matchTerms = [entry.canonical] + entry.aliases
            guard matchTerms.contains(where: { term in
                let key = looseMatchKey(for: term)
                return !key.isEmpty && transcriptKey.contains(key)
            }) else {
                continue
            }

            let aliases = entry.aliases.isEmpty ? "" : " aliases: \(entry.aliases.joined(separator: ", "))"
            let line = "\(entry.canonical)\(aliases)"
            let key = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else {
                continue
            }
            let nextCount = count + line.count
            guard nextCount <= budget else {
                break
            }
            output.append(line)
            count = nextCount
        }

        return output
    }

    private func looseMatchKey(for text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let filteredScalars = folded.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && scalar != "."
                && scalar != "_"
                && scalar != "-"
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }
}

struct TextPolishTokenEstimator: Sendable {
    func estimate(
        transcript: String,
        terminologyEntries: [TerminologyEntry],
        config: TextPolishConfig
    ) -> TextPolishEstimate {
        let messages = TextPolishPromptBuilder().buildMessages(
            transcript: transcript,
            terminologyEntries: terminologyEntries,
            config: config
        )
        let promptCharacters = messages.map(\.content.count).reduce(0, +)
        let inputTokens = max(1, Int(ceil(Double(promptCharacters) / 1.8)))
        let outputTokens = max(120, min(config.maxOutputTokens, Int(ceil(Double(transcript.count) / 2.4))))
        return TextPolishEstimate(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            summary: "estimated \(inputTokens) input / \(outputTokens) output tokens"
        )
    }
}

struct OpenAICompatibleTextPolisher: TextPolishing {
    let config: TextPolishConfig
    let chatGPTAuthProvider: (any ChatGPTAuthProviding)?
    let chatGPTAuthAvailable: Bool
    let promptBuilder: TextPolishPromptBuilder
    let selector: TextPolishProviderSelector
    let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        config: TextPolishConfig,
        chatGPTAuthProvider: (any ChatGPTAuthProviding)? = nil,
        chatGPTAuthAvailable: Bool,
        promptBuilder: TextPolishPromptBuilder = .init(),
        selector: TextPolishProviderSelector = .init(),
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.config = config
        self.chatGPTAuthProvider = chatGPTAuthProvider
        self.chatGPTAuthAvailable = chatGPTAuthAvailable
        self.promptBuilder = promptBuilder
        self.selector = selector
        self.dataLoader = dataLoader
    }

    func polish(
        text: String,
        terminologyEntries: [TerminologyEntry],
        hintTerms: [String]
    ) async throws -> TextPolishResult {
        let allEntries = terminologyEntries + hintTerms.map {
            TerminologyEntry(canonical: $0, aliases: [])
        }
        let estimate = TextPolishTokenEstimator().estimate(
            transcript: text,
            terminologyEntries: allEntries,
            config: config
        )

        guard let selected = selector.selectProvider(
            config: config,
            chatGPTAuthAvailable: chatGPTAuthAvailable
        ) else {
            throw TextPolishError.providerUnavailable
        }

        guard selected.id == .chatGPTAuth, let chatGPTAuthProvider else {
            throw TextPolishError.providerUnavailable
        }

        let token = try await chatGPTAuthProvider.bestAvailableAccessToken()
        let messages = promptBuilder.buildMessages(
            transcript: text,
            terminologyEntries: allEntries,
            config: config
        )
        let polished = try await executeChatGPTResponsesRequest(
            token: token,
            messages: messages
        )
        return TextPolishResult(
            text: polished,
            provider: .chatGPTAuth,
            applied: polished != text,
            estimatedInputTokens: estimate.inputTokens,
            estimatedOutputTokens: estimate.outputTokens
        )
    }

    private func executeChatGPTResponsesRequest(
        token: String,
        messages: [TextPolishMessage]
    ) async throws -> String {
        let endpoint = config.chatGPTResponseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), !config.chatGPTResponseModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextPolishError.providerUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ChatType/0.5", forHTTPHeaderField: "User-Agent")

        let system = messages.first(where: { $0.role == "system" })?.content ?? ""
        let userText = messages
            .filter { $0.role != "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        let body: [String: Any] = [
            "model": config.chatGPTResponseModel,
            "instructions": system,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": userText,
                        ],
                    ],
                ],
            ],
            "stream": true,
            "store": false,
            "reasoning": ["effort": "none"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            return try await executeResponsesRequest(request)
        } catch let error as TextPolishHTTPError where error.shouldRefreshAuthToken {
            let refreshedToken = try await chatGPTAuthProvider?.refreshAccessToken() ?? token
            request.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
            return try await executeResponsesRequest(request)
        }
    }

    private func executeResponsesRequest(_ request: URLRequest) async throws -> String {
        let (data, response) = try await dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TextPolishError.requestFailed("missing HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TextPolishHTTPError(
                statusCode: httpResponse.statusCode,
                message: decodeProviderMessage(from: data) ?? "status \(httpResponse.statusCode)",
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                server: httpResponse.value(forHTTPHeaderField: "Server"),
                bodyPrefix: String(data: data.prefix(512), encoding: .utf8)
            )
        }

        if let text = decodeResponsesText(from: data) {
            return text
        }
        if let text = decodeResponsesSSEText(from: data) {
            return text
        }
        throw TextPolishError.invalidResponse
    }

    private func decodeResponsesText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let outputText = object["output_text"] as? String {
            let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let output = object["output"] as? [[String: Any]] else {
            return nil
        }
        let text = output
            .flatMap { item -> [[String: Any]] in
                item["content"] as? [[String: Any]] ?? []
            }
            .compactMap { content -> String? in
                content["text"] as? String
                    ?? content["output_text"] as? String
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func decodeResponsesSSEText(from data: Data) -> String? {
        guard let stream = String(data: data, encoding: .utf8) else {
            return nil
        }
        var output = ""
        for line in stream.components(separatedBy: .newlines) where line.hasPrefix("data: ") {
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]", let eventData = payload.data(using: .utf8) else {
                continue
            }
            guard let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                continue
            }
            if let delta = event["delta"] as? String,
               (event["type"] as? String) == "response.output_text.delta" {
                output += delta
            } else if let response = event["response"] as? [String: Any],
                      let responseData = try? JSONSerialization.data(withJSONObject: response),
                      let text = decodeResponsesText(from: responseData) {
                output = text
            }
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodeProviderMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }
}
