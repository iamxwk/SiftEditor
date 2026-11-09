// swift-tools-version: 5.9
import PackageDescription

// SiftEditor 的主体分为可重用核心和 GUI 可执行文件。
//
//   SiftEditorCore (library)——几乎整个主机。UI 和发动机也位于此处。
//        └── SiftEditor (executable) ── macOS 应用程序。
let package = Package(
    name: "SiftEditor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // 该核心在测试中也用作 SearchBenchCLI。
        .library(name: "SiftEditorCore", targets: ["SiftEditorCore"])
    ],
    targets: [
        .target(
            name: "SiftEditorCore",
            path: "Sources/SiftEditorCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "SiftEditor",
            dependencies: ["SiftEditorCore"],
            path: "Sources/SiftEditor"
        ),
        // 一个使用 release 测量搜索速度的工具（单独的 debug 可能是由于实现限制造成的）
        // （无法分离，可能是由于构建设置所致）。
        .executableTarget(
            name: "SearchBenchCLI",
            dependencies: ["SiftEditorCore"],
            path: "Sources/SearchBenchCLI"
        ),
        .testTarget(
            name: "SiftEditorTests",
            dependencies: ["SiftEditorCore"],
            path: "Tests/SiftEditorTests"
        )
    ]
)
