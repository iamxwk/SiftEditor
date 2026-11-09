#!/bin/sh
# GitHub Release 按以下顺序生成：“使用 draft 创建 → 附加 dmg → 验证是否已附加 → 发布”。
#
#   SIGN_IDENTITY=<40位哈希值> NOTARY_PROFILE=sifteditor \
#   sh scripts/release.sh 1.23.2 notes-1.23.2.md
#
# 发布前检查签名、公证和 dmg，避免生成不完整的公开 Release。
# 如果 SiftEditor-<版>.dmg 不存在，则最新版本将失败（版本 1.23.1 就是因为这个原因崩溃的）。
#
# 前提条件：最新版本的 main 未更改，并且任何版本更新（例如 AppInfo.swift）都已合并。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: release.sh <version> <notes-file>}"
NOTES="${2:?usage: release.sh <version> <notes-file>}"
TAG="v$VERSION"
DMG="$ROOT/.build/SiftEditor-$VERSION.dmg"

[ -f "$NOTES" ] || { echo "找不到发布说明：$NOTES" >&2; exit 1; }
[ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ] || {
    echo "需要 SIGN_IDENTITY 和 NOTARY_PROFILE（只发布已签名并公证的 dmg）" >&2; exit 1; }

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "当前不是 main 分支" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "存在未提交的修改" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "当前提交与 origin/main 不一致" >&2; exit 1; }

grep -q "\"$VERSION\"" Sources/SiftEditorCore/AppInfo.swift || {
    echo "AppInfo.swift 中找不到 $VERSION（版本更新尚未合并）" >&2; exit 1; }

if gh release view "$TAG" >/dev/null 2>&1; then
    [ "$(gh release view "$TAG" --json isDraft -q .isDraft)" = "true" ] || {
        echo "$TAG 已发布；若缺少 dmg，请使用 gh release upload 添加" >&2; exit 1; }
    echo ">> 使用现有草稿 $TAG"
else
    echo ">> 创建草稿"
    gh release create "$TAG" --draft --target "$(git rev-parse HEAD)" \
        --title "SiftEditor $VERSION" --notes-file "$NOTES"
fi

echo ">> 创建 dmg（签名并公证）"
VERSION="$VERSION" sh scripts/make_dmg.sh

echo ">> 附加 dmg"
gh release upload "$TAG" "$DMG" --clobber

LOCAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
REMOTE="$(gh release view "$TAG" --json assets -q ".assets[]|select(.name==\"SiftEditor-$VERSION.dmg\")|.digest")"
[ "$REMOTE" = "sha256:$LOCAL" ] || { echo "附加的 dmg 的 SHA-256 不一致：$REMOTE != $LOCAL" >&2; exit 1; }

echo ">> 公開"
gh release edit "$TAG" --draft=false --latest
echo "已发布 $TAG（dmg sha256:$LOCAL）"
