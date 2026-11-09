#!/usr/bin/env python3
"""SiftEditor 测试数据生成脚本。

生成一个测试文件，用于显示大文件和确定字符编码。

使用方法：
    # 10GB (UTF-8) 的英文日志
    python3 scripts/gen_testdata.py --size 10G --out test_10gb.log

    # 1GB / 日本語混在 / UTF-8
    python3 scripts/gen_testdata.py --size 1G --jp --out test_1gb_jp_utf8.log

    # 一组用于字符编码检测测试的小文件 (UTF-8 / Shift-JIS / EUC-JP)
    python3 scripts/gen_testdata.py --encoding-set --out-dir testdata/

尺寸规格：整数 + 单位 (B/K/M/G)。例如：500M、10G、1500000
"""

import argparse
import os
import sys
import time

# 用于包含日文文本的行的片段（在 Shift-JIS / EUC-JP 也可表示的范围内）
JP_FRAGMENTS = [
    "リクエスト受信",
    "ユーザー認証成功",
    "データベース接続",
    "キャッシュ書き込み完了",
    "タイムアウト発生",
    "セッション破棄",
    "ファイル読み込み中",
    "文字コード判定: 自動",
]


def parse_size(s: str) -> int:
    """将 '10G' 等大小字符串转换为字节数。"""
    s = s.strip().upper()
    units = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3}
    if s and s[-1] in units:
        return int(float(s[:-1]) * units[s[-1]])
    return int(s)


# 一个创建类似日志数据的表（即，测试分析功能所需的数据）。
#
# ⚠️ 于 2026-08-11 重制。之前的输出是
#   ① 时间仅推进了几毫秒，**仅0.4秒**（8642万行数据落入一个桶中）
#      = （时间分布演示和 E2E 均不可行）
#   ② `status=200` 为 100%，path 也为 1 型（= 甚至没有展示价值聚合）
# 这些数据不适合测试时间分析：时间已提前，且数值分散。
#
# 的表格设置为素数长度（以防止在使用 i % len 进行选择时出现偏差，从而使周期匹配且不会出现偏差）。
STATUS_TABLE = (
    ["200"] * 89 + ["302"] * 5 + ["404"] * 7 + ["500"] * 2 + ["503"] * 1 + ["401"] * 3
)                                   # 107 件商品（200 件约占 83%）
PATH_TABLE = [
    "/api/v1/users", "/api/v1/users/{id}", "/api/v1/orders", "/api/v1/orders/{id}",
    "/api/v1/search", "/api/v1/session", "/healthz", "/metrics",
    "/static/app.js", "/static/app.css", "/api/v2/graph", "/api/v1/upload",
    "/api/v1/report",
]                                   # 13 個
METHOD_TABLE = ["GET"] * 8 + ["POST"] * 3 + ["PUT"] + ["DELETE"]     # 13 個
REGION_TABLE = ["ap-northeast-1", "us-east-1", "eu-west-1"]

# 故障窗口（约占文件大小的 62-64%）。流量高峰仅出现在此区域，最常见的峰值为 500。
# 一座山，用于展示“在将其范围缩小到仅 ERROR 之后的时间分布”。
INCIDENT_FROM = 0.62
INCIDENT_TO = 0.64
INCIDENT_STATUS = ["500"] * 7 + ["503"] * 2 + ["200"] * 3           # 12 個
# 一行数据没有时间戳（堆栈跟踪中的延续行）。用于**不丢弃计数**的测试材料。
TRACE_LINES = [
    "    at com.example.OrderService.handle(OrderService.java:142)",
    "    at com.example.Repository.query(Repository.java:88)",
    "    ... 17 more",
]


