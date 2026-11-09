#!/bin/sh
# release 构建（universal: arm64 + x86_64）→ .app → 创建用于分发的 .dmg。
#
# ■ 默认值（无环境变量）：ad-hoc 签名
#   不会崩溃，但 Gatekeeper 显示“无法验证开发者”。
#   对于 ，用户首次使用时需要右键单击并选择“打开”。
#
# ■ 正式配布（Developer ID 署名＋公証）
#   一次性准备：
#     1. 创建证书 (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸
#        Developer ID Application）。已与 `security find-identity -v -p codesigning` 确认。
#     2. 将公证凭证存储在 Keychain 中：
#        xcrun notarytool store-credentials sifteditor \
#          --apple-id <AppleID> --team-id <TEAMID> --password <应用专用密码>
#        （App 的密码由 appleid.apple.com 发放。这不是 Apple 或 ID 的主密码。）
#   版本：
#     SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#     NOTARY_PROFILE=sifteditor \
#     sh scripts/make_dmg.sh
#
#   ■ 当有两个证书时，请使用它们的哈希值而不是它们的名称来引用它们。
#     如果同名证书存在于不同的钥匙串中（例如 login 和 System），则 codesign 将
#     构建过程卡在 `ambiguous (matches …)`，因为它无法解析名称。
#     在此处失败。使用 40 位 SHA-1 可以消除歧义：
#
#       security find-identity -v -p codesigning # 该行的前 40 位数字是井号。
#       SIGN_IDENTITY=CB470780A956A25E8DAE448646A06235156EDC38 \
#       NOTARY_PROFILE=sifteditor sh scripts/make_dmg.sh
#
#     使用哪一个取决于到期日期（`security find-certificate -a -Z -c \
#     "Developer ID Application" <keychain> | openssl x509 -noout -dates`）。
#     已签名二进制文件经过公证并加盖时间戳，但证书尚未过期。
#     也能通过验证，所以无需急于重新创建。请在下一个 ID 过期前准备好。
#
#   公证请求已发送至 Apple 服务器，我们正在等待审核（几分钟）。如果审核通过，请求将发送至 staple。
#   将公证凭证附加到 dmg，以便离线时也能通过 Gatekeeper 检查。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-SiftEditor}"
VERSION="${VERSION:-1.24.1}"
APP="$ROOT/.build/$APP_NAME.app"
DMG="$ROOT/.build/$APP_NAME-$VERSION.dmg"

# Apple 使其在 Silicon 和 Intel 上都能工作。
# 单独使用  `swift build -c release` 将生成特定于构建机器架构的二进制文件。
# Intel Mac 无法启动。
echo ">> 构建发布版（通用架构：arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64

echo ">> 创建并签名 .app 包"
BINDIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP_NAME="$APP_NAME" BINDIR="$BINDIR" sh "$ROOT/scripts/make_app.sh" release >/dev/null

# 首先，对 .app 本身进行公证，并将其更改为 staple。
# 如果只将 staple 应用于  dmg，则将其拖到 Applications 后，.app 中将不会有任何票据。
# ：在离线的 Mac 中，Gatekeeper 可能无法查询 Apple，从而导致验证失败。
# 公证文件应以 zip 格式提交（.app 是一个目录，不能直接发送）。
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
    ZIP="$ROOT/.build/$APP_NAME-notarize.zip"
    rm -f "$ZIP"
    echo ">> 提交 .app 公证"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    echo ">> 将公证凭证附加到 .app"
    xcrun stapler staple "$APP"
fi

rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
    echo ">> 使用 create-dmg 创建 .dmg"
    create-dmg \
        --volname "$APP_NAME $VERSION" \
        --window-size 540 380 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 140 190 \
        --app-drop-link 400 190 \
        --no-internet-enable \
        "$DMG" \
        "$APP" >/dev/null
else
    echo ">> 使用 hdiutil 创建 .dmg（未安装 create-dmg 时的备用方式）"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
        -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
fi

# ---------------------------------------------------------------------------
# 如果  Developer ID 已签名：也请对 dmg 进行签名、公证，并将其设为 staple。
# .app 已由 make_app.sh 签名。dmg 本身也必须签名才能通过公证。
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo ">> 签名 dmg"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

    if [ -n "$NOTARY_PROFILE" ]; then
        echo ">> 提交公证（Apple 服务器审核，可能需要几分钟）"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

        echo ">> 将公证凭证附加到 dmg（staple）"
        xcrun stapler staple "$DMG"

        echo ">> 验证 Gatekeeper 是否接受"
        # 如果  显示“Notarized Developer ID”，用户甚至不需要右键单击。
        spctl -a -vvv -t install "$DMG"
        xcrun stapler validate "$DMG"
        # .app 也有一个票据（因为它即使离线也能工作）。
        xcrun stapler validate "$APP"
    else
        echo ">> 未设置 NOTARY_PROFILE，跳过公证（仅签名）"
        echo "   未公证的应用仍可能触发 Gatekeeper 警告。"
    fi
fi

echo "$DMG"
