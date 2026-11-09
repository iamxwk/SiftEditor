import AppKit

/// 检查  / GitHub Releases 是否发布了新版本，如果有，请通知我。
///
/// **不会进行任何更换。** 只需从对话框中在浏览器中打开 dmg 发布页面即可。
/// 下载、验证和替换均由用户自行完成。系统将立即自动安装。
/// 在使用 Developer ID 签名后，将考虑使用机制（Sparkle 等）。未签名的应用
/// 自动替换是一种较差的分发方法。
enum UpdateChecker {

    /// 已识别的最新版本。
    struct Release {
        /// 从标签中提取的版本（例如，“1.2”代表“v1.2”）。
        let version: String
        /// 发布页面（如果 dmg 不可用，请在此处打开）。
        let pageURL: URL
        /// 分发材料的直接链接（如有）。
        let dmgURL: URL?
    }

    enum CheckError: Error { case network(Error), badResponse, notConfigured }

    /// 能否检查更新（即，该软件包是否声明了 feed）？
    /// .app 没有声明，因此不会显示自动检查或“检查更新”菜单。
    /// 更多详情请参见 [[AppInfo]].updateFeedURL。
    static var isAvailable: Bool { AppInfo.updateFeedURL != nil }

    // MARK: - 版本比较（纯功能 - 测试对象）

    /// 将  / "v1.2" / "1.2.3" / "1.2-beta" 转换为数字序列。除数字以外的任何值均视为 0。
    static func components(_ version: String) -> [Int] {
        version
            .drop(while: { !$0.isNumber })          // 丢弃开头的“v”等。
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// `a` 是否比 `b` 新？即使位数不同（例如“1.0” > “0.7”，“1.0.1” > “1.0”），也可以进行比较。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = components(a), rhs = components(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - 取得

    /// 获取最新版本。完成调用必须始终在主线程上进行。
    static func fetchLatest(_ completion: @escaping (Result<Release, CheckError>) -> Void) {
        guard let feed = AppInfo.updateFeedURL else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }
        var req = URLRequest(url: feed, timeoutInterval: 10)
        // GitHub API 请求 User-Agent。如果不存在，则返回 403 错误。
        req.setValue("SiftEditor/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: req) { data, response, error in
            let result: Result<Release, CheckError>
            if let error {
                result = .failure(.network(error))
            } else if let release = data.flatMap(parse) ,
                      (response as? HTTPURLResponse)?.statusCode == 200 {
                result = .success(release)
            } else {
                result = .failure(.badResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// 从  / GitHub 的 JSON 中仅提取三个必要的点（为了测试目的而分离）。
    static func parse(_ data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }

        let assets = root["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))

        let version = String(tag.drop(while: { !$0.isNumber }))
        guard !version.isEmpty else { return nil }
        return Release(version: version, pageURL: page, dmgURL: dmg)
    }

    // MARK: - UI

    /// 检查更新，如有必要，显示对话框。
    /// - Parameter manual: 是否是从菜单中明确调用的？ `true` 如果
    /// 通知您“最新”信息和故障信息。`false`（启动时自动检查）
    /// 我只在有新版本时才会发言。最好是默默失败。
    static func check(manual: Bool) {
        guard isAvailable else { return }   // 如果未声明 .app 的分发来源，则不执行任何操作。
        if !manual {
            guard AppSettings.automaticUpdateChecks, shouldCheckToday() else { return }
            AppSettings.lastUpdateCheck = Date()
        }
        fetchLatest { result in
            switch result {
            case .success(let release):
                if isNewer(release.version, than: AppInfo.version) {
                    presentAvailable(release)
                } else if manual {
                    presentUpToDate()
                }
            case .failure:
                if manual { presentFailure() }
            }
        }
    }

    /// 自动检查每天仅限一次。请勿每次启动计算机时都按 GitHub。
    private static func shouldCheckToday() -> Bool {
        guard let last = AppSettings.lastUpdateCheck else { return true }
        return Date().timeIntervalSince(last) >= 24 * 60 * 60
    }

    private static func presentAvailable(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = L("update.availableTitle", AppInfo.name, release.version)
        alert.informativeText = L("update.availableMessage", AppInfo.version)
        alert.addButton(withTitle: L("update.download"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: L("update.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.dmgURL ?? release.pageURL)
        }
    }

    private static func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = L("update.upToDateTitle", AppInfo.name, AppInfo.version)
        alert.informativeText = L("update.upToDateMessage")
        alert.runModal()
    }

    private static func presentFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("update.failedTitle")
        alert.informativeText = L("update.failedMessage")
        alert.runModal()
    }
}
