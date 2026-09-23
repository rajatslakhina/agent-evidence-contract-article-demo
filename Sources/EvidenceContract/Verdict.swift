/// The outcome for one claim. Event numbers are indices into the `SessionLog`.
public enum Verdict: Hashable, Sendable {
    /// A fresh, in-scope, successful run supports the claim.
    case backed(evidence: Int)
    /// The supporting run happened before the last edit. It proves something
    /// about a codebase that no longer exists.
    case stale(evidence: Int, lastEdit: Int)
    /// Only a narrower run exists: "all tests pass" backed by a filtered run.
    case underScoped(evidence: Int)
    /// The run executed zero tests (or its output had no summary). A filter
    /// that matches nothing still exits 0.
    case vacuous(evidence: Int)
    /// The agent's own evidence says the opposite.
    case contradicted(evidence: Int)
    /// "Fixed, covered by X" with no run showing X failing before the fix.
    /// A test that never failed has not been shown to exercise the bug.
    case neverFailed
    /// Checkable, and nothing in the session checked it.
    case unbacked
    /// Not a checkable claim. Passed through.
    case notProvable

    public var isAccepted: Bool {
        switch self {
        case .backed, .notProvable: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .backed: return "backed"
        case .stale: return "stale"
        case .underScoped: return "under-scoped"
        case .vacuous: return "vacuous"
        case .contradicted: return "contradicted"
        case .neverFailed: return "never failed"
        case .unbacked: return "unbacked"
        case .notProvable: return "not provable"
        }
    }
}

/// How to phrase the next command for this project. Placeholders: `{filter}`,
/// `{symbol}`.
public struct CommandBook: Hashable, Sendable {
    public var fullSuite: String
    public var filteredTests: String
    public var build: String
    public var search: String

    public init(fullSuite: String, filteredTests: String, build: String, search: String) {
        self.fullSuite = fullSuite
        self.filteredTests = filteredTests
        self.build = build
        self.search = search
    }

    public static let swiftPM = CommandBook(
        fullSuite: "swift test",
        filteredTests: "swift test --filter {filter}",
        build: "swift build",
        search: "rg -n {symbol}")

    func tests(_ scope: TestScope) -> String {
        switch scope {
        case .fullSuite: return fullSuite
        case .filtered(let filters): return filteredTests.replacingOccurrences(of: "{filter}", with: filters.joined(separator: " "))
        }
    }

    func search(_ symbol: String) -> String {
        search.replacingOccurrences(of: "{symbol}", with: symbol)
    }
}
