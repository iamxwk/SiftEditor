import Foundation

/// 允许读取远程文件的缓冲区，同时**仅将可见部分**嵌入到本地稀疏文件中。
///
/// 它显示的是与  / `FileBuffer` 相同的面（`count` / `withBytes` / `data`）。
/// 索引、搜索、piece、table 和结构化显示仅查看字节序列为 mmap。
/// **如果此部件形状相同，则可直接远程使用。**
///
/// - **禁止下载和打开**（决定日期：2026年8月30日）。待创建的文件为空的稀疏文件。
/// 只有你实际阅读的部分才有实质内容。即使你打开了 10GB，也只有你看到的内容会被保存到你的设备中。
/// - **该孔可读为零。** 因此，读取必须始终通过 `FetchedRanges`。
/// 如果缺少什么，我会去取。**如果我取不到，我会把空白处填上，但不显示零。**
/// 一串全是零的文本看起来很合理，但比根本不打开它更危险。
/// - **关闭后删除。** **日志包含机密信息，请勿在启动后保留。**
final class RemoteBuffer {

    /// 此函数用于检索范围。`nil` 失败（无法检索范围）。EOF 的返回值较短。
    /// **之所以设置为注入，是为了在不连接的情况下进行测试**（本地文件被视为远程文件）。
    typealias Fetch = (_ offset: Int, _ length: Int) -> Data?

    /// 远程获取的总字节数。如果无法获取，调用者将输出“未知”（不要写入 0）。
    private(set) var count: Int

    /// 我电脑上的一个小文件。关闭时请将其删除。
    let cacheURL: URL

    /// 最近一次检索失败了吗？这是向他人解释为何返回空结果的资料。
    private(set) var lastFetchFailed = false

    private let fetch: Fetch
    private let fd: Int32
    private var base: UnsafeMutableRawPointer
    private var fetched = FetchedRanges()
    private var lock = pthread_mutex_t()

    /// 一次检索的最小数据块。每次字节请求都进行一次往返会使其无法使用。
    static let chunk = 1 << 16   // 64KB

    init?(count: Int, cacheURL: URL, fetch: @escaping Fetch) {
        guard count >= 0 else { return nil }
        self.count = count
        self.cacheURL = cacheURL
        self.fetch = fetch

        FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
        let fd = open(cacheURL.path, O_RDWR)
        guard fd >= 0 else { return nil }

        // 仅为稀疏文件分配必要的长度。此处尚未写入任何字节。
        // （ftruncate 只会创建一个空洞，不会占用磁盘空间）。
        guard count == 0 || ftruncate(fd, off_t(count)) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
        self.fd = fd
        pthread_mutex_init(&lock, nil)

        if count == 0 {
            self.base = UnsafeMutableRawPointer(bitPattern: 0x1000)!  // 未引用地址
            return
        }
        guard let p = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              p != MAP_FAILED else {
            close(fd)
            pthread_mutex_destroy(&lock)
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
        self.base = p
    }

    deinit {
        if count > 0 { munmap(base, count) }
        close(fd)
        pthread_mutex_destroy(&lock)
        // 关闭时请删除。日志包含机密信息，请勿在启动过程中保留。
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// 收集该范围的数据。收集完成后，使用 true。
    ///
    /// 只去获取缺失的零件；不要重新绘制你已经拥有的零件。
    /// 即使请求很小，也会扩展到 `chunk` 单位（以包含滚动条下方的区域）。
    @discardableResult
    func ensure(_ range: Range<Int>) -> Bool {
        let clamped = max(0, range.lowerBound)..<min(count, range.upperBound)
        guard !clamped.isEmpty else { return true }

        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        return fillLocked(clamped)
    }

    /// 前瞻。**在让用户等待之前，填充显示位置周围的区域。**
    /// 如果你得不到，就默默接受吧（不要因为你的预见失败而阻止别人）。
    func prefetch(around range: Range<Int>, margin: Int = RemoteBuffer.chunk) {
        let lo = max(0, range.lowerBound - margin)
        let hi = min(count, range.upperBound + margin)
        guard lo < hi else { return }
        pthread_mutex_lock(&lock)
        _ = fillLocked(lo..<hi)
        pthread_mutex_unlock(&lock)
    }

    /// 已购入总数。“在 10 个 GB 中，我有 3 个 MB”要送给别人。
    var fetchedBytes: Int {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        return fetched.fetchedBytes
    }

    /// 将指定范围作为原始缓冲区传递（格式与 `FileBuffer` 相同）。
    ///
    /// **如果您无法匹配号码，我将向您发送一条空白短信。** 这是为了防止向您发送一条全是零的短信。
    /// 10GB 的带孔日志可以在屏幕上较为逼真地渲染出来。
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        guard lo < hi else { return body(UnsafeRawBufferPointer(start: nil, count: 0)) }

        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }

        guard fillLocked(lo..<hi) else {
            return body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return body(UnsafeRawBufferPointer(start: UnsafeRawPointer(base) + lo, count: hi - lo))
    }

    /// 将指定范围复制为 Data。如果范围不匹配，则返回空值（`FileBuffer` 返回空值，因为它超出范围）。
    func data(in range: Range<Int>) -> Data {
        withBytes(in: range) { Data($0) }
    }

    // MARK: - 内部

    /// 请填写空白处。**呼叫者必须拥有 lock 号码。**
    private func fillLocked(_ range: Range<Int>) -> Bool {
        let gaps = fetched.missing(in: range)
        if gaps.isEmpty { return true }

        for gap in gaps {
            // 取用前请将其摊成一团。但是，它不会超出文件范围。
            let lo = (gap.lowerBound / Self.chunk) * Self.chunk
            let hi = min(count, ((gap.upperBound + Self.chunk - 1) / Self.chunk) * Self.chunk)
            guard lo < hi else { continue }

            // 只绘制扩展范围中你还没有的部分。
            for want in fetched.missing(in: lo..<hi) {
                guard let data = fetch(want.lowerBound, want.count), !data.isEmpty else {
                    lastFetchFailed = true
                    return false
                }
                let wrote = min(data.count, count - want.lowerBound)
                data.withUnsafeBytes { src in
                    (base + want.lowerBound).copyMemory(from: src.baseAddress!, byteCount: wrote)
                }
                fetched.insert(want.lowerBound..<(want.lowerBound + wrote))

                // 比订购的短 = 就这样吧。我不会再回去取了。
                if wrote < want.count { break }
            }
        }

        lastFetchFailed = !fetched.contains(range)
        return !lastFetchFailed
    }
}
