import XCTest
@testable import DSHCore

final class AWSProfilesTests: XCTestCase {
    private static let config = #"""
        # Written by hand and by `aws configure`
        [default]
        region = eu-west-1
        output = json

        [profile corp-dev]
        sso_session = corp
        sso_account_id = 111122223333
        sso_role_name = Developer
        region = us-east-1

        [sso-session corp]
        sso_start_url = https://corp.awsapps.com/start
        sso_region = us-east-1

        [profile  deploy]
        role_arn = arn:aws:iam::111122223333:role/Deploy
        source_profile = default

        [profile tool]
        credential_process = "/Applications/Vault Tools/vault" aws-creds --role=dev

        [profile dsh-bedrock]
        login_session = arn:aws:iam::111122223333:user/alice
        Region = eu-central-1
        s3 =
          max_concurrent_requests = 20
          addressing_style = path

        [profile keys]
        region = us-west-2

        [profile "my project"]
        region: ap-northeast-1

        [profile ci]
        web_identity_token_file = /var/run/token
        role_arn = arn:aws:iam::111122223333:role/CI

        [services local-bedrock]
        bedrock =
          endpoint_url = http://localhost:4566

        [preview]
        cloudfront = true

        ; an empty profile, ready for aws login
        [profile fresh]
        """#

    private static let credentials = """
        [keys]
        aws_access_key_id = AKIAIOSFODNN7EXAMPLE
        aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

