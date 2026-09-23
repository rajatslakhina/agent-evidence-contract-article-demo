import XCTest
@testable import EvidenceContract

final class SampleSessionTests: XCTestCase {
    private let evaluator = ContractEvaluator()

    private func verdicts(_ report: ContractReport) -> [String] {
        report.results.map(\.verdict.label)
    }

    func testFirstAttemptLogHasTheExpectedShape() {
        let log = SampleSession.firstAttempt
        XCTAssertEqual(log.events.count, 8)
        XCTAssertEqual(log.lastEditIndex, 4)
        XCTAssertEqual(log.lastEditedFile, "Sources/Checkout/PriceFormatter.swift")
    }

    func testFirstAttemptVerdictsInReportOrder() {
        let report = evaluator.evaluate(report: SampleSession.report, log: SampleSession.firstAttempt)
        XCTAssertEqual(verdicts(report), [
            "stale",         // Fixed ... covered by CartStoreTests/testApplyCouponTwice
            "stale",         // CartStoreTests pass
            "vacuous",       // CouponValidatorTests pass
            "under-scoped",  // All tests pass
            "backed",        // The package builds cleanly
            "contradicted",  // No remaining references to legacyDiscount
            "not provable"   // I think the coupon flow is easier to follow
        ])
    }

    func testFirstAttemptHeadlineNumbers() {
        let report = evaluator.evaluate(report: SampleSession.report, log: SampleSession.firstAttempt)
        XCTAssertEqual(report.results.count, 7)
        XCTAssertEqual(report.checkable.count, 6)
        XCTAssertEqual(report.rejected.count, 5)
        XCTAssertEqual(report.count("contradicted"), 1, "exactly one claim is false on the agent's own evidence")
        XCTAssertEqual(report.count("backed"), 1)
        XCTAssertFalse(report.isSatisfied)
    }

    func testStaleVerdictsPointAtTheRightEvents() {
        let report = evaluator.evaluate(report: SampleSession.report, log: SampleSession.firstAttempt)
        guard report.results.count == 7 else { return XCTFail("expected 7 claims, got \(report.results.count)") }
        XCTAssertEqual(report.results[0].verdict, .stale(evidence: 2, lastEdit: 4))
        XCTAssertEqual(report.results[1].verdict, .stale(evidence: 2, lastEdit: 4))
        XCTAssertEqual(report.results[2].verdict, .vacuous(evidence: 5))
        XCTAssertEqual(report.results[3].verdict, .underScoped(evidence: 5))
        XCTAssertEqual(report.results[4].verdict, .backed(evidence: 6))
        XCTAssertEqual(report.results[5].verdict, .contradicted(evidence: 7))
    }

    func testStopHookReasonListsEveryRejectedClaimAsANextMove() throws {
        let report = evaluator.evaluate(report: SampleSession.report, log: SampleSession.firstAttempt)
        let reason = try XCTUnwrap(report.stopHookReason)
        XCTAssertTrue(reason.hasPrefix("Evidence contract: 5 of 6 checkable claims"))
        XCTAssertTrue(reason.contains("Re-run `swift test --filter CartStoreTests`"))
        XCTAssertTrue(reason.contains("predates your edit to Sources/Checkout/PriceFormatter.swift (event 4)"))
        XCTAssertTrue(reason.contains("Run `swift test`, or narrow the claim"))
        XCTAssertTrue(reason.contains("executed zero tests"))
        XCTAssertTrue(reason.contains(#"rg -n '\blegacyDiscount\b'"#))
        XCTAssertEqual(reason.split(separator: "\n").count, 6)
    }

    func testAfterFeedbackEveryClaimIsBacked() {
        let report = evaluator.evaluate(report: SampleSession.revisedReport, log: SampleSession.afterFeedback)
        XCTAssertEqual(verdicts(report), ["backed", "backed", "backed", "backed", "not provable"])
        guard report.results.count == 5 else { return XCTFail("expected 5 claims") }
        XCTAssertTrue(report.isSatisfied)
        XCTAssertNil(report.stopHookReason)
        XCTAssertEqual(report.results[0].verdict, .backed(evidence: 10))
        XCTAssertEqual(report.results[3].verdict, .backed(evidence: 9))
    }

    func testKnownLimitFullSuiteBacksAClaimAboutAClassThatDoesNotExist() {
        // Pinned on purpose. Coverage is by name: a fresh, green full-suite run
        // covers "CouponValidatorTests pass" even though no such class exists
        // (it is CouponRuleTests). The contract proves the claim is not
        // contradicted by fresh evidence, not that the name refers to anything.
        let report = evaluator.evaluate(report: SampleSession.report, log: SampleSession.afterFeedback)
        guard report.results.count == 7 else { return XCTFail("expected 7 claims") }
        XCTAssertEqual(report.results[2].verdict, .backed(evidence: 10))
    }
}
