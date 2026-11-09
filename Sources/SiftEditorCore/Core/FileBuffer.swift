import Foundation

/// 使用 mmap 将文件映射到虚拟地址空间，提供字节范围访问。
///
/// 不要将全部文本加载到内存中。让 OS 进行分页，只显示您实际操作过的部分。
/// 它将被加载到物理内存中。即使使用 10GB，它也只会存在于虚拟空间中，因此不会失败。
///
/// 对于  / tail -f，如果文件过长，则重新映射文件 (`remapIfGrownTry`)。
/// 读取 (withBytes/data) 和重新映射 (munmap+mmap) 与 rwlock 互斥。
final class FileBuffer {
    let url: URL
    /// 文件中的总字节数（由于重新映射可能会增加）。
    private(set) var count: Int

    private let fd: Int32
    private var base: UnsafeRawPointer
    private var mapped: Bool
    private var lock = pthread_rwlock_t()

    init?(url: URL) {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            return nil
        }
        let size = Int(st.st_size)
        self.count = size
        self.fd = fd
        pthread_rwlock_init(&lock, nil)

        if size == 0 {
            self.base = UnsafeRawPointer(bitPattern: 0x1000)!  // 未引用地址
            self.mapped = false
            return
        }

        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              p != MAP_FAILED else {
            close(fd)
            pthread_rwlock_destroy(&lock)
            return nil
        }
        self.base = UnsafeRawPointer(p)
        self.mapped = true
    }

    deinit {
        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: base), count)
        }
        close(fd)
        pthread_rwlock_destroy(&lock)
    }

    /// 将指定范围作为原始缓冲区传递（不复制）。范围被限制在文件内。
    @inline(__always)
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        let len = max(0, hi - lo)
        let ptr = len > 0 ? base + lo : nil
        return body(UnsafeRawBufferPointer(start: ptr, count: len))
    }

    /// 将指定范围复制为 Data（用于小切片）。
    func data(in range: Range<Int>) -> Data {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        guard lo < hi else { return Data() }
        return Data(bytes: base + lo, count: hi - lo)
    }

    /// 如果文件增大，则重新映射文件（仅在增长期间）。返回新的文件大小。nil 表示无更改/不可用。
    ///
    /// 读取时（按住 rdlock），重映射被放弃，nil 被返回（下次执行）。
    /// 这可以防止意外地将读取线程的指针设置为 munmap。
    /// 不包括减少和旋转（inode 替换）（仅增长）。
    func remapIfGrownTry() -> Int? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let newSize = Int(st.st_size)
        guard newSize > count else { return nil }

        guard pthread_rwlock_trywrlock(&lock) == 0 else { return nil }  // 有人正在阅读此内容 → 放弃
        defer { pthread_rwlock_unlock(&lock) }

        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: base), count)
            mapped = false
        }
        guard let p = mmap(nil, newSize, PROT_READ, MAP_PRIVATE, fd, 0),
              p != MAP_FAILED else {
            return nil
        }
        base = UnsafeRawPointer(p)
        mapped = true
        count = newSize
        return newSize
    }
}
