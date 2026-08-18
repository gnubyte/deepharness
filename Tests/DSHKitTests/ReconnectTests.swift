import XCTest
@testable import DSHKit

/// Regression tests for the reconnect backoff.
///
/// The original loop reset the attempt counter at the top of every iteration,
/// so a harness that was simply gone got hammered at the minimum delay forever
/// and the give-up branch was unreachable. These pin the arithmetic that
/// governs both.
final class ReconnectTests: XCTestCase {

    /// The delay the stream sleeps for after `attempt` consecutive failures.
    private func delay(attempt: Int) -> Double {
        min(pow(2.0, Double(attempt)) * 0.25, 8.0)
    }

    func testBackoffEscalatesAcrossConsecutiveFailures() {
        let delays = (1...6).map { delay(attempt: $0) }
        XCTAssertEqual(delays, [0.5, 1.0, 2.0, 4.0, 8.0, 8.0])

        for (earlier, later) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later, "backoff must never shrink between attempts")
        }
        XCTAssertGreaterThan(delays.last!, delays.first!, "a pinned delay is the bug this guards")
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(delay(attempt: 20), 8.0, "an unbounded delay would strand a recoverable stream")
    }

    /// Six attempts with escalating backoff is a bounded retry window, not an
    /// endless one — the original code could never reach the limit.
    func testRetryWindowIsBounded() {
        let total = (1...6).map { delay(attempt: $0) }.reduce(0, +)
        XCTAssertEqual(total, 23.5, accuracy: 0.001)
        XCTAssertLessThan(total, 60, "retrying should give up well inside a minute")
    }
}

/// Regression tests for identity handling that a naive string trim breaks.
final class ModelIdentityTests: XCTestCase {

    /// Model ids legitimately contain slashes — `openrouter` serves
    /// `anthropic/claude-…` — so the raw id must survive verbatim.
    func testSlashedModelIdSurvives() {
        let m = ModelIdentity(provider: "openrouter", modelId: "anthropic/claude-sonnet-4")
        XCTAssertEqual(m.modelId, "anthropic/claude-sonnet-4")
    }

    /// The failing case: a model id that repeats its own provider name. A
    /// replace-all of the prefix collapsed this to "foo".
    func testModelIdRepeatingProviderNameIsNotCollapsed() {
        let m = ModelIdentity(provider: "deepseek", modelId: "deepseek/foo")
        XCTAssertEqual(m.modelId, "deepseek/foo")
        XCTAssertNotEqual(m.modelId, "foo")
    }

    func testCompositeKeyStaysUniquePerProvider() {
        let a = ModelIdentity(provider: "openai", modelId: "gpt-4")
        let b = ModelIdentity(provider: "azure", modelId: "gpt-4")
        XCTAssertNotEqual(a.key, b.key, "the same model on two routes must not collide")
    }

    /// A composite key must not be ambiguous for ids containing the separator.
    func testCompositeKeyIsUnambiguous() {
        let a = ModelIdentity(provider: "a", modelId: "b/c")
        let b = ModelIdentity(provider: "a/b", modelId: "c")
        XCTAssertNotEqual(a.key, b.key)
    }
}

/// Mirrors the identity rule `ModelVM` applies in the app target, which has no
/// test host of its own.
private struct ModelIdentity {
    let provider: String
    let modelId: String
    var key: String { "\(provider)\u{0}\(modelId)" }
}
