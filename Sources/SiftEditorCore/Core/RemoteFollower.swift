import Foundation

/// 跟踪远程位置的终点（在另一端运行 `tail -f` 并输入数据）。
///
/// **跟踪路径与我当前使用的路径不同。** 我正在使用 `fstat` 来测试其性能，然后再添加 mmap。
/// 如果你远程执行此操作，你最终会不断地发送 `wc -c`，只是为了看看它如何改进。
/// 将其路由到另一个 `tail -f` 更直接，延迟也更低。
///
/// **别忘了停止它。** 即使您静默关闭窗口，ssh 的子进程仍会继续运行。
/// 它仍在当地运营。`stop()` 也称为 deinit。
public final class RemoteFollower {

    /// 当收到已完成的行时调用。**调用的函数是 main。**
    public var onLines: (([String]) -> Void)?
    /// 当连接中断时调用（另一端终止、断开或停止）。
    public var onEnd: (() -> Void)?

    private let target: RemoteFile.Target
    private var process: Process?
    private var accumulator = LineAccumulator()
    private let lock = NSLock()
    /// **保持打开状态的标准输入。** 如果此输入关闭，另一侧的防护罩将接收到 EOF。
    /// 游戏以击杀  / `tail` 结束。如果你使用 /dev/null，它会立即变成 EOF，在你追击之前就结束。
    private var stdin: Pipe?

    public init(target: RemoteFile.Target) {
        self.target = target
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// 开始追讨。`fromBytes` 是最终的初始金额 (`tail -c N -f`)。
    ///
    /// 如果它已经在运行，则什么也不做——如果它启动两次，同一行将出现两次。
    public func start(fromBytes: Int = 0) {
        lock.lock()
        guard process == nil else { lock.unlock(); return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = RemoteFile.sshArguments(
            host: target.host,
            remoteCommand: RemoteFile.followCommand(target.path, bytes: fromBytes)
        )
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        let input = Pipe()
        proc.standardInput = input
        self.stdin = input
        self.process = proc
        lock.unlock()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {                       // EOF
                handle.readabilityHandler = nil
                let rest = self.accumulator.flush()
                DispatchQueue.main.async {
                    if !rest.isEmpty { self.onLines?(rest) }
                    self.onEnd?()
                }
                return
            }
            let lines = self.accumulator.take(chunk)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { self.onLines?(lines) }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.process = nil; self.lock.unlock()
            DispatchQueue.main.async { self.onEnd?() }
        }

        do { try proc.run() } catch {
            lock.lock(); process = nil; lock.unlock()
            DispatchQueue.main.async { self.onEnd?() }
        }
    }

    /// 停止。**这也会导致另一侧的 `tail -f` 停止运行**（如果切断 ssh，它也会随之停止运行）。
    public func stop() {
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()

        guard let proc, proc.isRunning else { stdin = nil; return }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // 首先，关闭标准输入——另一边的守卫接收到 EOF 并杀死 tail。
        // 然后完成 ssh（如果顺序颠倒，则会在传输到另一侧之前被切断）。
        try? stdin?.fileHandleForWriting.close()
        stdin = nil
        proc.terminate()
    }
}
