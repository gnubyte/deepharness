import XCTest
@testable import DSHCore

// MARK: - Fixtures

/// `pkgutil --check-signature` for a package signed by Amazon's Developer ID Installer identity, in
/// the format Apple documents. (Modelled on Apple's documented output and on the AWS CLI's own
/// instructions for checking the package — not captured from a real AWS package, which the sandbox
/// this was written in cannot download; the fingerprints are placeholders.)
private let installerAmazonSignedReport = """
    Package "AWSCLIV2.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2026-09-01 18:00:00 +0000
       Certificate Chain:
        1. Developer ID Installer: AMZN Mobile LLC (94KV3E626L)
           Expires: 2027-02-01 22:12:15 +0000
           SHA256 Fingerprint:
               00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF 00 11 22 33 44 55
               66 77 88 99 AA BB CC DD EE FF
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
           Expires: 2027-02-01 22:12:15 +0000
           SHA256 Fingerprint:
               00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF 00 11 22 33 44 55
               66 77 88 99 AA BB CC DD EE FF
           ------------------------------------------------------------------------
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000
           SHA256 Fingerprint:
               00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF 00 11 22 33 44 55
               66 77 88 99 AA BB CC DD EE FF

    """

/// What `pkgutil` really printed (captured on macOS 26) for a package that has no signature, one whose
/// signature is invalid, and one signed by a certificate macOS doesn't trust.
private let installerNoSignatureReport = "Package \"x.pkg\":\n   Status: no signature\n"
private let installerInvalidSignatureReport = "Package \"x.pkg\":\n   Status: invalid signature\n"
private let installerUntrustedReport = """
    Package "CoreTypes.pkg":
       Status: signed by untrusted certificate
       Certificate Chain:
        1. Software Update
           Expires: 2029-04-14 21:28:23 +0000
           SHA256 Fingerprint:
               E0 74 D2 04 AC 24 98 E9 DC 90 4A 7B C7 CE D8 46 41 19 B7 9D 05 66
               80 28 92 05 83 B1 E8 96 EB B4

    """

private let installerReadyAfter = AWSCLIStatus.ready(version: SemanticVersion(2, 37, 5), path: "/Users/me/aws-cli/aws")

/// A signature as `pkgutil` would report it for an Amazon package.
private func installerAmazonSigned(name: String = "AMZN Mobile LLC") -> AWSPackageSignature {
    AWSPackageSignature(status: "signed by a developer certificate issued by Apple for distribution",
                        certificates: ["Developer ID Installer: \(name) (94KV3E626L)", "Developer ID Certification Authority", "Apple Root CA"],
                        isTrusted: true)
}

