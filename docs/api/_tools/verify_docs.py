#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 docs/api/*.md 里声明的文件行数与方法行号，是否与真实源码一致。

用法（仓库根目录）:
    python docs/api/_tools/verify_docs.py

检查项:
1. 形如 "## `路径`（N 行" 的文件头，路径能解析到真实文件时，N 必须等于真实行数。
2. 方法表里第二列的行号，必须 <= 该文件真实行数。
3. 报告无法解析的路径（文档里的简写），由人工确认。

退出码: 0 全部通过，1 有硬性不一致。
"""
import os
import re
import sys

ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
API_DIR = os.path.join(ROOT, "docs", "api")

HEADER_RE = re.compile(r"^##\s+`([^`]+)`（(\d+)\s*行")
ROW_RE = re.compile(r"^\|\s*(.+?)\s*\|\s*(\d+)\s*\|")
# 代码块内的表格行不算
CODE_FENCE = "```"

# 小节标题里只写文件名时，按册号推断所在目录（与每册开头的「覆盖 …」声明一致）
PREFIX_BY_BOOK = {
    "01": ["lualib/", "lualib/skyext/"],
    "02": ["lualib/skyext/"],
    "03": ["lualib/skyext/"],
    "04": ["lualib/skyext/"],
    "05": ["lualib/skyext/"],
    "06": ["lualib/skytest/"],
    "07": ["scripts/"],
    "08": ["sdk/"],
    "09": ["service/"],
    "10": ["example/"],
}


def find_real(path, book=None):
    """把文档里的路径解析成仓库内真实文件；解析不到返回 None。"""
    cand = path.replace("/", os.sep)
    if os.path.isfile(os.path.join(ROOT, cand)):
        return os.path.join(ROOT, cand)
    if not cand.endswith((".lua", ".ts")):
        for ext in (".lua", ".ts"):
            p = os.path.join(ROOT, cand + ext)
            if os.path.isfile(p):
                return p
    # 按册号推断前缀
    for prefix in PREFIX_BY_BOOK.get(book or "", []):
        for ext in ("", ".lua", ".ts"):
            p = os.path.join(ROOT, (prefix + path).replace("/", os.sep) + ext)
            if os.path.isfile(p):
                return p
    return None


def count_lines(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def check_file(md_path, book=None):
    errors, skipped = [], []
    cur_path = None
    cur_lines = None
    cur_real = None
    in_code = False
    with open(md_path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if line.strip().startswith(CODE_FENCE):
                in_code = not in_code
                continue
            if in_code:
                continue
            m = HEADER_RE.match(line)
            if m:
                cur_path, cur_lines = m.group(1), int(m.group(2))
                real = find_real(cur_path, book)
                if real is None:
                    skipped.append((cur_path, "路径无法解析"))
                    cur_real = None
                else:
                    cur_real = count_lines(real)
                    if cur_real != cur_lines:
                        errors.append(
                            "%s:%d 声明 %d 行，实际 %d 行（%s）"
                            % (os.path.basename(md_path), lineno, cur_lines, cur_real, cur_path)
                        )
                continue
            if line.startswith("## ") and cur_path is not None:
                # 进入下一个文件/章节
                cur_path, cur_lines, cur_real = None, None, None
                continue
            if cur_real is None:
                continue
            m = ROW_RE.match(line)
            if m and not m.group(1).startswith("---"):
                num = int(m.group(2))
                if num > cur_real:
                    errors.append(
                        "%s:%d 行号 %d 超出文件行数 %d（%s）"
                        % (os.path.basename(md_path), lineno, num, cur_real, cur_path)
                    )
    return errors, skipped


def main():
    if not os.path.isdir(API_DIR):
        print("找不到 docs/api/ 目录，请从仓库根目录运行")
        return 1
    all_errors, all_skipped = [], []
    for name in sorted(os.listdir(API_DIR)):
        if not name.endswith(".md"):
            continue
        errors, skipped = check_file(os.path.join(API_DIR, name), name[:2])
        all_errors.extend(errors)
        all_skipped.extend((name,) + s for s in skipped)
        print("%-30s %s" % (name, "OK" if not errors else "%d 处不一致" % len(errors)))
    print()
    if all_skipped:
        print("路径无法解析（文档里的简写，人工确认即可）:")
        for md, path, why in all_skipped:
            print("  %s: %s (%s)" % (md, path, why))
        print()
    if all_errors:
        print("不一致:")
        for e in all_errors:
            print("  " + e)
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
