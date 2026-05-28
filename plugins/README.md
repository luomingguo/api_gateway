# 自定义插件开发指南

## 目录结构

```
plugins/
├── my-auth-validator.lua       # 示例：自定义鉴权插件
├── request-id-enhancer.lua     # 示例：请求 ID 注入
├── your-plugin.lua             # 新插件放这里
└── tests/
    └── test-your-plugin.lua    # 对应的测试文件
```

## 开发新插件

1. 在 `plugins/` 目录下创建 `your-plugin.lua`
2. 在 `control-plane/conf/config.yaml` 和 `data-plane/conf/config.yaml` 的 `plugins` 列表中添加 `- custom/your-plugin`
3. 执行 `make plugin-reload` 热重载（无需重启 APISIX）

## 插件注册到路由

```bash
# 通过 Admin API 为路由添加自定义插件
curl -X PUT http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $APISIX_ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "uri": "/api/v1/*",
    "plugins": {
      "my-auth-validator": {
        "app_id": "app-001,app-002",
        "header_name": "X-App-ID"
      }
    },
    "upstream_id": "upstream-backend"
  }'
```

## 插件优先级参考

| 插件                  | 优先级  |
|-----------------------|---------|
| real-ip               | 23000   |
| request-id-enhancer   | 12015   |
| ip-restriction        | 3000    |
| my-auth-validator     | 2510    |
| key-auth              | 2500    |
| limit-req             | 1001    |
| cors                  | 4000    |
| proxy-rewrite         | 1008    |

数字越大，越先执行。
