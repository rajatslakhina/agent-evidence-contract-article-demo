/// Checks every claim in a final report against the harness's session log.
///
/// The load-bearing decision is the signature: the evaluator takes the report
/// (what the agent said) and the log (what the tools saw) as separate inputs,
/// and only the log can back a claim. Output the agent pastes into its summary
/// is prose, not evidence.
public struct ContractEvaluator: Sendable {
    public var extractor: ClaimExtractor
    public var commands: CommandBook

    public init(extractor: ClaimExtractor = ClaimExtractor(), commands: CommandBook = .swiftPM) {
        self.extractor = extractor
        self.commands = commands
    }

    public func evaluate(report: String, log: SessionLog) -> ContractReport {
        let results = extractor.claims(in: report).map { claim in
            let verdict = verdict(for: claim.kind, in: log)
            return ClaimResult(claim: claim, verdict: verdict,
                               nextMove: nextMove(for: claim.kind, verdict: verdict, log: log))
        }
        return ContractReport(results: results)
    }

    // MARK: - Verdicts

    public func verdict(for kind: ClaimKind, in log: SessionLog) -> Verdict {
        let lastEdit = log.lastEditIndex ?? -1
        let testRuns = log.runs.compactMap { entry -> (index: Int, run: ToolRun, scope: TestScope, executed: Int?, failed: [String])? in
            guard case .test(let scope, let executed, let failed) = entry.run.kind else { return nil }
            return (entry.index, entry.run, scope, executed, failed)
        }

        switch kind {
        case .notProvable:
            return .notProvable

        case .testsPass(let claimed):
            guard let latest = testRuns.last(where: { $0.scope.covers(claimed) }) else {
                if let narrower = testRuns.last { return .underScoped(evidence: narrower.index) }
                return .unbacked
            }
            if latest.index < lastEdit { return .stale(evidence: latest.index, lastEdit: lastEdit) }
            // Only failures inside the claimed scope contradict it. A failing
            // run that names no failures could have failed anywhere.
            let relevant = latest.failed.filter { claimed.covers(test: $0) }
            if !relevant.isEmpty || (!latest.run.succeeded && latest.failed.isEmpty) {
                return .contradicted(evidence: latest.index)
            }
            if (latest.executed ?? 0) == 0 { return .vacuous(evidence: latest.index) }
            return .backed(evidence: latest.index)

        case .buildSucceeds:
            let candidates = log.runs.filter { entry in
                switch entry.run.kind {
                case .build: return true
                case .test(_, let executed, _): return (executed ?? 0) > 0
                case .search: return false
                }
            }
            guard let latest = candidates.last else { return .unbacked }
            if latest.index < lastEdit { return .stale(evidence: latest.index, lastEdit: lastEdit) }
            if case .build = latest.run.kind, !latest.run.succeeded { return .contradicted(evidence: latest.index) }
            return .backed(evidence: latest.index)

        case .noReferences(let symbol):
            // rg and grep exit 1 for "no matches": that is a clean result, not
            // a failure. Exit 2 and above is an error and proves nothing.
            let searches = log.runs.compactMap { entry -> (index: Int, hits: Int, narrow: Bool)? in
                guard case .search(let pattern, let narrowed, let hits) = entry.run.kind,
                      pattern.contains(symbol), entry.run.exitCode <= 1 else { return nil }
                // Zero hits from a narrowed search does not mean "no
                // references"; hits from it still count.
                // Only `symbol` or `\bsymbol` is a search for every use. A
                // trailing boundary, a longer pattern (legacyDiscountFor), -w,
                // a path or a glob each search for less.
                let exact = pattern == symbol || pattern == #"\b"# + symbol
                let narrow = narrowed || !exact
                return (entry.index, hits, narrow)
            }
            guard let latest = searches.last(where: { !$0.narrow || $0.hits > 0 }) else {
                if let narrow = searches.last { return .underScoped(evidence: narrow.index) }
                return .unbacked
            }
            if latest.index < lastEdit { return .stale(evidence: latest.index, lastEdit: lastEdit) }
            if latest.hits > 0 { return .contradicted(evidence: latest.index) }
            return .backed(evidence: latest.index)

        case .regressionFixed(let test):
            let latest = testRuns.last(where: { $0.scope.covers(test: test) })
            func failsNow(_ entry: (index: Int, run: ToolRun, scope: TestScope, executed: Int?, failed: [String])) -> Bool {
                entry.failed.contains { $0 == test || $0.hasPrefix(test + "/") }
                    || (!entry.run.succeeded && entry.failed.isEmpty)
            }
            // Failing right now beats every other question.
            if let latest, latest.index > lastEdit, failsNow(latest) {
                return .contradicted(evidence: latest.index)
            }
            let reproduced = testRuns.contains { entry in
                entry.index < lastEdit && entry.failed.contains { $0 == test || $0.hasPrefix(test + "/") }
            }
            guard reproduced else { return .neverFailed }
            guard let latest else { return .unbacked }
            if latest.index < lastEdit { return .stale(evidence: latest.index, lastEdit: lastEdit) }
            if (latest.executed ?? 0) == 0 { return .vacuous(evidence: latest.index) }
            return .backed(evidence: latest.index)
        }
    }

