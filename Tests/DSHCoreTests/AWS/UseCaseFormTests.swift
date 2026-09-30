import XCTest
@testable import DSHCore

// MARK: - Anthropic's use-case form

final class UseCaseFormTests: XCTestCase {
    static let acme = UseCaseForm(companyName: "Acme Robotics", companyWebsite: "https://acme.example", industry: "Technology",
                                  useCases: "Coding assistant for our developers")
    private var acme: UseCaseForm { Self.acme }

    static let acmeJSON = #"{"companyName":"Acme Robotics","companyWebsite":"https://acme.example","intendedUsers":"0","industryOption":"Technology","otherIndustryOption":"","useCases":"Coding assistant for our developers"}"#

    func testTheFormIsTheJsonAwsExpects() {
        XCTAssertEqual(acme.toJSON(), Self.acmeJSON)
        XCTAssertEqual(acme.toBase64(), Data(Self.acmeJSON.utf8).base64EncodedString())
        XCTAssertEqual(acme.toBase64(),
                       "eyJjb21wYW55TmFtZSI6IkFjbWUgUm9ib3RpY3MiLCJjb21wYW55V2Vic2l0ZSI6Imh0dHBzOi8vYWNtZS5leGFtcGxlIiwiaW50ZW5kZWRVc2VycyI6IjAiLCJpbmR1c3RyeU9wdGlvbiI6IlRlY2hub2xvZ3kiLCJvdGhlckluZHVzdHJ5T3B0aW9uIjoiIiwidXNlQ2FzZXMiOiJDb2RpbmcgYXNzaXN0YW50IGZvciBvdXIgZGV2ZWxvcGVycyJ9")
        XCTAssertNil(acme.problem)
    }

    func testTheFormKeepsTextAsTyped() throws {
        let form = UseCaseForm(companyName: "  Café \"Zoë\" & Co ", companyWebsite: "zoe.example", industry: "Other",
                               useCases: "Refactoring <legacy> code\nand tests", intendedUsers: .both, otherIndustry: "Hospitality")
        let parsed = try XCTUnwrap(JSONValue(parsing: form.toJSON()))
        XCTAssertEqual(parsed["companyName"]?.string, "Café \"Zoë\" & Co")
        XCTAssertEqual(parsed["companyWebsite"]?.string, "https://zoe.example")
        XCTAssertEqual(parsed["intendedUsers"]?.string, "2")
        XCTAssertEqual(parsed["industryOption"]?.string, "Other")
        XCTAssertEqual(parsed["otherIndustryOption"]?.string, "Hospitality")
        XCTAssertEqual(parsed["useCases"]?.string, "Refactoring <legacy> code\nand tests")
        XCTAssertTrue(form.toJSON().contains("Café"), "not \\u-escaped")
        XCTAssertTrue(form.toJSON().contains("<legacy>"), "not HTML-escaped")
        XCTAssertTrue(form.toJSON().contains("\\n"), "a line break is written as \\n")
        XCTAssertFalse(form.toJSON().contains("\n"), "the JSON is on one line")
        var ignored = acme
        ignored.otherIndustry = "ignored"
        XCTAssertEqual(JSONValue(parsing: ignored.toJSON())?["otherIndustryOption"]?.string, "", "the other industry only counts for \"Other\"")
        var external = acme
        external.intendedUsers = .external
        XCTAssertEqual(JSONValue(parsing: external.toJSON())?["intendedUsers"]?.string, "1")
        XCTAssertEqual(UseCaseAudience.allCases.map(\.rawValue), [0, 1, 2])
    }

