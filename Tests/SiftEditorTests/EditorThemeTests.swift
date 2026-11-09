import XCTest
import AppKit
@testable import SiftEditorCore

/// 验证  / `EditorTheme` 的预设分辨率、自定义颜色持久性和更改通知。
/// 要访问  / UserDefaults.standard，请在每次测试中将其恢复为原始值。
final class EditorThemeTests: XCTestCase {

    private var savedPreset: ThemePreset!
    private var savedCustom: [EditorTheme.ColorKey: NSColor] = [:]
    private var savedOpacity: CGFloat = 1.0
    private var savedANSI = true

    override func setUp() {
        super.setUp()
        savedPreset = EditorTheme.preset
        savedOpacity = EditorTheme.backgroundOpacity
        savedANSI = EditorTheme.ansiColorsEnabled
        for key in EditorTheme.ColorKey.allCases { savedCustom[key] = EditorTheme.customColor(key) }
    }

    override func tearDown() {
        // custom 恢复颜色（setCustomColor 会将 preset 转换为 .custom，因此 preset 恢复将最后进行）。
        for key in EditorTheme.ColorKey.allCases {
            if let c = savedCustom[key] { EditorTheme.setCustomColor(key, c) }
        }
        EditorTheme.backgroundOpacity = savedOpacity
        EditorTheme.ansiColorsEnabled = savedANSI
        EditorTheme.preset = savedPreset
        super.tearDown()
    }

    func testDefaultSystemUsesSemanticColors() {
        EditorTheme.preset = .system
        let t = EditorTheme.current()
        // 与现有硬编码值（语义颜色）匹配 = 默认外观与以前相同。
        XCTAssertEqual(t.foreground, NSColor.textColor)
        XCTAssertEqual(t.background, NSColor.textBackgroundColor)
        XCTAssertEqual(t.selection, NSColor.selectedTextBackgroundColor)
    }

    func testPresetReturnsFixedColors() {
        EditorTheme.preset = .solarizedDark
        let bg = EditorTheme.current().background.usingColorSpace(.sRGB)!
        // Solarized Dark 背景 #002B36。
        XCTAssertEqual(bg.redComponent, 0x00 / 255.0, accuracy: 0.01)
        XCTAssertEqual(bg.greenComponent, 0x2B / 255.0, accuracy: 0.01)
        XCTAssertEqual(bg.blueComponent, 0x36 / 255.0, accuracy: 0.01)
    }

    func testSetCustomColorSwitchesToCustomAndRoundTrips() {
        let picked = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        EditorTheme.setCustomColor(.foreground, picked)
        XCTAssertEqual(EditorTheme.preset, .custom)
        let got = EditorTheme.current().foreground.usingColorSpace(.sRGB)!
        XCTAssertEqual(got.redComponent, 0.2, accuracy: 0.001)
        XCTAssertEqual(got.greenComponent, 0.4, accuracy: 0.001)
        XCTAssertEqual(got.blueComponent, 0.6, accuracy: 0.001)
        XCTAssertEqual(got.alphaComponent, 0.5, accuracy: 0.001)   // alpha 也被保存。
    }

    func testBackgroundOpacityClampsAndPersists() {
        EditorTheme.backgroundOpacity = 0.6
        XCTAssertEqual(EditorTheme.backgroundOpacity, 0.6, accuracy: 0.001)
        XCTAssertFalse(EditorTheme.isOpaqueBackground)
        // 超出范围的值将被限制 (0.30–1.00)。
        EditorTheme.backgroundOpacity = 5.0
        XCTAssertEqual(EditorTheme.backgroundOpacity, 1.0, accuracy: 0.001)
        XCTAssertTrue(EditorTheme.isOpaqueBackground)
        EditorTheme.backgroundOpacity = 0.0
        XCTAssertEqual(EditorTheme.backgroundOpacity, 0.30, accuracy: 0.001)
    }

    func testWithBackgroundOpacityMultipliesAlpha() {
        EditorTheme.backgroundOpacity = 1.0
        let opaque = NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        // 当完全不透明时，它会穿过（同一实例）。
        XCTAssertEqual(EditorTheme.withBackgroundOpacity(opaque), opaque)
        EditorTheme.backgroundOpacity = 0.5
        let half = EditorTheme.withBackgroundOpacity(opaque)
        XCTAssertEqual(half.alphaComponent, 0.5, accuracy: 0.001)
        // 原版 alpha 也受到尊重并被复制。
        let semi = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4)
        XCTAssertEqual(EditorTheme.withBackgroundOpacity(semi).alphaComponent, 0.2, accuracy: 0.001)
    }

    func testAnsiColorsEnabledDefaultsOnAndToggles() {
        EditorTheme.ansiColorsEnabled = true
        XCTAssertTrue(EditorTheme.ansiColorsEnabled)
        EditorTheme.ansiColorsEnabled = false
        XCTAssertFalse(EditorTheme.ansiColorsEnabled)
    }

    func testOpacityAndAnsiPostNotification() {
        let e1 = expectation(forNotification: .siftEditorDisplayChanged, object: nil)
        EditorTheme.backgroundOpacity = 0.7
        wait(for: [e1], timeout: 1)
        let e2 = expectation(forNotification: .siftEditorDisplayChanged, object: nil)
        EditorTheme.ansiColorsEnabled.toggle()
        wait(for: [e2], timeout: 1)
    }

    func testChangePostsDisplayNotification() {
        let presetExp = expectation(forNotification: .siftEditorDisplayChanged, object: nil)
        EditorTheme.preset = .monokai
        wait(for: [presetExp], timeout: 1)

        let colorExp = expectation(forNotification: .siftEditorDisplayChanged, object: nil)
        EditorTheme.setCustomColor(.background, .white)
        wait(for: [colorExp], timeout: 1)
    }
}
