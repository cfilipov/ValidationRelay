import XCTest
@testable import ValidationRelayCore

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffDoublesAndStopsAtMaximum() {
        var policy = RelayReconnectPolicy(initialDelay: 2, maximumDelay: 8)

        XCTAssertEqual(policy.consumeDelay(), 2)
        XCTAssertEqual(policy.consumeDelay(), 4)
        XCTAssertEqual(policy.consumeDelay(), 8)
        XCTAssertEqual(policy.consumeDelay(), 8)
    }

    func testResetReturnsToInitialDelay() {
        var policy = RelayReconnectPolicy(initialDelay: 3, maximumDelay: 12)
        _ = policy.consumeDelay()
        _ = policy.consumeDelay()

        policy.reset()

        XCTAssertEqual(policy.consumeDelay(), 3)
    }
}
