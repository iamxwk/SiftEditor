import Foundation

/// “从打开文件到屏幕上出现第一行所需的时间”的实际测量值。
///
/// README / LP 所列数字的来源。提供此信息是为了便于测量，而不是依赖推测。
/// 它仅在  / `SIFTEDITOR_TIMING=1` 创建时运行；在正常启动期间不执行任何操作。
///
///   SIFTEDITOR_TIMING=1 open -a .build/SiftEditor.app --args ...
/// → 仅向标准错误输出一次“first paint: NNN.N ms”。
enum OpenTiming {

    static let enabled = ProcessInfo.processInfo.environment["SIFTEDITOR_TIMING"] == "1"

    private static var startedAt: CFAbsoluteTime?
    private static var reported = false

    /// 请拨打  / open (url:) 的入口电话。
    static func begin() {
        guard enabled else { return }
        startedAt = CFAbsoluteTimeGetCurrent()
        reported = false
    }

    /// 当文本实际绘制时调用。仅报告第一次调用。
    static func firstPaint() {
        guard enabled, !reported, let t0 = startedAt else { return }
        reported = true
        log(String(format: "first paint: %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    /// 当后台行索引完成时调用。
    static func indexComplete(lines: Int) {
        guard enabled, let t0 = startedAt else { return }
        log(String(format: "index complete: %.2f s (%d lines)",
                   CFAbsoluteTimeGetCurrent() - t0, lines))
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
