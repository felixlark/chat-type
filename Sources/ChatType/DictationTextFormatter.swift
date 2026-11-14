import Foundation

/// Final typography only; literal contents and existing whitespace remain intact.
struct DictationTextFormatter {
    func format(_ text: String) -> String {
        guard let boundary = try? NSRegularExpression(
            pattern: #"(?<=\p{Han})(?=[\p{Latin}\p{Nd}])|(?<=[\p{Latin}\p{Nd}])(?=\p{Han})"#) else { return text }
        let protectedPatterns = [
            #"(?s)```.*?```|`[^`\n]*`"#,
            #"https?://[^\s，。！？；）】]+"#,
            #"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"(?<![:/])(?:~|/)[^\s，。！？；）】]+"#,
        ]
        let fullRange = NSRange(text.startIndex..., in: text)
        let protected = protectedPatterns.flatMap { pattern in
            (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: fullRange).map(\.range) ?? []
        }
        var output = text
        for match in boundary.matches(in: text, range: fullRange).reversed() {
            let offset = match.range.location
            guard !protected.contains(where: { offset > $0.location && offset < NSMaxRange($0) }),
                  let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: " ")
        }
        return output
    }
}