    func testTheOrderOfTheFieldsIsFixedAndEveryValueIsAString() throws {
        let json = UseCaseForm(companyName: "A", companyWebsite: "a.b", industry: "Other", useCases: "u", intendedUsers: .external, otherIndustry: "o").toJSON()
        XCTAssertEqual(json, #"{"companyName":"A","companyWebsite":"https://a.b","intendedUsers":"1","industryOption":"Other","otherIndustryOption":"o","useCases":"u"}"#)
        let value = try XCTUnwrap(JSONValue(parsing: json))
        XCTAssertEqual(value.object?.count, 6)
        for (_, v) in value.object ?? [:] { XCTAssertNotNil(v.string) }
    }

    func testIncompleteFormsSayWhatsMissing() {
        let rows: [(company: String, site: String, industry: String, useCases: String, other: String, mentions: String)] = [
            ("", "https://acme.example", "Technology", "x", "", "company"),
            ("Acme", "not a website", "Technology", "x", "", "website"),
            ("Acme", "ftp://acme.example", "Technology", "x", "", "website"),
            ("Acme", "https://acme.example", "", "x", "", "industry"),
            ("Acme", "https://acme.example", "Other", "x", "", "industry"),
            ("Acme", "https://acme.example", "Technology", " ", "", "use"),
        ]
        for row in rows {
            let problem = UseCaseForm(companyName: row.company, companyWebsite: row.site, industry: row.industry, useCases: row.useCases, otherIndustry: row.other).problem
            XCTAssertNotNil(problem, row.mentions)
            XCTAssertTrue((problem ?? "").localizedCaseInsensitiveContains(row.mentions), "\(problem ?? "nil") should mention \(row.mentions)")
        }
    }

    func testEachProblemHasItsOwnWordsAndTheFirstOneWins() {
        func problem(company: String = "Acme", site: String = "acme.example", industry: String = "Technology", useCases: String = "x", other: String = "") -> String? {
            UseCaseForm(companyName: company, companyWebsite: site, industry: industry, useCases: useCases, otherIndustry: other).problem
        }
        let noName = "Enter your company or organization name (or your own name)."
        let noSite = "Enter your company's website, like https://example.com."
        let noIndustry = "Choose an industry."
        let noOther = "Describe your industry."
        let noUse = "Describe briefly what you'll use the models for."
        XCTAssertEqual(problem(company: ""), noName)
        XCTAssertEqual(problem(company: " \t\n\u{A0}"), noName)
        XCTAssertNil(problem(company: "\u{200B}"), "a zero-width space is not white space to the Windows app")
        XCTAssertEqual(problem(site: ""), noSite)
        XCTAssertEqual(problem(site: "localhost"), noSite)
        XCTAssertEqual(problem(industry: ""), noIndustry)
        XCTAssertEqual(problem(industry: " "), noIndustry)
        XCTAssertEqual(problem(industry: "Other"), noOther)
        XCTAssertEqual(problem(industry: "OTHER", other: "  "), noOther)
        XCTAssertNil(problem(industry: "other", other: "Hospitality"))
        XCTAssertNil(problem(industry: "Other ", other: ""), "\"Other \" with a trailing space is not \"Other\" (and has an industry)")
        XCTAssertEqual(problem(useCases: ""), noUse)
        XCTAssertEqual(problem(useCases: "\n"), noUse)
        // The first thing wrong is the one reported.
        XCTAssertEqual(problem(company: "", site: "", industry: "", useCases: ""), noName)
        XCTAssertEqual(problem(site: "", industry: "", useCases: ""), noSite)
        XCTAssertEqual(problem(industry: "", useCases: ""), noIndustry)
        XCTAssertEqual(problem(industry: "Other", useCases: ""), noOther)
        XCTAssertEqual(problem(useCases: ""), noUse)
        XCTAssertNil(problem())
    }

    func testEveryIndustryTheGuideOffersIsAccepted() {
        XCTAssertEqual(UseCaseForm.industries.count, 12)
        XCTAssertEqual(Set(UseCaseForm.industries).count, 12)
        XCTAssertTrue(UseCaseForm.industries.contains("Other"))
        XCTAssertTrue(UseCaseForm.industries.contains("Technology"))
        XCTAssertEqual(UseCaseForm.industries.last, "Other")
        for industry in UseCaseForm.industries {
            var form = acme
            form.industry = industry
            form.otherIndustry = "Something"
            XCTAssertNil(form.problem, industry)
            XCTAssertEqual(JSONValue(parsing: form.toJSON())?["industryOption"]?.string, industry)
        }
    }

    func testTheWebsiteIsCompletedAndTrimmed() {
        func site(_ text: String) -> String { UseCaseForm(companyName: "A", companyWebsite: text, industry: "I", useCases: "u").normalizedWebsite }
        XCTAssertEqual(site("example.com"), "https://example.com")
        XCTAssertEqual(site("  example.com \n"), "https://example.com")
        XCTAssertEqual(site("http://example.com"), "http://example.com")
        XCTAssertEqual(site("HTTPS://EXAMPLE.COM"), "HTTPS://EXAMPLE.COM", "the case is kept")
        XCTAssertEqual(site("ftp://x"), "ftp://x", "any scheme counts as a scheme")
        XCTAssertEqual(site("x/a://b"), "x/a://b", "a \"://\" anywhere means it has a scheme")
        XCTAssertEqual(site(""), "")
        XCTAssertEqual(site("   "), "")
        XCTAssertEqual(site("localhost:3000"), "https://localhost:3000")
        XCTAssertEqual(site("\u{3000}example.com\u{3000}"), "https://example.com", "ideographic spaces are white space")
        XCTAssertEqual(site("\u{200B}example.com"), "https://\u{200B}example.com", "a zero-width space is not")
    }

    func testFormsMatchTheWindowsAppFieldForField() {
        XCTAssertGreaterThan(UseCaseFormCorpora.forms.count, 20)
        for row in UseCaseFormCorpora.forms {
            let f = row.fields
            let form = UseCaseForm(companyName: f[0], companyWebsite: f[1], industry: f[2], useCases: f[3],
                                   intendedUsers: UseCaseAudience(rawValue: row.audience)!, otherIndustry: f[4])
            XCTAssertEqual(form.toJSON(), row.json, "\(f)")
            XCTAssertEqual(form.problem, row.problem, "\(f)")
        }
    }

    // MARK: Reading the stored form back

    private func wrap(_ text: String, _ times: Int) -> String {
        var wrapped = text
        for _ in 0..<times { wrapped = Data(wrapped.utf8).base64EncodedString() }
        return wrapped
    }

    func testReadsTheFormBack() {
        XCTAssertEqual(UseCaseForm.fromFormData(acme.toBase64()), acme)
        // AWS may hand back the stored value base64-encoded once more.
        XCTAssertEqual(UseCaseForm.fromFormData(wrap(acme.toBase64(), 1)), acme)
        // A CLI that printed the raw JSON needs no unwrapping.
        XCTAssertEqual(UseCaseForm.fromFormData(Self.acmeJSON), acme)
        // Two layers is the limit.
        XCTAssertEqual(UseCaseForm.fromFormData(wrap(Self.acmeJSON, 2)), acme)
        XCTAssertNil(UseCaseForm.fromFormData(wrap(Self.acmeJSON, 3)))
        XCTAssertNil(UseCaseForm.fromFormData("not base64 at all!"))
        XCTAssertNil(UseCaseForm.fromFormData(""))
        XCTAssertNil(UseCaseForm.fromFormData("   "))
        XCTAssertEqual(UseCaseForm.fromFormData("\n" + acme.toBase64() + "\n"), acme, "the CLI's newline")
        XCTAssertEqual(UseCaseForm.fromFormData("  " + Self.acmeJSON + "  "), acme)
    }

    func testEveryKindOfFormRoundTrips() {
        let forms = [
            acme,
            UseCaseForm(companyName: "Zoë & Söhne <GmbH>", companyWebsite: "https://zoe.example/über?q=1", industry: "Other",
                        useCases: "Line one\nLine two\t\"quoted\" \\ backslash", intendedUsers: .both, otherIndustry: "Hospitality"),
            UseCaseForm(companyName: "日本語 株式会社", companyWebsite: "日本語.jp", industry: "Legal", useCases: "🙂 emoji and \u{7F} controls \u{2028}", intendedUsers: .external),
        ]
        for form in forms {
            let back = UseCaseForm.fromFormData(form.toBase64())
            XCTAssertEqual(back?.toJSON(), form.toJSON())
            XCTAssertEqual(UseCaseForm.fromFormData(wrap(form.toBase64(), 1))?.toJSON(), form.toJSON())
            XCTAssertEqual(back?.intendedUsers, form.intendedUsers)
        }
        XCTAssertEqual(UseCaseForm.fromFormData(forms[0].toBase64()), forms[0], "an already-normalised form comes back equal")
    }

    func testStoredFormsAreReadLeniently() throws {
        func read(_ json: String, layers: Int = 1) -> UseCaseForm? { UseCaseForm.fromFormData(wrap(json, layers)) }
        // Wrong or missing types read as empty fields.
        let empty = try XCTUnwrap(read("{}"))
        XCTAssertEqual([empty.companyName, empty.companyWebsite, empty.industry, empty.useCases, empty.otherIndustry], ["", "", "", "", ""])
        XCTAssertEqual(empty.intendedUsers, .internal)
        XCTAssertEqual(read(#"{"companyName":null,"companyWebsite":5,"industryOption":true,"useCases":[1],"otherIndustryOption":{"a":1}}"#), empty)
        XCTAssertEqual(read(#"{"companyName":"Acme"}"#)?.companyName, "Acme")
        XCTAssertEqual(read(#"  {"companyName":"lead"}"#)?.companyName, "lead", "white space before the object")
        XCTAssertEqual(read(#"{"a":{"b":{"c":{"companyName":"deep"}}},"companyName":"top"}"#)?.companyName, "top", "only the top level counts")
        XCTAssertEqual(read(#"{"companyName":"A\u00e9\ud83d\ude00\n"}"#)?.companyName, "Aé😀\n")
        XCTAssertEqual(UseCaseForm.fromFormData("e30="), empty, "a bare {}")
        // The text must start with "{": a byte order mark, or a zero-width space, in front is not white space to trim.
        XCTAssertNil(UseCaseForm.fromFormData("\u{FEFF}" + Self.acmeJSON))
        XCTAssertNil(read("\u{FEFF}" + Self.acmeJSON))
        XCTAssertNil(read(" \u{FEFF}" + Self.acmeJSON))
        XCTAssertNil(read(Self.acmeJSON + "\u{FEFF}"))
        XCTAssertNil(read("\u{200B}" + Self.acmeJSON))
        XCTAssertEqual(read("\u{A0}" + Self.acmeJSON), Self.acme, "a no-break space is white space")
        // Anything that isn't an object, or isn't JSON, is not a form.
        for notAForm in [#"["companyName"]"#, #""just a string""#, "[1,2,3]", "{", "}", #"{"companyName":"Acme"} trailing"#,
                         #"{"companyName":"Acme"}{"companyName":"Two"}"#, #"{"companyName":"Acme"#, #"{"companyName":"Acme" /* c */}"#,
                         #"{"companyName":"Acme"} // c"#, "{'companyName':'Acme'}", #"{companyName:"Acme"}"#, "x" + #"{"companyName":"lead"}"#] {
            XCTAssertNil(read(notAForm), notAForm)
            XCTAssertNil(UseCaseForm.fromFormData(notAForm), notAForm)
        }
    }

    func testTheAudienceIsReadFromANumberOrItsText() {
        let cases: [(String, UseCaseAudience)] = [
            ("0", .internal), ("1", .external), ("2", .both), ("3", .internal), ("-1", .internal), ("1.0", .external), ("1.5", .internal),
            ("2e0", .both), (#""2""#, .both), (#"" 2 ""#, .both), (#""+2""#, .both), (#""02""#, .both), (#""2.0""#, .internal),
            (#""two""#, .internal), (#""""#, .internal), ("true", .internal), ("null", .internal), ("[1]", .internal),
            ("4294967297", .internal), ("99999999999999999999", .internal), (#""99999999999999999999""#, .internal),
            (#""1""#, .external), (#""-0""#, .internal), (#"" 1""#, .external),
        ]
        for (json, audience) in cases {
            XCTAssertEqual(UseCaseForm.fromFormData(wrap(#"{"intendedUsers":\#(json)}"#, 1))?.intendedUsers, audience, json)
        }
        XCTAssertNil(UseCaseForm.fromFormData(wrap(#"{"intendedUsers":"#, 1)))
    }

    // MARK: The size AWS accepts

    func testTheFormMayBeSixteenKilobytes() {
        func size(_ useCases: String) -> Int {
            UseCaseForm(companyName: "Acme", companyWebsite: "https://acme.example", industry: "Technology", useCases: useCases).toJSON().utf8.count
        }
        func form(_ useCases: String) -> UseCaseForm {
            UseCaseForm(companyName: "Acme", companyWebsite: "https://acme.example", industry: "Technology", useCases: useCases)
        }
        let overhead = size("")
        let atLimit = String(repeating: "a", count: 16384 - overhead)
        XCTAssertEqual(size(atLimit), 16384)
        XCTAssertNil(form(atLimit).problem, "exactly 16384 bytes is fine")
        XCTAssertEqual(form(atLimit + "a").problem, "The description is too long; shorten it.")
        // It is the bytes written that count: an "é" is two, an emoji is twelve (two escaped UTF-16 units).
        let accented = String(repeating: "é", count: (16384 - overhead) / 2)
        XCTAssertEqual(size(accented), overhead + 2 * ((16384 - overhead) / 2))
        XCTAssertNil(form(accented).problem)
        XCTAssertEqual(form(accented + "é" + "é").problem, "The description is too long; shorten it.")
        XCTAssertEqual(size("🙂"), overhead + 12)
        XCTAssertNil(form(String(repeating: "🙂", count: (16384 - overhead) / 12)).problem)
        XCTAssertNotNil(form(String(repeating: "🙂", count: (16384 - overhead) / 12 + 1)).problem)
        // Trimmed white space isn't sent, so it doesn't count.
        XCTAssertNil(form(atLimit + String(repeating: " ", count: 100)).problem)
        // The other fields count too.
        var long = form("x")
        long.companyName = String(repeating: "n", count: 20000)
        XCTAssertEqual(long.problem, "The description is too long; shorten it.")
    }

    // MARK: Characters in text, one at a time

    private static let escapedControls: [(UInt32, String)] = [
        (0x00, "\\u0000"), (0x01, "\\u0001"), (0x02, "\\u0002"), (0x03, "\\u0003"), (0x04, "\\u0004"), (0x05, "\\u0005"), (0x06, "\\u0006"),
        (0x07, "\\u0007"), (0x08, "\\b"), (0x09, "\\t"), (0x0A, "\\n"), (0x0B, "\\u000B"), (0x0C, "\\f"), (0x0D, "\\r"), (0x0E, "\\u000E"),
        (0x0F, "\\u000F"), (0x10, "\\u0010"), (0x11, "\\u0011"), (0x12, "\\u0012"), (0x13, "\\u0013"), (0x14, "\\u0014"), (0x15, "\\u0015"),
        (0x16, "\\u0016"), (0x17, "\\u0017"), (0x18, "\\u0018"), (0x19, "\\u0019"), (0x1A, "\\u001A"), (0x1B, "\\u001B"), (0x1C, "\\u001C"),
        (0x1D, "\\u001D"), (0x1E, "\\u001E"), (0x1F, "\\u001F"), (0x22, "\\\""), (0x5C, "\\\\"), (0x7F, "\\u007F"),
    ]

    func testAsciiIsEscapedAsTheWindowsAppDoes() {
        let special = Dictionary(uniqueKeysWithValues: Self.escapedControls)
        for value in UInt32(0)...0x7F {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(UseCaseForm.quote(String(scalar)), "\"" + (special[value] ?? String(scalar)) + "\"", String(value, radix: 16))
        }
        // The characters HTML-safe encoders escape are left alone.
        XCTAssertEqual(UseCaseForm.quote("<>&'+`=/%~"), "\"<>&'+`=/%~\"")
    }

    func testCharactersOutsideAsciiAreEscapedExactlyAsTheWindowsAppDoes() {
        // The C# table: which of the 65,536 UTF-16 code units .NET's relaxed JSON encoder (Unicode 15) writes as they are.
        var raw = Set<UInt32>()
        for range in Self.rawRanges.split(separator: ",") {
            let ends = range.split(separator: "-").map { UInt32($0, radix: 16)! }
            raw.formUnion(ends[0]...ends[1])
        }
        XCTAssertEqual(raw.count, 55_548, "the table itself")
        var checked = 0, skipped = 0
        for value in UInt32(0x80)...0xFFFF where !(value >= 0xD800 && value <= 0xDFFF) {
            let scalar = Unicode.Scalar(value)!
            // A character assigned after Unicode 15.0 (the C# probe's tables) was not known to it: its answer may differ.
            if let age = scalar.properties.age, (age.major, age.minor) > (15, 0) { skipped += 1; continue }
            let expected = raw.contains(value) ? String(scalar) : String(format: "\\u%04X", value)
            XCTAssertEqual(UseCaseForm.quote(String(scalar)), "\"" + expected + "\"", String(value, radix: 16))
            checked += 1
        }
        XCTAssertGreaterThan(checked, 63_000)
        XCTAssertLessThan(skipped, 300)
    }

    func testSpecificCharactersOfEachKind() {
        func q(_ scalars: UInt32...) -> String {
            var s = ""
            for v in scalars { s.unicodeScalars.append(Unicode.Scalar(v)!) }
            return UseCaseForm.quote(s)
        }
        // Written as they are: letters and marks of any script, symbols, format characters, the replacement character.
        for value: UInt32 in [0xE9, 0x4E2D, 0x0416, 0x05D0, 0x0627, 0xAC00, 0xAD, 0x200B, 0x200E, 0x202E, 0x2060, 0xFFFD, 0xFFFC, 0x2603, 0x20AC, 0x0301] {
            XCTAssertEqual(q(value), "\"\(Unicode.Scalar(value)!)\"", String(value, radix: 16))
        }
        // Escaped: C1 controls, no-break and other spaces, separators, private use, BOM, noncharacters, unassigned.
        for value: UInt32 in [0x80, 0x85, 0x9F, 0xA0, 0x1680, 0x2000, 0x2003, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xE000, 0xF8FF, 0xFEFF,
                              0xFFFE, 0xFFFF, 0x378, 0x530, 0xFDD0] {
            XCTAssertEqual(q(value), "\"" + String(format: "\\u%04X", value) + "\"", String(value, radix: 16))
        }
    }

    func testCharactersBeyondTheBasicPlaneAreEscapedAsSurrogatePairs() {
        func q(_ text: String) -> String { UseCaseForm.quote(text) }
        XCTAssertEqual(q("🙂"), "\"\\uD83D\\uDE42\"")
        XCTAssertEqual(q("\u{10000}"), "\"\\uD800\\uDC00\"")
        XCTAssertEqual(q("\u{1F600}"), "\"\\uD83D\\uDE00\"")
        XCTAssertEqual(q("\u{1D11E}"), "\"\\uD834\\uDD1E\"")
        XCTAssertEqual(q("\u{E0001}"), "\"\\uDB40\\uDC01\"")
        XCTAssertEqual(q("\u{20000}"), "\"\\uD840\\uDC00\"")
        XCTAssertEqual(q("\u{10FFFF}"), "\"\\uDBFF\\uDFFF\"")
        XCTAssertEqual(q("a🙂b"), "\"a\\uD83D\\uDE42b\"")
        XCTAssertEqual(q("👨‍👩‍👧"), "\"\\uD83D\\uDC68\u{200D}\\uD83D\\uDC69\u{200D}\\uD83D\\uDC67\"", "a family emoji: the joiners stay, each person is a pair")
        // The same in a whole form, as the C# probe wrote it.
        let form = UseCaseForm(companyName: "A🙂", companyWebsite: "https://acme.example/🙂", industry: "Technology", useCases: "x🙂y", intendedUsers: .both)
        XCTAssertEqual(form.toJSON(), #"{"companyName":"A\uD83D\uDE42","companyWebsite":"https://acme.example/\uD83D\uDE42","intendedUsers":"2","industryOption":"Technology","otherIndustryOption":"","useCases":"x\uD83D\uDE42y"}"#)
        XCTAssertEqual(UseCaseForm.fromFormData(form.toBase64())?.useCases, "x🙂y", "and it reads back")
    }

    // Which of the BMP is written as it is: from the C# probe (see `testCharactersOutsideAsciiAreEscapedExactlyAsTheWindowsAppDoes`).
    private static let rawRanges = [
        "0020-0021,0023-005b,005d-007e,00a1-0377,037a-037f,0384-038a,038c-038c,038e-03a1,03a3-052f,0531-0556,0559-058a,",
        "058d-058f,0591-05c7,05d0-05ea,05ef-05f4,0600-070d,070f-074a,074d-07b1,07c0-07fa,07fd-082d,0830-083e,0840-085b,",
        "085e-085e,0860-086a,0870-088e,0890-0891,0898-0983,0985-098c,098f-0990,0993-09a8,09aa-09b0,09b2-09b2,09b6-09b9,",
        "09bc-09c4,09c7-09c8,09cb-09ce,09d7-09d7,09dc-09dd,09df-09e3,09e6-09fe,0a01-0a03,0a05-0a0a,0a0f-0a10,0a13-0a28,",
        "0a2a-0a30,0a32-0a33,0a35-0a36,0a38-0a39,0a3c-0a3c,0a3e-0a42,0a47-0a48,0a4b-0a4d,0a51-0a51,0a59-0a5c,0a5e-0a5e,",
        "0a66-0a76,0a81-0a83,0a85-0a8d,0a8f-0a91,0a93-0aa8,0aaa-0ab0,0ab2-0ab3,0ab5-0ab9,0abc-0ac5,0ac7-0ac9,0acb-0acd,",
        "0ad0-0ad0,0ae0-0ae3,0ae6-0af1,0af9-0aff,0b01-0b03,0b05-0b0c,0b0f-0b10,0b13-0b28,0b2a-0b30,0b32-0b33,0b35-0b39,",
        "0b3c-0b44,0b47-0b48,0b4b-0b4d,0b55-0b57,0b5c-0b5d,0b5f-0b63,0b66-0b77,0b82-0b83,0b85-0b8a,0b8e-0b90,0b92-0b95,",
        "0b99-0b9a,0b9c-0b9c,0b9e-0b9f,0ba3-0ba4,0ba8-0baa,0bae-0bb9,0bbe-0bc2,0bc6-0bc8,0bca-0bcd,0bd0-0bd0,0bd7-0bd7,",
        "0be6-0bfa,0c00-0c0c,0c0e-0c10,0c12-0c28,0c2a-0c39,0c3c-0c44,0c46-0c48,0c4a-0c4d,0c55-0c56,0c58-0c5a,0c5d-0c5d,",
        "0c60-0c63,0c66-0c6f,0c77-0c8c,0c8e-0c90,0c92-0ca8,0caa-0cb3,0cb5-0cb9,0cbc-0cc4,0cc6-0cc8,0cca-0ccd,0cd5-0cd6,",
        "0cdd-0cde,0ce0-0ce3,0ce6-0cef,0cf1-0cf3,0d00-0d0c,0d0e-0d10,0d12-0d44,0d46-0d48,0d4a-0d4f,0d54-0d63,0d66-0d7f,",
        "0d81-0d83,0d85-0d96,0d9a-0db1,0db3-0dbb,0dbd-0dbd,0dc0-0dc6,0dca-0dca,0dcf-0dd4,0dd6-0dd6,0dd8-0ddf,0de6-0def,",
        "0df2-0df4,0e01-0e3a,0e3f-0e5b,0e81-0e82,0e84-0e84,0e86-0e8a,0e8c-0ea3,0ea5-0ea5,0ea7-0ebd,0ec0-0ec4,0ec6-0ec6,",
        "0ec8-0ece,0ed0-0ed9,0edc-0edf,0f00-0f47,0f49-0f6c,0f71-0f97,0f99-0fbc,0fbe-0fcc,0fce-0fda,1000-10c5,10c7-10c7,",
        "10cd-10cd,10d0-1248,124a-124d,1250-1256,1258-1258,125a-125d,1260-1288,128a-128d,1290-12b0,12b2-12b5,12b8-12be,",
        "12c0-12c0,12c2-12c5,12c8-12d6,12d8-1310,1312-1315,1318-135a,135d-137c,1380-1399,13a0-13f5,13f8-13fd,1400-167f,",
        "1681-169c,16a0-16f8,1700-1715,171f-1736,1740-1753,1760-176c,176e-1770,1772-1773,1780-17dd,17e0-17e9,17f0-17f9,",
        "1800-1819,1820-1878,1880-18aa,18b0-18f5,1900-191e,1920-192b,1930-193b,1940-1940,1944-196d,1970-1974,1980-19ab,",
        "19b0-19c9,19d0-19da,19de-1a1b,1a1e-1a5e,1a60-1a7c,1a7f-1a89,1a90-1a99,1aa0-1aad,1ab0-1ace,1b00-1b4c,1b50-1b7e,",
        "1b80-1bf3,1bfc-1c37,1c3b-1c49,1c4d-1c88,1c90-1cba,1cbd-1cc7,1cd0-1cfa,1d00-1f15,1f18-1f1d,1f20-1f45,1f48-1f4d,",
        "1f50-1f57,1f59-1f59,1f5b-1f5b,1f5d-1f5d,1f5f-1f7d,1f80-1fb4,1fb6-1fc4,1fc6-1fd3,1fd6-1fdb,1fdd-1fef,1ff2-1ff4,",
        "1ff6-1ffe,200b-2027,202a-202e,2030-205e,2060-2064,2066-2071,2074-208e,2090-209c,20a0-20c0,20d0-20f0,2100-218b,",
        "2190-2426,2440-244a,2460-2b73,2b76-2b95,2b97-2cf3,2cf9-2d25,2d27-2d27,2d2d-2d2d,2d30-2d67,2d6f-2d70,2d7f-2d96,",
        "2da0-2da6,2da8-2dae,2db0-2db6,2db8-2dbe,2dc0-2dc6,2dc8-2dce,2dd0-2dd6,2dd8-2dde,2de0-2e5d,2e80-2e99,2e9b-2ef3,",
        "2f00-2fd5,2ff0-2ffb,3001-303f,3041-3096,3099-30ff,3105-312f,3131-318e,3190-31e3,31f0-321e,3220-a48c,a490-a4c6,",
        "a4d0-a62b,a640-a6f7,a700-a7ca,a7d0-a7d1,a7d3-a7d3,a7d5-a7d9,a7f2-a82c,a830-a839,a840-a877,a880-a8c5,a8ce-a8d9,",
        "a8e0-a953,a95f-a97c,a980-a9cd,a9cf-a9d9,a9de-a9fe,aa00-aa36,aa40-aa4d,aa50-aa59,aa5c-aac2,aadb-aaf6,ab01-ab06,",
        "ab09-ab0e,ab11-ab16,ab20-ab26,ab28-ab2e,ab30-ab6b,ab70-abed,abf0-abf9,ac00-d7a3,d7b0-d7c6,d7cb-d7fb,f900-fa6d,",
        "fa70-fad9,fb00-fb06,fb13-fb17,fb1d-fb36,fb38-fb3c,fb3e-fb3e,fb40-fb41,fb43-fb44,fb46-fbc2,fbd3-fd8f,fd92-fdc7,",
        "fdcf-fdcf,fdf0-fe19,fe20-fe52,fe54-fe66,fe68-fe6b,fe70-fe74,fe76-fefc,ff01-ffbe,ffc2-ffc7,ffca-ffcf,ffd2-ffd7,",
        "ffda-ffdc,ffe0-ffe6,ffe8-ffee,fff9-fffd,",
    ].joined()
}

// MARK: - Which websites the form takes

final class UseCaseWebsiteTests: XCTestCase {
    private let noSite = "Enter your company's website, like https://example.com."

    private func problem(_ site: String) -> String? {
        UseCaseForm(companyName: "Acme", companyWebsite: site, industry: "Technology", useCases: "x").problem
    }

    func testWebsitesAreJudgedAsTheWindowsAppJudgesThem() {
        XCTAssertGreaterThan(UseCaseFormCorpora.websites.count, 900)
        var accepted = 0
        for (site, ok) in UseCaseFormCorpora.websites {
            let actual = problem(site)
            if ok {
                XCTAssertNil(actual, "should take: \(BedrockFixtureText.escaped(site))")
                accepted += 1
            } else {
                XCTAssertEqual(actual, noSite, "should refuse: \(BedrockFixtureText.escaped(site))")
            }
        }
        XCTAssertGreaterThan(accepted, 300)
        XCTAssertGreaterThan(UseCaseFormCorpora.websites.count - accepted, 300)
    }

    func testTheSitesPeopleActuallyTypeAreTaken() {
        for site in ["example.com", "www.example.com", "https://example.com", "https://example.com/", "http://example.com/about?x=1#top", "example.co.uk",
                     "github.com/octocat", "linkedin.com/in/someone", "https://sub.domain.example.org:8443/path", "my-site.dev", "MyCompany.COM",
                     "https://münchen.de", "日本語.jp", "  https://acme.example  ", "acme.example.", "1.2.3.4", "https://[::ffff:1.2.3.4]/x"] {
            XCTAssertNil(problem(site), site)
        }
    }

    func testTheOnesThatAreNotAWebsiteAreRefused() {
        for site in ["", "   ", "none", "n/a", "-", "no website", "personal", "localhost", "localhost:3000", "http://localhost", "intranet", "example",
                     "https://", "http://", "://example.com", "ftp://example.com", "file:///etc/passwd", "mailto:example.com",
                     "javascript:alert(1)", "ws://example.com", "https://exa mple.com", "https://example.com:abc", "https://example.com:99999",
                     "https://.com", "https://example..com", "http://[::1]", "https://a@", "https://example.com\\path", "<example.com>", "\"example.com\"",
                     "example.com,", "https://%41.com"] {
            XCTAssertEqual(problem(site), noSite, site)
        }
    }

    func testTheSchemeMustBeHttpOrHttpsInAnyCase() {
        for scheme in ["http", "https", "HTTP", "HTTPS", "Http", "hTTpS"] { XCTAssertNil(problem("\(scheme)://a.b"), scheme) }
        for scheme in ["ftp", "ftps", "ws", "wss", "file", "gopher", "httpx", "xhttp", "http+x", "h", ""] { XCTAssertEqual(problem("\(scheme)://a.b"), noSite, scheme) }
    }

    func testTheHostNeedsADotOrIsANumberThatSystemUriReadsAsAnAddress() {
        XCTAssertNil(problem("http://1"), "1 is 0.0.0.1")
        XCTAssertNil(problem("http://2130706433"), "127.0.0.1")
        XCTAssertNil(problem("http://0x7f000001"))
        XCTAssertNil(problem("http://017700000001"))
        XCTAssertNil(problem("http://4294967295"))
        XCTAssertNil(problem("http://0"))
        XCTAssertEqual(problem("http://4294967296"), noSite, "more than 32 bits")
        XCTAssertEqual(problem("http://0x100000000"), noSite)
        XCTAssertEqual(problem("http://08"), noSite, "not octal")
        XCTAssertEqual(problem("http://0x"), noSite)
        XCTAssertEqual(problem("http://1a"), noSite)
        XCTAssertNil(problem("http://256.256.256.256"), "not an address, but a dotted name")
        XCTAssertNil(problem("http://1.a"))
        XCTAssertEqual(problem("http://a1"), noSite)
    }

    func testAPortIsDigitsUpTo65535() {
        for port in ["", "0", "80", "65535", "0080", "00000000000000000080"] { XCTAssertNil(problem("https://a.b:\(port)"), port) }
        for port in ["65536", "99999", "abc", "-1", "+80", "8 0", " 80", "0x50", "80.0", "٨٠", "80:90"] { XCTAssertEqual(problem("https://a.b:\(port)"), noSite, port) }
    }

    func testUserInfoIsIgnoredAndBackslashesAreNotAllowedInTheHost() {
        XCTAssertNil(problem("https://user@a.b"))
        XCTAssertNil(problem("https://user:secret@a.b:8080/x"))
        XCTAssertNil(problem("https://us er@a.b"))
        XCTAssertNil(problem("https://@a.b"))
        XCTAssertEqual(problem("https://a@b@c.d"), noSite, "a second @")
        XCTAssertEqual(problem("https://a.b@"), noSite)
        XCTAssertEqual(problem("https://x@y"), noSite, "user info doesn't give the host a dot")
        XCTAssertEqual(problem("https://us\\er@a.b"), noSite)
        XCTAssertEqual(problem("https://a.b\\x"), noSite)
        XCTAssertNil(problem("https://a.b/x\\y"), "after the host a backslash is only text")
        XCTAssertNil(problem("https://a.b?x=\\"))
    }

    func testFullWidthAndIdeographicDotsSeparateLabelsTooButDoNotCountAsADot() {
        XCTAssertEqual(problem("http://a.\u{FF0E}"), noSite, "an empty label")
        XCTAssertEqual(problem("http://a.\u{FF61}"), noSite)
        XCTAssertEqual(problem("http://a\u{FF0E}.b"), noSite)
        XCTAssertEqual(problem("http://\u{FF0E}a.b"), noSite)
        XCTAssertEqual(problem("http://a\u{FF0E}\u{FF0E}b.c"), noSite)
        XCTAssertNil(problem("http://a\u{FF0E}b.c"))
        XCTAssertNil(problem("http://a\u{FF61}b.c"))
        XCTAssertNil(problem("http://a\u{3002}b.c"))
        XCTAssertEqual(problem("http://a\u{FF0E}b"), noSite, "and none of them is the dot the host needs")
    }

    func testAnAtSignEndingAnIPv6AuthorityIsOnlyToleratedAtTheEndOfTheText() {
        XCTAssertNil(problem("http://[::ffff:1.2.3.4]@"))
        XCTAssertNil(problem("http://[::ffff:1.2.3.4]x@"))
        for tail in ["/x", "?x", "#x"] {
            XCTAssertEqual(problem("http://[::ffff:1.2.3.4]@" + tail), noSite, tail)
            XCTAssertEqual(problem("http://[::ffff:1.2.3.4]x@" + tail), noSite, tail)
        }
        XCTAssertEqual(problem("http://[::1]@"), noSite, "and then the literal is the host: it has no dot")
        XCTAssertEqual(problem("http://a.b@/x"), noSite)
    }

    func testLabelsAndTheDotsBetweenThem() {
        for host in ["a.b", "a.b.", "a-b.c", "-.a", "a.-", "_.a", "a._", "a_b.c", "a--b.c", "xn--a.b", "1.a", "a.1", "A.B", "a.b.c.d.e.f.g.h"] { XCTAssertNil(problem("http://\(host)"), host) }
        for host in [".", "..", ".a", "a..b", "a.b..", ".a.b", "a b.c", "a,b.c", "a;b.c", "a!b.c", "a$b.c", "a%b.c", "a'b.c", "a(b.c", "a*b.c", "a+b.c",
                     "a=b.c", "a~b.c", "a{b.c", "a|b.c", "a^b.c", "a\"b.c", "a<b.c", "a`b.c", "a[b.c", "a]b.c", "a\tb.c", "a\nb.c", "a\u{0}b.c", "a\u{7F}b.c"] {
            XCTAssertEqual(problem("http://\(host)"), noSite, host)
        }
        XCTAssertEqual(problem("http://a\u{80}b.c"), noSite, "C1 controls")
        XCTAssertEqual(problem("http://a.\u{3002}"), noSite, "an ideographic full stop reads as a dot: an empty label")
        XCTAssertEqual(problem("http://a\u{3002}b"), noSite, "and is not a dot to the host check")
        XCTAssertNil(problem("http://a\u{3002}b.c"))
    }

    func testAfterTheFirstDigitLabelTheHostnameRulesApply() {
        // System.Uri reads a name starting with digits as a would-be IPv4 address first and then holds it to stricter rules.
        XCTAssertEqual(problem("http://80._c"), noSite)
        XCTAssertEqual(problem("http://80.-c"), noSite)
        XCTAssertNil(problem("http://80.c-"))
        XCTAssertNil(problem("http://80.c_"))
        XCTAssertNil(problem("http://8a._c"))
        XCTAssertNil(problem("http://80a._c"))
        XCTAssertEqual(problem("http://1.2._c"), noSite)
        XCTAssertNil(problem("http://_1.2.3.4"), "a leading underscore before the numbers is fine")
        // From the third label on, none may start with "-" or "_" (System.Uri).
        XCTAssertEqual(problem("http://_.a.-"), noSite)
        XCTAssertEqual(problem("http://a.b._c"), noSite)
        XCTAssertNil(problem("http://a._c"))
        XCTAssertNil(problem("http://a.b_.c"))
    }

    func testLongNamesAreCappedWhenALabelIsLong() {
        func host(_ lengths: [Int]) -> String { "http://" + lengths.map { String(repeating: "a", count: $0) }.joined(separator: ".") }
        // Labels up to 63 characters: any number of them.
        XCTAssertNil(problem(host([63, 63, 63, 63, 63])))
        XCTAssertNil(problem(host(Array(repeating: 1, count: 300))))
        XCTAssertNil(problem(host(Array(repeating: 30, count: 200))))
        // A longer label caps the whole name at 256 characters.
        XCTAssertNil(problem(host([127, 128])), "256 characters")
        XCTAssertNil(problem(host([127, 127])))
        XCTAssertEqual(problem(host([128, 128])), noSite)
        XCTAssertNil(problem(host([100, 100, 54])))
        XCTAssertEqual(problem(host([100, 100, 55])), noSite)
        XCTAssertNil(problem(host([1, 1, 1, 250])))
        XCTAssertEqual(problem(host([1, 1, 1, 251])), noSite)
        XCTAssertEqual(problem(host([63, 63, 63, 63, 64])), noSite)
        XCTAssertNil(problem(host([70, 1, 1, 1, 1])))
        XCTAssertNil(problem(host([254, 1])))
        XCTAssertEqual(problem(host([255, 1])), noSite)
        // After a leading all-digit label, later labels are held to 63.
        XCTAssertNil(problem("http://1." + String(repeating: "a", count: 63)))
        XCTAssertEqual(problem("http://1." + String(repeating: "a", count: 64)), noSite)
        XCTAssertNil(problem("http://a." + String(repeating: "a", count: 64)))
    }

    func testTheWholeAddressMayBeAtMost65519Units() {
        let prefix = "https://a.b/"
        func site(_ length: Int) -> String { prefix + String(repeating: "x", count: length - prefix.count) }
        // Acceptable as a website at 65519 (the form is then too big to send, but that is another message) …
        XCTAssertEqual(problem(site(65_519)), "The description is too long; shorten it.")
        XCTAssertEqual(problem(site(20_000)), "The description is too long; shorten it.")
        // … and no website at all from 65520.
        XCTAssertEqual(problem(site(65_520)), noSite)
        XCTAssertEqual(problem(site(70_000)), noSite)
        XCTAssertNil(problem(site(2_000)))
    }

    func testIPv6LiteralsNeedAnEmbeddedDottedQuadThatSystemUriKeeps() {
        for host in ["[::ffff:1.2.3.4]", "[::1.2.3.4]", "[::ffff:0:1.2.3.4]", "[::5efe:1.2.3.4]", "[1::5efe:1.2.3.4]", "[0:0:0:0:0:ffff:1.2.3.4]",
                     "[::ffff:102:304]", "[::102:304]", "[::FFFF:1.2.3.4]", "[::ffff:1.2.3.4%25eth0]", "[::ffff:1.2.3.4]:8080", "[::ffff:1.2.3.4]/x",
                     "[::ffff:1.2.3.4]junk", "user@[::ffff:1.2.3.4]"] {
            XCTAssertNil(problem("http://\(host)"), host)
        }
        for host in ["[::1]", "[::]", "[2001:db8::1]", "[fe80::1%25en0]", "[64:ff9b::1.2.3.4]", "[1:2:3:4:5:6:1.2.3.4]", "[::ffff:0.0.0.1]", "[::0.0.0.2]",
                     "[]", "[:]", "[::1", "::1]", "[g::1]", "[1::2::3]", "[1:2:3:4:5:6:7:8:9]", "[::ffff:1.2.3.256]", "[::ffff:001.2.3.4]",
                     "[::ffff:1.2.3.4]:x", "[::ffff:1.2.3.4]\\x", "[a.b]", "[1.2.3.4]"] {
            XCTAssertEqual(problem("http://\(host)"), noSite, host)
        }
    }

    func testIPv6GroupsAreExpanded() {
        func groups(_ text: String) -> [UInt16]? { WebsiteCheck.ipv6Groups(Array(text.unicodeScalars)) }
        XCTAssertEqual(groups("::1"), [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(groups("::"), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(groups("1::"), [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(groups("1:2:3:4:5:6:7:8"), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(groups("1:2:3:4:5:6:7::"), [1, 2, 3, 4, 5, 6, 7, 0])
        XCTAssertEqual(groups("::2:3:4:5:6:7:8"), [0, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(groups("::ffff:1.2.3.4"), [0, 0, 0, 0, 0, 0xFFFF, 0x0102, 0x0304])
        XCTAssertEqual(groups("fe80::1%25en0"), [0xFE80, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(groups("FE80::ABCD"), [0xFE80, 0, 0, 0, 0, 0, 0, 0xABCD])
        XCTAssertNil(groups("1:2:3:4:5:6:7:8:9"))
        XCTAssertNil(groups("1:2:3:4:5:6:7"))
        XCTAssertNil(groups("1::2::3"))
        XCTAssertNil(groups(":1"))
        XCTAssertNil(groups("1:"))
        XCTAssertNil(groups("12345::1"))
        XCTAssertNil(groups("::g"))
        XCTAssertNil(groups("::+1"))
        XCTAssertNil(groups("1.2.3.4::"))
        XCTAssertNil(groups("::1.2.3"))
        XCTAssertNil(groups("::1.2.3.4.5"))
        XCTAssertNil(groups(""))
    }

    func testWhichIPv6AddressesKeepTheirDottedQuad() {
        XCTAssertTrue(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0, 0xFFFF, 0x0102, 0x0304]), "IPv4-mapped")
        XCTAssertTrue(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0, 0, 0x0102, 0x0304]), "IPv4-compatible")
        XCTAssertTrue(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0xFFFF, 0, 0x0102, 0x0304]), "SIIT")
        XCTAssertTrue(WebsiteCheck.keepsDottedQuad([1, 0, 0, 0, 0, 0x5EFE, 0x0102, 0x0304]), "ISATAP")
        XCTAssertTrue(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0, 0x5EFE, 0, 0]), "ISATAP with an all-zero address")
        XCTAssertFalse(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0, 0, 0, 1]), "::1")
        XCTAssertFalse(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0, 0, 0, 0]), "::")
        XCTAssertFalse(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0, 0xFFFF, 0, 1]), "::ffff:0:1")
        XCTAssertFalse(WebsiteCheck.keepsDottedQuad([0x64, 0xFF9B, 0, 0, 0, 0, 0x0102, 0x0304]))
        XCTAssertFalse(WebsiteCheck.keepsDottedQuad([0, 0, 0, 1, 0, 0xFFFF, 0x0102, 0x0304]))
        XCTAssertFalse(WebsiteCheck.keepsDottedQuad([0, 0, 0, 0, 0x200, 0x5EFE, 0x0102, 0x0304]))
    }
}

// MARK: - Base64 the way .NET reads it

final class UseCaseBase64Tests: XCTestCase {
    func testDecodingMatchesConvertFromBase64String() {
        XCTAssertGreaterThan(UseCaseFormCorpora.base64.count, 30)
        for (text, hex) in UseCaseFormCorpora.base64 {
            let bytes = UseCaseForm.decodeBase64(text)
            XCTAssertEqual(bytes.map { $0.map { String(format: "%02X", $0) }.joined() }, hex, BedrockFixtureText.escaped(text))
        }
    }

    func testEncodingThenDecodingGivesTheBytesBack() {
        var generator = SystemRandomNumberGenerator()
        for length in 0...64 {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            XCTAssertEqual(UseCaseForm.decodeBase64(Data(bytes).base64EncodedString()), bytes, "\(length) bytes")
        }
        XCTAssertEqual(UseCaseForm.decodeBase64("YWJj\nZGVm"), Array("abcdef".utf8), "line breaks are skipped")
    }
}
