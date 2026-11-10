# SiftEditor

[English](README.md) | **简体中文**

SiftEditor 是一款面向大文本文件的 macOS 编辑器。项目包含采用 MIT 许可证的上游代码；必要的版权和许可声明保留在 [LICENSE](LICENSE) 中。

本项目增加了参考 EmEditor 的查找与提取界面、常见整行和字符串计数、CSV 结果视图以及查找历史。尚未实现的功能以 `*` 标记并禁用。开发进度见[功能清单](docs/EMEDITOR_FEATURE_CHECKLIST.md)。

界面文字由英语和简体中文语言文件管理。

## 构建与测试

需要 macOS 13 或更高版本、包含 Swift 5.9 或更高版本的 Xcode，以及构建机器上的 `rg`（ripgrep）。`build-app.sh` 会把 ripgrep 和 PCRE2 库打包进唯一的 `.build/SiftEditor.app`；使用打包后 App 的用户无需安装 `rg`。辅助程序必须支持与 App 相同的 CPU 架构。

```sh
swift test
sh build-app.sh
open .build/SiftEditor.app
```

本地 App 使用 `com.iamxwk.SiftEditor` Bundle ID 和 `sifteditor://` 设置链接。在已安装的 App 上运行 `scripts/install-cli.sh` 后，可使用终端命令 `sifteditor`。本地的 `test.sql`、`testdata/` 和 `.build/` 不纳入 Git。

大型 UTF-8 文件的正则查找及查找框提取使用 App 内置的 ripgrep。“搜索 > 提取常用字符串”中的正则、IPv4、IPv6、邮箱和网址也由它预筛选候选行，再由原匹配器提取和计数；整行及单词计数保留流式扫描。未保存的大文件会从当前编辑内容生成临时快照供查找和两种提取功能使用，不会保存原文件。临时目录需要约等于文档大小的可用空间；提取完成、关闭查找或再次编辑后会清理快照。

使用 `scripts/make_dmg.sh` 可生成 `.build/SiftEditor-<版本号>.dmg`。每次成功打包 App 都会递增 `VERSION` 文件中的补丁版本；正式发布也可以显式指定 `VERSION`。SiftEditor 尚未发布正式版本；签名和公证需要使用自己的开发者凭据。

## 项目状态

规划中的功能入口在实现之前保持禁用。打包后的 App 使用 `art/AppIcon.icns` 中的 SiftEditor 图标。

## 许可证

[MIT](LICENSE)。保留原作者的版权和许可证声明。
