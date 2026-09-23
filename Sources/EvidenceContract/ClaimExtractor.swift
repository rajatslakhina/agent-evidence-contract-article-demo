import Foundation

/// Pulls checkable claims out of an agent's final report.
///
/// Deterministic on purpose. If an LLM decided which sentences count as claims,
/// the gate would inherit the failure mode it exists to catch, and a red result
/// would become something to argue with instead of something to fix.
public struct ClaimExtractor: Sendable {
    public init() {}

    public func claims(in report: String) -> [Claim] {
        var result: [Claim] = []
        for sentence in Self.sentences(in: report) {
            let found = Self.kinds(in: sentence)
            if found.isEmpty {
                result.append(Claim(id: result.count, sentence: sentence, kind: .notProvable))
            } else {
                for kind in found {
                    result.append(Claim(id: result.count, sentence: sentence, kind: kind))
                }
            }
        }
        return result
    }

    // MARK: - Sentences

    /// Splits on line breaks and sentence-ending punctuation, strips bullets
    /// and backticks, and drops one-word fragments ("Summary:").
    static func sentences(in report: String) -> [String] {
        let cleaned = report.replacingOccurrences(of: "`", with: "")
        var pieces: [String] = []
        for line in cleaned.split(whereSeparator: \.isNewline) {
            var current = ""
            let characters = Array(line)
            for (offset, character) in characters.enumerated() {
                current.append(character)
                let isEnd = character == "." || character == "!" || character == "?"
                let nextIsBreak = offset + 1 >= characters.count || characters[offset + 1] == " "
                if isEnd && nextIsBreak {
                    pieces.append(current)
                    current = ""
                }
            }
            pieces.append(current)
        }
        return pieces
            .map { piece in
                var trimmed = piece.trimmingCharacters(in: .whitespaces)
                while let first = trimmed.first, first == "-" || first == "*" || first == "•" {
                    trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { $0.split(separator: " ").count >= 2 }
    }

    // MARK: - Patterns

    private static let regression = try! NSRegularExpression(
        pattern: #"\b(?:fixed|fixes|resolved)\b.*?\bcovered by\s+([A-Za-z_]\w*(?:/[A-Za-z_]\w*)?)"#,
        options: [.caseInsensitive])
    private static let references = try! NSRegularExpression(
        pattern: #"\bno\s+(?:remaining\s+|other\s+|more\s+)?(?:references|callers|usages|uses)\s+(?:to|of)\s+([A-Za-z_]\w*)"#,
        options: [.caseInsensitive])
    private static let fullSuite = try! NSRegularExpression(
        pattern: #"\b(?:all(?:\s+the)?(?:\s+\d+)?\s+tests\s+(?:pass|are\s+passing|are\s+green)|(?:full\s+)?test\s+suite\s+(?:passes|is\s+green))\b"#,
        options: [.caseInsensitive])
    private static let namedTests = try! NSRegularExpression(
        pattern: #"\b([A-Z]\w*Tests(?:/\w+)?)\s+(?:pass|passes|are\s+passing|are\s+green)\b"#)
    private static let build = try! NSRegularExpression(
        pattern: #"\b(?:builds?\s+(?:cleanly|successfully|fine)|build\s+(?:succeeds|succeeded|is\s+green)|compiles\s+(?:cleanly|without\s+(?:errors|warnings)))\b"#,
        options: [.caseInsensitive])

    /// Clause boundaries: "but", "yet", "although", semicolons, and exception
    /// qualifiers such as "except".
    private static let clauseBreak = try! NSRegularExpression(
        pattern: #",?\s+(?:but|yet|although|though|whereas)\s+|;\s*|,?\s+(?:except|apart from|other than)\b"#,
        options: [.caseInsensitive])

    /// A hedged success is not a success claim. Only the two words directly
    /// before the match count, within the same clause and after the last
    /// comma: "Not all tests pass" and "It doesn't build cleanly" are hedged;
    /// "No UI changes, all tests pass" and "I didn't touch the API, and all
    /// tests pass" are not. An exception qualifier closing the clause ("builds
    /// cleanly except on Catalyst") also hedges it.
    static func isHedged(_ sentence: String, matchAt location: Int) -> Bool {
        let ns = sentence as NSString
        let breaks = clauseBreak.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
        let clauseStart = breaks.last(where: { $0.range.location + $0.range.length <= location })
            .map { $0.range.location + $0.range.length } ?? 0
        var before = ns.substring(with: NSRange(location: clauseStart, length: location - clauseStart)).lowercased()
        if let comma = before.lastIndex(of: ",") { before = String(before[before.index(after: comma)...]) }
        let window = before.split(whereSeparator: { $0 == " " }).suffix(2)
        if window.contains(where: { ["not", "no", "never", "none"].contains($0) || $0.hasSuffix("n't") }) { return true }
        if let next = breaks.first(where: { $0.range.location >= location }) {
            let separator = ns.substring(with: next.range).lowercased()
            if ["except", "apart from", "other than"].contains(where: { separator.contains($0) }) { return true }
        }
        return false
    }

    static func kinds(in sentence: String) -> [ClaimKind] {
        let range = NSRange(sentence.startIndex..., in: sentence)
        var found: [(location: Int, kind: ClaimKind)] = []

        func capture(_ match: NSTextCheckingResult) -> String? {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: sentence) else { return nil }
            return String(sentence[r])
        }

        for match in regression.matches(in: sentence, range: range) {
            if let test = capture(match) { found.append((match.range.location, .regressionFixed(test: test))) }
        }
        for match in references.matches(in: sentence, range: range) {
            if let symbol = capture(match) { found.append((match.range.location, .noReferences(symbol: symbol))) }
        }
        for match in fullSuite.matches(in: sentence, range: range) where !isHedged(sentence, matchAt: match.range.location) {
            found.append((match.range.location, .testsPass(.fullSuite)))
        }
        for match in namedTests.matches(in: sentence, range: range) where !isHedged(sentence, matchAt: match.range.location) {
            if let name = capture(match) { found.append((match.range.location, .testsPass(.filtered([name])))) }
        }
        for match in build.matches(in: sentence, range: range) where !isHedged(sentence, matchAt: match.range.location) {
            found.append((match.range.location, .buildSucceeds))
        }
        return found.sorted { $0.location < $1.location }.map(\.kind)
    }
}
