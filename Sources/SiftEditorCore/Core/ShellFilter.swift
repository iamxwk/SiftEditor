import Foundation

/// 将选定的文本作为 stdin 传递给外部命令 (`/bin/sh -c`)，并接收 stdout。
/// vim 等效于 `!` 滤波器 / BBEdit 等效于 Filter 滤波器。纯字符串 in → 字符串 out，
/// UI 与查看器无关。为避免死锁，请写入 stdin 和 stdout/stderr。
/// 在单独的线程中并行读取数据，并使用 timeout 终止整个进程。
enum ShellFilter {
    enum Failure: Error, Equatable {
        case launchFailed(String)
        case timedOut
        case nonZeroExit(code: Int32, stderr: String)
    }

    /// 执行  / `command`，返回 `input` 至 stdin 和 stdout 作为字符串。
    /// - 非零终止抛出 `nonZeroExit`（带 stderr）= 调用者可以中止而不损坏主体。
    /// - `timeout` 超出限制，因此子进程为 terminate 和 `timedOut`。
    static func run(command: String, input: String, timeout: TimeInterval = 20) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do { try proc.run() }
        catch { throw Failure.launchFailed(error.localizedDescription) }

        // stdin 写入和 stdout/stderr 读取操作并行执行（以防止管道缓冲区满时相互阻塞）。
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global().async {
            let handle = stdinPipe.fileHandleForWriting
            if !input.isEmpty { try? handle.write(contentsOf: Data(input.utf8)) }
            try? handle.close()
            io.leave()
        }
        var outData = Data(), errData = Data()
        io.enter()
        DispatchQueue.global().async { outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }
        io.enter()
        DispatchQueue.global().async { errData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }

        if io.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = io.wait(timeout: .now() + 2)   // 等待读取线程完成。
            throw Failure.timedOut
        }
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let stderr = String(decoding: errData, as: UTF8.self)
            throw Failure.nonZeroExit(code: proc.terminationStatus, stderr: stderr)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
