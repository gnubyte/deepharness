import Foundation
import Darwin

// MARK: - Installing the AWS CLI on macOS
//
// The same steps as AWS's own instructions for macOS: download the installer package from
// awscli.amazonaws.com, refuse it unless macOS says its signature is valid and it is Amazon's, run
// Apple's `installer`, and check `aws --version` where the package puts the CLI (this app's PATH
// predates the install, and a GUI app's PATH is minimal anyway). macOS ships only a .pkg:
//
//   for this user   installer -pkg AWSCLIV2.pkg -target CurrentUserHomeDirectory
//                             -applyChoiceChangesXML choices.xml   → ~/aws-cli/aws
//                   (no administrator rights, no prompt; the choices file is AWS's documented
//                   "install for the current user only" recipe, and ~/.local/bin/aws is linked to
//                   it afterwards as the same document does)
//   for everyone    installer -pkg AWSCLIV2.pkg -target /           → /usr/local/aws-cli, linked
//                   from /usr/local/bin/aws; needs an administrator, so it runs through
//                   osascript's `do shell script … with administrator privileges` (the system's own
//                   password / Touch ID sheet)
//
// When the package route fails for a reason other than the user saying no, Homebrew (`brew install
// awscli`) is the fallback, when `brew` is on this Mac.

public enum AWSCLIInstallScope: Sendable, Equatable {
    /// Just for this Mac user: no administrator rights needed.
    case currentUser
    /// For everyone on this Mac (/usr/local): macOS asks for an administrator's approval.
    case allUsers
}

/// Where the install is. `done` and `total` are bytes while downloading.
public struct AWSCLIInstallProgress: Sendable, Equatable {
    public var stage: String
    public var done: Int64
    public var total: Int64?
    public var detail: String?

    public init(stage: String, done: Int64 = 0, total: Int64? = nil, detail: String? = nil) {
        self.stage = stage
        self.done = done
        self.total = total
        self.detail = detail
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(max(Double(done) / Double(total), 0), 1)
    }
}

public enum AWSCLIInstallOutcome: Sendable, Equatable {
    case installed
    /// The user declined the administrator prompt.
    case cancelled
    /// Installing for everyone needs an administrator who isn't there (or whose password wasn't accepted).
    case needsAdministrator
    case downloadFailed
    /// The download wasn't validly signed by Amazon, or the signature couldn't be checked; nothing ran.
    case signatureRejected
    /// This Mac can't run the AWS CLI installer (old macOS, unknown processor, no Homebrew).
    case notSupported
    case failed
}

/// How an install ended, in words for the guide.
public struct AWSCLIInstallResult: Sendable, Equatable {
    public var outcome: AWSCLIInstallOutcome
    public var message: String
    public var exitCode: Int?
    /// The AWS CLI found afterwards (`.ready` when it worked).
    public var cli: AWSCLIStatus?
    /// What the installer printed, kept when something went wrong.
    public var logPath: String?

    public init(outcome: AWSCLIInstallOutcome, message: String, exitCode: Int? = nil, cli: AWSCLIStatus? = nil, logPath: String? = nil) {
        self.outcome = outcome
        self.message = message
        self.exitCode = exitCode
        self.cli = cli
        self.logPath = logPath
    }

    public var succeeded: Bool { outcome == .installed }

    /// Worth offering `AWSCLIInstaller.installWithHomebrew` instead.
    public var canTryHomebrew: Bool { outcome == .failed || outcome == .needsAdministrator || outcome == .downloadFailed }
}

/// What macOS says about a package's signature (`pkgutil --check-signature`).
public struct AWSPackageSignature: Sendable, Equatable {
    /// pkgutil's "Status:" text: "signed by a developer certificate issued by Apple for distribution",
    /// "no signature", "invalid signature", "signed by untrusted certificate", …
    public var status: String
    /// The certificate chain as pkgutil prints it, signing certificate first:
    /// "Developer ID Installer: Some Company (TEAMID1234)", "Developer ID Certification Authority", …
    public var certificates: [String]
    /// True only when pkgutil succeeded and the status says the signature is valid and trusted.
    public var isTrusted: Bool

    public init(status: String, certificates: [String] = [], isTrusted: Bool) {
        self.status = status
        self.certificates = certificates
        self.isTrusted = isTrusted
    }

    /// The certificate that signed the package.
    public var signer: String? { certificates.first }
}

