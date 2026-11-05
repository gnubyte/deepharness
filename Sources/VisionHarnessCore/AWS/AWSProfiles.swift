import Foundation

// MARK: - AWS CLI profiles
//
// What is already set up in ~/.aws/config and ~/.aws/credentials, read the way botocore reads it
// (configloader.build_profile_map): "[default]" and "[profile NAME]" sections in config, bare "[NAME]"
// sections in credentials, credentials values layered over config values. The app only ever reads
// these files; anything it changes goes through the CLI (`aws login`, `aws configure set`), which
// knows how to rewrite them safely.

/// How a profile gets its credentials, in the order `aws login` checks them
/// (awscli/customizations/login/login.py).
public enum AWSProfileKind: Sendable, Equatable {
    /// No credentials configured yet (maybe just a Region) — `aws login` can use it.
    case empty
    /// Signed in with `aws login` (login_session).
    case loginSession
    /// IAM Identity Center (sso_session, or the older sso_start_url/sso_account_id/sso_role_name).
    case sso
    /// Long-term access keys (aws_access_key_id).
    case accessKeys
    /// Assumes a role (role_arn) from another profile or source.
    case assumeRole
    /// Runs a program for credentials (credential_process).
    case credentialProcess
    /// A web identity token file (web_identity_token_file).
    case webIdentity
}

/// One profile: its name, how it signs in, its Region, and every setting (lower-case keys).
public struct AWSProfile: Sendable, Equatable {
    public var name: String
    public var kind: AWSProfileKind
    public var region: String?
    public var settings: [String: String]

    public init(name: String, kind: AWSProfileKind, region: String?, settings: [String: String]) {
        self.name = name
        self.kind = kind
        self.region = region
        self.settings = settings
    }

    /// "signed in with the browser (aws login)", "IAM Identity Center (SSO)", ...
    public var kindDescription: String { Self.describe(kind) }

    /// `aws login` refuses profiles that already have another kind of credentials.
    public var canUseAWSLogin: Bool { kind == .empty || kind == .loginSession }

    public static func describe(_ kind: AWSProfileKind) -> String {
        switch kind {
        case .loginSession: return "signed in with the browser (aws login)"
        case .sso: return "IAM Identity Center (SSO)"
        case .accessKeys: return "access keys"
        case .assumeRole: return "an assumed role"
        case .credentialProcess: return "a credential program (credential_process)"
        case .webIdentity: return "a web identity token"
        case .empty: return "no credentials yet"
        }
    }
}

/// The profiles in the AWS CLI's config and credentials files.
public struct AWSProfiles: Sendable {
    /// Every profile, config file order first, then any only in the credentials file.
    public let profiles: [AWSProfile]

    /// The Region the CLI uses when none is given: AWS_REGION, then AWS_DEFAULT_REGION, then the
    /// default profile's region.
    public let defaultRegion: String?

    public let configFile: String?
    public let credentialsFile: String?

    private let byName: [String: AWSProfile]

    private init(profiles: [AWSProfile], defaultRegion: String?, configFile: String?, credentialsFile: String?) {
        self.profiles = profiles
        self.defaultRegion = defaultRegion
        self.configFile = configFile
        self.credentialsFile = credentialsFile
        self.byName = Dictionary(profiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Profile names are case-sensitive, as in the CLI.
    public func find(_ name: String) -> AWSProfile? { byName[name] }

    /// The config file: AWS_CONFIG_FILE, else ~/.aws/config.
    public static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        resolve(environment, variable: "AWS_CONFIG_FILE", file: "config")
    }

    /// The credentials file: AWS_SHARED_CREDENTIALS_FILE, else ~/.aws/credentials.
    public static func credentialsPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        resolve(environment, variable: "AWS_SHARED_CREDENTIALS_FILE", file: "credentials")
    }

    /// "~" is HOME as the CLI sees it: the HOME variable, else the account's home folder.
    private static func home(_ environment: [String: String]) -> String {
        let home = environment["HOME"] ?? ""
        return home.isEmpty ? NSHomeDirectory() : home
    }

    private static func resolve(_ environment: [String: String], variable: String, file: String) -> String {
        let home = home(environment)
        if let custom = environment[variable], !custom.isEmpty {
            let expanded = AWSCLIText.trimmed(custom)
            if expanded == "~" || expanded.hasPrefix("~/") {
                return home + expanded.dropFirst(1)
            }
            return expanded
        }
        return home + "/.aws/" + file
    }

