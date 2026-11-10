import Foundation

/// 整个申请过程中引用的基本信息。
///
/// **更改产品名称时，只需更改此处即可。**
/// 有关菜单和窗口标题等所有运行时显示，请参阅 `AppInfo.name`。
///（.app 发行版的捆绑包名称等应与 `scripts/make_app.sh` 和 `APP_NAME` 的名称一致。）
enum AppInfo {
    /// 产品名称（显示名称）。**捆绑销售的 `CFBundleName` 是唯一原装正品**（`scripts/make_app.sh` 的原装正品）。
    /// `APP_NAME`）。开发版本（不含捆绑包）请使用 SiftEditor。
    static var name: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? fallbackName
    }
    private static let fallbackName = "SiftEditor"

    /// 显示版本。分发 .app 优先考虑 Info.plist (CFBundleShortVersionString)。
    /// 此常量在开发构建中用作备用（不打包）。
    /// **发布时，它将与 `VERSION` 相同，即 `scripts/make_app.sh`。**
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
    }
    private static let fallbackVersion = "development"

    static var windowName: String { "\(name) \(version)" }

    /// 从“帮助”菜单打开项目页面。
    static let helpURL = URL(string: "https://github.com/iamxwk/SiftEditor")!

    /// Info.plist 是声明 feed 进行更新确认的密钥（由 `scripts/make_app.sh` 写入）。
    static let updateFeedKey = "SiftEditorUpdateFeed"

    /// 更新检查位置。**如果未指定，则 nil = 不执行更新检查。**
    ///
    /// 仅当软件包声明其分发来源时才检查更新。
    static var updateFeedURL: URL? {
        updateFeed(from: Bundle.main.infoDictionary?[updateFeedKey])
    }

    /// 从  / Info.plist 的值中提取 feed（为了测试，已分开）。空字符串和空格均视为“无”。
    static func updateFeed(from value: Any?) -> URL? {
        declaredURL(from: value)
    }

    /// URL 在  / Info.plist 中声明。空字符串、仅空格或不会变成 URL 的值均被视为“未声明”。
    static func declaredURL(from value: Any?) -> URL? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return URL(string: s)
    }

    // MARK: - 要望

    /// 声明请求提交通道（GitHub 的 Issue 表单）和已发布请求列表（带状态）的密钥。
    /// (由 `scripts/make_app.sh` 编写)。
    static let requestFormKey = "SiftEditorRequestForm"
    static let requestListKey = "SiftEditorRequestList"

    /// 请求提交点。**如果未声明，则 nil = 不在帮助菜单中显示该项目。**
    ///
    /// 与  / feed 类似，用于更新确认，URL 在产品捆绑包方面声明。
    static var requestFormURL: URL? { declaredURL(from: Bundle.main.infoDictionary?[requestFormKey]) }

    /// 公开发布请求列表（英文版页面）。如未作声明，则为 nil。
    static var requestListURL: URL? { declaredURL(from: Bundle.main.infoDictionary?[requestListKey]) }

    /// 将版本和 OS 添加到接收输入 URL（Issue 表单中的相应字段将从一开始就被填充）。
    /// 保留现有查询（例如 `template=`）不变。
    static func requestURL(form: URL, version: String, os: String) -> URL? {
        guard var c = URLComponents(url: form, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "os", value: os),
        ]
        return c.url
    }

    /// 请求列表的英文页面使用 name.html，简体中文页面使用 name.zh-Hans.html。
    static func requestListURL(base: URL, chinese: Bool) -> URL {
        guard chinese, base.pathExtension == "html" else { return base }
        let name = base.deletingPathExtension().lastPathComponent
        return base.deletingLastPathComponent().appendingPathComponent("\(name).zh-Hans.html")
    }

    /// 满足请求的 OS 表示法，例如“macOS 26.0”。
    static func osDescription(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
}
