import XCTest
@testable import EvidenceContract

final class VerdictRuleTests: XCTestCase {
    private let evaluator = ContractEvaluator()

    private func test(_ scope: TestScope, executed: Int? = 10, failed: [String] = [], exit: Int32 = 0) -> SessionEvent {
        .run(ToolRun(command: "swift test", exitCode: exit, kind: .test(scope: scope, executed: executed, failedTests: failed)))
    }

    func testNoEvidenceAtAllIsUnbacked() {
        let log = SessionLog([.edit(file: "A.swift")])
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.fullSuite), in: log), .unbacked)
        XCTAssertEqual(evaluator.verdict(for: .buildSucceeds, in: log), .unbacked)
        XCTAssertEqual(evaluator.verdict(for: .noReferences(symbol: "x"), in: log), .unbacked)
    }

    func testAnEditAfterTheRunMakesItStaleEvenWhenGreen() {
        let log = SessionLog([test(.fullSuite), .edit(file: "A.swift")])
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.fullSuite), in: log), .stale(evidence: 0, lastEdit: 1))
    }

    func testNoEditsMeansEveryRunIsFresh() {
        let log = SessionLog([test(.fullSuite)])
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.fullSuite), in: log), .backed(evidence: 0))
    }

    func testFreshFailureContradicts() {
        let log = SessionLog([.edit(file: "A.swift"), test(.fullSuite, failed: ["ATests/testX"], exit: 1)])
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.fullSuite), in: log), .contradicted(evidence: 1))
    }

    func testUnknownExecutedCountIsVacuousNotBacked() {
        let log = SessionLog([test(.fullSuite, executed: nil)])
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.fullSuite), in: log), .vacuous(evidence: 0))
    }

    func testPrefixWithoutSlashBoundaryDoesNotCover() {
        XCTAssertFalse(TestScope.filtered(["CartStore"]).covers(test: "CartStoreTests"))
        XCTAssertTrue(TestScope.filtered(["CartStoreTests"]).covers(test: "CartStoreTests/testA"))
        XCTAssertFalse(TestScope.filtered(["CartStoreTests/testA"]).covers(test: "CartStoreTests"))
        XCTAssertFalse(TestScope.filtered([]).covers(.filtered([])))
        XCTAssertFalse(TestScope.filtered(["A"]).covers(.fullSuite))
    }

    func testRegressionThatNeverFailedIsRejectedEvenIfNowGreen() {
        let log = SessionLog([.edit(file: "A.swift"), test(.filtered(["ATests/testBug"]), executed: 1)])
        XCTAssertEqual(evaluator.verdict(for: .regressionFixed(test: "ATests/testBug"), in: log), .neverFailed)
    }

    func testRegressionTestFailingNowIsContradictedNotNeverFailed() {
        let log = SessionLog([.edit(file: "A.swift"), test(.filtered(["ATests/testBug"]), executed: 1, failed: ["ATests/testBug"], exit: 1)])
        XCTAssertEqual(evaluator.verdict(for: .regressionFixed(test: "ATests/testBug"), in: log), .contradicted(evidence: 1))
    }

    func testRegressionReproThenFixThenGreenIsBacked() {
        let log = SessionLog([
            test(.filtered(["ATests/testBug"]), executed: 1, failed: ["ATests/testBug"], exit: 1),
            .edit(file: "A.swift"),
            test(.filtered(["ATests"]), executed: 6)
        ])
        XCTAssertEqual(evaluator.verdict(for: .regressionFixed(test: "ATests/testBug"), in: log), .backed(evidence: 2))
    }

    func testWordBoundarySearchWithNoHitsIsUnderScoped() {
        let anchored = ToolRun(command: "rg", exitCode: 1, kind: .search(pattern: #"\blegacyDiscount\b"#, narrowed: false, hits: 0))
        let word = ToolRun(command: "rg -w", exitCode: 1, kind: .search(pattern: "legacyDiscount", narrowed: true, hits: 0))
        let anchoredHit = ToolRun(command: "rg", exitCode: 0, kind: .search(pattern: #"\blegacyDiscount\b"#, narrowed: false, hits: 1))
        let symbol = ClaimKind.noReferences(symbol: "legacyDiscount")
        XCTAssertEqual(evaluator.verdict(for: symbol, in: SessionLog([.run(anchored)])), .underScoped(evidence: 0))
        XCTAssertEqual(evaluator.verdict(for: symbol, in: SessionLog([.run(word)])), .underScoped(evidence: 0))
        XCTAssertEqual(evaluator.verdict(for: symbol, in: SessionLog([.run(anchoredHit)])), .contradicted(evidence: 0))
    }

    func testLongerPatternThanTheSymbolIsUnderScoped() {
        let longer = ToolRun(command: "rg", exitCode: 1, kind: .search(pattern: "legacyDiscountFor", narrowed: false, hits: 0))
        let leading = ToolRun(command: "rg", exitCode: 1, kind: .search(pattern: #"\blegacyDiscount"#, narrowed: false, hits: 0))
        let symbol = ClaimKind.noReferences(symbol: "legacyDiscount")
        XCTAssertEqual(evaluator.verdict(for: symbol, in: SessionLog([.run(longer)])), .underScoped(evidence: 0))
        XCTAssertEqual(evaluator.verdict(for: symbol, in: SessionLog([.run(leading)])), .backed(evidence: 0))
    }

    func testFailureOutsideTheClaimedScopeDoesNotContradictIt() {
        let log = SessionLog([test(.fullSuite, executed: 200, failed: ["SyncTests/testX"], exit: 1)])
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.filtered(["CartStoreTests"])), in: log), .backed(evidence: 0))
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.fullSuite), in: log), .contradicted(evidence: 0))
        let unnamed = SessionLog([test(.fullSuite, executed: nil, failed: [], exit: 1)])
        XCTAssertEqual(evaluator.verdict(for: .testsPass(.filtered(["CartStoreTests"])), in: unnamed), .contradicted(evidence: 0))
    }

    func testSearchExitOneIsACleanResultAndExitTwoIsIgnored() {
        let clean = ToolRun(command: "rg x", exitCode: 1, kind: .search(pattern: "x", narrowed: false, hits: 0))
        let broken = ToolRun(command: "rg x", exitCode: 2, kind: .search(pattern: "x", narrowed: false, hits: 0))
        XCTAssertEqual(evaluator.verdict(for: .noReferences(symbol: "x"), in: SessionLog([.run(clean)])), .backed(evidence: 0))
        XCTAssertEqual(evaluator.verdict(for: .noReferences(symbol: "x"), in: SessionLog([.run(broken)])), .unbacked)
    }

    func testFailedBuildContradictsAndTestRunThatExecutedImpliesBuild() {
        let failed = ToolRun(command: "swift build", exitCode: 1, kind: .build)
        XCTAssertEqual(evaluator.verdict(for: .buildSucceeds, in: SessionLog([.run(failed)])), .contradicted(evidence: 0))
        XCTAssertEqual(evaluator.verdict(for: .buildSucceeds, in: SessionLog([test(.fullSuite, failed: ["A/b"], exit: 1)])), .backed(evidence: 0))
        XCTAssertEqual(evaluator.verdict(for: .buildSucceeds, in: SessionLog([test(.fullSuite, executed: 0)])), .unbacked)
    }

    func testNotProvableIsAcceptedAndHasNoNextMove() {
        let report = evaluator.evaluate(report: "I think the naming is clearer now.", log: SessionLog())
        XCTAssertTrue(report.isSatisfied)
        XCTAssertNil(report.results.first?.nextMove)
        XCTAssertTrue(report.checkable.isEmpty)
    }
}
