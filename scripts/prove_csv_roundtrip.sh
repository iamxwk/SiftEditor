#!/bin/sh
# ：终端显示“能否对 CSV 进行过滤、校正，并以原始格式保存？”
#
#   sh scripts/prove_csv_roundtrip.sh
#
# 针对  于 2026-09-05 向 Threads 提出的问题，答案是：无需进行屏幕录制。
# （无需任何权限，也不占用 machine 内存）。输出一个可直接使用的输出。
#
# 主题为所有实际公司记录 CSV（1.06GB、Shift-JIS、CRLF，带引号）。
# **请勿触碰原件。** 制作一份工作副本，打开它，进行更正，然后保存。
# 将  与原始文档和 byte 进行比较。
#
# 我想展示的不是它“不会出错”，而是**“即使是一个字节也会穿过那些未被触及的部分”。**
# piece table 以原始字节的形式保存原始数据，存储设备会按原样复制片段。
# 修正行之外的部分不进行转换。因此，无需实现“保留”BOM、CRLF或引号的功能。

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SIFTEDITOR_CSV_SRC:-$ROOT/testdata/houjin_zenken_sjis.csv}"
OUT="$ROOT/build/csvproof"
WORK="$OUT/work.csv"
TERM_="${SIFTEDITOR_CSV_TERM:-東京都}"

[ -f "$SRC" ] || { echo "找不到 $SRC" >&2; exit 1; }
mkdir -p "$OUT"

echo "原本: $SRC"
ls -l "$SRC" | awk '{printf "      %s byte\n", $5}'
echo
echo "==> 创建工作副本（不修改原文件）"
rm -f "$WORK"
cp "$SRC" "$WORK"

echo
echo "==> 打开 → 筛选 → 修改 → 保存（与应用相同的流程）"
SIFTEDITOR_CSV_WORK="$WORK" SIFTEDITOR_CSV_TERM="$TERM_" \
    swift test --filter testRealHoujinCsvWhole 2>/dev/null \
    | grep -E "^  (打开|筛选|修改|保存)"

echo
echo "==> 与原文件对照"
echo
echo "--- 大小（只增加了新内容）---"
BEFORE=$(wc -c < "$SRC" | tr -d ' ')
AFTER=$(wc -c < "$WORK" | tr -d ' ')
echo "原本   : $BEFORE byte"
echo "保存後 : $AFTER byte  (+$((AFTER - BEFORE)))"

echo
echo "--- 第一个不同的字节（应仅涉及修改的一行）---"
cmp "$SRC" "$WORK" || true

echo
echo "--- 修改行的前后内容是否与原文件相同 ---"
DIFF_AT=$(cmp "$SRC" "$WORK" 2>/dev/null | sed -E 's/.*byte ([0-9]+),.*/\1/' || true)
if [ -n "${DIFF_AT:-}" ]; then
    HEAD=$((DIFF_AT - 1))
    if cmp -n "$HEAD" "$SRC" "$WORK" >/dev/null 2>&1; then
        echo "前 ($HEAD byte): 一致"
    else
        echo "前部 ($HEAD 字节)：不一致"; exit 1
    fi
    ADDED=$((AFTER - BEFORE))
    if cmp -i "$HEAD:$((HEAD + ADDED))" "$SRC" "$WORK" >/dev/null 2>&1; then
        echo "後 ($((BEFORE - HEAD)) byte): 一致"
    else
        echo "后部：不一致"; exit 1
    fi
fi

echo
echo "--- 前 16 字节（确认未添加 BOM）---"
head -c 16 "$WORK" | xxd

echo
echo "--- CR 数量（确认 CRLF 未变为 LF）---"
printf "原本   : "; LC_ALL=C tr -dc '\r' < "$SRC"  | wc -c | tr -d ' '
printf "保存後 : "; LC_ALL=C tr -dc '\r' < "$WORK" | wc -c | tr -d ' '

echo
echo "--- 引号数量（确认未重新添加）---"
printf "原本   : "; LC_ALL=C tr -dc '"' < "$SRC"  | wc -c | tr -d ' '
printf "保存後 : "; LC_ALL=C tr -dc '"' < "$WORK" | wc -c | tr -d ' '

echo
echo "--- 修改的行（仍可按 Shift-JIS 读取）---"
sed -n "$(LC_ALL=C awk -v d="${DIFF_AT:-1}" 'BEGIN{print 1}')"p /dev/null 2>/dev/null || true
LC_ALL=C dd if="$WORK" bs=1 skip=$((${DIFF_AT:-1} - 260)) count=400 2>/dev/null \
    | iconv -f SHIFT_JIS -t UTF-8 2>/dev/null | sed -n '2p' | cut -c1-160

echo
echo "工作副本较大；不需要时可手动删除："
echo "  rm -f $WORK"
