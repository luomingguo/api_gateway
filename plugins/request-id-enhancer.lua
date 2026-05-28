-- ============================================================
-- 自定义插件示例：request-id-enhancer
-- 功能：为每个请求注入全局唯一 ID，并附加到响应头
-- ============================================================

local core        = require("apisix.core")
local uuid        = require("resty.jit-uuid")
local plugin_name = "request-id-enhancer"

local schema = {
    type = "object",
    properties = {
        request_id_header = {
            type    = "string",
            default = "X-Request-ID"
        },
        include_in_response = {
            type    = "boolean",
            default = true
        }
    }
}

local _M = {
    version  = 0.1,
    priority = 12015,
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local request_id = core.request.header(ctx, conf.request_id_header)

    -- 如果上游没传 Request-ID，则自动生成
    if not request_id or request_id == "" then
        uuid.seed()
        request_id = uuid.generate_v4()
        core.request.set_header(ctx, conf.request_id_header, request_id)
    end

    ctx.request_id = request_id
end

function _M.header_filter(conf, ctx)
    if conf.include_in_response and ctx.request_id then
        core.response.set_header(conf.request_id_header, ctx.request_id)
    end
end

return _M