/// A fake package: the "xar!" header every flat package starts with, then filler.
private func installerFakePackage(size: Int = 1_000_000) -> Data {
    var bytes = [UInt8](repeating: 0, count: size)
    var state: UInt32 = 7
    for index in bytes.indices {
        state = state &* 1_664_525 &+ 1_013_904_223
        bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    bytes.replaceSubrange(0..<4, with: [0x78, 0x61, 0x72, 0x21])
    return Data(bytes)
}

/// Serves the AWS CLI download for the installer's URLSession: a status, a body delivered in chunks,
/// and optionally a stall that only a cancel ends.
final class AWSDownloadStub: URLProtocol, @unchecked Sendable {
    struct Behavior: Sendable {
        var status = 200
        var body = Data()
        /// The Content-Length sent (nil = the body's size).
        var declaredLength: Int64?
        /// False: no Content-Length header at all.
        var sendLength = true
        var chunkSize = 64 * 1024
        /// Stop delivering after this many bytes and wait for the request to be cancelled.
        var stallAfter: Int?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behavior = Behavior()
    nonisolated(unsafe) private static var urls: [URL] = []

    static func configure(_ behavior: Behavior) {
        lock.withLock {
            self.behavior = behavior
            urls = []
        }
    }

    static var requested: [URL] { lock.withLock { urls } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AWSDownloadStub.self]
        return URLSession(configuration: configuration)
    }

    private let stopped = DispatchSemaphore(value: 0)
    private let flag = AWSLockedBox(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let behavior = Self.lock.withLock { () -> Behavior in
            Self.urls.append(request.url!)
            return Self.behavior
        }
        let length = behavior.declaredLength ?? Int64(behavior.body.count)
        var headers = ["Content-Type": "application/octet-stream"]
        if behavior.sendLength { headers["Content-Length"] = "\(length)" }
        let response = HTTPURLResponse(url: request.url!, statusCode: behavior.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            var offset = 0
            while offset < behavior.body.count {
                if flag.value { return }
                if let stall = behavior.stallAfter, offset >= stall {
                    _ = stopped.wait(timeout: .now() + 30)
                    return
                }
                let end = min(offset + behavior.chunkSize, behavior.body.count)
                client?.urlProtocol(self, didLoad: behavior.body.subdata(in: offset..<end))
                offset = end
            }
            if !flag.value { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        flag.mutate { $0 = true }
        stopped.signal()
    }
}

/// Install progress, kept in order.
private final class InstallerProgressLog: @unchecked Sendable {
    private let box = AWSLockedBox<[AWSCLIInstallProgress]>([])
    var onReport: (@Sendable (AWSCLIInstallProgress) -> Void)?

    var items: [AWSCLIInstallProgress] { box.value }
    var stages: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.stage) { seen.append(item.stage) }
        return seen
    }

    var handler: AWSCLIInstaller.Progress {
        { [self] progress in
            box.append(progress)
            onReport?(progress)
        }
    }
}

/// An installer whose every outside effect is scripted and recorded.
private final class InstallerHarness: @unchecked Sendable {
    let work: AWSScratchDirectory
    let home: AWSScratchDirectory
    let progress = InstallerProgressLog()

    // What the outside world does.
    var package = installerFakePackage()
    var status = 200
    var signature: @Sendable () throws -> AWSPackageSignature = { installerAmazonSigned() }
    var installerResult = AWSCLIResult(exitCode: 0, stdout: "installer: Package name is AWS Command Line Interface\ninstaller: The install was successful.\n")
    var elevatedResult = AWSCLIResult(exitCode: 0, stdout: "installer: The install was successful.\n")
    var after = installerReadyAfter

    // What happened.
    let signatureChecks = AWSLockedBox<[String]>([])
    let userLaunches = AWSLockedBox<[AWSCLIInstallerLaunch]>([])
    let elevatedLaunches = AWSLockedBox<[AWSCLIInstallerLaunch]>([])
    let installedBytes = AWSLockedBox<Data?>(nil)
    let choicesFile = AWSLockedBox<Data?>(nil)

    init(test: XCTestCase) {
        work = test.makeScratch("dsh-aws-install")
        home = test.makeScratch("dsh-aws-home")
    }

    var requested: [URL] { AWSDownloadStub.requested }

    func installer() -> AWSCLIInstaller {
        AWSDownloadStub.configure(.init(status: status, body: status == 200 ? package : Data("Not Found".utf8)))
        var installer = AWSCLIInstaller(homeDirectory: home.path, workFolder: work.path)
        installer.platformProblem = nil
        installer.session = AWSDownloadStub.session()
        installer.checkSignature = { [self] path in
            signatureChecks.append(path)
            return try signature()
        }
        installer.runInstaller = { [self] launch, onLine in
            userLaunches.append(launch)
            installedBytes.mutate { $0 = FileManager.default.contents(atPath: launch.packagePath) }
            if let index = launch.arguments.firstIndex(of: "-applyChoiceChangesXML") {
                choicesFile.mutate { $0 = FileManager.default.contents(atPath: launch.arguments[index + 1]) }
            }
            for line in installerResult.stdout.components(separatedBy: "\n") where !line.isEmpty { onLine(line) }
            return installerResult
        }
        installer.runElevated = { [self] launch, onLine in
            elevatedLaunches.append(launch)
            installedBytes.mutate { $0 = FileManager.default.contents(atPath: launch.packagePath) }
            for line in elevatedResult.stdout.components(separatedBy: "\n") where !line.isEmpty { onLine(line) }
            return elevatedResult
        }
        installer.checkInstalled = { [self] in after }
        return installer
    }

    /// Everything left in the work folder.
    func filesLeft() -> [String] { work.files() }
}

// MARK: - The whole install

final class AWSCLIInstallerTests: XCTestCase {

    func testInstallsJustForThisUserWithoutAnAdministrator() async throws {
        let h = InstallerHarness(test: self)
        let result = try await h.installer().install(scope: .currentUser, progress: h.progress.handler)

        XCTAssertEqual(result.outcome, .installed)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.message, "AWS CLI 2.37.5 is installed.")
        XCTAssertEqual(result.cli, installerReadyAfter)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(h.requested, [URL(string: "https://awscli.amazonaws.com/AWSCLIV2.pkg")!])

        XCTAssertTrue(h.elevatedLaunches.value.isEmpty, "no administrator prompt for a per-user install")
        let launch = try XCTUnwrap(h.userLaunches.value.first)
        XCTAssertEqual(h.userLaunches.value.count, 1)
        XCTAssertFalse(launch.elevated)
        XCTAssertEqual(launch.executable, "/usr/sbin/installer")
        XCTAssertTrue(launch.packagePath.hasSuffix("/AWSCLIV2.pkg"))
        XCTAssertEqual(launch.arguments.count, 6)
        XCTAssertEqual(Array(launch.arguments.prefix(4)), ["-pkg", launch.packagePath, "-target", "CurrentUserHomeDirectory"])
        XCTAssertEqual(launch.arguments[4], "-applyChoiceChangesXML")
        XCTAssertTrue(launch.arguments[5].hasSuffix("/choices.xml"))
        XCTAssertEqual(h.installedBytes.value, h.package, "what was checked is what was installed")
        XCTAssertEqual(h.signatureChecks.value, [launch.packagePath])
        XCTAssertTrue(h.filesLeft().isEmpty, "the download and its settings are removed after success: \(h.filesLeft())")

        // AWS's documented choices file, pointing the install at the home folder.
        let choices = try XCTUnwrap(h.choicesFile.value)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: choices, format: nil) as? [[String: String]])
        XCTAssertEqual(plist, [["choiceIdentifier": "default", "choiceAttribute": "customLocation", "attributeSetting": h.home.path]])

        // The CLI is linked into ~/.local/bin as the AWS instructions do.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: h.home[".local/bin/aws"]), h.home["aws-cli/aws"])

        XCTAssertEqual(h.progress.stages, ["Downloading the AWS CLI installer", "Checking the installer's digital signature", "Installing the AWS CLI", "Checking the installation"])
        let downloads = h.progress.items.filter { $0.stage.hasPrefix("Downloading") }
        XCTAssertGreaterThanOrEqual(downloads.count, 4)
        XCTAssertTrue(downloads.allSatisfy { $0.total == Int64(h.package.count) })
        XCTAssertEqual(downloads.map(\.done), downloads.map(\.done).sorted(), "progress only goes forward")
        XCTAssertEqual(downloads.first?.done, 0)
        XCTAssertEqual(downloads.last?.done, Int64(h.package.count))
        XCTAssertEqual(downloads.last?.fraction, 1.0)
        XCTAssertTrue(h.progress.items.contains { $0.detail == "installer: The install was successful." }, "the installer's own lines are shown")
    }

    func testInstallingForEveryoneAsksForAnAdministrator() async throws {
        let h = InstallerHarness(test: self)
        let result = try await h.installer().install(scope: .allUsers, progress: h.progress.handler)
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertEqual(result.message, "AWS CLI 2.37.5 is installed.")
        XCTAssertEqual(h.requested, [URL(string: "https://awscli.amazonaws.com/AWSCLIV2.pkg")!])
        XCTAssertTrue(h.userLaunches.value.isEmpty, "everything goes through the administrator prompt")
        let launch = try XCTUnwrap(h.elevatedLaunches.value.first)
        XCTAssertTrue(launch.elevated)
        XCTAssertEqual(launch.arguments, ["-pkg", launch.packagePath, "-target", "/"])
        XCTAssertTrue(h.progress.items.contains { $0.stage.contains("approve the administrator prompt") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home[".local/bin/aws"]), "an all-users install leaves the user's folders alone")
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testRefusesAnythingNotValidlySignedByAmazon() async throws {
        let notAmazon = AWSPackageSignature(status: "signed by a developer certificate issued by Apple for distribution",
                                            certificates: ["Developer ID Installer: Totally Legit Software (ABCDE12345)", "Developer ID Certification Authority", "Apple Root CA"],
                                            isTrusted: true)
        let lookalike = AWSPackageSignature(status: "signed by a developer certificate issued by Apple for distribution",
                                            certificates: ["Developer ID Installer: Amazon Web Services, Inc. (ZZZZZZZZZZ)"], isTrusted: true)
        let wrongKind = AWSPackageSignature(status: "signed by a developer certificate issued by Apple for distribution",
                                            certificates: ["Developer ID Application: AMZN Mobile LLC (94KV3E626L)"], isTrusted: true)
        let noChain = AWSPackageSignature(status: "signed by a developer certificate issued by Apple for distribution", certificates: [], isTrusted: true)
        let cases: [AWSPackageSignature] = [
            AWSCLIInstaller.parseSignature(installerNoSignatureReport, exitCode: 1)!,
            AWSCLIInstaller.parseSignature(installerInvalidSignatureReport, exitCode: 1)!,
            AWSCLIInstaller.parseSignature(installerUntrustedReport, exitCode: 1)!,
            notAmazon, lookalike, wrongKind, noChain,
        ]
        for signature in cases {
            let h = InstallerHarness(test: self)
            h.signature = { signature }
            let result = try await h.installer().install()
            XCTAssertEqual(result.outcome, .signatureRejected, "\(signature)")
            XCTAssertTrue(result.message.contains("didn't run it"), result.message)
            XCTAssertTrue(h.userLaunches.value.isEmpty && h.elevatedLaunches.value.isEmpty, "nothing may run: \(signature)")
            XCTAssertTrue(h.filesLeft().isEmpty)
            XCTAssertFalse(result.canTryHomebrew)
        }
    }

    func testRefusesWhenTheSignatureCantBeChecked() async throws {
        let h = InstallerHarness(test: self)
        h.signature = { throw AWSCLIInstallerError("pkgutil isn't available") }
        let result = try await h.installer().install()
        XCTAssertEqual(result.outcome, .signatureRejected)
        XCTAssertTrue(result.message.contains("couldn't check"), result.message)
        XCTAssertTrue(result.message.contains("pkgutil isn't available"))
        XCTAssertTrue(h.userLaunches.value.isEmpty)
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testADownloadThatIsntAPackageIsNotRun() async throws {
        let h = InstallerHarness(test: self)
        h.package = Data("<html><body>Access denied by your proxy</body></html>".utf8)
        let result = try await h.installer().install()
        XCTAssertEqual(result.outcome, .downloadFailed)
        XCTAssertTrue(result.message.contains("isn't a macOS installer package"), result.message)
        XCTAssertTrue(h.signatureChecks.value.isEmpty)
        XCTAssertTrue(h.userLaunches.value.isEmpty)
        XCTAssertTrue(result.canTryHomebrew)
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testDownloadErrorsAreExplained() async throws {
        let h = InstallerHarness(test: self)
        h.status = 404
        let result = try await h.installer().install()
        XCTAssertEqual(result.outcome, .downloadFailed)
        XCTAssertTrue(result.message.contains("404"), result.message)
        XCTAssertTrue(result.message.contains("Check your internet connection"))
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testABodyShorterThanItsLengthIsAFailedDownload() async throws {
        let h = InstallerHarness(test: self)
        let installer = h.installer()
        AWSDownloadStub.configure(.init(body: h.package, declaredLength: Int64(h.package.count) + 500))
        let result = try await installer.install()
        XCTAssertEqual(result.outcome, .downloadFailed)
        XCTAssertTrue(result.message.contains("stopped early"), result.message)
        XCTAssertTrue(h.filesLeft().isEmpty, "a partial download is removed: \(h.filesLeft())")
    }

    func testAnUnreachableServerIsADownloadFailure() async throws {
        let h = InstallerHarness(test: self)
        var installer = h.installer()
        installer.download = { _, _, _ in throw URLError(.notConnectedToInternet) }
        let result = try await installer.install()
        XCTAssertEqual(result.outcome, .downloadFailed)
        XCTAssertTrue(result.message.contains(URLError(.notConnectedToInternet).localizedDescription), result.message)
        XCTAssertTrue(result.canTryHomebrew)
    }

    func testCancellingTheDownloadInstallsNothingAndLeavesNothing() async throws {
        let h = InstallerHarness(test: self)
        let installer = h.installer()
        AWSDownloadStub.configure(.init(body: installerFakePackage(size: 4_000_000), stallAfter: 300_000))
        let task = Task { try await installer.install(scope: .currentUser, progress: h.progress.handler) }
        await waitUntil(10, "some of the download") { h.progress.items.contains { $0.done > 0 } }
        task.cancel()
        _ = await assertThrows(CancellationError.self) { _ = try await task.value }
        XCTAssertTrue(h.signatureChecks.value.isEmpty)
        XCTAssertTrue(h.userLaunches.value.isEmpty)
        XCTAssertTrue(h.filesLeft().isEmpty, "\(h.filesLeft())")
    }

    func testTheDefaultDownloadReadsThroughARealSession() async throws {
        // No stub: the installer's own URLSession, pointed at a local file.
        let h = InstallerHarness(test: self)
        let source = h.work.writeData("served/AWSCLIV2.pkg", h.package)
        var installer = h.installer()
        installer.session = nil
        installer.packageURL = URL(fileURLWithPath: source)
        let result = try await installer.install(progress: h.progress.handler)
        XCTAssertEqual(result.outcome, .installed, result.message)
        XCTAssertEqual(h.installedBytes.value, h.package)
        let downloads = h.progress.items.filter { $0.stage.hasPrefix("Downloading") }
        XCTAssertEqual(downloads.last?.done, Int64(h.package.count))
        XCTAssertEqual(downloads.last?.total, Int64(h.package.count))
    }

    func testTheRealSignatureCheckRefusesAPackageThatIsNotOne() async throws {
        let h = InstallerHarness(test: self)
        var installer = h.installer()
        // macOS's own pkgutil looks at a file that has the header of a package and nothing else.
        installer.checkSignature = AWSCLIInstaller(homeDirectory: h.home.path, workFolder: h.work.path).checkSignature
        let result = try await installer.install()
        XCTAssertEqual(result.outcome, .signatureRejected, result.message)
        XCTAssertTrue(h.userLaunches.value.isEmpty && h.elevatedLaunches.value.isEmpty)
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testAFailedInstallKeepsItsLog() async throws {
        let h = InstallerHarness(test: self)
        h.installerResult = AWSCLIResult(exitCode: 1, stdout: """
            installer: Package name is AWS Command Line Interface
            installer: Installing at base path /Users/me
            installer: The install failed. (The Installer encountered an error that caused the installation to fail. Contact the software manufacturer for assistance.)

            """)
        let result = try await h.installer().install()
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.message.contains("error 1"), result.message)
        XCTAssertTrue(result.message.contains("The install failed."), result.message)
        XCTAssertTrue(result.canTryHomebrew)
        let log = try XCTUnwrap(result.logPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log))
        XCTAssertEqual(h.filesLeft().map { h.work.path + "/" + $0 }, [log], "only the log is left; the package itself is gone")
        XCTAssertTrue(try String(contentsOfFile: log, encoding: .utf8).contains("Installing at base path /Users/me"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home[".local/bin/aws"]), "nothing is linked after a failure")
    }

    func testInstalledButStillNotUsableIsAFailure() async throws {
        let h = InstallerHarness(test: self)
        h.after = .missing
        let result = try await h.installer().install()
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("still can't use the AWS CLI"), result.message)
        XCTAssertTrue(result.message.contains("isn't installed"), "it says what the check found")
        XCTAssertTrue(result.canTryHomebrew)
        XCTAssertEqual(result.cli, .missing)
    }

    func testADeclinedAdministratorPromptIsCancelled() async throws {
        let h = InstallerHarness(test: self)
        h.elevatedResult = AWSCLIResult(exitCode: 1, stdout: "", stderr: "0:143: execution error: User canceled. (-128)\n")
        let result = try await h.installer().install(scope: .allUsers)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertNil(result.logPath)
        XCTAssertFalse(result.canTryHomebrew)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testAnInstallerThatWontStartIsAFailure() async throws {
        let h = InstallerHarness(test: self)
        var installer = h.installer()
        installer.runInstaller = { _, _ in throw AWSCLIStartError(executable: "/usr/sbin/installer", reason: "the file doesn't exist.") }
        let result = try await installer.install()
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.hasPrefix("The macOS installer didn't start"), result.message)
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testNothingHappensWhereItCantWork() async throws {
        let h = InstallerHarness(test: self)
        var installer = h.installer()
        installer.platformProblem = "The AWS CLI installer needs macOS 10.15 or newer."
        let installed = try await installer.install()
        XCTAssertEqual(installed.outcome, .notSupported)
        XCTAssertEqual(installed.message, "The AWS CLI installer needs macOS 10.15 or newer.")
        let brewed = try await installer.installWithHomebrew()
        XCTAssertEqual(brewed.outcome, .notSupported)
        XCTAssertTrue(h.requested.isEmpty)
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    func testTheSecondInstallStartsInAFreshFolder() async throws {
        let h = InstallerHarness(test: self)
        let installer = h.installer()
        _ = try await installer.install()
        _ = try await installer.install()
        let launches = h.userLaunches.value.map(\.packagePath)
        XCTAssertEqual(launches.count, 2)
        XCTAssertNotEqual(launches[0], launches[1])
        XCTAssertTrue(h.filesLeft().isEmpty)
    }

    // MARK: Upgrading

    func testUpgradesInTheScopeItWasInstalledIn() throws {
        let dir = makeScratch()
        dir.write("system/aws-cli/aws", "", executable: true)
        try FileManager.default.createDirectory(atPath: dir["system/bin"], withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir["system/bin/aws"], withDestinationPath: "../aws-cli/aws")
        dir.write("home/aws-cli/aws", "", executable: true)
        dir.write("brew/Cellar/awscli/2.31.0/bin/aws", "", executable: true)
        dir.write("system/aws-cli-lookalike/aws", "", executable: true)
        let system = dir["system/aws-cli"]
        func old(_ path: String) -> AWSCLIStatus { .tooOld(version: SemanticVersion(2, 31, 0), path: path) }

        XCTAssertEqual(AWSCLIInstaller.scopeFor(old(dir["system/aws-cli/aws"]), systemFolder: system), .allUsers)
        XCTAssertEqual(AWSCLIInstaller.scopeFor(old(dir["system/bin/aws"]), systemFolder: system), .allUsers, "reached through the link in /usr/local/bin")
        XCTAssertEqual(AWSCLIInstaller.scopeFor(.ready(version: SemanticVersion(2, 40, 0), path: dir["system/aws-cli/aws"]), systemFolder: system), .allUsers)
        XCTAssertEqual(AWSCLIInstaller.scopeFor(.broken(path: dir["system/aws-cli/aws"], problem: "x"), systemFolder: system), .allUsers)
        XCTAssertEqual(AWSCLIInstaller.scopeFor(old(dir["home/aws-cli/aws"]), systemFolder: system), .currentUser)
        XCTAssertEqual(AWSCLIInstaller.scopeFor(old(dir["brew/Cellar/awscli/2.31.0/bin/aws"]), systemFolder: system), .currentUser)
        XCTAssertEqual(AWSCLIInstaller.scopeFor(old(dir["system/aws-cli-lookalike/aws"]), systemFolder: system), .currentUser, "a folder that merely starts the same")
        XCTAssertEqual(AWSCLIInstaller.scopeFor(old("/usr/bin/aws")), .currentUser)
        XCTAssertEqual(AWSCLIInstaller.scopeFor(.missing, systemFolder: system), .currentUser)
    }

    func testUpgradeUsesTheMatchingInstaller() async throws {
        let h = InstallerHarness(test: self)
        let result = try await h.installer().upgrade(.tooOld(version: SemanticVersion(2, 31, 0), path: "/usr/local/aws-cli/aws"))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(h.requested.count, 1)
        XCTAssertEqual(h.elevatedLaunches.value.count, 1, "a system-wide install is updated system-wide")
        XCTAssertTrue(h.userLaunches.value.isEmpty)

        let user = InstallerHarness(test: self)
        let again = try await user.installer().upgrade(.broken(path: "/Users/me/aws-cli/aws", problem: "x"))
        XCTAssertTrue(again.succeeded)
        XCTAssertEqual(user.userLaunches.value.count, 1)
        XCTAssertTrue(user.elevatedLaunches.value.isEmpty)
    }

    // MARK: The link in ~/.local/bin

    func testTheUserLinkIsCreatedReplacedAndLeftAloneWhenItIsNotALink() throws {
        let home = makeScratch("dsh-aws-home")
        var installer = AWSCLIInstaller(homeDirectory: home.path, workFolder: home["work"])
        installer.platformProblem = nil
        let link = home[".local/bin/aws"]
        let target = home["aws-cli/aws"]
        let manager = FileManager.default

        // Nothing there yet: the folder and the link are made.
        XCTAssertNil(installer.linkIntoUserBin())
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link), target)
        // Already right: untouched.
        XCTAssertNil(installer.linkIntoUserBin())
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link), target)
        // A link to somewhere else (an older install), or to nothing at all: replaced.
        try manager.removeItem(atPath: link)
        try manager.createSymbolicLink(atPath: link, withDestinationPath: "/nonexistent/old/aws")
        XCTAssertNil(installer.linkIntoUserBin())
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link), target)
        // A real file the user put there: left alone, with a word about it.
        try manager.removeItem(atPath: link)
        home.write(".local/bin/aws", "#!/bin/sh\necho mine\n", executable: true)
        let note = installer.linkIntoUserBin()
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("isn't a link") == true)
        XCTAssertEqual(try String(contentsOfFile: link, encoding: .utf8), "#!/bin/sh\necho mine\n")
        XCTAssertNil(try? manager.destinationOfSymbolicLink(atPath: link))
    }

    func testAnUnwritableLinkFolderDoesNotFailTheInstall() async throws {
        let h = InstallerHarness(test: self)
        // ~/.local is a file, so ~/.local/bin can't be made.
        h.home.write(".local", "in the way")
        let result = try await h.installer().install()
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertTrue(result.message.hasPrefix("AWS CLI 2.37.5 is installed."))
        XCTAssertTrue(result.message.contains("DSH couldn't link"), result.message)
        XCTAssertTrue(result.message.contains("DSH uses \(h.home["aws-cli/aws"]) directly"), result.message)
    }

    // MARK: Exit codes, platforms, signatures

    func testMapsWhatTheInstallerSaid() {
        let asRoot = "installer: Must be run as root to install this package.\n"
        let cases: [(result: AWSCLIResult, elevated: Bool, outcome: AWSCLIInstallOutcome, homebrew: Bool)] = [
            (AWSCLIResult(exitCode: 0, stdout: "installer: The install was successful.\n"), false, .installed, false),
            (AWSCLIResult(exitCode: 0), true, .installed, false),
            (AWSCLIResult(exitCode: 1, stderr: asRoot), false, .needsAdministrator, true),
            (AWSCLIResult(exitCode: 1, stdout: "installer: The install failed. (nope)\n"), false, .failed, true),
            (AWSCLIResult(exitCode: 1, stdout: "installer: The install failed. (nope)\n"), true, .failed, true),
            (AWSCLIResult(exitCode: 1, stderr: "0:143: execution error: User canceled. (-128)\n"), true, .cancelled, false),
            (AWSCLIResult(exitCode: 1, stderr: "0:143: execution error: The administrator user name or password was incorrect. (-60007)\n"), true, .needsAdministrator, true),
            (AWSCLIResult(exitCode: -1, timedOut: true), false, .failed, true),
            // osascript's own words only count for the elevated run.
            (AWSCLIResult(exitCode: 1, stderr: "User canceled. (-128)"), false, .failed, true),
        ]
        for (index, entry) in cases.enumerated() {
            let mapped = AWSCLIInstaller.mapInstallerResult(entry.result, elevated: entry.elevated)
            XCTAssertEqual(mapped.outcome, entry.outcome, "case \(index): \(mapped.message)")
            XCTAssertEqual(mapped.exitCode, entry.result.exitCode, "case \(index)")
            XCTAssertEqual(mapped.canTryHomebrew, entry.homebrew, "case \(index)")
            XCTAssertFalse(mapped.message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let generic = AWSCLIInstaller.mapInstallerResult(AWSCLIResult(exitCode: 73, stdout: "installer: Package name is X\ninstaller: The install failed. (boom)\n"))
        XCTAssertTrue(generic.message.contains("error 73"))
        XCTAssertTrue(generic.message.contains("The install failed. (boom)"))
        XCTAssertFalse(generic.message.contains("installer: The install failed"), "the tool's own prefix is dropped")
        XCTAssertTrue(generic.message.contains("/var/log/install.log"))
        XCTAssertTrue(AWSCLIInstaller.mapInstallerResult(AWSCLIResult(exitCode: 1)).message.contains("error 1."))
    }

    func testKnowsWhereTheInstallerRuns() {
        func version(_ major: Int, _ minor: Int) -> OperatingSystemVersion { OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0) }
        let cases: [(isMac: Bool, version: OperatingSystemVersion, architecture: String, problem: Bool)] = [
            (false, version(14, 0), "arm64", true),
            (true, version(15, 2), "arm64", false),    // Apple silicon
            (true, version(14, 0), "x86_64", false),   // Intel
            (true, version(26, 0), "arm64e", false),
            (true, version(10, 15), "x86_64", false),
            (true, version(10, 14), "x86_64", true),   // too old
            (true, version(9, 9), "x86_64", true),
            (true, version(14, 0), "i386", true),      // neither
        ]
        for entry in cases {
            let problem = AWSCLIInstaller.platformProblemFor(isMacOS: entry.isMac, osVersion: entry.version, architecture: entry.architecture)
            XCTAssertEqual(problem != nil, entry.problem, "\(entry)")
        }
        XCTAssertTrue(AWSCLIInstaller.platformProblemFor(isMacOS: true, osVersion: version(10, 14), architecture: "x86_64")?.contains("10.15") == true)
        XCTAssertNil(AWSCLIInstaller.currentPlatformProblem(), "the Macs this app runs on can run the installer")
    }

    // MARK: Signatures

    func testReadsWhatPkgutilPrintsForAnAmazonPackage() throws {
        let signature = try XCTUnwrap(AWSCLIInstaller.parseSignature(installerAmazonSignedReport))
        XCTAssertEqual(signature.status, "signed by a developer certificate issued by Apple for distribution")
        XCTAssertEqual(signature.certificates, ["Developer ID Installer: AMZN Mobile LLC (94KV3E626L)", "Developer ID Certification Authority", "Apple Root CA"])
        XCTAssertEqual(signature.signer, "Developer ID Installer: AMZN Mobile LLC (94KV3E626L)")
        XCTAssertTrue(signature.isTrusted)
        let verdict = AWSCLIInstaller.isAmazonSignature(signature)
        XCTAssertTrue(verdict.accepted, verdict.reason)
        // The team ID is what identifies Amazon, whatever the company name in front of it says.
        XCTAssertTrue(AWSCLIInstaller.isAmazonSignature(installerAmazonSigned(name: "Amazon Web Services, Inc.")).accepted)
        XCTAssertTrue(AWSCLIInstaller.isAmazonSignature(installerAmazonSigned(name: "Amazon.com Services LLC")).accepted)
        // A non-zero exit from pkgutil overrules a hopeful-looking Status line.
        XCTAssertFalse(try XCTUnwrap(AWSCLIInstaller.parseSignature(installerAmazonSignedReport, exitCode: 1)).isTrusted)
    }

    func testReadsWhatPkgutilPrintsForPackagesThatAreNotValid() throws {
        let none = try XCTUnwrap(AWSCLIInstaller.parseSignature(installerNoSignatureReport, exitCode: 1))
        XCTAssertEqual(none.status, "no signature")
        XCTAssertFalse(none.isTrusted)
        XCTAssertTrue(none.certificates.isEmpty)
        let invalid = try XCTUnwrap(AWSCLIInstaller.parseSignature(installerInvalidSignatureReport, exitCode: 1))
        XCTAssertEqual(invalid.status, "invalid signature")
        XCTAssertFalse(invalid.isTrusted)
        let untrusted = try XCTUnwrap(AWSCLIInstaller.parseSignature(installerUntrustedReport, exitCode: 1))
        XCTAssertEqual(untrusted.status, "signed by untrusted certificate")
        XCTAssertEqual(untrusted.certificates, ["Software Update"])
        XCTAssertFalse(untrusted.isTrusted, "\"signed by\" alone doesn't make it trusted")
        // Even with a zero exit, only the known good statuses count.
        for status in ["no signature", "invalid signature", "signed by untrusted certificate", "signed by a certificate that has since expired", ""] {
            XCTAssertFalse(try XCTUnwrap(AWSCLIInstaller.parseSignature("Package \"x\":\n   Status: \(status)\n", exitCode: 0)).isTrusted, status)
        }
        // Statuses macOS uses for trusted signatures.
        for status in ["signed by a developer certificate issued by Apple for distribution", "signed by a certificate trusted by macOS",
                       "signed by a certificate trusted by Mac OS X", "signed Apple Software"] {
            XCTAssertTrue(try XCTUnwrap(AWSCLIInstaller.parseSignature("Package \"x\":\n   Status: \(status)\n")).isTrusted, status)
        }
    }

    func testPkgutilErrorsAreNotSignatureReports() {
        for output in ["Could not open package: notapkg.txt\n", "Package does not exist: /nonexistent/file.pkg\n", "", "gibberish"] {
            XCTAssertNil(AWSCLIInstaller.parseSignature(output, exitCode: 1), output)
        }
    }

    func testOnlyAmazonsTeamAndOnlyInstallerIdentitiesPass() {
        func verdict(_ signer: String?, trusted: Bool = true) -> (accepted: Bool, reason: String) {
            AWSCLIInstaller.isAmazonSignature(AWSPackageSignature(status: trusted ? "signed by a developer certificate issued by Apple for distribution" : "invalid signature",
                                                                  certificates: signer.map { [$0] } ?? [], isTrusted: trusted))
        }
        XCTAssertTrue(verdict("Developer ID Installer: AMZN Mobile LLC (94KV3E626L)").accepted)
        XCTAssertTrue(verdict("Developer ID Installer: Some (Odd) Name (94KV3E626L)").accepted, "parentheses in the company name")
        let mallory = verdict("Developer ID Installer: Mallory (ABCDE12345)")
        XCTAssertFalse(mallory.accepted)
        XCTAssertTrue(mallory.reason.contains("Mallory"), mallory.reason)
        XCTAssertFalse(verdict("Developer ID Installer: Amazon Web Services, Inc. (ABCDE12345)").accepted, "the name alone proves nothing")
        XCTAssertFalse(verdict("Developer ID Application: AMZN Mobile LLC (94KV3E626L)").accepted, "an app-signing identity is not an installer identity")
        XCTAssertFalse(verdict("Developer ID Installer: AMZN Mobile LLC (94KV3E626L) extra").accepted)
        XCTAssertFalse(verdict("Developer ID Installer: AMZN Mobile LLC (94kv3e626l)").accepted, "team IDs are upper-case")
        let none = verdict(nil)
        XCTAssertFalse(none.accepted)
        XCTAssertTrue(none.reason.contains("no signing certificate"))
        let invalid = verdict("Developer ID Installer: AMZN Mobile LLC (94KV3E626L)", trusted: false)
        XCTAssertFalse(invalid.accepted, "a valid-looking identity on an invalid signature")
        XCTAssertTrue(invalid.reason.contains("invalid signature"), invalid.reason)
        XCTAssertTrue(AWSCLIInstaller.isAmazonSignature(AWSPackageSignature(status: "", certificates: [], isTrusted: false)).reason.contains("missing"))
        XCTAssertEqual(AWSCLIInstaller.amazonTeamIDs, ["94KV3E626L"])
    }

    func testTheRealSignatureCheckReportsWhatPkgutilSays() async throws {
        let dir = makeScratch()
        // The real /usr/sbin/pkgutil, on things that are not packages: its own error is passed on.
        let text = dir.write("notapkg.pkg", "just text")
        let notAPackage = await assertThrows(AWSCLIInstallerError.self) { _ = try await AWSCLIInstaller.pkgutilSignature(of: text) }
        XCTAssertTrue(notAPackage?.message.contains("Could not open package") == true, "\(String(describing: notAPackage))")
        let missing = await assertThrows(AWSCLIInstallerError.self) { _ = try await AWSCLIInstaller.pkgutilSignature(of: dir["nothing.pkg"]) }
        XCTAssertTrue(missing?.message.contains("Package does not exist") == true, "\(String(describing: missing))")
        _ = await assertThrows(AWSCLIStartError.self) { _ = try await AWSCLIInstaller.pkgutilSignature(of: text, tool: "/nonexistent/pkgutil") }
    }

    func testTheSignatureCheckPassesPkgutilsExitCodeAlong() async throws {
        let dir = makeScratch()
        let good = dir.write("pkgutil-good", "#!/bin/sh\ncat <<'REPORT'\n\(installerAmazonSignedReport)REPORT\nexit 0\n", executable: true)
        let signature = try await AWSCLIInstaller.pkgutilSignature(of: "/some/AWSCLIV2.pkg", tool: good)
        XCTAssertTrue(signature.isTrusted)
        XCTAssertTrue(AWSCLIInstaller.isAmazonSignature(signature).accepted)
        let contradiction = dir.write("pkgutil-bad", "#!/bin/sh\ncat <<'REPORT'\n\(installerAmazonSignedReport)REPORT\nexit 1\n", executable: true)
        let distrusted = try await AWSCLIInstaller.pkgutilSignature(of: "/some/AWSCLIV2.pkg", tool: contradiction)
        XCTAssertFalse(distrusted.isTrusted, "pkgutil failing overrules its own Status line")
        // The arguments pkgutil gets.
        let echo = dir.write("pkgutil-args", "#!/bin/sh\necho \"Package \\\"x\\\":\"\necho \"   Status: args=[$*]\"\n", executable: true)
        let args = try await AWSCLIInstaller.pkgutilSignature(of: "/a b/it's.pkg", tool: echo)
        XCTAssertEqual(args.status, "args=[--check-signature /a b/it's.pkg]")
    }

    // MARK: Files

    func testKnowsAPackageWhenItSeesOne() throws {
        let dir = makeScratch()
        XCTAssertTrue(AWSCLIInstaller.hasPackageHeader(dir.writeData("real.pkg", installerFakePackage(size: 100))))
        XCTAssertFalse(AWSCLIInstaller.hasPackageHeader(dir.write("html.pkg", "<html>proxy says no</html>")))
        XCTAssertFalse(AWSCLIInstaller.hasPackageHeader(dir.write("short.pkg", "xar")))
        XCTAssertFalse(AWSCLIInstaller.hasPackageHeader(dir.write("empty.pkg", "")))
        XCTAssertFalse(AWSCLIInstaller.hasPackageHeader(dir["missing.pkg"]))
        XCTAssertFalse(AWSCLIInstaller.hasPackageHeader(dir.path), "a folder")
    }

    func testTheInstallerArgumentsForBothScopes() {
        XCTAssertEqual(AWSCLIInstaller.installerArguments(scope: .currentUser, package: "/t/AWSCLIV2.pkg", choices: "/t/choices.xml"),
                       ["-pkg", "/t/AWSCLIV2.pkg", "-target", "CurrentUserHomeDirectory", "-applyChoiceChangesXML", "/t/choices.xml"])
        XCTAssertEqual(AWSCLIInstaller.installerArguments(scope: .allUsers, package: "/t/AWSCLIV2.pkg", choices: "/t/choices.xml"),
                       ["-pkg", "/t/AWSCLIV2.pkg", "-target", "/"], "the choices file is for the per-user install only")
        XCTAssertEqual(AWSCLIInstaller.userInstallPath(home: "/Users/me"), "/Users/me/aws-cli/aws")
        XCTAssertEqual(AWSCLIInstaller.userLinkPath(home: "/Users/me"), "/Users/me/.local/bin/aws")
    }

    func testTheChoicesFileSurvivesAnAwkwardHomeFolder() throws {
        let home = #"/Users/o'brien & "sons" <ltd>"#
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: AWSCLIInstaller.choicesXML(home: home), format: nil) as? [[String: String]])
        XCTAssertEqual(plist.first?["attributeSetting"], home)
        XCTAssertEqual(plist.first?["choiceIdentifier"], "default")
        XCTAssertEqual(plist.first?["choiceAttribute"], "customLocation")
        let text = String(decoding: AWSCLIInstaller.choicesXML(home: "/Users/me"), as: UTF8.self)
        XCTAssertTrue(text.contains("<key>choiceAttribute</key>") && text.contains("<string>customLocation</string>"), text)
    }

    func testTheDefaultWorkFolderIsInThePrivateTemporaryFolder() {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        XCTAssertEqual(AWSCLIInstaller.defaultWorkFolder(), URL(fileURLWithPath: temporary).appendingPathComponent("dsh-aws-cli").path)
        XCTAssertEqual(AWSCLIInstaller().workFolder, AWSCLIInstaller.defaultWorkFolder())
        XCTAssertEqual(AWSCLIInstaller().homeDirectory, NSHomeDirectory())
    }

    func testCleanupKeepsOnlyWhatItIsToldTo() throws {
        let dir = makeScratch()
        dir.write("job/a.pkg", "a")
        dir.write("job/install.log", "log")
        dir.write("job/sub/b", "b")
        AWSCLIInstaller.cleanup(dir["job"], keep: dir["job/install.log"])
        XCTAssertEqual(dir.files(), ["job/install.log"])
        AWSCLIInstaller.cleanup(dir["job"], keep: nil)
        XCTAssertFalse(dir.exists("job"), "an empty folder goes too")
        AWSCLIInstaller.cleanup(dir["never-existed"], keep: nil) // no crash
    }

    // MARK: The download

    func testDownloadReportsProgressAsItGoes() async throws {
        let dir = makeScratch()
        let package = installerFakePackage(size: 1_000_000)
        AWSDownloadStub.configure(.init(body: package))
        let reports = AWSLockedBox<[(Int64, Int64?)]>([])
        let destination = dir["AWSCLIV2.pkg"]
        try await AWSCLIInstaller.downloadFile(from: URL(string: "https://awscli.amazonaws.com/AWSCLIV2.pkg")!, to: destination,
                                               using: AWSDownloadStub.session()) { done, total in reports.append((done, total)) }
        XCTAssertEqual(FileManager.default.contents(atPath: destination), package)
        XCTAssertEqual(dir.files(), ["AWSCLIV2.pkg"], "no .partial file is left")
        let all = reports.value
        XCTAssertGreaterThanOrEqual(all.count, 4)
        XCTAssertTrue(all.allSatisfy { $0.1 == 1_000_000 })
        XCTAssertEqual(all.map(\.0), all.map(\.0).sorted())
        XCTAssertEqual(all.first?.0, 0)
        XCTAssertEqual(all.last?.0, 1_000_000)
        // About every 256 KB, not every chunk.
        XCTAssertLessThanOrEqual(all.count, 8)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testDownloadWithoutALengthReportsWhatItGot() async throws {
        let dir = makeScratch()
        let package = installerFakePackage(size: 200_000)
        AWSDownloadStub.configure(.init(body: package, sendLength: false))
        let reports = AWSLockedBox<[(Int64, Int64?)]>([])
        try await AWSCLIInstaller.downloadFile(from: URL(string: "https://awscli.amazonaws.com/AWSCLIV2.pkg")!, to: dir["p.pkg"],
                                               using: AWSDownloadStub.session()) { done, total in reports.append((done, total)) }
        XCTAssertEqual(FileManager.default.contents(atPath: dir["p.pkg"]), package)
        XCTAssertEqual(reports.value.last?.0, 200_000)
        XCTAssertEqual(reports.value.last?.1, 200_000, "the final report is complete even without a declared length")
        XCTAssertNil(reports.value.first?.1)
    }

    func testDownloadRefusesAnErrorPageAndKeepsNothing() async throws {
        let dir = makeScratch()
        AWSDownloadStub.configure(.init(status: 403, body: Data("Forbidden".utf8)))
        let failure = await assertThrows(AWSCLIInstallerError.self) {
            try await AWSCLIInstaller.downloadFile(from: URL(string: "https://awscli.amazonaws.com/AWSCLIV2.pkg")!, to: dir["p.pkg"],
                                                   using: AWSDownloadStub.session()) { _, _ in }
        }
        XCTAssertTrue(failure?.message.contains("403") == true, "\(String(describing: failure))")
        XCTAssertTrue(dir.files().isEmpty)
    }

    func testDownloadReplacesAnOlderFileAtomically() async throws {
        let dir = makeScratch()
        dir.write("p.pkg", "old contents")
        let package = installerFakePackage(size: 70_000)
        AWSDownloadStub.configure(.init(body: package))
        try await AWSCLIInstaller.downloadFile(from: URL(string: "https://awscli.amazonaws.com/AWSCLIV2.pkg")!, to: dir["p.pkg"],
                                               using: AWSDownloadStub.session()) { _, _ in }
        XCTAssertEqual(FileManager.default.contents(atPath: dir["p.pkg"]), package)
    }

    // MARK: Running the installer for real (stand-in programs)

    func testTheInstallerRunsToTheEndEvenIfTheTaskIsCancelled() async throws {
        let dir = makeScratch()
        let tool = dir.write("installer", """
            #!/bin/sh
            cd '\(dir.path)' || exit 99
            echo "installer: Package name is AWS Command Line Interface"
            echo "args=[$*]"
            sleep 1
            echo done > finished.marker
            echo "installer: The install was successful."
            """, executable: true)
        let lines = AWSLockedBox<[String]>([])
        let launch = AWSCLIInstallerLaunch(executable: tool, arguments: ["-pkg", "/a b.pkg", "-target", "/"], packagePath: "/a b.pkg", elevated: false)
        let task = Task { try await AWSCLIInstaller.runToCompletion(launch) { lines.append($0) } }
        await waitUntil(10, "the installer to start") { !lines.value.isEmpty }
        task.cancel() // half an installation is worse than waiting
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(dir.exists("finished.marker"), "cancelling must not stop a running installer")
        XCTAssertEqual(lines.value, ["installer: Package name is AWS Command Line Interface", "args=[-pkg /a b.pkg -target /]", "installer: The install was successful."])
    }

    func testTheAdministratorPromptRunsTheCommandAndReportsItsExitStatus() async throws {
        let dir = makeScratch()
        // Stand-ins for osascript: they record the script they were given and answer the way it does.
        let succeeds = dir.write("osascript-ok", """
            #!/bin/sh
            [ "$1" = "-e" ] || exit 64
            printf '%s' "$2" > '\(dir.path)/script.txt'
            printf 'installer: Package name is AWS Command Line Interface\\ninstaller: The install was successful.\\nDSH_EXIT_STATUS=0\\n'
            """, executable: true)
        let fails = dir.write("osascript-fails", "#!/bin/sh\nprintf 'installer: The install failed. (boom)\\nDSH_EXIT_STATUS=1\\n'\n", executable: true)
        let declined = dir.write("osascript-declined", "#!/bin/sh\necho '0:143: execution error: User canceled. (-128)' >&2\nexit 1\n", executable: true)
        let silent = dir.write("osascript-silent", "#!/bin/sh\necho 'something else'\n", executable: true)
        let launch = AWSCLIInstallerLaunch(arguments: ["-pkg", "/tmp/it's here/AWSCLIV2.pkg", "-target", "/"], packagePath: "/tmp/it's here/AWSCLIV2.pkg", elevated: true)
        let lines = AWSLockedBox<[String]>([])

        let ok = try await AWSCLIInstaller.runWithAdministratorPrivileges(launch, osascript: succeeds) { lines.append($0) }
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertEqual(ok.stdout, "installer: Package name is AWS Command Line Interface\ninstaller: The install was successful.")
        XCTAssertEqual(lines.value, ["installer: Package name is AWS Command Line Interface", "installer: The install was successful."])
        XCTAssertEqual(try String(contentsOfFile: dir["script.txt"], encoding: .utf8),
                       AWSCLIInstaller.appleScript(elevating: "/usr/sbin/installer", arguments: launch.arguments))
        XCTAssertEqual(AWSCLIInstaller.mapInstallerResult(ok, elevated: true).outcome, .installed)

        let failed = try await AWSCLIInstaller.runWithAdministratorPrivileges(launch, osascript: fails) { _ in }
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertEqual(AWSCLIInstaller.mapInstallerResult(failed, elevated: true).outcome, .failed)

        let refused = try await AWSCLIInstaller.runWithAdministratorPrivileges(launch, osascript: declined) { _ in }
        XCTAssertEqual(AWSCLIInstaller.mapInstallerResult(refused, elevated: true).outcome, .cancelled)

        let unclear = try await AWSCLIInstaller.runWithAdministratorPrivileges(launch, osascript: silent) { _ in }
        XCTAssertNotEqual(unclear.exitCode, 0, "without the exit status marker the install can't be called a success")
        XCTAssertEqual(AWSCLIInstaller.mapInstallerResult(unclear, elevated: true).outcome, .failed)

        _ = await assertThrows(AWSCLIStartError.self) {
            _ = try await AWSCLIInstaller.runWithAdministratorPrivileges(launch, osascript: "/nonexistent/osascript") { _ in }
        }
    }

    // MARK: The administrator script

    /// The text an AppleScript string literal stands for.
    private func unescapeAppleScript(_ literal: String) -> String {
        var result = ""
        var escaped = false
        for character in literal {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    func testShellQuotingSurvivesARealShell() async throws {
        let awkward = ["plain", "with space", "it's", "''", "'", #"a"b"#, "$HOME", "`date`", "$(date)", "a;b", "a && b", "line1\nline2", #"back\slash"#,
                       "*", "~", "!bang", "tab\there", "é✓ 😀", "-n"]
        for text in awkward {
            let result = try await ProcessAWSCLIRunner(executable: "/bin/sh").run(["-c", "printf '%s' \(AWSCLIInstaller.shellQuote(text))"], options: AWSCLIRunOptions(timeout: 20))
            XCTAssertEqual(result.stdout, text, "quoted as \(AWSCLIInstaller.shellQuote(text))")
        }
        XCTAssertEqual(AWSCLIInstaller.shellQuote(""), "''")
    }

    func testTheAdministratorScriptQuotesEverythingAndKeepsTheExitStatus() async throws {
        let dir = makeScratch()
        // A stand-in `installer` that prints its arguments one per line and fails with 7.
        let tool = dir.write("it's an installer", #"""
            #!/bin/sh
            for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
            echo "to stderr" >&2
            exit 7
            """#, executable: true)
        let arguments = ["-pkg", #"/tmp/a b/it's "quoted" $HOME `x`/AWSCLIV2.pkg"#, "-target", "/"]
        let script = AWSCLIInstaller.appleScript(elevating: tool, arguments: arguments)

        // do shell script "<literal>" with administrator privileges
        let prefix = "do shell script \""
        let suffix = "\" with administrator privileges"
        XCTAssertTrue(script.hasPrefix(prefix) && script.hasSuffix(suffix), script)
        let literal = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        XCTAssertFalse(literal.contains("\n"), "the literal is one line")
        // Every quote inside the literal is escaped: the first unescaped one would end the string early.
        var escaped = false
        for character in literal {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            XCTAssertNotEqual(character, "\"", "an unescaped quote in \(literal)")
        }
        let shell = unescapeAppleScript(literal)
        XCTAssertTrue(shell.hasPrefix("{ "), shell)
        XCTAssertTrue(shell.contains("2>&1; echo \"DSH_EXIT_STATUS=$?\"; }"), shell)

        // Run what `do shell script` would run (it uses /bin/sh -c): the arguments arrive intact, the
        // exit status is echoed after the output.
        let result = try await ProcessAWSCLIRunner(executable: "/bin/sh").run(["-c", shell], options: AWSCLIRunOptions(timeout: 20))
        XCTAssertEqual(result.exitCode, 0, "the wrapper itself succeeds; the status is in the output")
        let parsed = try XCTUnwrap(AWSCLIInstaller.parseElevatedOutput(result.stdout))
        XCTAssertEqual(parsed.exitCode, 7)
        XCTAssertEqual(parsed.output, "arg=[-pkg]\narg=[/tmp/a b/it's \"quoted\" $HOME `x`/AWSCLIV2.pkg]\narg=[-target]\narg=[/]\nto stderr")
    }

    func testAppleScriptStringsEscapeWhatWouldEndOrBreakThem() {
        XCTAssertEqual(AWSCLIInstaller.appleScriptEscape(#"a"b\c"#), #"a\"b\\c"#)
        XCTAssertEqual(AWSCLIInstaller.appleScriptEscape("x\ny\rz\tw"), #"x\ny\rz\tw"#)
        XCTAssertEqual(AWSCLIInstaller.appleScriptEscape("plain $? 'single'"), "plain $? 'single'")
        for text in [#"a"b\c"#, "x\ny\rz\tw", #"\"#, #"\\""#, "", "é✓"] {
            XCTAssertEqual(unescapeAppleScript(AWSCLIInstaller.appleScriptEscape(text)), text)
        }
    }

    func testTheElevatedOutputIsSplitIntoOutputAndExitStatus() {
        let split = AWSCLIInstaller.parseElevatedOutput("line one\nline two\nDSH_EXIT_STATUS=0\n")
        XCTAssertEqual(split?.output, "line one\nline two")
        XCTAssertEqual(split?.exitCode, 0)
        XCTAssertEqual(AWSCLIInstaller.parseElevatedOutput("DSH_EXIT_STATUS=127")?.exitCode, 127)
        XCTAssertEqual(AWSCLIInstaller.parseElevatedOutput("DSH_EXIT_STATUS=127")?.output, "")
        XCTAssertEqual(AWSCLIInstaller.parseElevatedOutput("a\r\nDSH_EXIT_STATUS=2\r\n")?.exitCode, 2)
        // The last marker counts; text that merely mentions it doesn't.
        XCTAssertEqual(AWSCLIInstaller.parseElevatedOutput("DSH_EXIT_STATUS=0\nmore\nDSH_EXIT_STATUS=3")?.exitCode, 3)
        XCTAssertNil(AWSCLIInstaller.parseElevatedOutput("no marker"))
        XCTAssertNil(AWSCLIInstaller.parseElevatedOutput("DSH_EXIT_STATUS=abc"))
        XCTAssertNil(AWSCLIInstaller.parseElevatedOutput("said DSH_EXIT_STATUS=0"))
    }

    // MARK: Homebrew

    func testHomebrewIsTheFallback() async throws {
        let h = InstallerHarness(test: self)
        let ran = AWSLockedBox<[String]?>(nil)
        var installer = h.installer()
        installer.runBrew = { arguments, onLine in
            ran.mutate { $0 = arguments }
            onLine("==> Fetching awscli")
            onLine("==> Pouring awscli--2.37.5.arm64_sequoia.bottle.tar.gz")
            return 0
        }
        let result = try await installer.installWithHomebrew(progress: h.progress.handler)
        XCTAssertEqual(result.outcome, .installed)
        XCTAssertEqual(result.message, "AWS CLI 2.37.5 is installed.")
        XCTAssertEqual(result.cli, installerReadyAfter)
        XCTAssertEqual(ran.value, ["install", "awscli"])
        XCTAssertTrue(h.progress.items.contains { $0.detail == "==> Pouring awscli--2.37.5.arm64_sequoia.bottle.tar.gz" })
        XCTAssertEqual(h.progress.stages, ["Installing the AWS CLI with Homebrew", "Checking the installation"])
        XCTAssertTrue(h.requested.isEmpty, "Homebrew doesn't use the package")
    }

    func testHomebrewFailuresShowTheCode() async throws {
        let h = InstallerHarness(test: self)
        h.after = .missing
        var installer = h.installer()
        installer.runBrew = { _, _ in 1 }
        let result = try await installer.installWithHomebrew()
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("exit code 1"), result.message)
        XCTAssertTrue(result.message.contains("isn't installed"))
        installer.runBrew = { _, _ in throw AWSCLIStartError(executable: "/opt/homebrew/bin/brew", reason: "no.") }
        let unstarted = try await installer.installWithHomebrew()
        XCTAssertEqual(unstarted.outcome, .failed)
        XCTAssertTrue(unstarted.message.hasPrefix("Homebrew didn't start"), unstarted.message)
    }

    func testWithoutHomebrewTheFallbackSaysSo() async throws {
        let h = InstallerHarness(test: self)
        var installer = h.installer()
        installer.runBrew = nil
        installer.findBrew = { nil }
        XCTAssertFalse(installer.homebrewAvailable)
        let result = try await installer.installWithHomebrew()
        XCTAssertEqual(result.outcome, .notSupported)
        XCTAssertTrue(result.message.contains("Homebrew isn't installed"), result.message)
        XCTAssertTrue(result.message.contains("https://awscli.amazonaws.com/AWSCLIV2.pkg"))
        installer.findBrew = { "/opt/homebrew/bin/brew" }
        XCTAssertTrue(installer.homebrewAvailable)
    }

    func testTheRealBrewRunnerStreamsLinesAndReturnsTheExitCode() async throws {
        let dir = makeScratch()
        let brew = dir.write("brew", "#!/bin/sh\necho \"args=[$*] hints=[$HOMEBREW_NO_ENV_HINTS]\"\necho '==> done'\nexit 3\n", executable: true)
        let h = InstallerHarness(test: self)
        h.after = .missing
        var installer = h.installer()
        installer.runBrew = nil
        installer.findBrew = { brew }
        let result = try await installer.installWithHomebrew(progress: h.progress.handler)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(h.progress.items.contains { $0.detail == "args=[install awscli] hints=[1]" }, "\(h.progress.items)")
        XCTAssertTrue(h.progress.items.contains { $0.detail == "==> done" })
    }

    func testHomebrewUpgradesItsOwnCliInsteadOfInstallingAgain() throws {
        let dir = makeScratch()
        dir.write("prefix/Cellar/awscli/2.31.0/bin/aws", "", executable: true)
        try FileManager.default.createDirectory(atPath: dir["prefix/bin"], withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir["prefix/bin/aws"], withDestinationPath: "../Cellar/awscli/2.31.0/bin/aws")
        let old = AWSCLIStatus.tooOld(version: SemanticVersion(2, 31, 0), path: dir["prefix/bin/aws"])
        XCTAssertEqual(AWSCLIInstaller.homebrewArguments(current: old), ["upgrade", "awscli"])
        XCTAssertEqual(AWSCLIInstaller.homebrewArguments(current: .tooOld(version: SemanticVersion(2, 31, 0), path: "/usr/local/aws-cli/aws")), ["install", "awscli"])
        XCTAssertEqual(AWSCLIInstaller.homebrewArguments(current: .missing), ["install", "awscli"])
        XCTAssertEqual(AWSCLIInstaller.homebrewArguments(), ["install", "awscli"])
    }

    func testFindsHomebrewOnPathOrAtItsUsualPlaces() {
        let dir = makeScratch()
        let onPath = dir.write("bin/brew", "", executable: true)
        XCTAssertEqual(AWSCLIInstaller.locateBrew(environment: ["PATH": dir["bin"]]), onPath)
        // Not on PATH (a GUI app's minimal PATH): the standard prefixes are looked in.
        let usual = AWSCLIInstaller.locateBrew(environment: ["PATH": "/usr/bin:/bin"], fileExists: { $0 == "/opt/homebrew/bin/brew" })
        XCTAssertEqual(usual, "/opt/homebrew/bin/brew")
        let intel = AWSCLIInstaller.locateBrew(environment: ["PATH": ""], fileExists: { $0 == "/usr/local/bin/brew" })
        XCTAssertEqual(intel, "/usr/local/bin/brew")
        XCTAssertNil(AWSCLIInstaller.locateBrew(environment: ["PATH": dir["nothing"]], fileExists: { _ in false }))
    }
}
