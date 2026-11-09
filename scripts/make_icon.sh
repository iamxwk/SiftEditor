#!/bin/sh
# art/icon.svg（用于密集/大尺寸）和 art/icon-small.svg（用于简化/小尺寸）
# 生成  art/AppIcon.icns。需要 rsvg-convert (librsvg) 和 iconutil (macOS 标准)。
#
# 小尺寸图标省去阴影和高亮行中的箭头，以保持 16/32px 下的清晰度。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/art"
ISET="$ART/AppIcon.iconset"
S="$ART/icon-small.svg"   # 16 / 32px 简化版
B="$ART/icon.svg"         # 64px 及以上

rm -rf "$ISET"; mkdir -p "$ISET"
rsvg-convert -w 16   -h 16   "$S" -o "$ISET/icon_16x16.png"
rsvg-convert -w 32   -h 32   "$S" -o "$ISET/icon_16x16@2x.png"
rsvg-convert -w 32   -h 32   "$S" -o "$ISET/icon_32x32.png"
rsvg-convert -w 64   -h 64   "$B" -o "$ISET/icon_32x32@2x.png"
rsvg-convert -w 128  -h 128  "$B" -o "$ISET/icon_128x128.png"
rsvg-convert -w 256  -h 256  "$B" -o "$ISET/icon_128x128@2x.png"
rsvg-convert -w 256  -h 256  "$B" -o "$ISET/icon_256x256.png"
rsvg-convert -w 512  -h 512  "$B" -o "$ISET/icon_256x256@2x.png"
rsvg-convert -w 512  -h 512  "$B" -o "$ISET/icon_512x512.png"
rsvg-convert -w 1024 -h 1024 "$B" -o "$ISET/icon_512x512@2x.png"

iconutil -c icns "$ISET" -o "$ART/AppIcon.icns"
rm -rf "$ISET"
echo "$ART/AppIcon.icns"
