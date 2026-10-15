import XCTest
import Carbon.HIToolbox
@testable import DSHCore

/// The keyboard tool's key table, checked against the real `kVK_*` constants
/// from Carbon's HIToolbox/Events.h. A wrong entry is not cosmetic: before
/// this table was fixed, "t" was sent as kVK_Delete, so ⌘T in Finder became
/// ⌘⌫ (Move to Trash).
final class KeyboardKeyCodeTests: XCTestCase {
    /// Every key the tool accepts, with the constant it must send.
    static let expected: [(name: String, code: Int)] = [
        // Letters.
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
        ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
        ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
        ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
        ("z", kVK_ANSI_Z),
        // Digits.
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
        ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        // Punctuation, by character and by name.
        ("=", kVK_ANSI_Equal), ("equal", kVK_ANSI_Equal), ("equals", kVK_ANSI_Equal),
        ("-", kVK_ANSI_Minus), ("minus", kVK_ANSI_Minus),
        ("]", kVK_ANSI_RightBracket), ("rightbracket", kVK_ANSI_RightBracket),
        ("[", kVK_ANSI_LeftBracket), ("leftbracket", kVK_ANSI_LeftBracket),
        ("'", kVK_ANSI_Quote), ("quote", kVK_ANSI_Quote),
        (";", kVK_ANSI_Semicolon), ("semicolon", kVK_ANSI_Semicolon),
        ("\\", kVK_ANSI_Backslash), ("backslash", kVK_ANSI_Backslash),
        (",", kVK_ANSI_Comma), ("comma", kVK_ANSI_Comma),
        ("/", kVK_ANSI_Slash), ("slash", kVK_ANSI_Slash),
        (".", kVK_ANSI_Period), ("period", kVK_ANSI_Period),
        ("`", kVK_ANSI_Grave), ("grave", kVK_ANSI_Grave), ("backtick", kVK_ANSI_Grave),
        // Named keys.
        ("enter", kVK_Return), ("return", kVK_Return), ("tab", kVK_Tab), ("space", kVK_Space),
        ("delete", kVK_Delete), ("backspace", kVK_Delete), ("esc", kVK_Escape), ("escape", kVK_Escape),
        ("forwarddelete", kVK_ForwardDelete), ("help", kVK_Help), ("home", kVK_Home), ("end", kVK_End),
        ("pgup", kVK_PageUp), ("pageup", kVK_PageUp), ("pgdn", kVK_PageDown), ("pagedown", kVK_PageDown),
        ("left", kVK_LeftArrow), ("right", kVK_RightArrow), ("down", kVK_DownArrow), ("up", kVK_UpArrow),
        // Function keys.
        ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5),
        ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10),
        ("f11", kVK_F11), ("f12", kVK_F12), ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15),
        ("f16", kVK_F16), ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19), ("f20", kVK_F20),
    ]

    func testEveryKeyMatchesTheCarbonConstant() {
        for (name, code) in Self.expected {
            XCTAssertEqual(KeyboardTool.keyCodes[name].map(Int.init), code, "key '\(name)'")
        }
    }

    func testTableHasNoEntryWithoutACheck() {
        let checked = Set(Self.expected.map(\.name))
        XCTAssertEqual(checked.count, Self.expected.count, "duplicate rows in the expectation table")
        XCTAssertEqual(Set(KeyboardTool.keyCodes.keys), checked,
                       "every key the tool accepts must be listed in `expected` with its kVK constant")
    }

    func testCoversEveryLetterDigitAndPunctuationKey() {
        let required = "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`".map(String.init)
        for key in required {
            XCTAssertNotNil(KeyboardTool.keyCodes[key], "missing key '\(key)'")
        }
    }

    func testTheTrashRegression() throws {
        // ⌘T must be ⌘T, never ⌘⌫ (Finder: Move to Trash).
        let combo = try KeyboardTool.resolve("cmd+t").get()
        XCTAssertEqual(Int(combo.code), kVK_ANSI_T)
        XCTAssertNotEqual(Int(combo.code), kVK_Delete)
        XCTAssertTrue(combo.cmd)
        XCTAssertFalse(combo.shift || combo.ctrl || combo.alt)
    }
}

final class KeyboardComboParsingTests: XCTestCase {
    typealias Combo = KeyboardTool.Combo

