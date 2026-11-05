import XCTest
@testable import VisionHarnessCore

/// The screenshot mode's isolated run: only an absolute folder named in the environment switches it on, and then the
/// settings file, data folder and home folder the app uses are all inside that folder. A normal run is untouched.
final class IsolatedRunTests: XCTestCase {
    func testOnlyAnAbsoluteFolderSwitchesItOn() {
        XCTAssertNil(IsolatedRun.root(fromEnvironment: nil))
        XCTAssertNil(IsolatedRun.root(fromEnvironment: ""))
        XCTAssertNil(IsolatedRun.root(fromEnvironment: "/"), "the whole disk is not a throwaway folder")
        XCTAssertNil(IsolatedRun.root(fromEnvironment: "relative/folder"))
        XCTAssertEqual(IsolatedRun.root(fromEnvironment: "/tmp/vision-snapshot-1/")?.path, "/tmp/vision-snapshot-1")
        XCTAssertEqual(IsolatedRun.root(fromEnvironment: "/tmp/a/../vision-snapshot-2")?.path, "/tmp/vision-snapshot-2")
    }

    func testEverythingIsolatedLivesInsideTheFolder() {
        let root = URL(fileURLWithPath: "/tmp/vision-snapshot-3", isDirectory: true)
        XCTAssertEqual(IsolatedRun.home(in: root).path, "/tmp/vision-snapshot-3/home")
        XCTAssertEqual(IsolatedRun.applicationSupport(in: root).path,
                       "/tmp/vision-snapshot-3/home/Library/Application Support")
        XCTAssertEqual(IsolatedRun.settingsFile(in: root).path, "/tmp/vision-snapshot-3/settings.plist")
        // The data folder resolved there is the app's own name inside it.
        let support = AppPaths.resolveSupport(in: IsolatedRun.applicationSupport(in: root))
        XCTAssertEqual(support.path, "/tmp/vision-snapshot-3/home/Library/Application Support/Vision")
    }

    /// A normal run (this test process) is not isolated: the usual settings, folders and Keychain.
    func testANormalRunIsUntouched() {
        XCTAssertNil(getenv(IsolatedRun.environmentVariable), "the test run must not be isolated")
        XCTAssertFalse(IsolatedRun.isActive)
        XCTAssertNil(IsolatedRun.home)
        XCTAssertNil(IsolatedRun.applicationSupport)
        XCTAssertTrue(IsolatedRun.defaults === UserDefaults.standard)
        XCTAssertEqual(AppPaths.applicationSupport,
                       FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(SkillLocations.standard.home, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(AppSecrets.keychain is LegacyFallbackSecretStore)
        XCTAssertTrue(AppSecrets.vault is LegacyFallbackBlobStore)
    }

    /// The isolated settings file is a plist at an absolute path: what is written there stays there.
    func testASettingsSuiteNamedByPathKeepsToItsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vision-isolated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = IsolatedRun.settingsFile(in: folder)
        let suite = try XCTUnwrap(UserDefaults(suiteName: file.path))
        suite.set("on", forKey: "isolated.probe")
        suite.synchronize()
        XCTAssertEqual(suite.string(forKey: "isolated.probe"), "on")
        XCTAssertNil(UserDefaults.standard.object(forKey: "isolated.probe"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        suite.removePersistentDomain(forName: file.path)
    }
}
