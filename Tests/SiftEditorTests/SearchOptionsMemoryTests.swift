import XCTest
import AppKit
@testable import SiftEditorCore

final class SearchOptionsMemoryTests: XCTestCase {
    private var saved: [FindOption: Any] = [:]

    override func setUp() {
        super.setUp()
        for option in FindOption.allCases {
            saved[option] = UserDefaults.standard.object(forKey: "SiftEditor.find.\(option.rawValue)")
        }
    }

    override func tearDown() {
        for option in FindOption.allCases {
            let key = "SiftEditor.find.\(option.rawValue)"
            if let value = saved[option] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testFindOptionsRestoreAfterClosingAndReopening() {
        AppSettings.setFindOption(.matchCase, true)
        AppSettings.setFindOption(.regex, true)
        let bar = SearchBarView()
        bar.restoreSearchOptions()
        XCTAssertTrue(bar.isCaseSensitive)
        XCTAssertTrue(bar.isRegex)

        bar.clear()
        XCTAssertFalse(bar.isCaseSensitive)
        XCTAssertFalse(bar.isRegex)
        bar.restoreSearchOptions()
        XCTAssertTrue(bar.isCaseSensitive)
        XCTAssertTrue(bar.isRegex)

        bar.prefillFromSelection("selected text")
        XCTAssertTrue(bar.isRegex, "Selection prefill must preserve the chosen search mode")
        XCTAssertTrue(bar.isCaseSensitive)
        XCTAssertTrue(AppSettings.findOption(.regex))
        bar.restoreSearchOptions()
        XCTAssertTrue(bar.isRegex)
    }

    func testDisabledOptionsUseSameStoredValuesWhenEnabledLater() {
        let key = "SiftEditor.find.wrap"
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(AppSettings.findOption(.wrap))
        AppSettings.setFindOption(.wrap, false)
        XCTAssertFalse(AppSettings.findOption(.wrap))
        AppSettings.setFindOption(.wholeWord, true)
        XCTAssertTrue(AppSettings.findOption(.wholeWord))
    }

    func testClickingOptionsSavesImmediately() throws {
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.compactMap { button(title, in: $0) }.first
        }
        AppSettings.setFindOption(.matchCase, false)
        AppSettings.setFindOption(.regex, false)
        AppSettings.setFindOption(.wholeWord, false)
        let bar = SearchBarView()

        let matchCase = try XCTUnwrap(button(L("search.dialog.case"), in: bar))
        matchCase.performClick(nil)
        XCTAssertTrue(AppSettings.findOption(.matchCase))

        let regex = try XCTUnwrap(button(L("search.dialog.regex"), in: bar))
        regex.performClick(nil)
        XCTAssertTrue(AppSettings.findOption(.regex))
        try XCTUnwrap(button(L("search.dialog.none"), in: bar)).performClick(nil)
        XCTAssertFalse(AppSettings.findOption(.regex))

        let wholeWord = try XCTUnwrap(button(L("search.dialog.wholeWord") + " *", in: bar))
        wholeWord.isEnabled = true  // Future feature activation uses the same action.
        wholeWord.performClick(nil)
        XCTAssertTrue(AppSettings.findOption(.wholeWord))
    }
}
