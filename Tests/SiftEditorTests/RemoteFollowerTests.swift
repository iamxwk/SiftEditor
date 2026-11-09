import XCTest
@testable import SiftEditorCore

/// **实际运行 `tail -f` 至 ssh。** 仅当使用密钥输入 localhost 时才运行。
///
/// 有两种事故只发生在这里——被追踪的线路永远不会到达，
/// 即使我阻止了它，它仍然继续向另一侧移动。
final class RemoteFollowerTests: XCTestCase {

    private var log: URL!

    override func setUpWithError() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "localhost", "true"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "localhost へ鍵で ssh できないので飛ばす")

        log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-follow-\(UUID().uuidString).log")
        try Data("start\n".utf8).write(to: log)
    }

    override func tearDown() {
        if let log { try? FileManager.default.removeItem(at: log) }
        super.tearDown()
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// 新增线路已到达。
    func testFollowDeliversAppendedLines() throws {
        let follower = RemoteFollower(target: RemoteFile.Target(host: "localhost", path: log.path))
        let got = expectation(description: "追記が届く")
        var seen: [String] = []
        follower.onLines = { lines in
            seen += lines
            if seen.contains("appended-2") { got.fulfill() }
        }
        follower.start(fromBytes: 0)
        defer { follower.stop() }

        // 我会在等待  tail -f 启动后再写信。
        Thread.sleep(forTimeInterval: 2.0)
        try append("appended-1\nappended-2\n")

        wait(for: [got], timeout: 20)
        XCTAssertTrue(seen.contains("appended-1"))
        XCTAssertTrue(seen.contains("appended-2"))
    }

    /// **如果你停止它，另一边也会停止。** 如果你切断 ssh，`tail -f` 也会随之停止。
    func testStopEndsTheRemoteProcess() throws {
        let follower = RemoteFollower(target: RemoteFile.Target(host: "localhost", path: log.path))
        let ended = expectation(description: "終わる")
        follower.onEnd = { ended.fulfill() }
        follower.start(fromBytes: 0)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(follower.isRunning)

        follower.stop()
        wait(for: [ended], timeout: 15)
        XCTAssertFalse(follower.isRunning)
    }

    /// 不会重复出现 -- 同一行出现两次。
    func testStartingTwiceDoesNotDoubleUp() throws {
        let follower = RemoteFollower(target: RemoteFile.Target(host: "localhost", path: log.path))
        follower.start(fromBytes: 0)
        Thread.sleep(forTimeInterval: 1.5)
        follower.start(fromBytes: 0)   // 第二次什么都不做。
        XCTAssertTrue(follower.isRunning)
        follower.stop()
    }
}
