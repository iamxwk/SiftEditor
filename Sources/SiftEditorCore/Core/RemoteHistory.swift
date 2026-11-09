import Foundation

/// 远程打开目标的历史记录（最新记录在前，无重复记录）。**仅包含目标字符串** --
/// 无密钥或密码（身份验证由 `/usr/bin/ssh` 和 ssh-agent 处理）。
public enum RemoteHistory {
    public static let limit = 10
    private static let key = "remote.history"

    /// 添加到顶部。删除前面的重复项，并丢弃超出限制的任何条目，从最早的条目开始。
    public static func adding(_ entry: String, to list: [String]) -> [String] {
        let e = entry.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return list }
        return Array(([e] + list.filter { $0 != e }).prefix(limit))
    }

    public static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public static func record(_ entry: String, _ defaults: UserDefaults = .standard) {
        defaults.set(adding(entry, to: load(defaults)), forKey: key)
    }

    public static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
