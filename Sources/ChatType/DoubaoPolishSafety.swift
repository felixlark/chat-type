import Foundation
import NaturalLanguage

/// A narrow local safeguard, not a semantic correctness classifier. The service
/// sometimes inserts a clause break in “不要删除历史录音”. Keep ASR unchanged
/// instead of accepting a newly detached negated predicate. Do not invent the
/// missing sentence boundaries or send the material to another provider.
enum DoubaoPolishSafety {
    static func hasDetachedNegatedPredicate(original: String, rewritten: String) -> Bool {
        let negations: Set<String> = ["不要", "不能", "不得", "禁止", "不许", "请勿", "勿"]
        let breaks: Set<Character> = ["。", "；", ";", "！", "!", "？", "?", "\n", "\r"]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = original
        tagger.setLanguage(.simplifiedChinese, range: original.startIndex..<original.endIndex)
        var tokens: [(String, NLTag?, Range<String.Index>)] = []
        tagger.enumerateTags(in: original.startIndex..<original.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace]) { tag, range in
            tokens.append((String(original[range]), tag, range)); return true
        }
        for i in tokens.indices.dropLast() where negations.contains(tokens[i].0) && tokens[i + 1].1 == .verb {
            let end = tokens[i + 1].2.upperBound
            guard end < original.endIndex else { continue }
            let following = original[end...].drop(while: { $0.isWhitespace && !breaks.contains($0) })
            guard let first = following.first, !first.isPunctuation, !breaks.contains(first) else { continue }
            let predicate = String(original[tokens[i].2.lowerBound..<end])
            var search = rewritten.startIndex..<rewritten.endIndex
            while let found = rewritten.range(of: predicate, range: search) {
                let tail = rewritten[found.upperBound...].drop(while: { $0.isWhitespace && !breaks.contains($0) })
                if let first = tail.first, breaks.contains(first) { return true }
                search = found.upperBound..<rewritten.endIndex
            }
        }
        return false
    }
}
