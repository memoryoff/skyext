"""为 docs/api/ 生成"方法证据包"：签名 + 上方注释 + 函数体关键语句。

覆盖四类导出/内部定义：
  Lua  function M.foo(...) / function M.methods.bar(...) / function M:baz(...)
       M.foo = function(...)
       local function helper(...)          -> 内部函数，标注 int
       return { a = ..., b = ... }         -> 模块导出表的键
  TS   export function / export async function / export const / export class
       export interface / export type
       class 内方法
"""

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

LUA_DEF = re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_.]*)[.:]([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)")
LUA_ASSIGN = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_.]*)[.:]([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function\s*\(([^)]*)\)"
)
LUA_LOCAL = re.compile(r"^\s*local\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)")
LUA_RETURN_TABLE = re.compile(r"^\s*return\s*\{")
LUA_TABLE_KEY = re.compile(r"^\s{2,}([a-z_][A-Za-z0-9_]*)\s*=\s*[^=]")
TS_DEF = re.compile(
    r"^export\s+(?:default\s+)?(?:async\s+)?(function|class|const|interface|type|enum)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)
TS_METHOD = re.compile(
    r"^\s{2,}(?:public\s+|private\s+|protected\s+|readonly\s+|static\s+)*(?:async\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*[^={]+)?\{"
)

KEY = re.compile(
    r"assert|error\(|return|skynet\.|config\.|fs\.|path\.|etcd|metrics|log\.|getenv|setenv|"
    r"pcall|xpcall|queue\(|watch|lease|lock|fence|revision|seq|retry|timeout|dump|"
    r"string\.|table\.|math\.|cjson|bson|md5|crypto|httpc|http\.|zip|lcov|os\.|io\."
)

SKIP_DIRS = {".git", "node_modules", "3rd", "skynet", "bin", "luaclib", "cservice",
             "release-assets", "coverage", "logs", "build-output", ".codegraph"}
SCAN = ["lualib", "service", "scripts", "example", "sdk"]


def comments(lines, idx):
    out, j = [], idx - 1
    while j >= 0 and len(out) < 7:
        s = lines[j].strip()
        if s.startswith("--") or s.startswith("//") or s.startswith("/*") or s.startswith("*"):
            out.append(s.lstrip("-/* ").strip())
            j -= 1
        else:
            break
    return list(reversed(out))


def collect(lines, is_ts):
    defs = []
    in_return_table = None
    for i, line in enumerate(lines):
        if is_ts:
            m = TS_DEF.match(line)
            if m:
                defs.append((i, m.group(2), "", m.group(1), True))
                continue
            m = TS_METHOD.match(line)
            if m and m.group(1) not in ("if", "for", "while", "switch", "catch", "constructor"):
                defs.append((i, m.group(1), m.group(2), "method", True))
                continue
        else:
            m = LUA_DEF.match(line) or LUA_ASSIGN.match(line)
            if m:
                mod, name = m.group(1), m.group(2)
                sep = ":" if ":" in line.split("(")[0] else "."
                defs.append((i, f"{mod}{sep}{name}", m.group(3).strip(), "function", True))
                continue
            m = LUA_LOCAL.match(line)
            if m:
                defs.append((i, m.group(1), m.group(2).strip(), "int", False))
                continue
            if LUA_RETURN_TABLE.match(line):
                in_return_table = i
                continue
            if in_return_table is not None and i - in_return_table <= 25:
                m = LUA_TABLE_KEY.match(line)
                if m:
                    defs.append((i, m.group(1), "", "export-key", True))
    return defs


def evidence(lines, start, end):
    body = []
    for j in range(start + 1, end):
        s = lines[j].strip()
        if not s or s.startswith(("--", "//", "/*", "*")):
            continue
        if s in ("end", "}", "});", "end,", "else", "end)", "})", "endif"):
            continue
        if KEY.search(s):
            body.append(s)
        if len(body) >= 8:
            break
    return body


def main():
    files = []
    for t in SCAN:
        p = os.path.join(ROOT, t)
        for dp, dn, fn in os.walk(p):
            dn[:] = [d for d in dn if d not in SKIP_DIRS]
            for f in fn:
                if f.endswith((".lua", ".ts")):
                    files.append(os.path.join(dp, f))

    total_files = total_defs = 0
    for path in sorted(files):
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        if ".test." in rel or rel.endswith("/fixture.lua") or rel.endswith("/nested.lua"):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        defs = collect(lines, path.endswith(".ts"))
        total_files += 1
        total_defs += len(defs)
        print(f"\n=== {rel} ({len(lines)}L, {len(defs)} defs) ===")
        for k, (i, name, args, kind, exported) in enumerate(defs):
            nxt = defs[k + 1][0] if k + 1 < len(defs) else len(lines)
            tag = {"int": " [internal]", "export-key": " [export key]", "method": " [method]",
                   "class": " [class]", "const": " [const]", "interface": " [interface]",
                   "type": " [type]", "enum": " [enum]"}.get(kind, "")
            print(f"[{i + 1}] {name}({args}){tag}")
            for c in comments(lines, i):
                print(f"   ~ {c}")
            if kind not in ("export-key", "interface", "type", "enum", "const", "class"):
                for b in evidence(lines, i, min(nxt, i + 90)):
                    print(f"   + {b}")
    print(f"\n-- files {total_files}, defs {total_defs}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
