#!/bin/sh
# `sifteditor` 在此处输入命令（通过管道传递命令的入口点）。
#
#   sh scripts/install-cli.sh # /usr/local/bin/sifteditor
#   PREFIX=~/bin sh scripts/install-cli.sh # 更改位置
#
# 只需将 symlink 应用到应用本身即可。即使更新应用，也无需重新应用。
#
#   kubectl logs -f pod/api | sifteditor # 通过管道
#   sifteditor app.log.gz # gzip 按原样打开
#   sifteditor < app.log # 重定向相同。
#
# 移除时：rm <PREFIX>/sifteditor
set -eu

APP="${APP:-/Applications/SiftEditor.app}"
PREFIX="${PREFIX:-/usr/local/bin}"
BIN="$APP/Contents/MacOS/SiftEditor"

[ -x "$BIN" ] || { echo "在 $APP 找不到 SiftEditor.app；可通过 APP=... 指定位置。" >&2; exit 1; }
mkdir -p "$PREFIX"
ln -sf "$BIN" "$PREFIX/sifteditor"

echo "ok    $PREFIX/sifteditor → $BIN"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "警告：$PREFIX 不在 PATH 中，请将其加入 Shell 配置。" ;;
esac
