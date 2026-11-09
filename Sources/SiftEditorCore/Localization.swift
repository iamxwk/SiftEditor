import Foundation

/// 从 SwiftPM 资源包中选取与用户首选语言匹配的本地化资源。
/// Bundle.module 没有 CFBundleLocalizations，因此需要自行匹配语言。
private let localizedBundle: Bundle = {
    let available = Bundle.module.localizations

    func bestMatch() -> String {
        for pref in Locale.preferredLanguages {
            if available.contains(pref) { return pref }
            let chinese = pref.lowercased()
            if (chinese == "zh" || chinese.hasPrefix("zh-hans") ||
                chinese.hasPrefix("zh-cn") || chinese.hasPrefix("zh-sg")),
                available.contains("zh-Hans") {
                return "zh-Hans"
            }
            let code = String(pref.prefix { $0 != "-" })
            if available.contains(code) { return code }
        }
        return "en"
    }

    if let path = Bundle.module.path(forResource: bestMatch(), ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    return .module
}()

/// 获取本地化字符串；传入参数时使用 String(format:) 格式化。
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
