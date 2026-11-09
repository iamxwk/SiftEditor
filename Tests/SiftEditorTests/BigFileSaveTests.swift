import XCTest
@testable import SiftEditorCore

/// 10GB 使用实际文件验证流保存（生命线）。
/// 通常以 skip 运行。仅当设置了 `SIFTEDITOR_BIG_SAVE_TEST=1` 时才运行（因为它是一个单独的卷，需要一些时间）。
/// swift test --filter BigFileSaveTests（含环境变量）
final class BigFileSaveTests: XCTestCase {
    /// 关键点：即使您“立即保存”到包含 mmap 的文件，mmap 仍将继续存在。
    /// 后续读取不应被破坏（替换 atomic 可保留原始 inode）。已使用小文件验证。
    func testSaveInPlaceKeepsMmapValid() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-inplace-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "hello world\n".write(to: url, atomically: true, encoding: .utf8)

        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }
        let pt = PieceTable(original: FileBufferSource(buffer), originalNewlines: 0)
        pt.insert(Array("X-".utf8), at: 0)                 // "X-hello world\n"

        // 写回使用  mmap 的实际 url（重复与 viewer.write 相同的过程）。
        func saveInPlace() throws {
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".sifteditor-save-\(UUID().uuidString)")
            XCTAssertTrue(FileManager.default.createFile(atPath: tmp.path, contents: nil))
            let h = try FileHandle(forWritingTo: tmp)
            try pt.writeAll { try h.write(contentsOf: Data($0)) }
            try h.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        }
        try saveInPlace()

        // 光盘内容已被编辑。
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X-hello world\n")
        // 即使在替换之后，通过  mmap 读取的原始文档仍然有效（即，原始文档 inode 仍然保留）。
        let viaMmap = pt.bytes(in: 0..<pt.byteCount)
        XCTAssertEqual(viaMmap, Array("X-hello world\n".utf8))

        // 第二次编辑 + 即时保存也有效（从追加缓冲区重建 + 保留原始数据）。
        pt.insert(Array("Y-".utf8), at: 0)                 // "Y-X-hello world\n"
        try saveInPlace()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Y-X-hello world\n")
    }

    func testStreamSave10GB() throws {
        guard ProcessInfo.processInfo.environment["SIFTEDITOR_BIG_SAVE_TEST"] == "1" else {
            throw XCTSkip("SIFTEDITOR_BIG_SAVE_TEST=1 で 10GB 保存テストを実行")
        }
        let src = URL(fileURLWithPath: "/Users/hitoshi/Git/SiftEditor/testdata/test_10gb.log")
        guard let buffer = FileBuffer(url: src) else { return XCTFail("mmap 失敗") }
        let originalSize = buffer.count

        // 将 mmap 覆盖在原文本上，并在开头和结尾插入编辑内容（整个文本并未加载到内存中）。
        let pt = PieceTable(original: FileBufferSource(buffer), originalNewlines: 0)
        let head = Array("EDITED-HEAD\n".utf8)
        let tail = Array("\nEDITED-TAIL".utf8)
        pt.insert(head, at: 0)
        pt.insert(tail, at: pt.byteCount)
        XCTAssertEqual(pt.byteCount, originalSize + head.count + tail.count)

        // 为避免使用不同的卷，请写入同一目录（testdata/ 变为 gitignore）。
        let out = src.deletingLastPathComponent().appendingPathComponent("b3-10gb-out.log")
        try? FileManager.default.removeItem(at: out)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(FileManager.default.createFile(atPath: out.path, contents: nil))
        let handle = try FileHandle(forWritingTo: out)

        let t0 = Date()
        var written = 0
        try pt.writeAll(chunk: 4 << 20) { slice in
            try handle.write(contentsOf: Data(slice))
            written += slice.count
        }
        try handle.close()
        let dt = Date().timeIntervalSince(t0)

        let outSize = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? -1
        print(String(format: "[B3] 10GB stream-save: %.1fs, %.1f MB/s, out=%ld bytes",
                     dt, Double(written) / 1e6 / dt, outSize))

        XCTAssertEqual(written, pt.byteCount)
        XCTAssertEqual(outSize, pt.byteCount)

        // 阅读文档的开头和结尾，检查是否包含编辑内容（不要阅读全文）。
        let outBuf = try FileHandle(forReadingFrom: out)
        let first = try outBuf.read(upToCount: head.count).map { Array($0) }
        XCTAssertEqual(first, head)
        try outBuf.seek(toOffset: UInt64(outSize - tail.count))
        let last = try outBuf.readToEnd().map { Array($0) }
        XCTAssertEqual(last, tail)
        try outBuf.close()
    }
}