/// One run of Apple's `installer`: what to run and whether it needs an administrator.
public struct AWSCLIInstallerLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var packagePath: String
    public var elevated: Bool

    public init(executable: String = AWSCLIInstaller.installerTool, arguments: [String], packagePath: String, elevated: Bool) {
        self.executable = executable
        self.arguments = arguments
        self.packagePath = packagePath
        self.elevated = elevated
    }
}

/// Something went wrong that the installer explains in a sentence.
public struct AWSCLIInstallerError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// Downloads, verifies and installs the AWS CLI v2 on macOS. Every outside effect — HTTP, the signature
/// check, `installer`, the administrator prompt, Homebrew, finding the result — is a replaceable
/// property, so the flow is tested without a package, an administrator or a network. (Files are plain
/// `FileManager` work under `workFolder` and `homeDirectory`, which tests point at scratch folders.)
public struct AWSCLIInstaller: Sendable {
    public static let packageURLString = "https://awscli.amazonaws.com/AWSCLIV2.pkg"
    public static let homebrewFormula = "awscli"

    /// Apple's installer, package tool and AppleScript runner.
    public static let installerTool = "/usr/sbin/installer"
    public static let pkgutilTool = "/usr/sbin/pkgutil"
    public static let osascriptTool = "/usr/bin/osascript"

    /// The Apple Developer team that signs the AWS CLI package (the identity reads
    /// "Developer ID Installer: <company> (94KV3E626L)"). The team ID is what identifies Amazon; the
    /// company name in front of it is only a label.
    public static let amazonTeamIDs: Set<String> = ["94KV3E626L"]

    /// What the elevated script prints after `installer`, so the exit status survives osascript
    /// (whose own exit status is 1 for any failure).
    static let exitMarker = "DSH_EXIT_STATUS="

    public typealias LineHandler = @Sendable (String) -> Void
    public typealias Progress = @Sendable (AWSCLIInstallProgress) -> Void

    /// The user's home folder: where the current-user package lands (`~/aws-cli`) and where its link
    /// goes (`~/.local/bin/aws`).
    public var homeDirectory: String

    /// Where downloads go (a fresh, private folder inside it per install).
    public var workFolder: String

    /// Why this Mac can't run the installer, or nil.
    public var platformProblem: String?

    /// The package to download.
    public var packageURL: URL

    /// The download's URLSession (nil = a fresh one, which honours the system proxy).
    public var session: URLSession?

    /// Fetches the package into a file and reports (bytes so far, total bytes if known). Nil = download
    /// with `session`.
    public var download: (@Sendable (URL, String, @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Void)?

    /// Reads the downloaded file's signature. Throwing means "couldn't check", and the app then refuses
    /// to install.
    public var checkSignature: @Sendable (String) async throws -> AWSPackageSignature

    /// Runs `installer` as this user. Once it has started it is not stopped by cancelling: half an
    /// installation is worse than waiting for it.
    public var runInstaller: @Sendable (AWSCLIInstallerLaunch, @escaping LineHandler) async throws -> AWSCLIResult

    /// Runs `installer` as an administrator (macOS asks for the password). The result's exit code is
    /// `installer`'s; an administrator prompt that was declined is reported as osascript says it
    /// ("User canceled. (-128)" in `stderr`).
    public var runElevated: @Sendable (AWSCLIInstallerLaunch, @escaping LineHandler) async throws -> AWSCLIResult

    /// Runs `brew` with the given arguments, reporting its output lines; returns its exit code.
    /// Nil = find `brew` on this Mac.
    public var runBrew: (@Sendable ([String], @escaping LineHandler) async throws -> Int)?

    /// Where Homebrew is (PATH, then its two standard prefixes), or nil.
    public var findBrew: @Sendable () -> String?

    /// Finds and checks the AWS CLI after installing (the known install folders included).
    public var checkInstalled: @Sendable () async -> AWSCLIStatus

    public init(homeDirectory: String = NSHomeDirectory(), workFolder: String? = nil) {
        self.homeDirectory = homeDirectory
        self.workFolder = workFolder ?? Self.defaultWorkFolder()
        self.platformProblem = Self.currentPlatformProblem()
        self.packageURL = URL(string: Self.packageURLString)!
        self.session = nil
        self.download = nil
        self.checkSignature = { path in try await Self.pkgutilSignature(of: path) }
        self.runInstaller = { launch, onLine in try await Self.runToCompletion(launch, onLine: onLine) }
        self.runElevated = { launch, onLine in try await Self.runWithAdministratorPrivileges(launch, onLine: onLine) }
        self.runBrew = nil
        self.findBrew = { Self.locateBrew() }
        self.checkInstalled = { [home = homeDirectory] in
            await AWSCLI.check(search: AWSCLISearch.forThisMachine(home: home))
        }
    }

    /// `$TMPDIR/dsh-aws-cli` (a GUI app's TMPDIR is its private per-user temporary folder).
    public static func defaultWorkFolder() -> String {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: temporary).appendingPathComponent("dsh-aws-cli").path
    }

