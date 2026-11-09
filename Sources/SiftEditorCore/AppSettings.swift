import AppKit
import Foundation

/// 如何在保存时显示进度。
/// - `statusBar`：非模态。即使在保存时也可以滚动和查看（仅暂停编辑）。
/// - `sheet`：模态框。易于理解，但保存完成前会阻止操作。
enum SaveProgressStyle: String {
    case statusBar
    case sheet
}

/// 行距（正文中行高与行高的比例）。
enum LineSpacing: String, CaseIterable {
    case standard   // 1.0（既定）
    case wide       // 1.3
    case wider      // 1.6

    var multiplier: CGFloat {
        switch self {
        case .standard: return 1.0
        case .wide:     return 1.3
        case .wider:    return 1.6
        }
    }
}

/// 插入符形状（插入位置）。在可编辑窗格中启用。
enum CursorShape: String, CaseIterable {
    case bar        // 縦線（既定）
    case block      // 填充矩形（1 个字符宽）
    case underline  // 下線
}

/// 1 个文档需要恢复。
/// - 已保存文件：`path`，下次将重新打开该文件。
/// - 新建未保存文档：包含 `draftID`。**正文不应放置在此处**（文件 [[DraftStore]]）。
struct SessionEntry: Codable {
    /// 保存文件的路径（对于新的、未保存的文件，路径为 nil）。
    var path: String?
    /// id，draft 文件包含未保存的新文档的正文（已保存的文件为 nil）。
    var draftID: String?
    /// 恢复过程中是否应将其标记为未保存（已编辑）？
    var dirty: Bool

    /// 旧版本（~1.0.1）的残留文件，其中主要文本直接存储在会话中。只读（用于更新期间的迁移）。
    /// `DraftStore.migratingLegacyText(in:)` 被移至 draft 文件，然后重命名为 nil。
    var text: String?
}

/// 1 个在启动时打开的项目。
enum RestoreItem: Equatable {
    case file(path: String)
    case draft(id: String, dirty: Bool)
}

/// 规划应用程序启动时要打开的内容以及打开的顺序。
struct RestorePlan: Equatable {
    var items: [RestoreItem]
    /// `items` 内的活跃位置（-1 = 无）。
    var activeIndex: Int
}

/// 程序上次关闭时打开的文档列表及其当前状态。
/// **不保存正文**（未保存的正文由 DraftStore 持有；这里只引用其 ID）。
struct SessionState: Codable {
    var entries: [SessionEntry]
    /// `entries` 内的活跃位置（-1 = 无）。
    var activeIndex: Int

    /// 根据打开文档的信息构建会话（无副作用，可测试）。
    /// - 已保存（包含 `url`）仅指路径。未保存的新路径（不包含 `url`）指的是 draft 中的 id。
    /// **包含空文本的新条目将被跳过**（不会恢复）。导入选项卡 (`| sifteditor`) 也将被跳过。
    /// 由于跳过， / - `activeIndex`（在 `docs` 中的位置）将被移动，因此它将被移动到 `entries` 中的位置。
    static func make(docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)],
                     activeIndex: Int) -> SessionState {
        var entries: [SessionEntry] = []
        var active = -1
        for (i, d) in docs.enumerated() {
            let entry: SessionEntry?
            if let url = d.url {
                // 导入的标签页不会保留在之前的会话中（它不会被恢复，就像一个内容为空的新条目一样）。
                entry = Intake.isPipedStream(url)
                    ? nil
                    : SessionEntry(path: url.path, draftID: nil, dirty: false, text: nil)
            } else if let id = d.draftID, let text = d.text, !text.isEmpty {
                entry = SessionEntry(path: nil, draftID: id, dirty: d.dirty, text: nil)
            } else {
                entry = nil
            }
            if let entry {
                if i == activeIndex { active = entries.count }
                entries.append(entry)
            }
        }
        return SessionState(entries: entries, activeIndex: active)
    }

    /// 决定启动时要打开的内容（无副作用，可测试）。**此功能对数据保护至关重要。**
    ///
    /// 不变条件：**无论会话如何，实际的 draft (`draftIDs`) 将始终包含在计划中。**
    /// 即使会话为 nil、已损坏或被其他内容覆盖，未保存的文本也将恢复。
    /// 假设磁盘上的实际实体（draft 文件）而不是索引（会话）才是真正的实体。
    ///
    /// - `hasOpenDocuments` = 当文件从参数或 Finder 打开并启动时。
    /// 优先处理此问题，不要重新打开之前保存的文件（与之前一样，这是有意为之的行为）。
    /// 未保存的 draft 在这种情况下也总是会被恢复。
    static func restorePlan(session: SessionState?,
                            draftIDs: [String],
                            hasOpenDocuments: Bool) -> RestorePlan {
        var items: [RestoreItem] = []
        var active = -1
        var placed = Set<String>()

        if let session {
            for (i, e) in session.entries.enumerated() {
                let item: RestoreItem?
                if let path = e.path {
                    item = hasOpenDocuments ? nil : .file(path: path)
                } else if let id = e.draftID, draftIDs.contains(id) {
                    placed.insert(id)
                    item = .draft(id: id, dirty: e.dirty)
                } else {
                    item = nil   // draft 参考号（无文本）将被丢弃（= 已保存/已丢弃）。
                }
                if let item {
                    if i == session.activeIndex { active = items.count }
                    items.append(item)
                }
            }
        }

        // 还会打开 draft（孤立端口），该端口未被当前会话指向。这是最后一道防线。
        // 只要文本仍然存在，用户就还没有保存或丢弃它。
        for id in draftIDs where !placed.contains(id) {
            items.append(.draft(id: id, dirty: true))
        }
        return RestorePlan(items: items, activeIndex: active)
    }
}

