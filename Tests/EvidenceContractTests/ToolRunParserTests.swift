import XCTest
@testable import EvidenceContract

/// The `swift test` outputs below were captured verbatim (Swift
/// 6.0.3, Linux aarch64) on a small probe package, then trimmed of the
/// Swift Testing footer.
final class ToolRunParserTests: XCTestCase {
    private let noMatch = """
    warning: No matching test cases were run
    Test Suite 'Selected tests' started at 2026-09-23 13:40:44.465
    Test Suite 'Selected tests' passed at 2026-09-23 13:40:44.476
    \t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
    """

    private let oneFailure = """
    Test Suite 'Selected tests' started at 2026-09-23 13:40:44.965
    Test Suite 'CartTests' started at 2026-09-23 13:40:44.966
    Test Case 'CartTests.testFails' started at 2026-09-23 13:40:44.966
    /var/tmp/probe923/Tests/PTests/PTests.swift:5: error: CartTests.testFails : XCTAssertEqual failed: ("1") is not equal to ("2") -
    Test Case 'CartTests.testFails' failed (0.0 seconds)
    Test Suite 'CartTests' failed at 2026-09-23 13:40:44.966
    \t Executed 1 test, with 1 failure (0 unexpected) in 0.0 (0.0) seconds
    Test Suite 'Selected tests' failed at 2026-09-23 13:40:44.966
    \t Executed 1 test, with 1 failure (0 unexpected) in 0.0 (0.0) seconds
    """