    // MARK: Platform

    public static func currentPlatformProblem() -> String? {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return platformProblemFor(isMacOS: true, osVersion: ProcessInfo.processInfo.operatingSystemVersion, architecture: machine)
    }

    /// Intel and Apple silicon both run the package (it is a universal build); only a system far older
    /// than this app, or a processor neither of those, is a problem.
    public static func platformProblemFor(isMacOS: Bool, osVersion: OperatingSystemVersion, architecture: String) -> String? {
        if !isMacOS {
            return "DSH installs the AWS CLI on macOS only. Install it with your system's package manager, or from https://aws.amazon.com/cli/."
        }
        if osVersion.majorVersion < 10 || (osVersion.majorVersion == 10 && osVersion.minorVersion < 15) {
            return "The AWS CLI installer needs macOS 10.15 or newer."
        }
        if architecture != "arm64" && architecture != "arm64e" && architecture != "x86_64" {
            return "The AWS CLI installer is built for Intel and Apple silicon Macs."
        }
        return nil
    }

    // MARK: Commands

    /// The path of the current-user install (the package puts `aws` in `aws-cli` under the folder it is
    /// told to install into).
    public static func userInstallPath(home: String) -> String { home + "/aws-cli/aws" }

    /// Where the current-user install is linked from, as AWS's instructions do.
    public static func userLinkPath(home: String) -> String { home + "/.local/bin/aws" }

    /// `-pkg <package> -target CurrentUserHomeDirectory -applyChoiceChangesXML <choices>` for this user;
    /// `-pkg <package> -target /` for everyone.
    public static func installerArguments(scope: AWSCLIInstallScope, package: String, choices: String?) -> [String] {
        switch scope {
        case .currentUser:
            return ["-pkg", package, "-target", "CurrentUserHomeDirectory"] + (choices.map { ["-applyChoiceChangesXML", $0] } ?? [])
        case .allUsers:
            return ["-pkg", package, "-target", "/"]
        }
    }

    /// AWS's documented choices file for "install for the current user only": the package's one choice
    /// ("default") gets a custom location, the home folder.
    public static func choicesXML(home: String) -> Data {
        let choices: [[String: String]] = [[
            "choiceIdentifier": "default",
            "choiceAttribute": "customLocation",
            "attributeSetting": home,
        ]]
        // (A property list of strings always serialises.)
        return (try? PropertyListSerialization.data(fromPropertyList: choices, format: .xml, options: 0)) ?? Data()
    }

    /// `brew install awscli`, or `brew upgrade awscli` when the CLI that needs updating is Homebrew's.
    public static func homebrewArguments(current: AWSCLIStatus? = nil) -> [String] {
        guard let path = current?.path else { return ["install", homebrewFormula] }
        let resolved = resolveSymlinks(path)
        return resolved.contains("/Cellar/awscli/") ? ["upgrade", homebrewFormula] : ["install", homebrewFormula]
    }

    /// The scope that upgrades `current` in place: all users when it is in the package's system folder
    /// (`/usr/local/aws-cli`, even when reached through the link in `/usr/local/bin`), otherwise just
    /// this user (the current-user package installs beside anything unofficial — Homebrew's, pip's —
    /// and the app then finds the new one).
    public static func scopeFor(_ current: AWSCLIStatus, systemFolder: String = "/usr/local/aws-cli") -> AWSCLIInstallScope {
        guard let path = current.path else { return .currentUser }
        let folder = resolveSymlinks(systemFolder)
        return resolveSymlinks(path).hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") ? .allUsers : .currentUser
    }

    static func resolveSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Update an installed AWS CLI that is too old (or broken): the same package, which installs over the old one.
    public func upgrade(_ current: AWSCLIStatus, progress: Progress? = nil) async throws -> AWSCLIInstallResult {
        try await install(scope: Self.scopeFor(current), progress: progress)
    }

