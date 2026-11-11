# 05 · 协议分发、定时器与工具库

> 覆盖 `lualib/skyext/` 下的 `sproto_api.lua`、`sproto_host.lua`、`time.lua`、`timer.lua`、`util/`（`fs`、`io`、`path`、`string`、`table`）。
> 第二列是源码起始行号。

## `sproto_api.lua`（329 行，协议注册与分发）

### 注册

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.register_module(mod_name, module, cmds)` | 48 | 注册一个协议模块：`module` 里按协议名放处理函数（用 `:` 定义时 `self` 就是 request）；`cmds` 是协议名前缀；可选 `middleware_cbs` 做协议拦截；可选 `with_request(fd, f, req_id, request_name)` 把处理放进连接自己的串行队列；可选 `reject_client(fd, reason)` 在错误码回不去时断连 | 同一协议重复注册直接 `error` |
| `M.set_sender(sender)` | 200 | 换掉「回包怎么送到客户端」的实现 | — |
| `M.get_sproto_info()` / `M.get_sproto_host()` | 293 / 297 | 当前 sproto schema 信息 / 打包解包对象 | — |

### 分发

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.dispatch_message(conn, data)` | 252 | 处理一个上行包（gate 转来的原始字节），`conn` 是 fd 或会话键 | — |
| `M.raw_dispatch(fd, type, request_name, request, response_cb, req_id)` | 219 | 按 `REQUEST`/`RESPONSE` 分派；整个过程 `xpcall` 包住，异常只记日志 | — |
| `dispatch_request(fd, request_name, request, response_cb, req_id)` | 168 | 有 `with_request` 就走串行队列（带幂等），否则直接执行 | `pack` 或 `nil, reason, code` |
| `dispatch_request_unlocked(...)` | 131 | 真正调用：中间件 → 业务函数；**业务函数不该有返回值**（有就记 error，回包统一由 `response_cb` 产出） | 中间件报错返回 `errcode_internal`，中间件拒绝返回中间件给的 code |
| `reject_request(fd, request_name, reason, code, response_cb)` | 110 | 请求没产出回包时的统一出口：① 客户端没带 session，不会等回包 → 只记日志；② response 有错误码字段 → 回错误码，连接保留；③ 回不了 → **断连**，让客户端立刻失败而不是静默等超时 | — |
| `response_errcode_field(request_name)` | 64 | 查该协议的 RESPONSE 里有没有能承载错误码的字段，结果缓存 | 无 response/协议不存在返回 `nil` |
| `disconnect_client` / `register_request_func` / `socket_sender` / `send_package` / `wakeup_call` | 85-208 | 断连兜底；注册表；默认「直接写本进程 socket」（实体 agent 里由 `entity.session` 换成「发给会话所在的 gate」）；唤醒等待中的 `call` | — |

### 下行

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.notify(conn, name, param)` | 258 | 主动推送（无回包） | — |
| `M.encode_notify(name, param)` | 264 | **只编码不发送**：会话层要先计数、入重放缓冲、再决定写不写网关——离线时它手上根本没有连接标识，走不了 `notify` | 字节串 |
| `M.call(fd, name, param, session, timeout)` | 268 | 客户端式请求-响应；`timeout` 默认取配置 `sproto_timeout`（10 秒） | 超时返回 `nil`；正常返回响应体 |
| `gen_response` / `dispatch`（见 `sproto_host`） | — | 回包闭包，负责按 request id 打头 | — |

## `sproto_host.lua`（95 行，sproto 打包/解包封装）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.new(sp, packagename)` | 33 | 建 host：持有 sproto 对象与包头名，维护「request id → 等待者」表 |
| `host:dispatch(...)` | 44 | 解一个包：`"REQUEST"`（协议名、请求体、回包函数、request id）/ `"RESPONSE"`（request id、响应体）；认不出的 id 返回 `nil`；协议名不存在返回 `"REQUEST", nil` |
| `host:attach()` | 78 | 返回打包函数 `(name, args, req_id) -> 字节`；带 `req_id` 时登记等待响应 |
| `gen_response(self, response, req_id)` | 21 | 回包闭包：有 `req_id` 就带头，否则只发型别字节 |

## `time.lua`（22 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.now()` | 6 | 秒级整数（`skynet.time() // 1`） |
| `M.time()` | 10 | 原样返回 `skynet.time()`（浮点秒，用于差值） |
| `M.now_ms()` | 14 | 毫秒整数 |
| `M.format(sec)` | 18 | `"YYYY-MM-DD HH:MM:SS"` |

**别用 `os.time()` 做游戏内计时**：`skynet.time()` 是框架的虚拟时钟，单测里可以快进。

## `timer.lua`（304 行，定时器）

