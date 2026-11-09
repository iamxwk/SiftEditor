import XCTest
import zlib
@testable import SiftEditorCore

/// 入口 — 管道和压缩。
///
/// 这是一个用于“查看大型日志”的工具，但这些日志并非以原始文件的形式提供。
/// 有很多这样的问题。如果此端口被阻塞，则无法访问任何内部功能。
final class IntakeTests: XCTestCase {

    // MARK: 标准输入是否为管道

    func testAPipeIsAccepted() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertTrue(Intake.stdinIsPiped(fds[0]))
    }

    func testARedirectedFileIsAccepted() throws {
        // `sifteditor < app.log` 也将被接受。就像那根管道一样，它已经被“移交”了。
        let url = Intake.scratchURL(named: "intake-test-\(UUID().uuidString)")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        XCTAssertTrue(Intake.stdinIsPiped(fd))
    }

    func testDevNullIsNotAPipe() throws {
        // **这是重点。** 从 Finder 或 Dock 启动时，标准输入为 /dev/null，
        // 不是终端，所以只有 isatty 为真。如果您接受此设置，它将在每次启动时显示。
        // 空白标签页数量增加。
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        XCTAssertFalse(Intake.stdinIsPiped(fd))
    }

    // MARK: gzip 的确定依据其内容。

    func testGzipIsDetectedByItsMagicNumber() {
        XCTAssertTrue(Intake.isGzip([0x1f, 0x8b, 0x08, 0x00]))
    }

    func testExtensionsAreNotTrusted() {
        // `.gz` 然而，原始文本（尽管已展开，但只保留了名称）实际上是存在的。
        // 既然我们要查看内容，我们就直接打开这类文件。
        XCTAssertFalse(Intake.isGzip(Array("2026-08-28 ERROR".utf8)))
        XCTAssertFalse(Intake.isGzip([0x1f]))          // 只能读取 1 个字节。
        XCTAssertFalse(Intake.isGzip([]))              // 空文件
    }

    // MARK: 展開

    func testGunzipExpandsAndKeepsTheOriginalName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plain = dir.appendingPathComponent("app.log")
        try "2026-08-28 ERROR boom\n".write(to: plain, atomically: true, encoding: .utf8)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [plain.path]
        try gzip.run(); gzip.waitUntilExit()

        let expanded = try XCTUnwrap(Intake.gunzip(dir.appendingPathComponent("app.log.gz")))
        defer { try? FileManager.default.removeItem(at: expanded) }
        XCTAssertEqual(try String(contentsOf: expanded, encoding: .utf8), "2026-08-28 ERROR boom\n")
        // 选项卡中显示的名称与之前相同。如果这是一个临时文件的随机名称，则无法确定它正在查找什么。
        XCTAssertEqual(expanded.lastPathComponent, "app.log")
    }

    // MARK: zip

    private func makeZip(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            let file = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", "archive.zip"] + files.keys.sorted()
        zip.currentDirectoryURL = dir
        try zip.run(); zip.waitUntilExit()
        return dir.appendingPathComponent("archive.zip")
    }

    func testZipIsDetectedByItsMagicNumber() {
        XCTAssertTrue(Intake.isZip([0x50, 0x4b, 0x03, 0x04]))
        XCTAssertTrue(Intake.isZip([0x50, 0x4b, 0x05, 0x06]))   // 空图书馆
        XCTAssertFalse(Intake.isZip([0x50, 0x4b]))              // 只能读取 2 个字节。
        XCTAssertFalse(Intake.isZip(Array("PK is not it".utf8)))
    }

    func testEntriesSkipDirectoriesAndFinderJunk() throws {
        // 使用  压缩时，Finder、__MACOSX/ 和 .DS_Store 始终包含在内。列出时：
        // 选择的数量翻了一番，而且内容却是没人想看的。
        let url = try makeZip(["app.log": "a\n",
                               "logs/db.log": "b\n",
                               "__MACOSX/._app.log": "junk",
                               ".DS_Store": "junk"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(Intake.zipEntries(url).sorted(), ["app.log", "logs/db.log"])
    }

    func testUnzipTakesTheNameFromInsideTheArchive() throws {
        // 即使“archive.zip”出现在  选项卡中，也不清楚正在查看的是哪个选项。
        let url = try makeZip(["logs/db.log": "2026-08-28 slow query\n"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let out = try XCTUnwrap(Intake.unzip(url, entry: "logs/db.log"))
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(out.lastPathComponent, "db.log")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "2026-08-28 slow query\n")
    }

    func testUnzipReturnsNilForAnEntryThatIsNotThere() throws {
        let url = try makeZip(["app.log": "a\n"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(Intake.unzip(url, entry: "nope.log"))
    }

    // MARK: Windows-made zip (Shift-JIS / CP932) 日文文件名 (B16)

    private func makeZipWithShiftJIS(entryName: String, body: String, method: UInt16 = 8) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("windows.zip")

        let cp932 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        let nameEncoding = String.Encoding(rawValue: cp932)
        guard let nameBytes = entryName.data(using: nameEncoding) else {
            throw NSError(domain: "test", code: 1)
        }
        let bodyData = Data(body.utf8)

        let compressed: Data
        if method == 8 {
            var stream = z_stream()
            deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            var comp = Data(count: bodyData.count + 64)
            bodyData.withUnsafeBytes { inBytes in
                comp.withUnsafeMutableBytes { outBytes in
                    stream.next_in = UnsafeMutablePointer(mutating: inBytes.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(inBytes.count)
                    stream.next_out = outBytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outBytes.count)
                    deflate(&stream, Z_FINISH)
                }
            }
            deflateEnd(&stream)
            comp.count = Int(stream.total_out)
            compressed = comp
        } else {
            compressed = bodyData
        }

        let crc = UInt32(crc32(0, [UInt8](bodyData), uInt(bodyData.count)))

        func appendUInt16(_ val: UInt16, to data: inout Data) {
            var v = val.littleEndian
            data.append(Data(bytes: &v, count: 2))
        }
        func appendUInt32(_ val: UInt32, to data: inout Data) {
            var v = val.littleEndian
            data.append(Data(bytes: &v, count: 4))
        }

        var zipData = Data()

        // 1. Local File Header (PK\x03\x04)
        zipData.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
        appendUInt16(20, to: &zipData) // version needed
        appendUInt16(0, to: &zipData)  // flags (bit 11 = 0 => not UTF-8)
        appendUInt16(method, to: &zipData)
        appendUInt16(0, to: &zipData)  // mod time
        appendUInt16(0, to: &zipData)  // mod date
        appendUInt32(crc, to: &zipData)
        appendUInt32(UInt32(compressed.count), to: &zipData)
        appendUInt32(UInt32(bodyData.count), to: &zipData)
        appendUInt16(UInt16(nameBytes.count), to: &zipData)
        appendUInt16(0, to: &zipData)  // extra len
        zipData.append(nameBytes)
        zipData.append(compressed)

        let localHeaderOffset: UInt32 = 0
        let cdOffset = UInt32(zipData.count)

        // 2. Central Directory File Header (PK\x01\x02)
        var cdData = Data()
        cdData.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
        appendUInt16(20, to: &cdData) // version made by
        appendUInt16(20, to: &cdData) // version needed
        appendUInt16(0, to: &cdData)  // flags (bit 11 = 0)
        appendUInt16(method, to: &cdData)
        appendUInt16(0, to: &cdData)  // mod time
        appendUInt16(0, to: &cdData)  // mod date
        appendUInt32(crc, to: &cdData)
        appendUInt32(UInt32(compressed.count), to: &cdData)
        appendUInt32(UInt32(bodyData.count), to: &cdData)
        appendUInt16(UInt16(nameBytes.count), to: &cdData)
        appendUInt16(0, to: &cdData)  // extra len
        appendUInt16(0, to: &cdData)  // comment len
        appendUInt16(0, to: &cdData)  // disk start
        appendUInt16(0, to: &cdData)  // int attrs
        appendUInt32(0, to: &cdData)  // ext attrs
        appendUInt32(localHeaderOffset, to: &cdData)
        cdData.append(nameBytes)

        zipData.append(cdData)
        let cdSize = UInt32(cdData.count)

        // 3. End of Central Directory Record (PK\x05\x06)
        zipData.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        appendUInt16(0, to: &zipData)  // disk
        appendUInt16(0, to: &zipData)  // start disk
        appendUInt16(1, to: &zipData)  // disk entries
        appendUInt16(1, to: &zipData)  // total entries
        appendUInt32(cdSize, to: &zipData)
        appendUInt32(cdOffset, to: &zipData)
        appendUInt16(0, to: &zipData)  // comment len

        try zipData.write(to: zipURL)
        return zipURL
    }

    func testZipEntriesDecodesShiftJISFileNameFromWindows() throws {
        // Windows 的 zip（不带标志的 UTF-8、Shift-JIS / CP932）应该能够检索日语文件名而不会出现乱码。
        let japaneseName = "売上報告_2026年10月.csv"
        let url = try makeZipWithShiftJIS(entryName: japaneseName, body: "1,りんご,150\n2,みかん,100\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let entries = Intake.zipEntries(url)
        XCTAssertEqual(entries, [japaneseName])
    }

    func testUnzipExtractsShiftJISFileNameEntry() throws {
        let japaneseName = "ログ_障害調査.txt"
        let content = "2026-10-21 ERROR Database timeout\n"
        let url = try makeZipWithShiftJIS(entryName: japaneseName, body: content)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let out = try XCTUnwrap(Intake.unzip(url, entry: japaneseName))
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertEqual(out.lastPathComponent, japaneseName)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), content)
    }

    func testUnzipExtractsStoredEntry() throws {
        // 未压缩的 (method 0) 条目也应该能够正确提取。
        let japaneseName = "無圧縮_設定.ini"
        let content = "[Settings]\nTimeout=30\n"
        let url = try makeZipWithShiftJIS(entryName: japaneseName, body: content, method: 0)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let out = try XCTUnwrap(Intake.unzip(url, entry: japaneseName))
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertEqual(out.lastPathComponent, japaneseName)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), content)
    }

    func testGunzipReturnsNilForSomethingThatIsNotGzip() throws {
        let url = Intake.scratchURL(named: "not-gzip-\(UUID().uuidString).gz")
        try "plain text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(Intake.gunzip(url))
    }

    // MARK: 运行中转移给自己 (B15)

    func testOnlyOurScratchFolderIsAcceptedFromANotification() {
        // 任何人都可以发送分布式通知。您无法打开指定位置之外的路径。
        XCTAssertTrue(Intake.isScratchFile(Intake.scratchURL(named: "stdin-1-2.log")))
        XCTAssertFalse(Intake.isScratchFile(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertFalse(Intake.isScratchFile(
            Intake.scratchURL(named: "x").deletingLastPathComponent()
                .appendingPathComponent("../../etc/hosts")))
    }

    /// 注入信号的名称因应用程序的捆绑包 ID 而异。
    /// 当两者都打开时，发送到其中一个的内容会在两个中打开。
    func testPipeNotificationNamesAreScopedPerApp() {
        let free = Intake.pipeNotificationName("pipe", bundleID: "com.iamxwk.SiftEditor")
        let other = Intake.pipeNotificationName("pipe", bundleID: "com.example.OtherEditor")
        XCTAssertNotEqual(free, other)
        XCTAssertNotEqual(Intake.pipeNotificationName("pipe", bundleID: "com.iamxwk.SiftEditor"),
                          Intake.pipeNotificationName("pipeEnd", bundleID: "com.iamxwk.SiftEditor"))
        // 同一个应用程序（发送数据的应用程序和接收数据的应用程序）将匹配。
        XCTAssertEqual(free, Intake.pipeNotificationName("pipe", bundleID: "com.iamxwk.SiftEditor"))
        // 即使在没有捆绑包的情况下启动开发实例，您也可以创建名称。
        XCTAssertEqual(Intake.pipeNotificationName("pipe", bundleID: nil).rawValue, "app.iamxwk.SiftEditor.pipe")
    }
}