    // MARK: Installing

    /// Download, verify and install the AWS CLI. Cancelling works until `installer` starts; from then
    /// on it runs to the end.
    public func install(scope: AWSCLIInstallScope = .currentUser, progress: Progress? = nil) async throws -> AWSCLIInstallResult {
        if let problem = platformProblem { return AWSCLIInstallResult(outcome: .notSupported, message: problem) }
        let folder = workFolder + "/" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        do {
            // A private folder: what was checked must be what gets installed.
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return AWSCLIInstallResult(outcome: .failed, message: "DSH couldn't make a folder for the AWS CLI installer (\(error.localizedDescription)).")
        }
        let name = packageURL.lastPathComponent.isEmpty ? "AWSCLIV2.pkg" : packageURL.lastPathComponent
        let package = folder + "/" + name
        let log = folder + "/install.log"
        var keepLog = false
        defer { Self.cleanup(folder, keep: keepLog ? log : nil) }

        do {
            try await fetch(packageURL, to: package, progress: progress)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return AWSCLIInstallResult(outcome: .downloadFailed,
                                       message: "DSH couldn't download the AWS CLI installer (\(error.localizedDescription)). Check your internet connection and try again.")
        }
        if !Self.hasPackageHeader(package) {
            return AWSCLIInstallResult(outcome: .downloadFailed,
                                       message: "The download isn't a macOS installer package (a proxy or firewall may have replaced it). Nothing was installed.")
        }

        progress?(AWSCLIInstallProgress(stage: "Checking the installer's digital signature"))
        let signature: AWSPackageSignature
        do {
            signature = try await checkSignature(package)
        } catch {
            if error is CancellationError { throw error }
            return AWSCLIInstallResult(outcome: .signatureRejected,
                                       message: "DSH couldn't check the installer's digital signature (\(error.localizedDescription)), so it didn't install it.")
        }
        let verdict = Self.isAmazonSignature(signature)
        if !verdict.accepted {
            return AWSCLIInstallResult(outcome: .signatureRejected,
                                       message: "The downloaded installer isn't validly signed by Amazon (\(verdict.reason)), so DSH didn't run it.")
        }

        try Task.checkCancellation()
        let elevated = scope == .allUsers
        var choices: String?
        if scope == .currentUser {
            let path = folder + "/choices.xml"
            guard Self.writePrivateFile(Self.choicesXML(home: homeDirectory), to: path) else {
                return AWSCLIInstallResult(outcome: .failed, message: "DSH couldn't write the installer's settings file in \(folder).")
            }
            choices = path
        }
        let launch = AWSCLIInstallerLaunch(arguments: Self.installerArguments(scope: scope, package: package, choices: choices),
                                           packagePath: package, elevated: elevated)
        let stage = elevated ? "Installing the AWS CLI — approve the administrator prompt to continue" : "Installing the AWS CLI"
        progress?(AWSCLIInstallProgress(stage: stage))
        let output: AWSCLIResult
        do {
            output = try await (elevated ? runElevated : runInstaller)(launch) { line in
                progress?(AWSCLIInstallProgress(stage: stage, detail: line))
            }
        } catch {
            if error is CancellationError { throw error }
            return AWSCLIInstallResult(outcome: .failed, message: "The macOS installer didn't start (\(error.localizedDescription)).")
        }

        let outcome = Self.mapInstallerResult(output, elevated: elevated)
        if !outcome.succeeded {
            var failed = outcome
            // (A declined prompt has nothing worth keeping.)
            if outcome.outcome != .cancelled {
                keepLog = Self.writeLog(output, to: log)
                failed.logPath = keepLog ? log : nil
            }
            return failed
        }

        let linkNote = scope == .currentUser ? linkIntoUserBin() : nil
        progress?(AWSCLIInstallProgress(stage: "Checking the installation"))
        let status = await checkInstalled()
        if case .ready(let version, _) = status {
            return AWSCLIInstallResult(outcome: .installed,
                                       message: "AWS CLI \(version) is installed." + (linkNote.map { " " + $0 } ?? ""),
                                       exitCode: output.exitCode, cli: status)
        }
        keepLog = Self.writeLog(output, to: log)
        return AWSCLIInstallResult(outcome: .failed,
                                   message: "The installer finished, but DSH still can't use the AWS CLI: \(status.summary)",
                                   exitCode: output.exitCode, cli: status, logPath: keepLog ? log : nil)
    }