class Timeline:
    """根据行号生成时间戳。作为日志，**时间必须单调递增**。

    如果我们为每一行都创建 `datetime`，那么对于 8642 万行来说是不可能的，因此字符串直到秒为止是
    仅当秒发生变化时才重新组装，并且仅替换毫秒。
    """

    def __init__(self, total_lines: int, span_days: float = 14.0,
                 start_epoch: int = 1_782_000_000, tz: str = "+09:00"):
        self.total = max(1, total_lines)
        self.start = start_epoch
        self.tz = tz
        self.span_ms = int(span_days * 86_400 * 1000)
        # 正常间隔（毫秒）。故障期间此值变为 1/8。
        self.step_ms = max(1, self.span_ms // self.total)
        self.incident_from = int(self.total * INCIDENT_FROM)
        self.incident_to = int(self.total * INCIDENT_TO)
        self._sec = -1
        self._prefix = ""

    def at(self, i: int, incident: bool) -> str:
        # 进度完全由行号决定（不使用随机数=可重复）。
        #
        # ⚠️ 通过障碍物窗口后，**已包装的数量将原样保留**。请仅包装窗口内的空隙。
        # 如果您之后恢复到原始公式，时间会在您离开的那一刻跳跃，并且**图表中会出现一个空洞**（第一个版本）。
        # 这就是发生的情况，实际设备的图表显示，峰值之后立即出现了一个空白区域。
        head = min(i, self.incident_from) * self.step_ms
        burst = max(0, min(i, self.incident_to) - self.incident_from) * self.step_ms // 8
        tail = max(0, i - self.incident_to) * self.step_ms
        base = head + burst + tail
        ms = self.start * 1000 + base + (i % 7)      # 稍微调整一下时间，以免人们同时排队。
        sec, milli = divmod(ms, 1000)
        if sec != self._sec:
            self._sec = sec
            t = time.gmtime(sec + 9 * 3600)          # 显示为 JST（以明确指示偏移量）。
            self._prefix = time.strftime("%Y-%m-%dT%H:%M:%S", t)
        return f"{self._prefix}.{milli:03d}{self.tz}"


def gen_line(i: int, jp: bool, timeline: "Timeline", total: int) -> str:
    """生成一行日志。"""
    incident = INCIDENT_FROM * total <= i < INCIDENT_TO * total
    status = (INCIDENT_STATUS[i % len(INCIDENT_STATUS)] if incident
              else STATUS_TABLE[i % len(STATUS_TABLE)])
    level = "ERROR" if status in ("500", "503") else ("WARN" if status in ("404", "401") else "INFO")
    path = PATH_TABLE[i % len(PATH_TABLE)]
    method = METHOD_TABLE[i % len(METHOD_TABLE)]
    latency = (17 + (i % 400)) * (9 if incident else 1)
    base = (
        f"{timeline.at(i, incident)} [{level:<5}] "
        f"request_id={i} status={status} method={method} path={path} "
        f"latency={latency}ms region={REGION_TABLE[i % 3]}"
    )
    if jp:
        base += f" msg={JP_FRAGMENTS[i % len(JP_FRAGMENTS)]}"
    return base + "\n"


def write_sized(path: str, target_bytes: int, jp: bool, encoding: str) -> None:
    """写入日志行，直到达到指定字节数。

    **计数结果将保存到 `<out>.stats.txt`。** 分析功能将使用“实际数据的固定值”进行测试。
    将用作证据（规范 §8），因此请确保生成的数字以后可以交叉引用。
    """
    written = 0
    i = 0
    # 1 行估算（用于确定时间间隔）。如果行数增加，则行数减少。
    # 时间仍在向前流逝，但时间段之间的间隔稍微粗略了一些。
    estimated_lines = max(1, target_bytes // (150 if jp else 130))
    timeline = Timeline(estimated_lines)
    stats = {"lines": 0, "no_timestamp": 0, "status": {}, "level": {}}
    first_line = last_line = ""

    buf = []
    buf_bytes = 0
    FLUSH = 8 * 1024 * 1024
    with open(path, "w", encoding=encoding, errors="replace", newline="") as f:
        while written < target_bytes:
            line = gen_line(i, jp, timeline, estimated_lines)
            lines = [line]
            # 在失败的窗口中，混合没有时间的延续行（**不丢弃的计数材料**）。
            if "[ERROR]" in line or "[ERROR" in line:
                if i % 5 == 0:
                    lines += [t + "\n" for t in TRACE_LINES]
                    stats["no_timestamp"] += len(TRACE_LINES)
            for one in lines:
                enc_len = len(one.encode(encoding, errors="replace"))
                buf.append(one)
                buf_bytes += enc_len
                written += enc_len
                stats["lines"] += 1
            if not first_line:
                first_line = line
            last_line = line
            status = line.split(" status=", 1)[1].split(" ", 1)[0]
            level = line.split("[", 1)[1].split("]", 1)[0].strip()
            stats["status"][status] = stats["status"].get(status, 0) + 1
            stats["level"][level] = stats["level"].get(level, 0) + 1
            i += 1
            if buf_bytes >= FLUSH:
                f.write("".join(buf))
                buf.clear()
                buf_bytes = 0
                _progress(written, target_bytes)
        if buf:
            f.write("".join(buf))
    _progress(written, target_bytes, final=True)

    report = [
        f"file: {path}",
        f"bytes: {written}",
        f"lines: {stats['lines']}",
        f"lines_without_timestamp: {stats['no_timestamp']}",
        f"first: {first_line.rstrip()}",
        f"last: {last_line.rstrip()}",
    ]
    report += [f"status {k}: {v}" for k, v in sorted(stats["status"].items())]
    report += [f"level {k}: {v}" for k, v in sorted(stats["level"].items())]
    with open(path + ".stats.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(report) + "\n")
    print("\n" + "\n".join(report))


def _progress(written: int, target: int, final: bool = False) -> None:
    pct = min(100, written * 100 // max(1, target))
    end = "\n" if final else "\r"
    print(f"  {pct:3d}%  {written/1024/1024:,.0f} MB", end=end, flush=True)


def gen_encoding_set(out_dir: str) -> None:
    """将相同内容分别写为三种编码，用于测试编码检测。"""
    os.makedirs(out_dir, exist_ok=True)
    targets = {
        "sample_utf8.txt": "utf-8",
        "sample_sjis.txt": "shift_jis",
        "sample_euc.txt": "euc_jp",
    }
    # 包含日语的内容
    lines = [
        "これは文字コード判定のテストです。\n",
        "吾輩は猫である。名前はまだ無い。\n",
        "祇園精舎の鐘の声、諸行無常の響きあり。\n",
        "ABCabc123 半角と全角アルファベットＡＢＣ\n",
        "記号: ①②③ 〜 ※ 【重要】 «»\n",
    ] * 20
    text = "".join(lines)
    for name, enc in targets.items():
        path = os.path.join(out_dir, name)
        with open(path, "w", encoding=enc, errors="replace", newline="") as f:
            f.write(text)
        size = os.path.getsize(path)
        print(f"  {path}  ({enc}, {size} bytes)")
    print("编码测试文件生成完成")


def main() -> int:
    p = argparse.ArgumentParser(description="生成 SiftEditor 测试数据")
    p.add_argument("--size", help="生成大小（例如 10G、1G、500M）")
    p.add_argument("--out", default="test.log", help="输出文件路径")
    p.add_argument("--jp", action="store_true", help="混入日文内容，用于编码测试")
    p.add_argument(
        "--encoding",
        default="utf-8",
        help="输出编码（utf-8 / shift_jis / euc_jp）",
    )
    p.add_argument(
        "--encoding-set",
        action="store_true",
        help="生成用于编码检测测试的三个文件",
    )
    p.add_argument("--out-dir", default="testdata", help="--encoding-set 的输出目录")
    args = p.parse_args()

    if args.encoding_set:
        gen_encoding_set(args.out_dir)
        return 0

    if not args.size:
        p.error("请指定 --size（或使用 --encoding-set）")

    target = parse_size(args.size)
    print(f"生成開始: {args.out}  target={target:,} bytes  jp={args.jp}  enc={args.encoding}")
    write_sized(args.out, target, args.jp, args.encoding)
    return 0


if __name__ == "__main__":
    sys.exit(main())
