import AppKit
import UniformTypeIdentifiers

/// UI 侧的接线，用于导出、读取和共享外观设置链接 ([[SettingsBundle]])。
/// 首选项的“配色方案”面板中的按钮，以及打开 `sifteditor://` 链接时显示的 `AppDelegate`。
/// 调用自  /。申请前务必进行确认（因为外观不会随着其他人的链接/文件而悄然改变）。
enum SettingsShare {

    /// 输出文件为 UTType（未注册的扩展名，因此是动态类型；如果找不到，则视为 JSON）。
    private static var fileType: UTType {
        UTType(filenameExtension: SettingsBundle.fileExtension) ?? .json
    }

    // MARK: - 写入

    /// 将当前外观写入文件 (.sifteditortheme)。
    static func export(presenting window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = "\(L("prefs.share.export.defaultName")).\(SettingsBundle.fileExtension)"
        let write: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? SettingsBundle.capture().jsonData().write(to: url, options: .atomic)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) }
        else { write(panel.runModal()) }
    }

    // MARK: - 读取（文件）

    /// 从文件中读取外观，确认后应用。
    static func importFromFile(presenting window: NSWindow?, onApplied: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType, .json]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        let read: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let bundle = try SettingsBundle.decode(fromJSON: data)
                confirmAndApply(bundle, presenting: window, onApplied: onApplied)
            } catch {
                showFailure(presenting: window)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: read) }
        else { read(panel.runModal()) }
    }

    // MARK: - 分享链接

    /// 将当前外观作为链接 (`sifteditor://theme?d=…`) 分享并保存到剪贴板。
    static func copyShareLink() {
        let url = SettingsBundle.capture().shareURL()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// 从剪贴板读取字符串作为共享链接（或 base64url），确认它，然后应用它。
    static func importFromClipboard(presenting window: NSWindow?, onApplied: (() -> Void)? = nil) {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            showEmptyClipboard(presenting: window)
            return
        }
        let bundle: SettingsBundle?
        if let url = URL(string: raw), SettingsBundle.isSettingsURL(url) {
            bundle = try? SettingsBundle.decode(fromURL: url)
        } else {
            bundle = try? SettingsBundle.decode(fromEncoded: raw)
        }
        if let bundle {
            confirmAndApply(bundle, presenting: window, onApplied: onApplied)
        } else {
            showFailure(presenting: window)
        }
    }

    /// `sifteditor://` 打开链接 (`AppDelegate`) 后，请确认并申请。
    static func apply(url: URL, presenting window: NSWindow?, onApplied: (() -> Void)? = nil) {
        do {
            let bundle = try SettingsBundle.decode(fromURL: url)
            confirmAndApply(bundle, presenting: window, onApplied: onApplied)
        } catch {
            showFailure(presenting: window)
        }
    }

    // MARK: - 确认单

    private static func confirmAndApply(_ bundle: SettingsBundle, presenting window: NSWindow?,
                                        onApplied: (() -> Void)?) {
        let alert = NSAlert()
        alert.messageText = L("share.apply.title")
        alert.informativeText = bundle.summaryLines().joined(separator: "\n")
        alert.addButton(withTitle: L("share.apply.confirm"))
        alert.addButton(withTitle: L("common.cancel"))
        let apply: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .alertFirstButtonReturn else { return }
            bundle.apply()
            onApplied?()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    private static func showFailure(presenting window: NSWindow?) {
        alert(title: L("share.import.failed.title"), message: L("share.import.failed.message"), window: window)
    }

    private static func showEmptyClipboard(presenting window: NSWindow?) {
        alert(title: L("share.clipboard.empty.title"), message: L("share.clipboard.empty.message"), window: window)
    }

    private static func alert(title: String, message: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: L("common.ok"))
        if let window { a.beginSheetModal(for: window, completionHandler: nil) }
        else { a.runModal() }
    }
}
