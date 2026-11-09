#!/usr/bin/env python3
"""检查 SiftEditor 的版本号和本地化字符串。"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / ".consistency.json"
FAIL: list[str] = []
WARN: list[str] = []


def read(p: str) -> str:
    return (ROOT / p).read_text(encoding="utf-8")


def head(title: str) -> None:
    print(f"\n──── {title}")


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        print(f"缺少配置: {CONFIG_PATH.name}", file=sys.stderr)
        sys.exit(2)
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


# 1. 版本字符串 ---------------------------------------------------------

def check_versions(sources: list[dict]) -> None:
    head("版本字符串")
    versions = {}
    for src in sources:
        # 同一文件可能多次写出版本号；检查所有匹配项是否一致。
        found = re.findall(src["pattern"], read(src["path"]))
        if not found:
            FAIL.append(f"找不到版本号: {src['name']}（{src['path']}）")
            continue
        if len(set(found)) > 1:
            FAIL.append(f"同一文件中的版本号不一致: {src['name']}"
                        f"（{src['path']}）→ {sorted(set(found))}")
            continue
        versions[src["name"]] = found[0]
        n = f" ×{len(found)}" if len(found) > 1 else ""
        print(f"  {src['name']:24s} {found[0]}{n}")

    if len(set(versions.values())) > 1:
        FAIL.append(f"版本号不一致: {versions}")
    elif versions:
        print("  → 全部一致 ✅")


# 2. 本地化字符串 ---------------------------------------------------------

def check_i18n(cfg: dict) -> None:
    head("国际化键")
    langs = cfg.get("langs", ["en", "zh-Hans"])
    tables = {lang: {m.group(1): m.group(2)
                     for m in re.finditer(r'^"([^"]+)"\s*=\s*"(.*)";',
                                          read(cfg["table"].format(lang=lang)), re.M)}
              for lang in langs}
    print("  " + " / ".join(f"{lang}: {len(t)}" for lang, t in tables.items()))

    base = langs[0]
    for lang in langs[1:]:
        for miss in sorted(set(tables[base]) - set(tables[lang])):
            FAIL.append(f"{lang} 缺少的键: {miss}")
        for miss in sorted(set(tables[lang]) - set(tables[base])):
            FAIL.append(f"{base} 缺少的键: {miss}")

        # 如果格式说明符的数量不同，程序将在运行时崩溃。
        for k in sorted(set(tables[base]) & set(tables[lang])):
            fb = re.findall(r'%[@dfs]|%\d\$[@dfs]', tables[base][k])
            fl = re.findall(r'%[@dfs]|%\d\$[@dfs]', tables[lang][k])
            if len(fb) != len(fl):
                FAIL.append(f"格式占位符数量不一致（运行时可能崩溃）: {k}  {base}={fb} {lang}={fl}")

    # 检查代码使用的键是否存在；动态键因包含插值而不参与静态检查。
    used: set[str] = set()
    for f in (ROOT / cfg["code_dir"]).rglob(cfg.get("code_glob", "*.swift")):
        used |= set(re.findall(cfg["call"], f.read_text()))
    static_used = {k for k in used if "\\(" not in k}
    for k in sorted(static_used - set(tables[base])):
        FAIL.append(f"使用了未定义的键（界面会显示键名）: {k}")

    # 疑似未使用（无法检测到通过变量 L(key) 使用的部分，因此仅收到警告）
    dynamic_prefixes = {k.split("\\(")[0] for k in used if "\\(" in k}
    suspicious = {k for k in set(tables[base]) - static_used
                  if not any(k.startswith(p) for p in dynamic_prefixes)}
    if suspicious:
        WARN.append(f"疑似未使用的键 {len(suspicious)} 个（通过变量引用则无需处理）")

    print("  键和格式占位符均一致 ✅")


def main() -> int:
    cfg = load_config()
    print(f"一致性检查: {cfg.get('product', ROOT.name)}")

    if cfg.get("versions"):
        check_versions(cfg["versions"])
    if cfg.get("i18n"):
        check_i18n(cfg["i18n"])

    print()
    for warning in WARN:
        print(f"  ⚠️  {warning}")
    if FAIL:
        print(f"\n❌ {len(FAIL)} 处不一致:")
        for failure in FAIL:
            print(f"   - {failure}")
        return 1
    print("\n✅ 一致性检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