    /// The fallback: install with Homebrew, which builds its own copy of the AWS CLI. Pass the status
    /// of the CLI that needs updating so a Homebrew-managed one is upgraded rather than "installed".
    public func installWithHomebrew(current: AWSCLIStatus? = nil, progress: Progress? = nil) async throws -> AWSCLIInstallResult {
        if let problem = platformProblem { return AWSCLIInstallResult(outcome: .notSupported, message: problem) }
        guard let run = runBrew ?? defaultBrew() else {
            return AWSCLIInstallResult(outcome: .notSupported,
                                       message: "Homebrew isn't installed on this Mac. Download and run the installer yourself: \(Self.packageURLString)")
        }
        let stage = "Installing the AWS CLI with Homebrew"
        progress?(AWSCLIInstallProgress(stage: stage))
        let exitCode: Int
        do {
            exitCode = try await run(Self.homebrewArguments(current: current)) { line in
                progress?(AWSCLIInstallProgress(stage: stage, detail: line))
            }
        } catch {
            if error is CancellationError { throw error }
            return AWSCLIInstallResult(outcome: .failed, message: "Homebrew didn't start (\(error.localizedDescription)).")
        }
        progress?(AWSCLIInstallProgress(stage: "Checking the installation"))
        let status = await checkInstalled()
        if case .ready(let version, _) = status {
            return AWSCLIInstallResult(outcome: .installed, message: "AWS CLI \(version) is installed.", exitCode: exitCode, cli: status)
        }
        return AWSCLIInstallResult(outcome: .failed,
                                   message: "Homebrew couldn't install the AWS CLI (exit code \(exitCode)). \(status.summary)",
                                   exitCode: exitCode, cli: status)
    }

    /// Whether the Homebrew fallback can run here (for showing its button).
    public var homebrewAvailable: Bool { runBrew != nil || findBrew() != nil }

    private func defaultBrew() -> (@Sendable ([String], @escaping LineHandler) async throws -> Int)? {
        guard let brew = findBrew() else { return nil }
        return { arguments, onLine in
            let result = try await ProcessAWSCLIRunner(executable: brew).run(arguments, options: AWSCLIRunOptions(
                environment: ["HOMEBREW_NO_ENV_HINTS": "1"], onLine: { onLine($0.text) }, timeout: 20 * 60))
            return result.exitCode
        }
    }

    /// `brew` on PATH, or at either of Homebrew's standard prefixes.
    static func locateBrew(environment: [String: String] = ProcessInfo.processInfo.environment,
                           fileExists: @escaping @Sendable (String) -> Bool = AWSCLISearch.isExecutableFile) -> String? {
        let search = AWSCLISearch.forThisMachine(environment: environment)
        return AWSCLI.candidates(AWSCLISearch(pathDirectories: search.pathDirectories,
                                              knownLocations: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
                                              fileName: "brew", fileExists: fileExists)).first
    }

    // MARK: What the installer said

    /// What `installer`'s result means. `elevated` results come from `runElevated`: the exit code is
    /// `installer`'s, and osascript's own failures (a declined prompt, a rejected password) are in
    /// `stderr`.
    public static func mapInstallerResult(_ result: AWSCLIResult, elevated: Bool = false) -> AWSCLIInstallResult {
        let code = result.exitCode
        if code == 0 && !result.timedOut {
            return AWSCLIInstallResult(outcome: .installed, message: "The AWS CLI is installed.", exitCode: code)
        }
        let output = result.stderr + "\n" + result.stdout
        let lowered = output.lowercased()
        if result.timedOut {
            return AWSCLIInstallResult(outcome: .failed, message: "The AWS CLI installer took too long, so DSH stopped it.", exitCode: code)
        }
        if elevated && (lowered.contains("user canceled") || lowered.contains("user cancelled") || lowered.contains("(-128)")) {
            return AWSCLIInstallResult(outcome: .cancelled,
                                       message: "The administrator prompt was declined, so the AWS CLI wasn't installed.", exitCode: code)
        }
        if elevated && (lowered.contains("(-60007)") || lowered.contains("(-60005)") || lowered.contains("(-60008)")
                        || lowered.contains("user name or password was incorrect")) {
            return AWSCLIInstallResult(outcome: .needsAdministrator,
                                       message: "The administrator's password wasn't accepted, so the AWS CLI wasn't installed. Install it just for you instead, or ask an administrator.",
                                       exitCode: code)
        }
        if lowered.contains("must be run as root") || lowered.contains("must be an administrator") || lowered.contains("requires an administrator") {
            return AWSCLIInstallResult(outcome: .needsAdministrator,
                                       message: "Installing the AWS CLI needs administrator rights on this Mac. Choose the install for everyone on this Mac (macOS asks for an administrator's password), or ask an administrator.",
                                       exitCode: code)
        }
        var message = "The AWS CLI installer stopped with error \(code)."
        if let last = lastLine(of: output) { message += " It said: \(last)" }
        message += " The macOS install log (/var/log/install.log) has the details."
        return AWSCLIInstallResult(outcome: .failed, message: message, exitCode: code)
    }

