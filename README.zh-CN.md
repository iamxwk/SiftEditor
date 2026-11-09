# SiftEditor

[English](README.md) | **简体中文**

SiftEditor 是一款面向大文本文件的 macOS 编辑器。项目包含采用 MIT 许可证的上游代码；必要的版权和许可声明保留在 [LICENSE](LICENSE) 中。

本项目增加了参考 EmEditor 的查找与提取界面、常见整行和字符串计数、CSV 结果视图以及查找历史。尚未实现的功能以 `*` 标记并禁用。开发进度见[功能清单](docs/EMEDITOR_FEATURE_CHECKLIST.md)。

界面文字由英语和简体中文语言文件管理。

## 构建与测试

需要 macOS 13 或更高版本，以及包含 Swift 5.9 或更高版本的 Xcode。

```sh
swift test
sh build-app.sh
open .build/SiftEditor.app
```

本地 App 使用 `com.iamxwk.SiftEditor` Bundle ID 和 `sifteditor://` 设置链接。在已安装的 App 上运行 `scripts/install-cli.sh` 后，可使用终端命令 `sifteditor`。本地的 `test.sql`、`testdata/` 和 `.build/` 不纳入 Git。

使用 `scripts/make_dmg.sh` 可生成分发用磁盘映像。当前沿用的版本号会生成 `.build/SiftEditor-1.24.1.dmg`。SiftEditor 尚未发布正式版本；签名和公证需要使用自己的开发者凭据。

## 项目状态

规划中的功能入口在实现之前保持禁用。打包后的 App 使用 `art/AppIcon.icns` 中的 SiftEditor 图标。

## 许可证

[MIT](LICENSE)。保留原作者的版权和许可证声明。