        [only-in-credentials]
        aws_access_key_id = AKIAOTHER
        aws_secret_access_key = secret
        region = sa-east-1
        """

    func testReadsProfilesAndHowEachSignsIn() throws {
        let profiles = AWSProfiles.parse(config: Self.config, credentials: Self.credentials)
        XCTAssertEqual(profiles.profiles.map(\.name),
                       ["default", "corp-dev", "deploy", "tool", "dsh-bedrock", "keys", "my project", "ci", "fresh", "only-in-credentials"])

        XCTAssertEqual(profiles.find("default")?.kind, .empty)
        XCTAssertEqual(profiles.find("corp-dev")?.kind, .sso)
        XCTAssertEqual(profiles.find("deploy")?.kind, .assumeRole)
        XCTAssertEqual(profiles.find("tool")?.kind, .credentialProcess)
        XCTAssertEqual(profiles.find("dsh-bedrock")?.kind, .loginSession)
        XCTAssertEqual(profiles.find("keys")?.kind, .accessKeys)
        XCTAssertEqual(profiles.find("ci")?.kind, .webIdentity)
        XCTAssertEqual(profiles.find("fresh")?.kind, .empty)
        XCTAssertEqual(profiles.find("only-in-credentials")?.kind, .accessKeys)

        XCTAssertNil(profiles.find("corp"), "an sso-session, not a profile")
        XCTAssertNil(profiles.find("preview"), "not a profile section")
        XCTAssertNil(profiles.find("local-bedrock"), "a services section")
        XCTAssertNil(profiles.find("DSH-BEDROCK"), "names are case-sensitive")
    }

    func testReadsRegionsAndSettings() throws {
        let profiles = AWSProfiles.parse(config: Self.config, credentials: Self.credentials)
        XCTAssertEqual(profiles.find("corp-dev")?.region, "us-east-1")
        XCTAssertEqual(profiles.find("dsh-bedrock")?.region, "eu-central-1", "keys are case-insensitive (\"Region\")")
        XCTAssertEqual(profiles.find("keys")?.region, "us-west-2", "config and credentials merge")
        XCTAssertEqual(profiles.find("my project")?.region, "ap-northeast-1", "quoted name, \":\" separator")
        XCTAssertEqual(profiles.find("only-in-credentials")?.region, "sa-east-1")
        XCTAssertNil(profiles.find("fresh")?.region)
        XCTAssertEqual(profiles.find("tool")?.settings["credential_process"], #""/Applications/Vault Tools/vault" aws-creds --role=dev"#)
        XCTAssertEqual(profiles.find("dsh-bedrock")?.settings["s3"], "max_concurrent_requests = 20\naddressing_style = path")
        XCTAssertEqual(profiles.find("keys")?.settings["aws_access_key_id"], "AKIAIOSFODNN7EXAMPLE")
    }

    func testOnlyEmptyAndLoginProfilesCanUseAwsLogin() {
        let profiles = AWSProfiles.parse(config: Self.config, credentials: Self.credentials)
        XCTAssertEqual(profiles.profiles.filter(\.canUseAWSLogin).map(\.name), ["default", "dsh-bedrock", "my project", "fresh"])
        XCTAssertEqual(profiles.find("corp-dev")?.kindDescription, "IAM Identity Center (SSO)")
        XCTAssertEqual(profiles.find("keys")?.kindDescription, "access keys")
        XCTAssertEqual(profiles.find("dsh-bedrock")?.kindDescription, "signed in with the browser (aws login)")
        XCTAssertEqual(profiles.find("deploy")?.kindDescription, "an assumed role")
        XCTAssertEqual(profiles.find("tool")?.kindDescription, "a credential program (credential_process)")
        XCTAssertEqual(profiles.find("ci")?.kindDescription, "a web identity token")
        XCTAssertEqual(profiles.find("fresh")?.kindDescription, "no credentials yet")
    }

    func testTheOlderSSOSettingsCountAsSSOToo() {
        for setting in ["sso_start_url = https://x.awsapps.com/start", "sso_account_id = 1", "sso_role_name = R", "sso_session = s"] {
            let profiles = AWSProfiles.parse(config: "[profile p]\n\(setting)\n", credentials: nil)
            XCTAssertEqual(profiles.find("p")?.kind, .sso, setting)
        }
        // A value that is empty doesn't count.
        XCTAssertEqual(AWSProfiles.parse(config: "[profile p]\nsso_session =\naws_access_key_id = A\n", credentials: nil).find("p")?.kind, .accessKeys)
    }

    func testProfilesWithSeveralKindsOfSettingsFollowTheCliOrder() {
        // The order aws login checks them in: web identity, SSO, access keys, role, credential_process, login_session.
        let cases: [(settings: String, kind: AWSProfileKind)] = [
            ("web_identity_token_file = /t\nsso_session = s\naws_access_key_id = A\nrole_arn = r", .webIdentity),
            ("sso_session = s\naws_access_key_id = A\nrole_arn = r\ncredential_process = p\nlogin_session = l", .sso),
            ("aws_access_key_id = A\nrole_arn = r\ncredential_process = p\nlogin_session = l", .accessKeys),
            ("role_arn = r\ncredential_process = p\nlogin_session = l", .assumeRole),
            ("credential_process = p\nlogin_session = l", .credentialProcess),
            ("login_session = l\nregion = us-east-1", .loginSession),
            ("region = us-east-1\noutput = json", .empty),
        ]
        for (settings, kind) in cases {
            XCTAssertEqual(AWSProfiles.parse(config: "[profile p]\n\(settings)\n", credentials: nil).find("p")?.kind, kind, settings)
        }
    }

    func testCredentialsOverrideConfig() {
        let profiles = AWSProfiles.parse(config: "[profile p]\nregion = us-east-1\naws_access_key_id = FROMCONFIG\n",
                                         credentials: "[p]\naws_access_key_id = FROMCREDENTIALS\n")
        XCTAssertEqual(profiles.find("p")?.settings["aws_access_key_id"], "FROMCREDENTIALS")
        XCTAssertEqual(profiles.find("p")?.region, "us-east-1")
    }

    func testTheDefaultProfileIsBareInCredentialsToo() {
        let profiles = AWSProfiles.parse(config: "[default]\nregion = eu-west-1\n", credentials: "[default]\naws_access_key_id = AKIA\n")
        XCTAssertEqual(profiles.profiles.map(\.name), ["default"])
        XCTAssertEqual(profiles.find("default")?.kind, .accessKeys)
        XCTAssertEqual(profiles.find("default")?.region, "eu-west-1")
    }

    func testDefaultRegionComesFromTheEnvironmentFirst() {
        XCTAssertEqual(AWSProfiles.parse(config: Self.config, credentials: nil).defaultRegion, "eu-west-1")
        var env = ["AWS_DEFAULT_REGION": "ap-south-1"]
        XCTAssertEqual(AWSProfiles.parse(config: Self.config, credentials: nil, environment: env).defaultRegion, "ap-south-1")
        env["AWS_REGION"] = " us-east-2 "
        XCTAssertEqual(AWSProfiles.parse(config: Self.config, credentials: nil, environment: env).defaultRegion, "us-east-2")
        env["AWS_REGION"] = "   "
        XCTAssertEqual(AWSProfiles.parse(config: Self.config, credentials: nil, environment: env).defaultRegion, "ap-south-1", "blank counts as unset")
        XCTAssertNil(AWSProfiles.parse(config: nil, credentials: nil).defaultRegion)
    }

    func testEmptyOrOddFilesDontBreakIt() {
        XCTAssertTrue(AWSProfiles.parse(config: nil, credentials: nil).profiles.isEmpty)
        XCTAssertTrue(AWSProfiles.parse(config: "", credentials: "").profiles.isEmpty)
        let odd = AWSProfiles.parse(config: "\u{FEFF}region = orphan\n[profile ok]\r\nregion = us-east-1\r\n[profile \"unterminated]\nregion = x\n[profile a b]\nregion = y\n", credentials: nil)
        XCTAssertEqual(odd.profiles.map(\.name), ["ok"])
        XCTAssertEqual(odd.find("ok")?.region, "us-east-1")
    }

    func testTheIniParserReadsWhatPythonsParserReads() {
        let sections = AWSProfiles.parseINI("""
            ; comment
            # another
            [one]
            Key = Value With = Signs
            other: colon value
            no separator here
            =no key