    // MARK: - Next moves

    /// Phrased as the agent's next tool call, not as an accusation. The agent
    /// is going to read this, so it should be something it can act on.
    func nextMove(for kind: ClaimKind, verdict: Verdict, log: SessionLog) -> String? {
        let command: String
        switch kind {
        case .notProvable: return nil
        case .testsPass(let scope): command = commands.tests(scope)
        case .buildSucceeds: command = commands.build
        case .noReferences(let symbol): command = commands.search(symbol)
        case .regressionFixed(let test): command = commands.tests(.filtered([test]))
        }
        let edited = log.lastEditedFile ?? "a file"

        switch verdict {
        case .backed, .notProvable:
            return nil
        case .stale(let evidence, let lastEdit):
            return "Re-run `\(command)`. Your last run (event \(evidence)) predates your edit to \(edited) (event \(lastEdit))."
        case .underScoped(let evidence):
            return "Event \(evidence) checked a narrower scope than you claimed. Run `\(command)`, or narrow the claim to what you ran."
        case .vacuous(let evidence):
            return "Event \(evidence) executed zero tests, which exits 0 and proves nothing: `\(command)` matched no test. Correct the name and re-run, or drop the claim."
        case .contradicted(let evidence):
            return "Your own run at event \(evidence) says otherwise. Fix it and run `\(command)` again, or retract the claim."
        case .neverFailed:
            return "No run shows this test failing before your fix, so nothing shows it exercises the bug. Stash the fix, run `\(command)` and confirm it fails, restore the fix, then run it again."
        case .unbacked:
            return "Nothing in this session checks this. Run `\(command)`."
        }
    }
}

public struct ClaimResult: Hashable, Sendable, Identifiable {
    public let claim: Claim
    public let verdict: Verdict
    public let nextMove: String?
    public var id: Int { claim.id }
}

public struct ContractReport: Hashable, Sendable {
    public let results: [ClaimResult]

    public var checkable: [ClaimResult] { results.filter { $0.claim.kind != .notProvable } }
    public var rejected: [ClaimResult] { results.filter { !$0.verdict.isAccepted } }
    public var isSatisfied: Bool { rejected.isEmpty }

    public func count(_ label: String) -> Int {
        results.filter { $0.verdict.label == label }.count
    }

    /// Text for a Claude Code `Stop` hook's `reason` field when it returns
    /// `"decision": "block"`. Nil when the contract is satisfied.
    public var stopHookReason: String? {
        guard !isSatisfied else { return nil }
        var lines = ["Evidence contract: \(rejected.count) of \(checkable.count) checkable claims are not backed by a fresh tool run. Before finishing:"]
        for (offset, result) in rejected.enumerated() {
            lines.append("\(offset + 1). \"\(result.claim.sentence)\" [\(result.verdict.label)] \(result.nextMove ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
