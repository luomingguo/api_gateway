# APISIX Project

控制面与数据面分离部署，统一管理插件开发、路由配置与版本升级。

## 架构概览

```
外部流量  ──────────▶  数据面（apisix-dp）  ◀──etcd同步── 控制面（apisix-cp）
                       只转发，无 Admin API              Admin API + Dashboard

本地开发               dev/ 中的 etcd + Prometheus + Grafana
生产环境               外部 etcd（通过 .env 配置）+ 外部 Prometheus/Grafana
```

## 项目结构

```
.
├── control-plane/           控制面（Admin API + Dashboard）
│   ├── docker-compose.yml   生产模式（外部 etcd）
│   ├── docker-compose.dev.yml  开发覆盖层（本地 etcd）
│   └── conf/
│       ├── config.yaml      APISIX 配置
│       └── dashboard/       Dashboard 配置
├── data-plane/              数据面（流量网关）
│   ├── docker-compose.yml
│   ├── docker-compose.dev.yml
│   └── conf/config.yaml
├── dev/                     本地开发基础设施
│   ├── docker-compose.yml   etcd + Prometheus + Grafana
│   └── prometheus.yml
├── plugins/                 自定义 Lua 插件
│   ├── my-auth-validator.lua
│   ├── request-id-enhancer.lua
│   └── tests/
├── routes/                  路由声明（GitOps，通过 sync-routes.sh 同步）
│   ├── routes.yaml
│   ├── upstreams.yaml
│   ├── services.yaml
│   └── consumers.yaml
├── scripts/                 运维脚本
├── tests/                   自动化测试
│   ├── run-tests.sh         测试入口（自带 etcd，无需外部依赖）
│   ├── conf/                测试专用 APISIX 配置
│   └── docker-compose.test.yml
└── Makefile                 统一操作入口
```

## 快速开始

### 1. 初始化配置

```bash
cp .env.example .env
# 编辑 .env，填写密钥和生产 etcd 地址
```

### 2. 本地开发（一键启动）

```bash
make all-up          # 启动 dev etcd + 控制面 + 数据面
make status          # 查看服务状态
```

访问：
- **Dashboard**: http://localhost:9000
- **Admin API**: http://localhost:9180
- **网关 HTTP**: http://localhost:9080
- **Grafana**: http://localhost:3000 (admin/admin)

### 3. 同步路由

```bash
# 编辑 routes/ 目录下的 YAML 文件后：
make sync-routes
```

### 4. 开发自定义插件

```bash
# 1. 在 plugins/ 下新建 your-plugin.lua
# 2. 在 control-plane/conf/config.yaml 和 data-plane/conf/config.yaml 添加插件名
# 3. 热重载（无需重启）
make plugin-reload
```

### 5. 运行自动化测试

```bash
make test                         # 全部测试（自动启动独立测试环境）
bash tests/run-tests.sh smoke     # 只跑冒烟
bash tests/run-tests.sh --no-cleanup  # 失败时保留环境调试
```

### 6. 升级版本

```bash
make upgrade V=3.17.0   # 自动备份 → 拉镜像 → 滚动升级 → 健康检查
```

## 生产部署

生产环境 etcd、Prometheus、Grafana 均为外部服务，在 `.env` 中配置连接地址：

```ini
ETCD_HOSTS=http://10.0.1.10:2379,http://10.0.1.11:2379,http://10.0.1.12:2379
CP_ETCD_HOSTS=http://10.0.1.10:2379,http://10.0.1.11:2379,http://10.0.1.12:2379
PROMETHEUS_HOST=10.0.2.5
```

部署顺序：

```bash
make cp-up ENV=prod    # 1. 启动控制面（连接外部 etcd）
make sync-routes       # 2. 同步路由配置
make dp-up ENV=prod    # 3. 启动数据面
```

## 端口说明

| 服务              | 端口  | 说明                    |
|-------------------|-------|-------------------------|
| 控制面 Admin API  | 9180  | 仅内网访问              |
| Dashboard         | 9000  | 仅内网访问              |
| 控制面 Metrics    | 9191  | Prometheus 抓取         |
| 数据面 HTTP       | 9080  | 对外                    |
| 数据面 HTTPS      | 9443  | 对外                    |
| 数据面 Metrics    | 9192  | Prometheus 抓取         |
| dev etcd          | 2379  | 开发环境                |
| dev Prometheus    | 9090  | 开发环境                |
| dev Grafana       | 3000  | 开发环境                |
