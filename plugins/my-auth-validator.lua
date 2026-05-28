-- ============================================================
-- 自定义插件示例：my-auth-validator
-- 功能：在标准 key-auth 之外，额外校验请求头中的 X-App-ID
-- 放置路径：plugins/my-auth-validator.lua
-- 在 config.yaml 中注册：- custom/my-auth-validator
-- ============================================================

local core        = require("apisix.core")
local plugin_name = "my-auth-validator"

-- 插件 Schema（定义路由/服务上的配置项）
local schema = {
    type = "object",
    properties = {
        app_id = {
            type        = "string",
            description = "允许访问的 App ID（多个用逗号分隔）",
            default     = ""
        },
        header_name = {
            type        = "string",
            description = "携带 App ID 的请求头名称",
            default     = "X-App-ID"
        },
        reject_code = {
            type        = "integer",
            description = "拒绝时返回的 HTTP 状态码",
            default     = 403
        }
    },
    required = {"app_id"}
}

local _M = {
    version  = 0.1,
    priority = 2510,    -- 优先级高于 key-auth(2500)，先执行
    name     = plugin_name,
    schema   = schema,
}

-- 校验插件配置（可选，APISIX 会在保存路由时调用）
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- 请求阶段：在此处执行鉴权逻辑
function _M.access(conf, ctx)
    local header_name = conf.header_name or "X-App-ID"
    local app_id      = core.request.header(ctx, header_name)

    -- 未携带 App ID
    if not app_id or app_id == "" then
        core.log.warn("my-auth-validator: missing header ", header_name)
        return conf.reject_code or 403, { message = "Missing " .. header_name }
    end

    -- 校验 App ID 是否在白名单中
    local allowed = {}
    for id in string.gmatch(conf.app_id, "([^,]+)") do
        allowed[core.utils.trim(id)] = true
    end

    if not allowed[app_id] then
        core.log.warn("my-auth-validator: invalid app_id=", app_id)
        return conf.reject_code or 403, { message = "Invalid " .. header_name }
    end

    -- 鉴权通过：将 App ID 写入上下文，供后续插件/日志使用
    ctx.app_id = app_id
    core.log.info("my-auth-validator: authorized app_id=", app_id)
end

return _M