    /// The last non-empty line of what a tool printed, without its "installer: " prefix.
    private static func lastLine(of output: String) -> String? {
        let lines = AWSCLIText.normalizeNewlines(output).components(separatedBy: "\n")
            .map(AWSCLIText.trimmed).filter { !$0.isEmpty && !$0.hasPrefix(exitMarker) }
        guard var last = lines.last else { return nil }
        if last.hasPrefix("installer:") { last = AWSCLIText.trimmed(String(last.dropFirst("installer:".count))) }
        return AWSCLIText.prefix(last, 300)
    }

    // MARK: Signatures

    /// Valid, and signed by Amazon: the signing certificate is a "Developer ID Installer" identity of
    /// Amazon's Apple Developer team. `reason` says why not.
    public static func isAmazonSignature(_ signature: AWSPackageSignature) -> (accepted: Bool, reason: String) {
        if !signature.isTrusted {
            let status = AWSCLIText.trimmed(signature.status)
            return (false, "macOS reports the signature as \(status.isEmpty ? "missing" : status)")
        }
        guard let signer = signature.signer, !AWSCLIText.trimmed(signer).isEmpty else {
            return (false, "it has no signing certificate")
        }
        if let identity = developerIDInstaller(signer), amazonTeamIDs.contains(identity.teamID) { return (true, "") }
        return (false, "it is signed by \(signer)")
    }

    /// "Developer ID Installer: Some Company (ABCDE12345)" → (company, team ID); nil for anything else.
    static func developerIDInstaller(_ certificate: String) -> (name: String, teamID: String)? {
        guard let match = installerIdentityRegex.firstMatch(in: AWSCLIText.trimmed(certificate)),
              let name = match.group(at: 1), let team = match.group(at: 2) else { return nil }
        return (AWSCLIText.trimmed(name), team)
    }