/// 应用程序的持久设置（UserDefaults 聚合）。
enum AppSettings {
    private static let defaults = UserDefaults.standard
    private static let saveProgressKey = "SiftEditor.saveProgressStyle"
    private static let lineWrapKey = "SiftEditor.lineWrap"
    private static let tabWidthKey = "SiftEditor.tabWidth"
    private static let filterContextKey = "SiftEditor.filterContextLines"
    private static let searchFilterKey = "SiftEditor.searchFilterOn"
    private static let lineSpacingKey = "SiftEditor.lineSpacing"
    private static let highlightCurrentLineKey = "SiftEditor.highlightCurrentLine"
    private static let showLineNumbersKey = "SiftEditor.showLineNumbers"
    private static let showInvisiblesKey = "SiftEditor.showInvisibles"
    private static let cursorShapeKey = "SiftEditor.cursorShape"
    private static let sessionKey = "SiftEditor.session"
    private static let autoReloadKey = "SiftEditor.autoReloadExternalChanges"
    private static let lineEditSoundKey = "SiftEditor.lineEditSound"
    private static let autoUpdateCheckKey = "SiftEditor.automaticUpdateChecks"
    private static let lastUpdateCheckKey = "SiftEditor.lastUpdateCheck"
    private static let columnFieldsKey = "SiftEditor.columnFields"
    private static let aiProviderKey = "SiftEditor.ai.provider"
    private static let aiModelKey = "SiftEditor.ai.model"
    private static let aiBaseURLKey = "SiftEditor.ai.baseURL"
    /// account（`aiConfig` 的一部分）将在 [[Keychain]] 侧进行复制。可在捆绑包 ID 中读取。
    ///（通过与密钥相同的 Keychain），因此我们将使用此密钥作为真理来源（参见 `aiConfig`）。
    private static let aiSharedConfigAccount = "ai.sharedConfig"
    /// 型号 ID 已通过连接测试（由服务提供商提供）。从现在起，您可以从列表中选择。
    private static func aiRememberedModelsKey(_ provider: AIProvider) -> String {
        "SiftEditor.ai.remembered.\(provider.rawValue)"
    }

    static var saveProgressStyle: SaveProgressStyle {
        get { saveProgressStyle(from: defaults) }
        set { defaults.set(newValue.rawValue, forKey: saveProgressKey) }
    }
    private static func saveProgressStyle(from source: UserDefaults) -> SaveProgressStyle {
        SaveProgressStyle(rawValue: source.string(forKey: saveProgressKey) ?? "") ?? .sheet
    }

    /// 长行自动换行。false = 水平滚动不换行（默认），true = 按内容宽度换行。
    static var lineWrap: Bool {
        get { lineWrap(from: defaults) }
        set { defaults.set(newValue, forKey: lineWrapKey); NotificationCenter.default.post(name: .siftEditorLineWrapChanged, object: nil) }
    }
    private static func lineWrap(from source: UserDefaults) -> Bool { source.bool(forKey: lineWrapKey) }

