# 路由配置说明（GitOps 管理）

## 文件说明

| 文件              | 说明                            |
|-------------------|---------------------------------|
| `upstreams.yaml`  | 上游服务节点定义（先同步）      |
| `services.yaml`   | 服务定义，复用上游 + 公共插件   |
| `consumers.yaml`  | API 消费者 + 认证凭据           |
| `routes.yaml`     | 路由规则（最后同步）            |

## 同步顺序（重要）

```
upstreams → services → consumers → routes
```

## 手动同步

```bash
make sync-routes
```

## 单独操作某条路由

```bash
# 查询
curl http://localhost:9180/apisix/admin/routes \
  -H "X-API-KEY: $APISIX_ADMIN_KEY"

# 更新
curl -X PUT http://localhost:9180/apisix/admin/routes/route-user-service-v1 \
  -H "X-API-KEY: $APISIX_ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d @- < routes/routes.yaml
```
