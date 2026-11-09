import AppKit

/// 全局维护并持久化编辑器正文的等宽字体（类型和大小）。
/// 您可以使用 ⌘+ / ⌘- / ⌘0 更改大小，并在首选项 (⌘,) 中选择类型 + 大小。
/// 更改将通过 `.siftEditorFontChanged` 通知所有窗口查看器。
enum EditorFont {
    static let defaultSize: CGFloat = 12
    static let minSize: CGFloat = 9
    static let maxSize: CGFloat = 28
    private static let sizeKey = "SiftEditor.fontSize"
    private static let nameKey = "SiftEditor.fontName"

    /// 当未指定字体名称或无法生成字体名称时，从一开始就要尝试的默认候选字体。
    private static let fallbackNames = ["SF Mono", "Menlo", "Monaco", "Courier"]

    private static var size: CGFloat = {
        let v = UserDefaults.standard.double(forKey: sizeKey)
        return v > 0 ? CGFloat(v) : defaultSize
    }()

    /// 选定的字体名称（nil = 回退到系统默认等宽字体）。
    private static var name: String? = UserDefaults.standard.string(forKey: nameKey)

    static var currentSize: CGFloat { size }
    static var currentName: String? { name }

    /// 设置大小（为持久化和通知，限制为 min/max）。返回限制后的值。
    @discardableResult
    static func setSize(_ newSize: CGFloat) -> CGFloat {
        let clamped = min(max(minSize, newSize), maxSize)
        size = clamped
        UserDefaults.standard.set(Double(clamped), forKey: sizeKey)
        NotificationCenter.default.post(name: .siftEditorFontChanged, object: nil)
        return clamped
    }

    /// 设置字体名称（nil = 恢复为系统默认值）。保存并通知。
    static func setName(_ newName: String?) {
        name = newName
        let d = UserDefaults.standard
        if let n = newName { d.set(n, forKey: nameKey) } else { d.removeObject(forKey: nameKey) }
        NotificationCenter.default.post(name: .siftEditorFontChanged, object: nil)
    }

    static func current() -> NSFont {
        if let n = name, let f = NSFont(name: n, size: size) { return f }
        for n in fallbackNames { if let f = NSFont(name: n, size: size) { return f } }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 要作为选项显示的等宽字体系列名称（按显示名称排序）。
    /// 从整个系统中检索与 `isFixedPitch` 具有相同 ID 的项目，包括默认候选项目。
    static func availableMonospaceFamilies() -> [String] {
        var names = Set<String>()
        for family in NSFontManager.shared.availableFontFamilies {
            if let f = NSFont(name: family, size: defaultSize), f.isFixedPitch {
                names.insert(family)
            }
        }
        for n in fallbackNames where NSFont(name: n, size: defaultSize) != nil {
            names.insert(n)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

}

extension Notification.Name {
    /// 当编辑器字体（类型和大小）发生变化时（反映在所有打开的查看器中）。
    static let siftEditorFontChanged = Notification.Name("SiftEditor.fontChanged")
}