    /// 确认行编辑时的声音效果名称（“Glass”、“Pop”、“Tink”、“Ping”等。空字符串或“none”将不会发出声音）。默认值为“Glass”。
    static var lineEditSound: String {
        get { lineEditSound(from: defaults) }
        set { defaults.set(newValue, forKey: lineEditSoundKey) }
    }
    private static func lineEditSound(from source: UserDefaults) -> String {
        source.string(forKey: lineEditSoundKey) ?? "Glass"
    }

    /// 确认行编辑时播放音效（如果设置为“none”或为空则不播放）。
    static func playLineEditSound() {
        let sound = lineEditSound.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sound.isEmpty, sound.lowercased() != "none" else { return }
        NSSound(named: NSSound.Name(sound))?.play()
    }

    /// 仅显示匹配行时，在匹配行（相当于 `grep -C`）前后添加的行数。默认值为 0。
    /// 将设置作为一个应用程序而不是一个文件地记住（一旦设置，后续文件将看起来相同）。
    static var filterContextLines: Int {
        get { filterContextLines(from: defaults) }
        set {
            defaults.set(min(max(0, newValue), FilterContext.maxContext), forKey: filterContextKey)
            defaults.synchronize()
            NotificationCenter.default.post(name: .siftEditorFilterContextChanged, object: nil)
        }
    }
    private static func filterContextLines(from source: UserDefaults) -> Int {
        min(max(0, source.integer(forKey: filterContextKey)), FilterContext.maxContext)
    }

    /// 打开  / ⌘F，选择“仅显示匹配的行”。记住您上次操作的漏斗状态。
    ///
    /// 在进行结构化时，主要目的是“缩小范围”而不是“跳转到匹配的行”，但 ⌘F 总是以普通搜索的方式打开。
    /// 每次都需要额外一步才能重新插入漏斗。此外，疼痛患者无法使用漏斗。
    /// 当我迁移到  / (结构化，JSON) 时，它被强制更改为 off，即使我返回，它仍然是 off。
    /// **意图** 是你记住的内容，而它是否可用则由窗格决定。默认值为 false（与之前相同）。
    static var searchFilterOn: Bool {
        get { searchFilterOn(from: defaults) }
        set { defaults.set(newValue, forKey: searchFilterKey) }
    }
    private static func searchFilterOn(from source: UserDefaults) -> Bool { source.bool(forKey: searchFilterKey) }

    /// 制表符显示宽度（字符数）。默认值：4。选项：2/4/8。
    static var tabWidth: Int {
        get { tabWidth(from: defaults) }
        set { defaults.set(newValue, forKey: tabWidthKey); postDisplayChanged() }
    }
    private static func tabWidth(from source: UserDefaults) -> Int {
        let v = source.integer(forKey: tabWidthKey); return v > 0 ? v : 4
    }

    /// 行間。
    static var lineSpacing: LineSpacing {
        get { lineSpacing(from: defaults) }
        set { defaults.set(newValue.rawValue, forKey: lineSpacingKey); postDisplayChanged() }
    }
    private static func lineSpacing(from source: UserDefaults) -> LineSpacing {
        LineSpacing(rawValue: source.string(forKey: lineSpacingKey) ?? "") ?? .standard
    }

    /// 是否应以浅色带突出显示插入符线？默认值：true。
    static var highlightCurrentLine: Bool {
        get { highlightCurrentLine(from: defaults) }
        set { defaults.set(newValue, forKey: highlightCurrentLineKey); postDisplayChanged() }
    }
    private static func highlightCurrentLine(from source: UserDefaults) -> Bool {
        source.object(forKey: highlightCurrentLineKey) as? Bool ?? true
    }

    /// 显示行号（装订线）。默认值：true。
    /// 大文件由自定义装订线处理，小文件由 NSRulerView 处理，但只有一个设置。
    static var showLineNumbers: Bool {
        get { showLineNumbers(from: defaults) }
        set { defaults.set(newValue, forKey: showLineNumbersKey); postDisplayChanged() }
    }
    private static func showLineNumbers(from source: UserDefaults) -> Bool {
        source.object(forKey: showLineNumbersKey) as? Bool ?? true
    }