    private static let installerIdentityRegex = AWSCLIRegex(#"^Developer ID Installer:\s+(.+?)\s+\(([A-Z0-9]{10})\)$"#)
    private static let certificateLineRegex = AWSCLIRegex(#"^\s{1,10}\d{1,2}\.\s+(\S.*?)\s*$"#)

    /// Read `pkgutil --check-signature`'s output; nil when it isn't a signature report (an error such
    /// as "Could not open package: x" or "Package does not exist: x"). Its format:
    ///
    ///     Package "AWSCLIV2.pkg":
    ///        Status: signed by a developer certificate issued by Apple for distribution
    ///        Notarization: trusted by the Apple notary service
    ///        Signed with a trusted timestamp on: 2025-01-01 00:00:00 +0000
    ///        Certificate Chain:
    ///         1. Developer ID Installer: Some Company (ABCDE12345)
    ///            Expires: 2027-02-01 22:12:15 +0000
    ///            SHA256 Fingerprint: …
    ///         2. Developer ID Certification Authority
    ///         3. Apple Root CA
    ///
    /// A package that isn't validly signed has only the Status line ("no signature", "invalid
    /// signature") or an "untrusted certificate" chain; pkgutil then also exits with 1.
    public static func parseSignature(_ output: String, exitCode: Int = 0) -> AWSPackageSignature? {
        let lines = AWSCLIText.normalizeNewlines(output).components(separatedBy: "\n")
        guard let statusLine = lines.first(where: { AWSCLIText.trimmed($0).hasPrefix("Status:") }) else { return nil }
        let status = AWSCLIText.trimmed(String(AWSCLIText.trimmed(statusLine).dropFirst("Status:".count)))
        var certificates: [String] = []
        var inChain = false
        for line in lines {
            if AWSCLIText.trimmed(line) == "Certificate Chain:" {
                inChain = true
            } else if inChain, let certificate = certificateLineRegex.firstMatch(in: line)?.group(at: 1) {
                certificates.append(certificate)
            }
        }
        return AWSPackageSignature(status: status, certificates: certificates, isTrusted: exitCode == 0 && trustedStatus(status))
    }

    /// The Status texts that mean "valid signature from a certificate macOS trusts".
    private static func trustedStatus(_ status: String) -> Bool {
        let lowered = status.lowercased()
        return lowered.hasPrefix("signed by a developer certificate issued by apple")
            || lowered.hasPrefix("signed by a certificate trusted by")
            || lowered == "signed apple software"
    }

    /// The real signature check: `pkgutil --check-signature`. Throws when pkgutil isn't there or doesn't
    /// answer with a signature report — the app then refuses to install rather than install unchecked.
    public static func pkgutilSignature(of path: String, tool: String = pkgutilTool) async throws -> AWSPackageSignature {
        let result = try await ProcessAWSCLIRunner(executable: tool).run(["--check-signature", path], options: AWSCLIRunOptions(timeout: 120))
        if result.timedOut { throw AWSCLIInstallerError("pkgutil didn't answer") }
        let output = result.stdout + "\n" + result.stderr
        guard let signature = parseSignature(output, exitCode: result.exitCode) else {
            let said = AWSCLIText.firstLine(AWSCLIText.trimmed(output))
            throw AWSCLIInstallerError("pkgutil didn't report a signature: \(said.isEmpty ? "exit code \(result.exitCode)" : AWSCLIText.prefix(said, 300))")
        }
        return signature
    }

    // MARK: Running the installer

    /// Run a launch to the end, unstoppable: a task cancelled from here on doesn't reach `installer`.
    static func runToCompletion(_ launch: AWSCLIInstallerLaunch, onLine: @escaping LineHandler) async throws -> AWSCLIResult {
        try await Task.detached {
            try await ProcessAWSCLIRunner(executable: launch.executable).run(
                launch.arguments, options: AWSCLIRunOptions(onLine: { onLine($0.text) }, timeout: 30 * 60))
        }.value
    }

    /// `do shell script "…" with administrator privileges`: the system asks for an administrator's
    /// password (or Touch ID) and runs the command as root. The command's exit status is echoed after
    /// its output, because osascript itself only says "failed". Not stoppable once started.
    static func runWithAdministratorPrivileges(_ launch: AWSCLIInstallerLaunch, osascript: String = osascriptTool,
                                               onLine: @escaping LineHandler) async throws -> AWSCLIResult {
        let script = appleScript(elevating: launch.executable, arguments: launch.arguments)
        let result = try await Task.detached {
            try await ProcessAWSCLIRunner(executable: osascript).run(["-e", script], options: AWSCLIRunOptions(timeout: 30 * 60))
        }.value
        // osascript failing (a declined prompt, a rejected password) says so in its stderr.
        guard result.succeeded else { return result }
        guard let parsed = parseElevatedOutput(result.stdout) else {
            return AWSCLIResult(exitCode: 1, stdout: result.stdout,
                                stderr: "The administrator prompt finished without saying whether the installer succeeded.")
        }
        for line in parsed.output.components(separatedBy: "\n") where !line.isEmpty { onLine(line) }
        return AWSCLIResult(exitCode: parsed.exitCode, stdout: parsed.output, stderr: "")
    }

    /// The whole AppleScript: the command, both output streams kept, and the exit status echoed.
    static func appleScript(elevating executable: String, arguments: [String]) -> String {
        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let shell = "{ \(command) 2>&1; echo \"\(exitMarker)$?\"; }"
        return "do shell script \"\(appleScriptEscape(shell))\" with administrator privileges"
    }

    /// One shell word: in single quotes, with each single quote as '\'' — nothing in it is special.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The inside of an AppleScript string literal.
    static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Split osascript's output into the command's output and its exit status.
    static func parseElevatedOutput(_ text: String) -> (output: String, exitCode: Int)? {
        let lines = AWSCLIText.normalizeNewlines(text).components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.hasPrefix(exitMarker) }),
              let code = Int(AWSCLIText.trimmed(String(lines[index].dropFirst(exitMarker.count)))) else { return nil }
        return (lines[..<index].joined(separator: "\n"), code)
    }

