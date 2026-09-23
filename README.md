# EvidenceContract

**Never accept a claim from a coding agent that the agent could have proven with a tool call.**

A small Swift package that reads a coding agent's final report, pulls out the claims a tool could check ("all tests pass", "builds cleanly", "no remaining references to `legacyDiscount`", "fixed, covered by `CartStoreTests/testApplyCouponTwice`"), and checks each one against the harness's own log of what actually ran, in order.

Article: [Your Coding Agent Isn’t Lying. Its Evidence Is Just Two Edits Old.](https://medium.com/@er.rajatlakhina/your-coding-agent-isnt-lying-its-evidence-is-just-two-edits-old-ecf87fc85b44)

![Timeline of the sample session: seven claims checked against eight harness events; one backed, five rejected](docs/timeline.svg)

## The rule that matters

A claim is only backed by a run that is:

- **from the harness**, not quoted in the agent's summary. `ContractEvaluator.evaluate(report:log:)` takes the two separately and only the log can back anything; `SessionEvent` has no case for "the agent says it ran X". The only public way to put a tool run into the log is `record(command:output:exitCode:)` (edits go in through `recordEdit(_:)`). The type can't stop you feeding it invented output, so wire it to commands your harness actually executed.
- **fresh**: after the last edit, because a green run before an edit proves something about code that no longer exists,
- **in scope**: "all tests pass" needs a full-suite run, not `--filter CartStoreTests`. Only a search for `legacyDiscount` or `\blegacyDiscount` can back "no references". Zero hits from `\blegacyDiscount\b`, `rg -w`, a longer pattern, or a search restricted to a path, type or glob doesn't: the boundary misses the Objective-C selector `legacyDiscountFor:`, and the others miss part of the tree. `swift test --skip` and `xcodebuild -skip-testing:` runs back no claim by scope,
- **non-vacuous**: `swift test --filter NoSuchTests` exits 0 having executed zero tests (verified on Swift 6.0.3; captured output is in the tests).

`rg` and `grep` exit 1 for "no matches", which is a clean result, and exit 0 always counts as at least one hit, so `rg -q` can't sneak through.

Regression claims need one more thing: a run showing the test **failing before the fix**. A test that never failed has not been shown to exercise the bug. A crash counts: a trapped test prints no failure line or summary, so a signal exit under a filter naming exactly one test method is recorded as that test failing (real captured output is in `ToolRunParserTests`).

## Verdicts

| Verdict | Meaning | Accepted |
|---|---|---|
| backed | fresh, in-scope, successful run | yes |
| stale | the run predates the last edit | no |
| under-scoped | only a narrower run exists | no |
| vacuous | zero tests executed, or no summary line | no |
| contradicted | the agent's own evidence says otherwise | no |
| never failed | regression claim with no failing repro | no |
| unbacked | nothing checked it | no |
| not provable | opinion, taste, intent | passed through |

## Usage

```swift
import EvidenceContract

var log = SessionLog()
log.record(command: "swift test --filter CartStoreTests", output: capturedOutput, exitCode: 0)
log.recordEdit("Sources/Checkout/PriceFormatter.swift")

let report = ContractEvaluator().evaluate(report: agentFinalMessage, log: log)
if let reason = report.stopHookReason {
    // Claude Code Stop hook: print {"decision": "block", "reason": reason}
}
```

Each rejected claim comes with a next move phrased as a tool call, for example:

```text
2. "CartStoreTests pass." [stale] Re-run `swift test --filter CartStoreTests`. Your last run (event 2) predates your edit to Sources/Checkout/PriceFormatter.swift (event 4).
```

## The sample session

`SampleSession` is a **constructed** session, not a measurement: an agent fixing a crash when a coupon is applied twice. Its report makes seven claims; six are checkable. Against the first log: 1 backed, 2 stale, 1 vacuous, 1 under-scoped, 1 contradicted. In the constructed follow-up turn the agent makes one more edit and runs three commands, and a revised report is fully backed. `SampleSessionTests` pins every verdict and event number.

## Known limits

- Claim extraction is deterministic pattern matching. Phrasings it doesn't know become `not provable`, which the gate lets through, so it is only as strong as its patterns.
- Coverage is by name. A green full-suite run backs "CouponValidatorTests pass" even if no class has that name (pinned in `testKnownLimitFullSuiteBacksAClaimAboutAClassThatDoesNotExist`).
- Swift Testing counts are read ("Test run with N tests"), but its failing test names are not parsed yet, so a regression repro has to be an XCTest failure or a crash under a single-test filter.
- The parser understands `swift test`, `swift build`, `xcodebuild`, `rg` and `grep`. Turning your harness's transcript into `record(command:output:exitCode:)` calls is yours to write.

## How to run

```bash
git clone https://github.com/rajatslakhina/agent-evidence-contract-article-demo.git
cd agent-evidence-contract-article-demo
swift test
open Demo/Demo.xcodeproj   # pick an iOS 17+ Simulator, Build & Run
```

The Demo app consumes the package through a local package reference (`relativePath = ..`), so there is nothing else to fetch.

## Verification status

| Check | Result |
|---|---|
| `swift build` | passes (Swift 6.0.3, Linux aarch64) |
| `swift test` | 49 tests, 0 failures |
| `Demo.xcodeproj` | statically validated: balanced braces/parens, 20 objects all defined and referenced, parses as an OpenStep plist; shared scheme XML well-formed |
| Simulator run | **not done**. The app target has never been compiled, and neither has `EvidenceContractDemoView` (it is behind `#if canImport(SwiftUI)`, which Linux skips). See `Demo/Screenshots/README.md`. |

MIT License.