    /// 是否将不可见字符（制表符、换行符、全角空格和尾随空格）显示为符号。默认值：false。
    static var showInvisibles: Bool {
        get { showInvisibles(from: defaults) }
        set { defaults.set(newValue, forKey: showInvisiblesKey); postDisplayChanged() }
    }
    private static func showInvisibles(from source: UserDefaults) -> Bool { source.bool(forKey: showInvisiblesKey) }

    /// 插入符号形状。
    static var cursorShape: CursorShape {
        get { cursorShape(from: defaults) }
        set { defaults.set(newValue.rawValue, forKey: cursorShapeKey); postDisplayChanged() }
    }
    private static func cursorShape(from source: UserDefaults) -> CursorShape {
        CursorShape(rawValue: source.string(forKey: cursorShapeKey) ?? "") ?? .bar
    }

    /// 上次关机时的会话（左侧边栏中的顺序和活动位置）。下次启动时恢复。
    static var session: SessionState? {
        get {
            guard let data = defaults.data(forKey: sessionKey) else { return nil }
            return try? JSONDecoder().decode(SessionState.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                defaults.set(data, forKey: sessionKey)
            } else {
                defaults.removeObject(forKey: sessionKey)
            }
        }
    }

    // MARK: - 浮动面板的位置

    /// 抓取并移动的小窗口的位移量（与默认位置的偏差）。**此值适用于整个应用程序，而非单个文件。**
    /// 物品放置位置的偏好与人相关，而不是与打开的文件相关。
    static func overlayOffset(for name: String) -> CGPoint {
        let key = "SiftEditor.overlay.\(name)"
        guard let a = defaults.array(forKey: key) as? [CGFloat], a.count == 2 else { return .zero }
        return CGPoint(x: a[0], y: a[1])
    }

    static func setOverlayOffset(_ offset: CGPoint, for name: String) {
        let key = "SiftEditor.overlay.\(name)"
        if offset == .zero {
            defaults.removeObject(forKey: key)      // 默认位置 = 不记得了
        } else {
            defaults.set([offset.x, offset.y], forKey: key)
        }
    }

    // MARK: - 固定长度项目定义（每个文件）

    /// 要记住的最大文件数。如果超过此限制，**最旧的文件**将被丢弃。
    private static let columnFieldsCapacity = 200

    /// 记住每个文件的固定长度项目定义（边界数字）。
    ///
    /// 仅保存单个文件的列边界，供下次打开同一文件时恢复。
    /// 每条记录包含列边界数组和上次使用时间。
    private struct ColumnFieldsEntry: Codable {
        var columns: [Int]
        var usedAt: Date
    }

    private static func columnFieldsMap() -> [String: ColumnFieldsEntry] {
        guard let data = defaults.data(forKey: columnFieldsKey),
              let map = try? JSONDecoder().decode([String: ColumnFieldsEntry].self, from: data) else { return [:] }
        return map
    }

    /// 存储在该文件中的项目定义（如果不存在则为空）。
    static func columnGuides(for url: URL?) -> [Int] {
        guard let url else { return [] }
        return columnFieldsMap()[url.path]?.columns ?? []
    }