    // MARK: Files

    private func fetch(_ url: URL, to destination: String, progress: Progress?) async throws {
        let stage = "Downloading the AWS CLI installer"
        let report: @Sendable (Int64, Int64?) -> Void = { done, total in
            progress?(AWSCLIInstallProgress(stage: stage, done: done, total: total))
        }
        if let download {
            try await download(url, destination, report)
            return
        }
        let owned = session == nil
        let session = self.session ?? URLSession(configuration: .ephemeral)
        defer { if owned { session.finishTasksAndInvalidate() } }
        try await Self.downloadFile(from: url, to: destination, using: session, report: report)
    }

    /// GET `url` into `destination` (through a ".partial" file, so a stopped download never looks
    /// finished), reporting progress about every 256 KB. A non-2xx answer or a body shorter than its
    /// Content-Length is an error.
    static func downloadFile(from url: URL, to destination: String, using session: URLSession,
                             report: @Sendable (Int64, Int64?) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding") // so Content-Length counts the bytes we save
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AWSCLIInstallerError("the server answered \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
        }
        let total: Int64? = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        let partial = destination + ".partial"
        defer { try? FileManager.default.removeItem(atPath: partial) }
        // (Plain POSIX: only this user may read the download, and no temporary file is involved.)
        let descriptor = open(partial, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw AWSCLIInstallerError("couldn't create \(partial) (\(String(cString: strerror(errno))))")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var closed = false
        defer { if !closed { try? file.close() } }
        report(0, total)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(65_536)
        var done: Int64 = 0
        var reported: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                guard buffer.count >= 65_536 else { continue }
                try file.write(contentsOf: buffer)
                done += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
                if done - reported >= 256 * 1024 {
                    reported = done
                    report(done, total)
                }
            }
            if !buffer.isEmpty {
                try file.write(contentsOf: buffer)
                done += Int64(buffer.count)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
        try file.close()
        closed = true
        if let total, done != total {
            throw AWSCLIInstallerError("the download stopped early (\(done) of \(total) bytes)")
        }
        report(done, total ?? done)
        guard rename(partial, destination) == 0 else {
            throw AWSCLIInstallerError("couldn't move the download into place (\(String(cString: strerror(errno))))")
        }
    }

    /// Every flat installer package is a xar archive, which starts with "xar!".
    static func hasPackageHeader(_ path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        let head = (try? file.read(upToCount: 4)) ?? Data()
        return head == Data([0x78, 0x61, 0x72, 0x21])
    }

    /// `~/.local/bin/aws` → `~/aws-cli/aws`, as AWS's instructions for the current-user install do, so
    /// `aws` works in a terminal too. A link that points elsewhere is replaced; anything that isn't a
    /// link is left alone. Returns a sentence when something needs saying (the app finds
    /// `~/aws-cli/aws` on its own either way).
    func linkIntoUserBin() -> String? {
        let target = Self.userInstallPath(home: homeDirectory)
        let link = Self.userLinkPath(home: homeDirectory)
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if let existing = try? manager.destinationOfSymbolicLink(atPath: link) {
                if existing == target { return nil }
                try manager.removeItem(atPath: link)
            } else if manager.fileExists(atPath: link) {
                return "DSH left \(link) alone because it isn't a link; DSH uses \(target) directly."
            }
            try manager.createSymbolicLink(atPath: link, withDestinationPath: target)
            return nil
        } catch {
            return "DSH couldn't link \(link) to \(target) (\(error.localizedDescription)); DSH uses \(target) directly."
        }
    }

    /// Write what the installer printed next to the download; true when there was something to keep.
    private static func writeLog(_ output: AWSCLIResult, to path: String) -> Bool {
        let text = [output.stdout, output.stderr].map(AWSCLIText.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        return writePrivateFile(Data((text + "\n").utf8), to: path)
    }

    /// A file only this user can read, written in place (no temporary file beside it).
    private static func writePrivateFile(_ data: Data, to path: String) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            chmod(path, 0o600)
            return true
        } catch {
            return false
        }
    }

    /// Remove the download; a failed install's log stays for the user to look at.
    static func cleanup(_ folder: String, keep: String?) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
            let path = folder + "/" + name
            if let keep, path == keep, manager.fileExists(atPath: keep) { continue }
            try? manager.removeItem(atPath: path)
        }
        if ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).isEmpty { try? manager.removeItem(atPath: folder) }
    }
}
