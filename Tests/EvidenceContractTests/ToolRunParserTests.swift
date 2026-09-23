import XCTest
@testable import EvidenceContract

/// The three outputs below were captured verbatim from `swift test` (Swift
/// 6.0.3, Linux aarch64) on a two-test probe package, then trimmed of the
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

    func testSearchCountsNonEmptyLinesAndStripsWordBoundaries() throws {
        let run = try XCTUnwrap(ToolRunParser.parse(command: #"rg -n '\blegacyDiscount\b' Sources"#,
                                                    output: "a.swift:1: x\n\nb.m:2: y\n", exitCode: 0))
        XCTAssertEqual(run.kind, .search(pattern: "legacyDiscount", hits: 2))
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
