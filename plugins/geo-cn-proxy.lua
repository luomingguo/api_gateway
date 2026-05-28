apisix:
  config_provider: yaml      # Standalone 模式关键配置

plugins:
  # 官方插件按需开启
  - jwt-auth
  - limit-req
  - ip-restriction
  - geoip2
  - prometheus
  - request-id
  # 你的自定义插件，文件名即插件名
  - geo-cn-proxy
  - tenant-ratelimit
  - ai-response-cache

plugin_attr:
  prometheus:
    export_uri: /metrics
    export_addr:
      ip: "0.0.0.0"
      port: 9091
apisix/plugins/geo-cn-proxy.lua — 一个完整的自定义插件骨架：
lua-- geo-cn-proxy: 境内 IP 识别后切换到境内 upstream
local plugin_name = "geo-cn-proxy"

local schema = {
    type = "object",
    properties = {
        cn_upstream = { type = "string" },   -- 境内 upstream id
    },
    required = { "cn_upstream" },
}

local _M = {
    version = 0.1,
    priority = 1010,   -- 数字越大越先执行
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return require("apisix.core").schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local core = require("apisix.core")
    local geoip2 = require("resty.geoip2")

    local client_ip = core.request.get_ip(ctx)
    local country = geoip2.lookup(client_ip, "country", "iso_code")

    if country == "CN" then
        -- 切换到境内 upstream
        ctx.picked_server = nil
        ctx.upstream_id = conf.cn_upstream
        core.log.info("CN IP detected, routing to: ", conf.cn_upstream)
    end
end

return _M