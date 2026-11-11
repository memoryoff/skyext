"""抽取仓库里每个源文件的导出方法清单，供 docs/api/ 索引使用。

用法：
    python docs/api/_tools/extract.py            # 打印到 stdout
    python docs/api/_tools/extract.py --json     # 输出 JSON

规则（Lua）：
    function M.foo(a, b)          -> 导出，带模块前缀
    function M:foo(a)             -> 导出，方法（self）
    M.foo = function(a)           -> 导出
    function orm.foo(...)         -> 导出（模块名任意小写标识符）
    function t.foo(...)           -> 导出
    local function foo(...)       -> 内部，不计
规则（TypeScript）：
    export function foo(...)
    export async function foo(...)
    export const foo = ...        -> 常量/函数式导出
    export class Foo
"""

import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

LUA_DEF = re.compile(
    r"^(?P<indent>\s*)function\s+(?P<mod>[A-Za-z_][A-Za-z0-9_]*)[.:](?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*\((?P<args>[^)]*)\)"
)
LUA_ASSIGN = re.compile(
    r"^(?P<indent>\s*)(?P<mod>[A-Za-z_][A-Za-z0-9_]*)[.:](?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*=\s*function\s*\((?P<args>[^)]*)\)"
)
TS_FUNC = re.compile(r"^export\s+(?:async\s+)?function\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)")
TS_CONST = re.compile(
    r"^export\s+const\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*(?:async\s*)?\("
)
TS_CLASS = re.compile(r"^export\s+(?:abstract\s+)?class\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)")
TS_METHOD = re.compile(
    r"^\s{2,}(?:public\s+|private\s+|protected\s+)?(?:async\s+)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*\((?P<args>[^)]*)\)\s*(?::\s*[^>{]+)?\{"
)

SKIP_DIRS = {".git", "node_modules", "3rd", "skynet", "bin", "luaclib", "cservice",
             "release-assets", "coverage", "logs", "build-output", ".codegraph", "docs"}
SCAN_DIRS = ["lualib", "service", "scripts", "example", "sdk", "build.mk"]


def comment_block(lines, idx):
    """收集定义行上方连续 `--` 注释（限 6 行）。"""
    out = []
    j = idx - 1
    while j >= 0 and len(out) < 6:
        s = lines[j].strip()
        if s.startswith("--"):
            out.append(s.lstrip("-").strip())
            j -= 1
        else:
            break
    return list(reversed(out))


def scan_lua(path, lines):
    items = []
    for i, line in enumerate(lines):
        m = LUA_DEF.match(line) or LUA_ASSIGN.match(line)
        if not m:
            continue
        args = m.group("args").strip()
        items.append({
            "kind": "function",
            "module": m.group("mod"),
            "name": m.group("name"),
            "method": "." not in line.split("(")[0] and ":" in line.split("(")[0],
            "args": args,
            "line": i + 1,
            "comment": comment_block(lines, i),
        })
    return items


def scan_ts(path, lines):
    items = []
    for i, line in enumerate(lines):
        m = TS_FUNC.match(line) or TS_CLASS.match(line)
        if m:
            kind = "class" if "class" in line else "function"
            items.append({"kind": kind, "module": None, "name": m.group("name"),
                          "args": "", "line": i + 1, "comment": comment_block(lines, i)})
            continue
        m = TS_CONST.match(line)
        if m:
            items.append({"kind": "const", "module": None, "name": m.group("name"),
                          "args": "", "line": i + 1, "comment": comment_block(lines, i)})
    return items


def main():
    files = []
    for target in SCAN_DIRS:
        p = os.path.join(ROOT, target)
        if os.path.isfile(p):
            files.append(p)
            continue
        for dp, dn, fn in os.walk(p):
            dn[:] = [d for d in dn if d not in SKIP_DIRS]
            for f in fn:
                if f.endswith((".lua", ".ts")):
                    files.append(os.path.join(dp, f))

    result = {}
    for path in sorted(files):
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        if ".test." in rel:
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        items = scan_ts(path, lines) if path.endswith(".ts") else scan_lua(path, lines)
        if items:
            result[rel] = {"lines": len(lines), "items": items}

    if "--json" in sys.argv:
        print(json.dumps(result, ensure_ascii=False, indent=1))
        return

    total = 0
    for rel, info in result.items():
        print(f"\n## {rel}  ({info['lines']} 行)")
        for it in info["items"]:
            total += 1
            c = ("  // " + it["comment"][0]) if it["comment"] else ""
            print(f"  {it['line']:>5}  {it['module'] + '.' if it['module'] else ''}{it['name']}({it['args']}){c}")
    print(f"\n文件 {len(result)} 个，方法 {total} 个")


if __name__ == "__main__":
    main()
