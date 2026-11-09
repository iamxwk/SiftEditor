import Foundation

/// 将未保存的新文档的正文存储在磁盘上，**1 个文档 = 1 个文件**。
///
/// ## 为什么要将会话和容器分开？
/// 未保存的文本是**唯一**用户尚未保存到任何地方的副本，如果丢失，则无法恢复。
/// 另一方面，会话（打开的列表、排序和活动位置）仅仅是一个索引，即使它损坏了也可以重建。
/// 这两个被放在同一个容器（一个 UserDefaults 密钥）中，每次都会完全重写。
/// 1.0 存在数据丢失错误（启动时打开会覆盖会话并删除未保存的文本），
/// 这是导致整个电路板因碰撞而损坏的共同根源。
///
/// 因此，正文已移至此处。请遵循以下三条规则：
/// 1. 主文本由 **atomic** 写入 `Drafts/<id>.txt`。会话仅引用 `id`。
/// 2. **启动时，读取的是此目录，而不是会话。**（未列入索引）
/// 孤立文件 draft 也会被识别出来）。即使索引损坏或完全删除，正文内容也会被恢复。
/// 3. **仅当经过 `discard(_:)` 时才会消失。** 调用消息为“已成功保存到实际文件”。
/// 仅限两条路径：“用户关闭了文档（选择放弃）”。
/// 永远不要从会话导出中删除它。
struct DraftStore {
    /// draft 文件将放置的目录（提供了一个临时目录用于测试）。
    let root: URL

    static let shared = DraftStore(root: DraftStore.defaultRoot)

    /// `~/Library/Application Support/<製品名>/Drafts`
    ///
    /// 按应用名称区分 (`AppInfo.name` = `CFBundleName`)，使草稿保存在当前应用的目录中。
    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("\(AppInfo.name)/Drafts", isDirectory: true)
    }

    /// draft 的新标识符。请直接在文件名中使用它。
    static func newID() -> String { UUID().uuidString }

    private func url(for id: String) -> URL {
        root.appendingPathComponent(id).appendingPathExtension("txt")
    }

    /// 导出文本 (atomic)。**不存在空文本文件**（仅打开一个新标签页）。
    /// （恢复状态毫无意义）。它会在变为空时被删除，但 `id` 仍会保留，因此如果您重新输入它，它将被激活。
    func write(id: String, text: String) {
        guard !text.isEmpty else { discard(id); return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(for: id), options: .atomic)
        } catch {
            // 即使应用程序没有写入数据，也不要停止它（请尝试下一次按键）。
            NSLog("SiftEditor: 草稿写入失败 (%@): %@", id, error.localizedDescription)
        }
    }

    /// 阅读全文（如果全文不可用，则阅读 nil）。
    func read(id: String) -> String? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 返回现有 draft 中的 id，按**最早的在前**顺序返回（恢复后，顺序与之前的顺序类似）。
    func allIDs() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return names
            .filter { $0.pathExtension == "txt" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// **删除正文的唯一方法。** 仅在保存成功或用户关闭文档时调用。
    func discard(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// 在旧版本（1.0.1 及更早版本）中，会话文本位于会话本身中。
    /// 将文本移动到 draft 文件，并返回分配给 `draftID` 的会话（以防止因更新而导致数据丢失）。
    func migratingLegacyText(in state: SessionState) -> SessionState {
        var s = state
        for i in s.entries.indices {
            guard s.entries[i].path == nil, s.entries[i].draftID == nil,
                  let text = s.entries[i].text, !text.isEmpty else { continue }
            let id = DraftStore.newID()
            write(id: id, text: text)
            s.entries[i].draftID = id
            s.entries[i].text = nil
        }
        return s
    }
}