设计：单个 min-heap（`skyext.binaryheap` 的唯一堆）+ 一个调度协程，按最近的到期时间 `sleep`；同一帧到期的堆一次性弹出，**单轮最多执行 `MAX_BATCH_EXEC` 个**，剩下的留到下一轮，避免长时间占用工作线程。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.timeout(name, sec, func)` | 231 | 单次定时器 | `func` 必须函数、`sec >= 0` |
| `M.repeat_immediately(name, sec, func, times)` | 243 | 立即开始的周期定时器；不给 `times` 则无限 | 同上 |
| `M.repeat_delayed(name, sec, func, times)` | 255 | 延迟一个周期后开始 | 同上 |
| `M.repeat_random_delayed(name, sec, func, times)` | 267 | 首次随机延迟（打散同时起跑的定时器） | `sec > 0` |
| `M.active_count()` | 278 | 存活定时器数 | — |
| `M.shutdown()` | 287 | 停掉调度协程 | — |
| `timer:cancel()` | 49 | 取消 | — |
| `timer:wakeup()` | 58 | 把到期时间提前到下一帧执行 | — |
| `timer:__tostring()` | 79 | `<timer object (name:…,id:…) at 0x…>` | — |
| `new_timer_obj` / `insert_timer_exec_time` / `insert_timer` / `update_timer` | 89-128 | 建对象（`name`/`sec`/`func`/`first`/`times`）、算下次到期、入堆、按 `generation` 重建堆 | — |
| `minheap_pop_exec(generation)` | 152 | 弹出到期定时器并执行；`xpcall` 包住；回调耗时超阈值打 `timer callback too slow` | — |
| `do_sleep` / `ensure_init` / `do_wakeup` / `new_timer_id` | 30-177 | 调度协程主体：睡到最近到期；堆被改过就 `wakeup` 重算；过载超阈值打日志 | — |

## `util/fs.lua`（176 行，文件系统）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.join(...)` | 10 | 拼路径（按平台选分隔符，`native` 负责转换） | — |
| `M.absolute(path)` | 26 | 相对路径补上 `lfs.currentdir()` | 已是绝对路径原样返回 |
| `M.mode(path)` | 34 | `file` / `directory` / `link` / `nil`（`lfs.symlinkattributes`） | — |
| `M.mkdir(path)` | 38 | **递归建目录**（逐级建到根） | 父盘不存在报 `drive not found`；建完仍不是目录则断言失败 |
| `M.entries(path)` | 57 | 列目录项（排除 `.`/`..`，按名字排序） | — |
| `M.walk(root, accept)` | 68 | 递归遍历；`accept` 过滤；**符号链接必须指向同目录内的普通文件**，越界或指向目录都断言失败 | 不支持的类型直接断言 |
| `M.read(path)` / `M.write(path, data)` | 94 / 102 | 二进制读写，全断言（读不到、写不进、关不掉都抛） | — |
| `M.copy(source, target)` | 110 | 分块拷贝 | — |
| `M.copy_tree(source, target, accept)` | 127 | 递归拷贝目录 | `source` 必须是目录 |
| `M.remove_tree(path)` | 140 | 递归删除 | — |
| `M.temporary_dir(base)` | 152 | 建临时目录：`base` 取 `TMPDIR`/`TEMP`/`TMP`/当前目录，名字 `skyext-<时间>-<随机>`，**最多试 100 次** | 全失败 `error("cannot create a temporary directory in …")` |
| `M.with_dir(path, fn)` | 165 | 切到该目录执行 `fn`，**无论成败都切回** | `fn` 抛错时原样重抛 |
| `native(path)` | 6 | 把 `/` 和 `\` 统一成平台分隔符 | — |

注意：只有 `join`/`absolute`/`mkdir` 走 `native` 转换，`mode`/`entries`/`read`/`write`/`copy`/`with_dir` 直接用 `lfs.*` 与 `io.*`。

## `util/io.lua`（31 行）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.readfile(file)` | 6 | 二进制读整个文件 | 内容；失败 `nil, err`（**不抛错**） |
| `M.writefile(file, data)` | 21 | 覆盖写 | `true` / `false` |

与 `fs.read`/`fs.write` 的区别：这里失败返回而不是断言——调用方要自己判断（`hotfix_checksum` 就是靠这个给出「文件读不到」的报错）。

## `util/path.lua`（46 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.join(...)` | 10 | 跨平台拼路径：过滤空片段、按平台分隔符连接；全部为空返回 `""` |

与 `fs.join` 的分工：`path.join` 只做字符串拼接（不碰 `lfs`），`fs.join` 在拼接之外会把分隔符转成本地形式。

## `util/string.lua`（24 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.fromhex(str)` | 3 | 十六进制串 → 字节串 |
| `M.tohex(str)` | 9 | 字节串 → 大写十六进制 |
| `M.split(s, delim)` | 15 | 按分隔符切分（返回数组） |

## `util/table.lua`（168 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.deepcopy(orig, copies)` | 4 | 深拷贝，`copies` 记录已拷贝的表以处理共享引用 | 有环时按引用复用，不会无限递归 |
| `M.keys(data)` / `M.values(data)` | 24 / 47 | 键 / 值列表（`values` 不是深拷贝） | — |
| `M.size(data)` | 35 | 表长度（数组部分） | 空表 0 |
| `M.clear(t)` | 57 | 清空 | — |
| `M.merge(t1, t2)` | 63 | 合并（`t2` 覆盖 `t1`） | — |
| `M.tostring(tbl)` | 152 | 把表渲染成可读字符串（嵌套缩进、按 key 排序、带引用标记） | — |
| `M.tostring_tbl(tbl, result, seen)` / `M.concat_tostring_tbl(result)` | 122 / 147 | 分步版本：先累积片段再 `table.concat` | — |
| `M.in_array(tbl, check_value)` | 160 | 值是否在数组里，返回下标或 `nil` | — |
| `append_result` / `val_to_str` / `key_to_str` | 75-112 | 渲染内部：处理循环引用（`<ref:…>`）、字符串/数字/布尔、函数与 userdata | — |