    /// 记住该文件的项目定义（空数组 = 忘记）。
    static func setColumnGuides(_ columns: [Int], for url: URL?) {
        guard let url else { return }
        var map = columnFieldsMap()
        if columns.isEmpty {
            guard map.removeValue(forKey: url.path) != nil else { return }
        } else {
            let entry = ColumnFieldsEntry(columns: columns, usedAt: Date())
            if map[url.path]?.columns == columns { map[url.path]?.usedAt = entry.usedAt } else { map[url.path] = entry }
            if map.count > columnFieldsCapacity {
                for key in map.sorted(by: { $0.value.usedAt < $1.value.usedAt })
                    .prefix(map.count - columnFieldsCapacity).map(\.key) {
                    map.removeValue(forKey: key)
                }
            }
        }
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: columnFieldsKey) }
    }

    /// 当文件被另一个应用程序覆盖时，是否应该自动重新加载？默认值：true。
    /// **即使您离线，也会收到更改通知**（文本底部横幅）。我们不会默默地继续显示过时的内容。
    /// 如果存在未保存的更改，即使启用该功能也不会自动导入（因为它们会被覆盖）。
    static var autoReloadExternalChanges: Bool {
        get { autoReloadExternalChanges(from: defaults) }
        set { defaults.set(newValue, forKey: autoReloadKey) }
    }
    private static func autoReloadExternalChanges(from source: UserDefaults) -> Bool {
        source.object(forKey: autoReloadKey) as? Bool ?? true
    }

    /// 是否应在启动时自动检查新版本？默认值：true。
    /// App Store 由于这不是发行版，用户如果没有它就无法注意到新版本。
    static var automaticUpdateChecks: Bool {
        get { defaults.object(forKey: autoUpdateCheckKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoUpdateCheckKey) }
    }

    /// 上次执行自动检查的时间（限制为每天一次）。
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: lastUpdateCheckKey) as? Date }
        set { defaults.set(newValue, forKey: lastUpdateCheckKey) }
    }

    /// AI 联动 (BYOK) 设置。**不含钥匙本体**（钥匙为 [[Keychain]]）。
    ///
    /// 提供商、模型和基础 URL 保存在 UserDefaults，并同步到 Keychain。
    /// Keychain 是优先读取的来源。
    /// 如果不可用（第一次，Keychain 共享不可能的环境），则像以前一样从 UserDefaults 组装。
    static var aiConfig: AIConfig {
        get {
            if let json = Keychain.get(account: aiSharedConfigAccount),
               let data = json.data(using: .utf8),
               let shared = try? JSONDecoder().decode(AIConfig.self, from: data) {
                return shared
            }
            let hadLocalChoice = defaults.string(forKey: aiProviderKey) != nil
            let provider = AIProvider(rawValue: defaults.string(forKey: aiProviderKey) ?? "") ?? .anthropic
            let model = defaults.string(forKey: aiModelKey) ?? ""
            let base = defaults.string(forKey: aiBaseURLKey) ?? ""
            let local = AIConfig(provider: provider,
                                 model: model.isEmpty ? provider.defaultModel : model,
                                 baseURLOverride: base)
            // 此功能允许 Keychain 恢复到先前选择的设置，但只能恢复一次。
            // （默认设置 = 不重复从未选择过的项目）。
            if hadLocalChoice, let data = try? JSONEncoder().encode(local),
               let json = String(data: data, encoding: .utf8) {
                Keychain.set(json, account: aiSharedConfigAccount)
            }
            return local
        }
        set {
            defaults.set(newValue.provider.rawValue, forKey: aiProviderKey)
            defaults.set(newValue.model, forKey: aiModelKey)
            defaults.set(newValue.baseURLOverride, forKey: aiBaseURLKey)
            if let data = try? JSONEncoder().encode(newValue), let json = String(data: data, encoding: .utf8) {
                Keychain.set(json, account: aiSharedConfigAccount)
            }
        }
    }

    /// 我亲自验证过的型号（最新型号在前）。“我的列表”中列出了输入过 ID 的人员，但该型号不在列表中。
    static func aiRememberedModels(for provider: AIProvider) -> [String] {
        defaults.stringArray(forKey: aiRememberedModelsKey(provider)) ?? []
    }

    /// 记住通过连接测试的模型。拼写错误将导致测试失败，列表将不会显得杂乱。
    /// 按最新排序，无重复项，限制 8 个项目（以防止设置部分中的列表过长）。
    static func rememberAIModel(_ model: String, for provider: AIProvider) {
        let m = model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, !provider.suggestedModels.contains(m) else { return }   // 不要重新学习默认候选算法。
        var list = aiRememberedModels(for: provider).filter { $0 != m }
        list.insert(m, at: 0)
        defaults.set(Array(list.prefix(8)), forKey: aiRememberedModelsKey(provider))
    }

    private static func postDisplayChanged() {
        NotificationCenter.default.post(name: .siftEditorDisplayChanged, object: nil)
    }

}

extension Notification.Name {
    /// 当长行换行设置发生变化时（反映在打开的查看器中）。
    static let siftEditorLineWrapChanged = Notification.Name("SiftEditor.lineWrapChanged")
    /// 当显示设置（制表符宽度、行间距、当前行高亮显示、光标形状）更改时。
    static let siftEditorDisplayChanged = Notification.Name("SiftEditor.displayChanged")
    /// 当匹配行之前和之后添加的行数发生变化时（反映在打开的查看器中）。
    static let siftEditorFilterContextChanged = Notification.Name("SiftEditor.filterContextChanged")
}
