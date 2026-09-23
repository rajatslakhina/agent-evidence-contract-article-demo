/// A constructed session, not a measured one: an agent fixing a crash when a
/// coupon is applied twice, in a Swift package with an Objective-C app target
/// next to it. Every output line uses the format the real tool prints (for
/// tests, `swift test` 6.0.3 on Linux); the crash lines in event 0 were captured
/// from a real trapped test and renamed. Timestamps and counts are invented.
public enum SampleSession {
    public static let report = """
    Summary:
    - Fixed the crash when a coupon is applied twice, covered by `CartStoreTests/testApplyCouponTwice`.
    - CartStoreTests pass.
    - CouponValidatorTests pass.
    - All tests pass.
    - The package builds cleanly.
    - There are no remaining references to `legacyDiscount`.
    - I think the coupon flow is easier to follow now.
    """

    /// Events 0...7: what the harness saw before the agent tried to stop.
    public static var firstAttempt: SessionLog {
        var log = SessionLog()
        log.record(
            command: "swift test --filter CartStoreTests/testApplyCouponTwice",
            output: """
            Test Suite 'Selected tests' started at 2026-09-23 10:02:11.301
            Test Suite 'CartStoreTests' started at 2026-09-23 10:02:11.302
            Test Case 'CartStoreTests.testApplyCouponTwice' started at 2026-09-23 10:02:11.302
            Swift/ContiguousArrayBuffer.swift:675: Fatal error: Index out of range
            *** Program crashed: System trap at 0x0000eb0b74aa9994 ***
            error: Exited with unexpected signal code 5
            """,
            exitCode: 1)                                                   // 0: the repro (a trap, so no failure line)
        log.recordEdit("Sources/Checkout/CartStore.swift")                // 1: the fix
        log.record(
            command: "swift test --filter CartStoreTests",
            output: """
            Test Suite 'Selected tests' started at 2026-09-23 10:04:40.118
            Test Suite 'CartStoreTests' passed at 2026-09-23 10:04:40.161
            \t Executed 18 tests, with 0 failures (0 unexpected) in 0.043 (0.043) seconds
            Test Suite 'Selected tests' passed at 2026-09-23 10:04:40.161
            \t Executed 18 tests, with 0 failures (0 unexpected) in 0.043 (0.044) seconds
            """,
            exitCode: 0)                                                   // 2: green
        log.recordEdit("Sources/Checkout/CouponValidator.swift")          // 3: renames legacyDiscount(for:)
        log.recordEdit("Sources/Checkout/PriceFormatter.swift")           // 4: "while I'm in here"
        log.record(
            command: "swift test --filter CouponValidatorTests",
            output: """
            warning: No matching test cases were run
            Test Suite 'Selected tests' started at 2026-09-23 10:07:02.540
            Test Suite 'Selected tests' passed at 2026-09-23 10:07:02.551
            \t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
            """,
            exitCode: 0)                                                   // 5: the class is CouponRuleTests
        log.record(command: "swift build", output: "Build complete! (4.12s)", exitCode: 0)  // 6
        log.record(
            command: "rg -n legacyDiscount",
            output: """
            App/Legacy/PromoBridge.m:41:    NSDecimalNumber *d = [store legacyDiscountFor:code];
            App/Legacy/PromoBridge.m:88:    return [store legacyDiscountFor:promo.code];
            """,
            exitCode: 0)                                                   // 7: two hits `swift build` never compiles
        return log
    }

    public static let revisedReport = """
    - Fixed the crash when a coupon is applied twice, covered by CartStoreTests/testApplyCouponTwice.
    - All tests pass.
    - The package builds cleanly.
    - There are no remaining references to legacyDiscount.
    - I think the coupon flow is easier to follow now.
    """

    /// Events 8...11: the turn after the Stop hook handed back the next moves.
    public static var afterFeedback: SessionLog {
        var log = firstAttempt
        log.recordEdit("App/Legacy/PromoBridge.m")                         // 8
        log.record(command: "rg -n legacyDiscount", output: "", exitCode: 1)  // 9: rg exits 1 on no match
        log.record(
            command: "swift test",
            output: """
            Test Suite 'All tests' started at 2026-09-23 10:11:30.004
            Test Suite 'All tests' passed at 2026-09-23 10:11:31.872
            \t Executed 214 tests, with 0 failures (0 unexpected) in 1.861 (1.868) seconds
            """,
            exitCode: 0)                                                   // 10
        log.record(command: "swift build", output: "Build complete! (0.98s)", exitCode: 0)  // 11
        return log
    }
}
