/// What a coding agent asserted in its final report, reduced to something a
/// tool run could confirm or refute.
public enum ClaimKind: Hashable, Sendable {
    /// "All tests pass" (`.fullSuite`) or "CheckoutTests pass" (`.filtered`).
    case testsPass(TestScope)
    /// "The project builds cleanly."
    case buildSucceeds
    /// "No remaining references to `legacyDiscount`."
    case noReferences(symbol: String)
    /// "Fixed the crash, covered by `CartStoreTests/testApplyCouponTwice`."
    /// Needs the test observed failing before the fix and passing after it.
    case regressionFixed(test: String)
    /// Judgement, taste, intent. Passed through, never gated: a contract that
    /// rejects opinions teaches the agent to stop sharing them.
    case notProvable
}

public struct Claim: Hashable, Sendable, Identifiable {
    public let id: Int
    public let sentence: String
    public let kind: ClaimKind

    public init(id: Int, sentence: String, kind: ClaimKind) {
        self.id = id
        self.sentence = sentence
        self.kind = kind
    }
}

/// Which tests a run executed, or a claim is about.
///
/// Identifiers use `Class/method` or `Class`, the same shape `swift test
/// --filter` accepts. A filter covers an identifier when it is equal to it or a
/// `/`-delimited prefix of it, so `CartStoreTests` covers
/// `CartStoreTests/testApplyCouponTwice` but `CartStore` does not.
public enum TestScope: Hashable, Sendable {
    case fullSuite
    case filtered([String])

    public func covers(test identifier: String) -> Bool {
        switch self {
        case .fullSuite:
            return true
        case .filtered(let filters):
            return filters.contains { filter in
                identifier == filter || identifier.hasPrefix(filter + "/")
            }
        }
    }

    /// True when every test the other scope names is inside this one.
    public func covers(_ other: TestScope) -> Bool {
        switch (self, other) {
        case (.fullSuite, _):
            return true
        case (.filtered, .fullSuite):
            return false
        case (.filtered, .filtered(let wanted)):
            return !wanted.isEmpty && wanted.allSatisfy { covers(test: $0) }
        }
    }
}
