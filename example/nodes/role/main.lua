-- 逻辑节点：承载实体。示例里同时带一个 gate（同进程部署），玩家连哪个节点的 gate 都能进游戏，
-- 实体落在哪个节点由实体系统决定。只做逻辑节点时去掉 gate_port 配置即可
--
-- 启动顺序是硬约束：
--   1. 基础设施（metrics / GM / 停服编排 / 区服目录 / Mongo 索引门禁）
--   2. 实体系统，等每个类型 READY
--   3. 依赖实体路由的后台服务（Outbox、关键账本维护、支付回调、迁移协调器）
--   4. 网关，最后才开放客户端接入
-- 反过来（先起调度器或先开端口）会让后台任务扫不到 owner、玩家在实体就绪前进来。
local skynet = require "skynet"
local config = require "skyext.config"
local log = require "skyext.log"
local launcher = require "launcher"

skynet.start(function()
    log.info("role start begin")
    launcher.launcher_node()
    launcher.launcher_entities({ "role", "rank" })
    -- 示例运营命令（发系统邮件），依赖实体系统
    skynet.newservice("admin")
    launcher.launch_optional_services()
    if config.get("gate_port") then
        launcher.launcher_gate()
    end
    log.info("role start finished")
    skynet.exit()
end)
