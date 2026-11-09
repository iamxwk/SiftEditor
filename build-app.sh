#!/bin/sh
# 在项目根目录编译并更新唯一的 SiftEditor.app。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

swift build
sh "$ROOT/scripts/make_app.sh" debug