            [two ]
            a=1
            a=2
              continued
            [one]
            late = yes
            """)
        XCTAssertEqual(sections.map(\.section), ["one", "two", "one"])
        XCTAssertEqual(sections[0].values, ["key": "Value With = Signs", "other": "colon value"])
        XCTAssertEqual(sections[1].values, ["a": "2\ncontinued"])
        XCTAssertEqual(sections[2].values, ["late": "yes"])
        XCTAssertTrue(AWSProfiles.parseINI(nil).isEmpty)
        XCTAssertTrue(AWSProfiles.parseINI("").isEmpty)
        // Repeated sections merge into one profile, later values winning.
        let merged = AWSProfiles.parse(config: "[profile p]\nregion = a\n[profile p]\nregion = b\noutput = json\n", credentials: nil)
        XCTAssertEqual(merged.profiles.count, 1)
        XCTAssertEqual(merged.find("p")?.region, "b")
        XCTAssertEqual(merged.find("p")?.settings["output"], "json")
    }

    func testSectionNamesSplitLikeAShell() {
        XCTAssertEqual(AWSProfiles.splitSection("profile  my-name"), ["profile", "my-name"])
        XCTAssertEqual(AWSProfiles.splitSection("profile \"my project\""), ["profile", "my project"])
        XCTAssertEqual(AWSProfiles.splitSection("profile 'a b' c"), ["profile", "a b", "c"])
        XCTAssertEqual(AWSProfiles.splitSection("profile \"\""), ["profile", ""])
        XCTAssertEqual(AWSProfiles.splitSection("profile \"open"), [])
        XCTAssertEqual(AWSProfiles.splitSection(""), [])
    }

    func testFindsTheFilesTheCliUses() {
        let home = "/Users/test"
        XCTAssertEqual(AWSProfiles.configPath(environment: ["HOME": home]), "/Users/test/.aws/config")
        XCTAssertEqual(AWSProfiles.credentialsPath(environment: ["HOME": home]), "/Users/test/.aws/credentials")
        XCTAssertEqual(AWSProfiles.configPath(environment: ["HOME": home, "AWS_CONFIG_FILE": "/etc/aws/config"]), "/etc/aws/config")
        XCTAssertEqual(AWSProfiles.credentialsPath(environment: ["HOME": home, "AWS_SHARED_CREDENTIALS_FILE": "~/creds"]), "/Users/test/creds")
        XCTAssertEqual(AWSProfiles.credentialsPath(environment: ["HOME": home, "AWS_SHARED_CREDENTIALS_FILE": " ~ "]), "/Users/test")
        XCTAssertEqual(AWSProfiles.configPath(environment: ["HOME": home, "AWS_CONFIG_FILE": "relative/config"]), "relative/config")
        // Without HOME the account's home folder is used.
        XCTAssertEqual(AWSProfiles.configPath(environment: [:]), NSHomeDirectory() + "/.aws/config")
    }

    func testLoadsFromTheFilesTheEnvironmentNames() throws {
        let dir = makeScratch("dsh-aws-profiles")
        let config = dir.write("config", Self.config)
        let credentials = dir.write("credentials", Self.credentials)
        var env = ["AWS_CONFIG_FILE": config, "AWS_SHARED_CREDENTIALS_FILE": credentials, "HOME": dir.path]
        let profiles = AWSProfiles.load(environment: env)
        XCTAssertEqual(profiles.profiles.count, 10)
        XCTAssertEqual(profiles.configFile, config)
        XCTAssertEqual(profiles.credentialsFile, credentials)

        env["AWS_CONFIG_FILE"] = dir["missing-config"]
        XCTAssertEqual(AWSProfiles.load(environment: env).profiles.map(\.name), ["keys", "only-in-credentials"])
    }

    func testTheDefaultFilesAreUnderHome() throws {
        let home = makeScratch("dsh-aws-home")
        home.write(".aws/config", "[profile from-home]\nregion = eu-north-1\n")
        let profiles = AWSProfiles.load(environment: ["HOME": home.path])
        XCTAssertEqual(profiles.profiles.map(\.name), ["from-home"])
        XCTAssertEqual(profiles.configFile, home.path + "/.aws/config")
        XCTAssertEqual(profiles.credentialsFile, home.path + "/.aws/credentials")
    }

    func testUnreadableOrOddFilesCountAsEmpty() throws {
        let dir = makeScratch("dsh-aws-profiles")
        try FileManager.default.createDirectory(atPath: dir["a-folder"], withIntermediateDirectories: true)
        let loaded = AWSProfiles.load(environment: ["AWS_CONFIG_FILE": dir["a-folder"], "AWS_SHARED_CREDENTIALS_FILE": dir["nothing"], "HOME": dir.path])
        XCTAssertTrue(loaded.profiles.isEmpty, "a folder where a file should be is not a file")
        // Bytes that aren't UTF-8 are read as far as they make sense.
        let bytes = Data("[profile bad]\nregion = us-east-1\nnote = ".utf8) + Data([0xFF, 0xFE, 0x0A])
        let odd = dir.writeData("odd", bytes)
        let profiles = AWSProfiles.load(environment: ["AWS_CONFIG_FILE": odd, "AWS_SHARED_CREDENTIALS_FILE": dir["nothing"], "HOME": dir.path])
        XCTAssertEqual(profiles.find("bad")?.region, "us-east-1")
    }
}
