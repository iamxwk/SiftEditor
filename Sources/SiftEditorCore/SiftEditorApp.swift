import AppKit

/// SiftEditor 的应用入口。
public enum SiftEditorApp {

    /// `NSApplication.delegate` 是一个弱参考，所以我们将其保留在此处。
    /// （此前，顶级常量 `main.swift` 承担此角色。）
    private static var delegate: AppDelegate?

    public static func main() {
        // 第二个 `| sifteditor`：传递给当前运行的自身并结束 (B15)。
        if Intake.handOffStdinToRunningInstance() { exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
