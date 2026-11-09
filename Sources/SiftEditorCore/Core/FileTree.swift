import Foundation

/// 树中 1 个项目。**本地和远程使用相同的类型**（避免使用两种不同的方式呈现）。
/// `NSOutlineView` 正在被跟踪以进行身份识别，因此为 `NSObject`。
final class FileNode: NSObject {
    /// 屏幕上显示的名称（从搜索结果的起始点算起的相对路径）。
    let name: String
    /// 如果文件位于本地计算机，请使用文件系统路径；如果文件位于远程计算机，请使用另一台计算机上的绝对路径。
    let path: String
    let isDirectory: Bool
    /// `nil` = 尚未读取。空数组 = 已读取但为空。
    var children: [FileNode]?
    var isLoading = false
    /// 列表是否因达到限制而被截断？
    var truncated = false

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// 负责返回文件夹内容。本地 ID 为 `FileManager`，远程 ID 为 ssh。
/// **同步，呼叫方从后台队列呼叫**（远程访问速度慢，屏幕不应暂停）。
protocol DirectoryProvider {
    func list(_ path: String) throws -> (nodes: [FileNode], truncated: Bool)
    /// 搜索文件名中包含 `term` 的文件，从 `root` 开始。文件大小（大于或小于）将被忽略。
    func search(root: String, term: String) throws -> (nodes: [FileNode], truncated: Bool)
    func describe(_ error: Error) -> String
}

enum FileTreeOrder {
    /// 先按文件夹顺序，然后按字母顺序（数字被视为数值，忽略大于或等于小于）。
    static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - 手元

struct LocalDirectoryProvider: DirectoryProvider {

    static let listLimit = 5000
    static let searchLimit = 500

    func list(_ path: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        var nodes: [FileNode] = []
        for name in names.prefix(Self.listLimit) {
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            // 符号链接向前看（指向文件夹的链接可以像文件夹一样访问）。
            fm.fileExists(atPath: full, isDirectory: &isDir)
            nodes.append(FileNode(name: name, path: full, isDirectory: isDir.boolValue))
        }
        return (FileTreeOrder.sorted(nodes), names.count > Self.listLimit)
    }

    func search(root: String, term: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let fm = FileManager.default
        // 枚举 URL 返回到实际对象的路径 (`/tmp` → `/private/tmp`)，因此起始点也应该与实际对象对齐。
        // 如果不对齐它们，相对路径提取将会丢失。
        // （请勿使用 `resolvingSymlinksInPath`，因为它会自动删除 `/private`；请使用 `realpath` 获取实际对象。）
        let realRoot = URL(fileURLWithPath: Self.realPath(root))
        guard let walker = fm.enumerator(
            at: realRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return ([], false) }

        var found: [FileNode] = []
        var truncated = false
        let rootPath = realRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let url as URL in walker {
            // `.git` 的内容不包含在名称搜索中（它只会返回大量对象名称）。
            if url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            guard url.lastPathComponent.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { continue }
            if found.count >= Self.searchLimit { truncated = true; break }
            let rel = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.path
            found.append(FileNode(name: rel, path: url.path, isDirectory: false))
        }
        return (found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, truncated)
    }

    func describe(_ error: Error) -> String { error.localizedDescription }

    /// 实际文件的路径。如果无法解析，则保持不变。
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - 遠隔

struct RemoteDirectoryProvider: DirectoryProvider {
    let host: String

    /// 从另一端连接绝对通道。
    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    func list(_ path: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let r = try RemoteSession.listDirectory(host: host, path: path)
        let nodes = r.entries.map {
            FileNode(name: $0.name, path: Self.join(path, $0.name), isDirectory: $0.isDirectory)
        }
        return (FileTreeOrder.sorted(nodes), r.truncated)
    }

    func search(root: String, term: String) throws -> (nodes: [FileNode], truncated: Bool) {
        let r = try RemoteSession.findFiles(host: host, root: root, term: term)
        let nodes = r.paths.map { FileNode(name: $0, path: Self.join(root, $0), isDirectory: false) }
        return (nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, r.truncated)
    }

    func describe(_ error: Error) -> String { RemoteWindowController.describe(error) }
}
