import XCTest
@testable import SiftEditorCore

/// 验证行  / 1 (B12) 到 ssh 的重写情况。
/// 需要输入密钥。仅在目标地址为 ssh 的环境中运行。目标地址为 `MRED_SSH_TEST_HOST`（默认为 localhost）。
/// （ / `~/.ssh/config` 也是一个别名。）
final class RemoteEditSessionTests: XCTestCase {

    private var fixture: URL!
    private var host: String { ProcessInfo.processInfo.environment["MRED_SSH_TEST_HOST"] ?? "localhost" }

    override func setUpWithError() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "true"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "\(host) へ鍵で ssh できないので飛ばす")

        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-edit-\(UUID().uuidString).log")
        try "alpha\nbravo\ncharlie\n".write(to: fixture, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        super.tearDown()
    }

    private func session() throws -> RemoteSession {
        try RemoteSession.connect(to: RemoteFile.Target(host: host, path: fixture.path))
    }

    func testSameLengthEditOverSsh() throws {
        let outcome = try session().replaceLine(2, old: "bravo", new: "BRAVO")
        XCTAssertEqual(outcome, .overwrote)
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "alpha\nBRAVO\ncharlie\n")
    }

    func testLengthChangingEditOverSsh() throws {
        let outcome = try session().replaceLine(3, old: "charlie", new: "日本語 — it's 100% $(x)")
        XCTAssertEqual(outcome, .rewrote)
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "alpha\nbravo\n日本語 — it's 100% $(x)\n")
    }

    func testConflictOverSshWritesNothing() throws {
        let s = try session()
        try "alpha\nCHANGED\ncharlie\n".write(to: fixture, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try s.replaceLine(2, old: "bravo", new: "x")) { error in
            XCTAssertEqual((error as? RemoteSession.EditFailure)?.outcome, .conflict)
        }
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "alpha\nCHANGED\ncharlie\n")
    }
}

/// 通过 ssh 验证文件夹类型、列表和名称搜索。
final class RemoteDirectorySessionTests: XCTestCase {

    private var dir: URL!
    private var host: String { ProcessInfo.processInfo.environment["MRED_SSH_TEST_HOST"] ?? "localhost" }

    override func setUpWithError() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "true"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "\(host) へ鍵で ssh できないので飛ばす")

        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sifteditor-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try "x\n".write(to: dir.appendingPathComponent("logs/app.log"), atomically: true, encoding: .utf8)
        try "y\n".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    func testDirectoryIsReportedAsDirectory() throws {
        let s = try RemoteSession.connect(to: .init(host: host, path: dir.path))
        XCTAssertEqual(s.kind, .directory)
    }

    func testMissingAndFileKinds() throws {
        XCTAssertThrowsError(try RemoteSession.connect(to: .init(host: host, path: dir.appendingPathComponent("nope").path))) {
            XCTAssertEqual($0 as? RemoteSession.Failure, .missing)
        }
        let s = try RemoteSession.connect(to: .init(host: host, path: dir.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(s.kind, .file)
    }

    func testListAndFindOverSsh() throws {
        let listed = try RemoteSession.listDirectory(host: host, path: dir.path)
        XCTAssertEqual(Set(listed.entries.map(\.name)), ["logs", "notes.txt"])
        XCTAssertEqual(listed.entries.first { $0.name == "logs" }?.isDirectory, true)

        let found = try RemoteSession.findFiles(host: host, root: dir.path, term: "APP")
        XCTAssertEqual(found.paths, ["logs/app.log"])
    }
}
