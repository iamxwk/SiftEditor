import Foundation

/// 查看器读取的字节序列的来源。
///
/// Index/Search/piece table **仅查看字节范围**。因此，该范围
/// 任何可以传递的东西都会放在最上面——甚至包括我手里的文件（`FileBuffer`），
/// 这也适用于稀疏缓存 (`RemoteBuffer`)，它使用范围读取来填充远程数据。
///
/// **由于此连接，远程支持无需重写 viewer。**
/// 设计本身是为了避免增加面的数量，所以只复制了 `FileBuffer` 已有的四个面。
protocol ByteSource: AnyObject {
    /// 总字节数（可能会增加）。
    var count: Int { get }
    /// 将指定范围作为原始缓冲区传递。范围向内收缩。
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R
    /// 复制指定范围。
    func data(in range: Range<Int>) -> Data
    /// 如果尺寸增大，则会进行调整并返回新的尺寸。如果没有变化或无法调整，则返回 nil。
    func remapIfGrownTry() -> Int?
}

extension FileBuffer: ByteSource {}

extension RemoteBuffer: ByteSource {
    /// 远程操作，**请勿通过重新映射来追求增长。**
    ///
    /// 我可以用 `fstat` 查看我手头文件的增长情况，但如果我远程执行此操作……
    /// 每次滚动页面都会抛出 `wc -c`。追逐增长
    /// 这是末端的工作（在另一端运行 `tail -f` 并将其送入），路线不同。
    func remapIfGrownTry() -> Int? { nil }
}