    func testFilterThatMatchesNothingExitsZeroWithZeroExecuted() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: "swift test --filter NoSuchTests", output: noMatch, exitCode: 0))
        XCTAssertTrue(run.succeeded)
        XCTAssertEqual(run.kind, .test(scope: .filtered(["NoSuchTests"]), executed: 0, failedTests: []))
        XCTAssertEqual(ContractEvaluator().verdict(for: .testsPass(.filtered(["NoSuchTests"])),
                                                   in: SessionLog([.run(run)])), .vacuous(evidence: 0))
    }

    func testLinuxFailureLineBecomesClassSlashMethod() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: "swift test --filter CartTests/testFails", output: oneFailure, exitCode: 1))
        XCTAssertEqual(run.kind, .test(scope: .filtered(["CartTests/testFails"]), executed: 1, failedTests: ["CartTests/testFails"]))
    }

    func testDarwinFailureLineBecomesClassSlashMethod() {
        let output = "Test Case '-[CheckoutTests.CartStoreTests testApplyCouponTwice]' failed (0.012 seconds)."
        XCTAssertEqual(ToolRunParser.failedTests(in: output), ["CartStoreTests/testApplyCouponTwice"])
    }

    func testMissingSummaryMeansUnknownNotZero() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: "swift test", output: "error: fatalError", exitCode: 1))
        XCTAssertEqual(run.kind, .test(scope: .fullSuite, executed: nil, failedTests: []))
    }

    func testXcodebuildOnlyTestingDropsTheTargetComponent() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(
            command: "xcodebuild test -scheme Shop -only-testing:ShopTests/CartStoreTests -only-testing:ShopTests/PriceTests/testRounding",
            output: "Executed 22 tests, with 0 failures (0 unexpected) in 0.4 (0.5) seconds", exitCode: 0))
        XCTAssertEqual(run.kind, .test(scope: .filtered(["CartStoreTests", "PriceTests/testRounding"]), executed: 22, failedTests: []))
    }

    func testXcodebuildWithoutTestActionIsABuild() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: "xcodebuild build -scheme Shop", output: "** BUILD FAILED **", exitCode: 65))
        XCTAssertEqual(run.kind, .build)
        XCTAssertFalse(run.succeeded)
    }

    func testSearchCountsNonEmptyLinesAndKeepsThePatternVerbatim() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: #"rg -n '\blegacyDiscount\b' Sources"#,
                                                    output: "a.swift:1: x\n\nb.m:2: y\n", exitCode: 0))
        XCTAssertEqual(run.kind, .search(pattern: #"\blegacyDiscount\b"#, narrowed: true, hits: 2), "a path narrows")
        let word = try XCTUnwrap(ToolRunParser.parse(command: "rg -n -w legacyDiscount", output: "", exitCode: 1))
        XCTAssertEqual(word.kind, .search(pattern: "legacyDiscount", narrowed: true, hits: 0))
        let whole = try XCTUnwrap(ToolRunParser.parse(command: "grep -rn legacyDiscount .", output: "", exitCode: 1))
        XCTAssertEqual(whole.kind, .search(pattern: "legacyDiscount", narrowed: false, hits: 0))
    }

    func testSearchFlagsThatTakeValuesAreNotMistakenForThePattern() throws {
        let typed = try XCTUnwrap(ToolRunParser.parse(command: "rg -t swift legacyDiscount", output: "", exitCode: 1))
        XCTAssertEqual(typed.kind, .search(pattern: "legacyDiscount", narrowed: true, hits: 0))
        let explicit = try XCTUnwrap(ToolRunParser.parse(command: "rg -n -e legacyDiscount", output: "", exitCode: 1))
        XCTAssertEqual(explicit.kind, .search(pattern: "legacyDiscount", narrowed: false, hits: 0))
    }

    func testQuietSearchThatExitsZeroCountsAsAHit() throws {
        let quiet = try XCTUnwrap(ToolRunParser.parse(command: "rg -q legacyDiscount", output: "", exitCode: 0))
        XCTAssertEqual(quiet.kind, .search(pattern: "legacyDiscount", narrowed: false, hits: 1))
    }

    func testFilterEqualsFormAndSkipAreUnderstood() throws {
        let eq = try XCTUnwrap(ToolRunParser.parse(command: "swift test --filter=CartStoreTests",
                                                   output: "Executed 18 tests, with 0 failures", exitCode: 0))
        XCTAssertEqual(eq.kind, .test(scope: .filtered(["CartStoreTests"]), executed: 18, failedTests: []))
        let skip = try XCTUnwrap(ToolRunParser.parse(command: "swift test --skip SlowTests",
                                                     output: "Executed 200 tests, with 0 failures", exitCode: 0))
        XCTAssertEqual(skip.kind, .test(scope: .filtered([]), executed: 200, failedTests: []))
        XCTAssertEqual(ContractEvaluator().verdict(for: .testsPass(.fullSuite), in: SessionLog([.run(skip)])), .underScoped(evidence: 0))
    }

    func testSwiftTestingCountsAreAddedToXCTestCounts() {
        XCTAssertEqual(ToolRunParser.executedCount(in: "\u{2714} Test run with 12 tests passed after 0.004 seconds."), 12)
        XCTAssertEqual(ToolRunParser.executedCount(in: noMatch + "\n\u{2714} Test run with 0 tests passed after 0.001 seconds."), 0)
        XCTAssertEqual(ToolRunParser.executedCount(in: "Executed 3 tests, with 0 failures\n\u{2714} Test run with 4 tests passed after 0.1 seconds."), 7)
    }

    func testXcodebuildListIsNotEvidenceAndTestWithoutBuildingIsATestRun() throws {
        XCTAssertNil(ToolRunParser.parse(command: "xcodebuild -list", output: "", exitCode: 0))
        XCTAssertNil(ToolRunParser.parse(command: "xcodebuild clean -scheme Shop", output: "", exitCode: 0))
        XCTAssertNil(ToolRunParser.parse(command: "xcodebuild -resolvePackageDependencies", output: "", exitCode: 0))
        XCTAssertEqual(ToolRunParser.parse(command: "xcodebuild clean build -scheme Shop", output: "", exitCode: 0)?.kind, .build)
        XCTAssertEqual(ToolRunParser.parse(command: "xcodebuild -scheme Shop", output: "", exitCode: 0)?.kind, .build)
        let run = try XCTUnwrap(ToolRunParser.parse(command: "xcodebuild test-without-building -scheme Shop",
                                                    output: "Executed 5 tests, with 0 failures", exitCode: 0))
        XCTAssertEqual(run.kind, .test(scope: .fullSuite, executed: 5, failedTests: []))
    }

    /// Captured from `swift test --filter CartTests/testCrashes` on a test
    /// that indexes an empty array (backtrace trimmed). Exit code was 1.
    private let trapped = """
    Test Suite 'Selected tests' started at 2026-09-23 14:07:11.223
    Test Suite 'CartTests' started at 2026-09-23 14:07:11.225
    Test Case 'CartTests.testCrashes' started at 2026-09-23 14:07:11.225
    Swift/ContiguousArrayBuffer.swift:675: Fatal error: Index out of range
    *** Signal 5: Backtracing from 0xeb0b74aa9994... done ***
    *** Program crashed: System trap at 0x0000eb0b74aa9994 ***
    error: Exited with unexpected signal code 5
    """

    func testTrapUnderASingleTestFilterCountsAsThatTestFailing() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: "swift test --filter CartTests/testCrashes", output: trapped, exitCode: 1))
        XCTAssertEqual(run.kind, .test(scope: .filtered(["CartTests/testCrashes"]), executed: nil, failedTests: ["CartTests/testCrashes"]))
    }

    func testTrapUnderAClassFilterNamesNoTest() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: "swift test --filter CartTests", output: trapped, exitCode: 1))
        XCTAssertEqual(run.kind, .test(scope: .filtered(["CartTests"]), executed: nil, failedTests: []))
    }

    func testUnknownToolsAreNotEvidence() {
        XCTAssertNil(ToolRunParser.parse(command: "echo All tests pass", output: "All tests pass", exitCode: 0))
        XCTAssertNil(ToolRunParser.parse(command: "", output: "", exitCode: 0))
        XCTAssertNil(ToolRunParser.parse(command: "rg", output: "", exitCode: 2))
        var log = SessionLog()
        XCTAssertFalse(log.record(command: "cat test-results.txt", output: "Executed 99 tests, with 0 failures", exitCode: 0))
        XCTAssertTrue(log.events.isEmpty)
    }
}
