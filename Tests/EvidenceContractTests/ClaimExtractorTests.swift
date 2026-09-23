import XCTest
@testable import EvidenceContract

final class ClaimExtractorTests: XCTestCase {
    private let extractor = ClaimExtractor()

    private func kinds(_ text: String) -> [ClaimKind] {
        extractor.claims(in: text).map(\.kind)
    }

    func testRecognisesEachClaimShape() {
        XCTAssertEqual(kinds("All tests pass."), [.testsPass(.fullSuite)])
        XCTAssertEqual(kinds("The full test suite is green."), [.testsPass(.fullSuite)])
        XCTAssertEqual(kinds("CartStoreTests pass."), [.testsPass(.filtered(["CartStoreTests"]))])
        XCTAssertEqual(kinds("The app builds cleanly."), [.buildSucceeds])
        XCTAssertEqual(kinds("There are no other callers of `legacyDiscount`."), [.noReferences(symbol: "legacyDiscount")])
        XCTAssertEqual(kinds("Fixed the race, covered by `SyncTests/testDoubleFlush`."),
                       [.regressionFixed(test: "SyncTests/testDoubleFlush")])
    }

    func testSeveralClaimsInOneSentenceKeepTheirOrder() {
        XCTAssertEqual(kinds("It builds cleanly and all tests pass."), [.buildSucceeds, .testsPass(.fullSuite)])
    }

    func testHedgedSuccessIsNotASuccessClaim() {
        XCTAssertEqual(kinds("Not all tests pass yet."), [.notProvable])
        XCTAssertEqual(kinds("It builds cleanly except on Catalyst."), [.notProvable])
        XCTAssertEqual(kinds("CartStoreTests pass but SyncTests fail."), [.notProvable])
    }

    func testOpinionsPassThroughAndFragmentsAreDropped() {
        let claims = extractor.claims(in: "Summary:\n- I think this reads better now.")
        XCTAssertEqual(claims.map(\.kind), [.notProvable])
        XCTAssertEqual(claims.first?.sentence, "I think this reads better now.")
    }

    func testBulletsAndBackticksAreStripped() {
        let claims = extractor.claims(in: "* `All tests pass`.")
        XCTAssertEqual(claims.first?.sentence, "All tests pass.")
    }

    func testEmptyReportHasNoClaims() {
        XCTAssertTrue(extractor.claims(in: "").isEmpty)
        XCTAssertTrue(extractor.claims(in: "\n\n  \n").isEmpty)
    }

    func testClaimIdsAreSequential() {
        let claims = extractor.claims(in: SampleSession.report)
        XCTAssertEqual(claims.map(\.id), Array(0..<claims.count))
    }
}