    func testPlusAndCommaSeparatorsBothWork() {
        let cases: [(String, Combo)] = [
            ("cmd+s", Combo(key: "s", cmd: true)),
            ("cmd,s", Combo(key: "s", cmd: true)),
            ("CMD+S", Combo(key: "s", cmd: true)),
            ("cmd + s", Combo(key: "s", cmd: true)),
            ("cmd+shift+t", Combo(key: "t", cmd: true, shift: true)),
            ("cmd,shift,t", Combo(key: "t", cmd: true, shift: true)),
            ("ctrl+c", Combo(key: "c", ctrl: true)),
            ("ctrl,c", Combo(key: "c", ctrl: true)),
            ("option+command+esc", Combo(key: "esc", cmd: true, alt: true)),
            ("control+alt+delete", Combo(key: "delete", ctrl: true, alt: true)),
            ("⌘+⇧+z", Combo(key: "z", cmd: true, shift: true)),
            ("return", Combo(key: "return")),
            ("F5", Combo(key: "f5")),
            ("x", Combo(key: "x")),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(KeyboardTool.parseCombo(text), expected, text)
        }
    }

    func testSeparatorCharacterAsTheKey() {
        // ⌘, (Settings) and ⌘. (Stop) are everyday shortcuts.
        XCTAssertEqual(KeyboardTool.parseCombo("cmd+,"), Combo(key: ",", cmd: true))
        XCTAssertEqual(KeyboardTool.parseCombo("cmd,,"), Combo(key: ",", cmd: true))
        XCTAssertEqual(KeyboardTool.parseCombo("cmd + ,"), Combo(key: ",", cmd: true))
        XCTAssertEqual(KeyboardTool.parseCombo("cmd+."), Combo(key: ".", cmd: true))
        XCTAssertEqual(KeyboardTool.parseCombo("cmd,."), Combo(key: ".", cmd: true))
        XCTAssertEqual(KeyboardTool.parseCombo(","), Combo(key: ","))
        XCTAssertEqual(KeyboardTool.parseCombo("shift+="), Combo(key: "=", shift: true))
        XCTAssertEqual(KeyboardTool.parseCombo("cmd+-"), Combo(key: "-", cmd: true))
    }

    func testMalformedCombosAreRejectedNotGuessed() {
        // A typo must never press a bare key: "cmmd+q" is not "q".
        for text in ["", "   ", "cmd+", "cmd,", "cmd + ", "cmmd+q", "super+s", "cmd shift+t", "hyper+x"] {
            XCTAssertNil(KeyboardTool.parseCombo(text), "'\(text)' should not parse")
        }
    }

    func testResolveExplainsFailures() {
        guard case .failure(let unknownKey) = KeyboardTool.resolve("cmd+banana") else {
            return XCTFail("cmd+banana resolved")
        }
        XCTAssertTrue(unknownKey.message.contains("unknown key 'banana'"), unknownKey.message)
        XCTAssertTrue(unknownKey.message.contains("punctuation"), unknownKey.message)

        guard case .failure(let typo) = KeyboardTool.resolve("cmmd+q") else {
            return XCTFail("cmmd+q resolved")
        }
        XCTAssertTrue(typo.message.contains("joined by +"), typo.message)

        // "+" is not a physical key on a US keyboard (it is shift+=).
        if case .success = KeyboardTool.resolve("cmd++") { XCTFail("cmd++ resolved") }
    }

    func testResolveCarriesModifiers() throws {
        let combo = try KeyboardTool.resolve("ctrl+alt+shift+cmd+f12").get()
        XCTAssertEqual(Int(combo.code), kVK_F12)
        XCTAssertTrue(combo.cmd && combo.ctrl && combo.alt && combo.shift)
    }

    func testToolDescriptionExamplesAllResolve() throws {
        let spec = KeyboardTool.spec
        XCTAssertFalse(spec.description.contains("cmd,s"), "the description should teach the + form")
        XCTAssertTrue(spec.description.contains("\"cmd+s\""))
        XCTAssertTrue(spec.parameters.contains("'cmd+s'"))
        // Every quoted key in a [...] example of the description must work.
        let regex = try NSRegularExpression(pattern: #"\[("[^"\]]+"(?:,"[^"\]]+")*)\]"#)
        let text = spec.description as NSString
        var examples: [String] = []
        for match in regex.matches(in: spec.description, range: NSRange(location: 0, length: text.length)) {
            let list = text.substring(with: match.range(at: 1))
            examples += list.split(separator: "\"").map(String.init).filter { $0 != "," }
        }
        XCTAssertGreaterThanOrEqual(examples.count, 8, "found examples: \(examples)")
        for example in examples {
            if case .failure(let error) = KeyboardTool.resolve(example) {
                XCTFail("description example '\(example)' does not resolve: \(error.message)")
            }
        }
    }
}
