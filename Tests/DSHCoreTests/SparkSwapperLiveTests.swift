import XCTest
@testable import DSHCore

/// Against a running Spark Swapper. Skipped unless DSH_SWAPPER_URL is set:
///   DSH_SWAPPER_URL=https://127.0.0.1:18999 DSH_SWAPPER_USER=… DSH_SWAPPER_PASS=… swift test --filter SparkSwapperLiveTests
final class SparkSwapperLiveTests: XCTestCase {
    func testPinLoginStatusAndSwap() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["DSH_SWAPPER_URL"], let url = URL(string: raw) else {
            throw XCTSkip("set DSH_SWAPPER_URL to run")
        }
        let user = env["DSH_SWAPPER_USER"] ?? "", pass = env["DSH_SWAPPER_PASS"] ?? ""

        // Unpinned: a self-signed cert is refused, and its fingerprint surfaces.
        let unpinned = SparkSwapperClient(baseURL: url, username: user, password: pass, pinnedFingerprint: nil)
        do {
            _ = try await unpinned.status()
            XCTFail("an untrusted certificate must not be accepted silently")
        } catch let SwapperError.untrustedCertificate(fp) {
            XCTAssertEqual(fp.count, 95)
        }

        let fingerprint = await SparkSwapperClient.probeFingerprint(url)
        let fp = try XCTUnwrap(fingerprint)
        let client = SparkSwapperClient(baseURL: url, username: user, password: pass, pinnedFingerprint: fp)

        // Wrong password is a login error, not a crash.
        let bad = SparkSwapperClient(baseURL: url, username: user, password: "nope-nope", pinnedFingerprint: fp)
        do { _ = try await bad.status(); XCTFail("bad login accepted") } catch let SwapperError.badLogin(msg) {
            XCTAssertFalse(msg.isEmpty)
        }

        let status = try await client.status()
        XCTAssertFalse(status.models.isEmpty)
        XCTAssertEqual(status.resolve("flash"), "flash")
        XCTAssertEqual(status.resolve("27b"), "standard")
        print("SWAPPER: active=\(status.active ?? "-") models=\(status.ordered.map(\.key))")

        if env["DSH_SWAPPER_DO_SWAP"] == "1" {
            try await client.swap(to: "flash")
            var job: SwapperStatus.Job?
            for _ in 0..<20 {
                job = try await client.status().job
                if job?.isRunning == false { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            let j = try XCTUnwrap(job)
            print("SWAPPER: job state=\(j.state) step=\(j.currentStep?.label ?? "-") error=\(j.error ?? "-")")
            XCTAssertEqual(j.target, "flash")
        }
    }
}
