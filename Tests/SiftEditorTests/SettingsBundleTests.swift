import XCTest
import AppKit
@testable import SiftEditorCore

/// 导入/应用  / `SettingsBundle` 的往返行程，组装和分析共享的 URL，
/// 验证对无效输入的安全拒绝。在修改 UserDefaults.standard 之前恢复到原始值。
final class SettingsBundleTests: XCTestCase {

    private var saved: SettingsBundle!
    private var savedPreset: ThemePreset!
    private var savedCustom: [EditorTheme.ColorKey: NSColor] = [:]

    override func setUp() {
        super.setUp()
        saved = SettingsBundle.capture()
        savedPreset = EditorTheme.preset
        for key in EditorTheme.ColorKey.allCases { savedCustom[key] = EditorTheme.customColor(key) }
    }

    override func tearDown() {
        saved.apply()
        for key in EditorTheme.ColorKey.allCases {
            if let c = savedCustom[key] { EditorTheme.setCustomColor(key, c) }
        }
        EditorTheme.preset = savedPreset
        super.tearDown()
    }

    // MARK: - capture → apply 往復

    func testCaptureApplyRoundTripsAllFields() {
        // 创建已知状态。
        EditorTheme.preset = .dracula
        EditorFont.setName("Menlo")
        EditorFont.setSize(16)
        AppSettings.tabWidth = 8
        AppSettings.lineSpacing = .wide
        AppSettings.highlightCurrentLine = false
        AppSettings.cursorShape = .block
        AppSettings.lineWrap = true
        EditorTheme.backgroundOpacity = 0.65
        EditorTheme.ansiColorsEnabled = false

        let bundle = SettingsBundle.capture()

        // 将系统中断到不同的状态，然后使用 apply 将其恢复。
        EditorTheme.preset = .system
        EditorFont.setName(nil)
        EditorFont.setSize(12)
        AppSettings.tabWidth = 2
        AppSettings.lineSpacing = .standard
        AppSettings.highlightCurrentLine = true
        AppSettings.cursorShape = .bar
        AppSettings.lineWrap = false
        EditorTheme.backgroundOpacity = 1.0
        EditorTheme.ansiColorsEnabled = true

        bundle.apply()

        XCTAssertEqual(EditorTheme.backgroundOpacity, 0.65, accuracy: 0.001)
        XCTAssertFalse(EditorTheme.ansiColorsEnabled)
        XCTAssertEqual(EditorTheme.preset, .dracula)
        XCTAssertEqual(EditorFont.currentName, "Menlo")
        XCTAssertEqual(EditorFont.currentSize, 16)
        XCTAssertEqual(AppSettings.tabWidth, 8)
        XCTAssertEqual(AppSettings.lineSpacing, .wide)
        XCTAssertFalse(AppSettings.highlightCurrentLine)
        XCTAssertEqual(AppSettings.cursorShape, .block)
        XCTAssertTrue(AppSettings.lineWrap)
    }

    func testCustomColorsRoundTripWithAlpha() {
        let picked = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        EditorTheme.setCustomColor(.foreground, picked)   // 将  preset 更改为 .custom
        let bundle = SettingsBundle.capture()
        XCTAssertEqual(bundle.themePreset, ThemePreset.custom.rawValue)

        // 将其击败至不同颜色，然后 apply。
        EditorTheme.setCustomColor(.foreground, .white)
        bundle.apply()

        XCTAssertEqual(EditorTheme.preset, .custom)
        let got = EditorTheme.customColor(.foreground).usingColorSpace(.sRGB)!
        XCTAssertEqual(got.redComponent, 0.2, accuracy: 0.01)
        XCTAssertEqual(got.greenComponent, 0.4, accuracy: 0.01)
        XCTAssertEqual(got.blueComponent, 0.6, accuracy: 0.01)
        XCTAssertEqual(got.alphaComponent, 0.5, accuracy: 0.01)
    }

    func testNilFontNameRoundTrips() {
        EditorFont.setName(nil)
        let bundle = SettingsBundle.capture()
        XCTAssertNil(bundle.fontName)
        EditorFont.setName("Menlo")
        bundle.apply()
        XCTAssertNil(EditorFont.currentName)
    }

    // MARK: - JSON / base64url / URL 往復

    func testEncodedStringRoundTrips() throws {
        let bundle = SettingsBundle.capture()
        let encoded = bundle.encodedString()
        let back = try SettingsBundle.decode(fromEncoded: encoded)
        XCTAssertEqual(bundle, back)
    }

    func testShareURLRoundTrips() throws {
        EditorTheme.preset = .nord
        let bundle = SettingsBundle.capture()
        let url = bundle.shareURL()
        XCTAssertEqual(url.scheme, "sifteditor")
        XCTAssertEqual(url.host, "theme")
        let back = try SettingsBundle.decode(fromURL: url)
        XCTAssertEqual(bundle, back)
        XCTAssertEqual(back.themePreset, ThemePreset.nord.rawValue)
    }

    func testJSONRoundTrips() throws {
        let bundle = SettingsBundle.capture()
        let data = bundle.jsonData()
        let back = try SettingsBundle.decode(fromJSON: data)
        XCTAssertEqual(bundle, back)
    }

    // MARK: - 拒绝无效输入

    func testDecodeRejectsGarbageString() {
        XCTAssertThrowsError(try SettingsBundle.decode(fromEncoded: "!!!not base64!!!")) { err in
            XCTAssertEqual(err as? SettingsBundle.DecodeError, .malformed)
        }
    }

    func testDecodeRejectsWrongScheme() {
        let url = URL(string: "https://example.com/theme?d=abc")!
        XCTAssertThrowsError(try SettingsBundle.decode(fromURL: url)) { err in
            XCTAssertEqual(err as? SettingsBundle.DecodeError, .wrongScheme)
        }
    }

    func testDecodeRejectsMissingData() {
        let url = URL(string: "sifteditor://theme")!
        XCTAssertThrowsError(try SettingsBundle.decode(fromURL: url)) { err in
            XCTAssertEqual(err as? SettingsBundle.DecodeError, .missingData)
        }
    }

    func testDecodeRejectsFutureVersion() throws {
        var bundle = SettingsBundle.capture()
        bundle.version = SettingsBundle.currentVersion + 1
        let data = bundle.jsonData()
        XCTAssertThrowsError(try SettingsBundle.decode(fromJSON: data)) { err in
            XCTAssertEqual(err as? SettingsBundle.DecodeError, .unsupportedVersion)
        }
    }

    func testUnknownPresetFallsBackToSystemOnApply() throws {
        var bundle = SettingsBundle.capture()
        bundle.themePreset = "someFutureTheme"
        bundle.apply()
        XCTAssertEqual(EditorTheme.preset, .system)
    }

    // MARK: - 颜色 hex 助手

    func testColorFromHexParsesRGBAndRGBA() {
        let rgb = SettingsBundle.color(fromHex: "FF8000")!.usingColorSpace(.sRGB)!
        XCTAssertEqual(rgb.redComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(rgb.greenComponent, 0.5, accuracy: 0.01)
        XCTAssertEqual(rgb.alphaComponent, 1.0, accuracy: 0.01)

        let rgba = SettingsBundle.color(fromHex: "00FF0080")!.usingColorSpace(.sRGB)!
        XCTAssertEqual(rgba.greenComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(rgba.alphaComponent, 0.5, accuracy: 0.01)
    }

    func testColorFromHexRejectsBadLength() {
        XCTAssertNil(SettingsBundle.color(fromHex: "FFF"))
        XCTAssertNil(SettingsBundle.color(fromHex: "ZZZZZZ"))
    }
}