    /// Read this machine's files. Missing or unreadable files count as empty.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> AWSProfiles {
        let config = configPath(environment: environment)
        let credentials = credentialsPath(environment: environment)
        return parse(config: readOrNil(config), credentials: readOrNil(credentials), environment: environment,
                     configFile: config, credentialsFile: credentials)
    }

    private static func readOrNil(_ path: String) -> String? {
        // (A directory, or a file that can't be read, has no contents; bad UTF-8 becomes U+FFFD.)
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Parse the two files' text (either may be nil).
    public static func parse(config configText: String?, credentials credentialsText: String?,
                             environment: [String: String] = [:], configFile: String? = nil,
                             credentialsFile: String? = nil) -> AWSProfiles {
        var order: [String] = []
        var settings: [String: [String: String]] = [:]

        func merge(_ name: String, _ values: [String: String]) {
            if settings[name] == nil {
                settings[name] = [:]
                order.append(name)
            }
            for (key, value) in values { settings[name]![key] = value }
        }

        for (section, values) in parseINI(configText) {
            if section == "default" {
                merge("default", values)
            } else if section.hasPrefix("profile") {
                let parts = splitSection(section)
                if parts.count == 2, parts[0] == "profile" { merge(parts[1], values) }
            }
        }
        for (section, values) in parseINI(credentialsText) { merge(section, values) }

        let profiles = order.map { build($0, settings[$0] ?? [:]) }
        let defaultRegion = firstNonEmpty(environment["AWS_REGION"], environment["AWS_DEFAULT_REGION"], settings["default"]?["region"])
        return AWSProfiles(profiles: profiles, defaultRegion: defaultRegion, configFile: configFile, credentialsFile: credentialsFile)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { $0 }.first { !AWSCLIText.trimmed($0).isEmpty }.map(AWSCLIText.trimmed)
    }

    private static func build(_ name: String, _ values: [String: String]) -> AWSProfile {
        func has(_ key: String) -> Bool { !(values[key] ?? "").isEmpty }
        let kind: AWSProfileKind
        if has("web_identity_token_file") { kind = .webIdentity }
        else if has("sso_session") || has("sso_role_name") || has("sso_account_id") || has("sso_start_url") { kind = .sso }
        else if has("aws_access_key_id") { kind = .accessKeys }
        else if has("role_arn") { kind = .assumeRole }
        else if has("credential_process") { kind = .credentialProcess }
        else if has("login_session") { kind = .loginSession }
        else { kind = .empty }
        return AWSProfile(name: name, kind: kind, region: firstNonEmpty(values["region"]), settings: values)
    }

    /// "profile  my-name" → ["profile", "my-name"]; quotes group words, as shlex does.
    static func splitSection(_ section: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var any = false
        for c in section {
            if let open = quote {
                if c == open { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                any = true
                continue
            }
            if c.isWhitespace {
                if !current.isEmpty || any { parts.append(current) }
                current = ""
                any = false
                continue
            }
            current.append(c)
        }
        if quote != nil { return [] }
        if !current.isEmpty || any { parts.append(current) }
        return parts
    }

    /// INI as Python's RawConfigParser reads it: "#" and ";" start comment lines, "=" or ":" separates
    /// key and value, keys are lower-cased, and indented lines continue the previous value (botocore
    /// uses those for nested settings such as "s3 =", which the app doesn't need, so they are kept as
    /// text).
    public static func parseINI(_ text: String?) -> [(section: String, values: [String: String])] {
        guard let text, !text.isEmpty else { return [] }
        var sections: [(section: String, values: [String: String])] = []
        var section: String?
        var values: [String: String] = [:]
        var lastKey: String?
        func closeSection() {
            if let section { sections.append((section, values)) }
        }
        for rawLine in AWSCLIText.normalizeNewlines(String(text.drop { $0 == "\u{FEFF}" })).components(separatedBy: "\n") {
            let trimmed = AWSCLIText.trimmed(rawLine)
            if trimmed.isEmpty || trimmed.first == "#" || trimmed.first == ";" { continue }
            if trimmed.first == "[" && trimmed.last == "]" {
                closeSection()
                section = AWSCLIText.trimmed(String(trimmed.dropFirst().dropLast()))
                values = [:]
                lastKey = nil
                continue
            }
            if section == nil { continue }
            if let first = rawLine.first, first.isWhitespace, let key = lastKey {
                values[key] = AWSCLIText.trimmed((values[key] ?? "") + "\n" + trimmed)
                continue
            }
            let equals = trimmed.firstIndex(of: "=")
            let colon = trimmed.firstIndex(of: ":")
            let split: String.Index?
            switch (equals, colon) {
            case (nil, nil): split = nil
            case (let e?, nil): split = e
            case (nil, let c?): split = c
            case (let e?, let c?): split = min(e, c)
            }
            guard let split, split > trimmed.startIndex else { continue }
            let key = AWSCLIText.trimmed(String(trimmed[..<split])).lowercased()
            lastKey = key
            values[key] = AWSCLIText.trimmed(String(trimmed[trimmed.index(after: split)...]))
        }
        closeSection()
        return sections
    }
}
