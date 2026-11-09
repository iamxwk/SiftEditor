#!/bin/sh
# 使用  SPM 构建的二进制文件被打包成 .app 包。
# 未打包的可执行文件无法正确进行窗口合成，因此
# 运行此程序需要一个软件包， GUI。
set -e

CONFIG="${1:-debug}"

# 产品名称（显示名称）。运行时显示名称为 AppInfo.name，读取为 CFBundleName，因此这是唯一的来源。
# 这可以通过环境变量 APP_NAME 来覆盖（例如，APP_NAME=FooView sh scripts/make_app.sh）。
#
APP_NAME="${APP_NAME:-SiftEditor}"
BUNDLE_ID="${BUNDLE_ID:-com.iamxwk.SiftEditor}"
# 可执行文件名（executableTarget 是 SPM 的名称）。
EXECUTABLE="${EXECUTABLE:-SiftEditor}"
# 版本（嵌入 Info.plist）。可被 VERSION 覆盖，以匹配 make_dmg.sh。
VERSION="${VERSION:-1.24.1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON="${ICON:-$ROOT/art/AppIcon.icns}"
COPYRIGHT="${COPYRIGHT:-© 2026 iamxwk}"
# 共享链路方案（sifteditor://theme?d=…）。
URL_SCHEME="${URL_SCHEME:-sifteditor}"
# 由于尚未正式发布，我们暂不公布更新版本 feed 或功能需求列表。产品 URL 将在正式发布后公布。
UPDATE_FEED="${UPDATE_FEED-}"
REQUEST_LIST="${REQUEST_LIST-}"
# 的请求表单会将您引导至此存储库中的 Issue 模板。
if [ "$BUNDLE_ID" = "com.iamxwk.SiftEditor" ]; then
    REQUEST_FORM="${REQUEST_FORM-https://github.com/iamxwk/SiftEditor/issues/new?template=request.yml}"
else
    REQUEST_FORM="${REQUEST_FORM-}"
fi
# 交付物位置。位于 universal 版本（--arch arm64 --arch x86_64）
# 该路径会变为 .build/apple/Products/<Config>，因此 make_dmg.sh 通过 BINDIR 覆盖。
BINDIR="${BINDIR:-$ROOT/.build/$CONFIG}"
BIN="$BINDIR/$EXECUTABLE"
# SPM 的资源包为 `<包名>_<目标名>.bundle`。目标是
# SwiftPM 的生成名称由 Package.swift、package 和 target 确定。
RESBUNDLE="$BINDIR/SiftEditor_SiftEditorCore.bundle"
# 的位置为 .app。此存储库中的默认位置为 .build。
OUTDIR="${OUTDIR:-$ROOT/.build}"
APP="$OUTDIR/$APP_NAME.app"

# 代码签名是 ID。默认值为 ad-hoc（“-”）。
# 一旦你获得了  Developer ID，你只需要将 SIGN_IDENTITY="Developer ID Application: ..." 传递给它。
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ ! -f "$BIN" ]; then
    echo "找不到可执行文件：$BIN（请先运行 swift build）" >&2
    exit 1
fi
if [ ! -f "$ICON" ]; then
    echo "找不到应用图标：$ICON" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

# 包含用于本地化的资源包（由 SPM 生成）等。
# 如果没有 ，则无法解析 Bundle.module，字符串仍显示为 key。
if [ -d "$RESBUNDLE" ]; then
    cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
fi

# 包含应用图标；可用 ICON 覆盖默认图标。
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>$COPYRIGHT</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
$(if [ -n "$UPDATE_FEED" ]; then
    printf '    <key>SiftEditorUpdateFeed</key>\n    <string>%s</string>' "$UPDATE_FEED"
fi)
$(if [ -n "$REQUEST_FORM" ]; then
    printf '    <key>SiftEditorRequestForm</key>\n    <string>%s</string>' "$(printf '%s' "$REQUEST_FORM" | sed 's/&/\&amp;/g')"
fi)
$(if [ -n "$REQUEST_LIST" ]; then
    printf '    <key>SiftEditorRequestList</key>\n    <string>%s</string>' "$REQUEST_LIST"
fi)

    <!-- 在 Finder 的“打开方式”中显示本应用。
         缺少此声明时，AppDelegate 的 application(_:open:) 不会被调用。
         LSHandlerRank=Alternate：显示为候选，但不抢占 TextEdit 等默认应用。
         第二个 public.data 声明允许打开任意扩展名的日志，
         包括 .log、.out 和无扩展名文件。
         此处也使用 Alternate；None 表示不打开此类型，并非仅降低优先级。 -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Text Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.utf8-plain-text</string>
                <string>public.log</string>
                <string>public.comma-separated-values-text</string>
                <string>public.tab-separated-values-text</string>
                <string>public.json</string>
                <string>public.source-code</string>
                <string>public.script</string>
                <string>public.xml</string>
                <string>public.yaml</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Any File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
    <!-- 声明接收外观设置的共享链接（sifteditor://theme?d=…）。
         否则 macOS 不会把链接交给本应用；由 application(_:open:) 处理。 -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID.settings</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>$URL_SCHEME</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- 为 BYOK 连接 Ollama 等本地 OpenAI 兼容服务设置 ATS 例外。
         NSAllowsLocalNetworking 仅允许 loopback（127.0.0.1 / localhost）和 .local（mDNS）
         使用明文 HTTP；互联网连接仍要求 HTTPS。B18。 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# 代码签名。**省略此步骤会导致应用在其他已下载的 Mac 设备上崩溃。**
#
# Swift 的链接器使用 ad-hoc (flags:, adhoc, linker-signed) 对可执行二进制文件进行签名。
# 该签名假定“捆绑包具有资源签名”，但二进制文件已更改为 .app
# 简单地复制它不会创建 Contents/_CodeSignature/CodeResources。
# 结果 `codesign --verify` 为
#   "code has no resources but signature indicates they must be present"
# ID 变为 ，导致签名不一致。开发机器没有 quarantine 属性，因此无需验证即可运行，但是……
# ：下载 Mac 时，会添加 quarantine，而 AMFI 会验证并终止该进程。
# 用户看到“应用程序意外终止”。
# （不是像 Gatekeeper 那样的“无法打开”消息，而是崩溃）。
#
# 解决方案：重新签名整个捆绑包以创建 CodeResources。
# 即使您将其保留为  ad-hoc，**也不会再发生崩溃**（第一次需要右键单击并选择“打开”）。
# 一旦您获得  Developer ID，只需传递 SIGN_IDENTITY 即可切换到官方签名。
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP"
else
    # 在正式签名中，签名是按顺序从嵌套元素进行的，并且 hardened runtime 是有效的（公证要求）。
    if [ -d "$APP/Contents/Resources/$(basename "$RESBUNDLE")" ]; then
        # SPM resource bundles are data-only bundles. Timestamping their
        # standalone signature can make strict verification fail; the outer
        # app and DMG carry the notarized/timestamped signatures.
        codesign --force --options runtime --timestamp=none \
                 --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/$(basename "$RESBUNDLE")"
    fi
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

# ：确保签名一致（分发签名不一致的程序会导致程序在其他设备上崩溃）。
codesign --verify --deep --strict "$APP"

echo "$APP"
