# ============================================================
# APISIX Project Makefile
# ============================================================
# 用法：
#   make dev-up          本地开发环境（含 etcd / prometheus / grafana）
#   make cp-up           启动控制面
#   make dp-up           启动数据面
#   make all-up          一键启动全部（dev 模式）
#   make all-down        停止全部
#   make upgrade V=3.16.0  升级版本
#   make sync-routes     同步 routes/ 到 Admin API
#   make test            运行自动化测试
#   make plugin-reload   热重载自定义插件
# ============================================================

SHELL := /bin/bash
ENV   ?= dev

# 加载 .env（如存在）
ifeq ($(wildcard .env),)
    ifneq ($(wildcard .env.example),)
        $(shell cp .env.example .env)
    endif
endif

# 2. 引入 .env 变量
-include .env
ifndef APISIX_VERSION
    APISIX_DISTRO := $(shell \
        if [ -r /etc/lsb-release ]; then \
            . /etc/lsb-release; \
            echo "$${DISTRIB_ID:-debian}" | tr '[:upper:]' '[:lower:]'; \
        elif [ -r /etc/os-release ]; then \
            . /etc/os-release; \
            echo "$${ID:-debian}" | tr '[:upper:]' '[:lower:]'; \
        else \
            echo "debian"; \
        fi)
    APISIX_VERSION := 3.16.0-$(APISIX_DISTRO)
endif
export APISIX_VERSION
export


# Docker Compose 文件
CP_COMPOSE  = control-plane/docker-compose.yml
DP_COMPOSE  = data-plane/docker-compose.yml
DEV_COMPOSE = dev/docker-compose.yml

# 颜色输出
GREEN  = \033[0;32m
YELLOW = \033[1;33m
RED    = \033[0;31m
NC     = \033[0m

.PHONY: help dev-up dev-down cp-up cp-down dp-up dp-down \
        all-up all-down upgrade sync-routes backup restore \
        test plugin-reload logs-cp logs-dp status

# ── 帮助 ────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  $(GREEN)APISIX Project 操作手册$(NC)"
	@echo ""
	@echo "  $(YELLOW)开发环境$(NC)"
	@echo "    make dev-up          启动本地基础设施（etcd / prometheus / grafana）"
	@echo "    make dev-down        停止本地基础设施"
	@echo ""
	@echo "  $(YELLOW)控制面$(NC)"
	@echo "    make cp-up           启动控制面（依赖 dev-up 或生产 etcd）"
	@echo "    make cp-down         停止控制面"
	@echo "    make cp-logs         查看控制面日志"
	@echo ""
	@echo "  $(YELLOW)数据面$(NC)"
	@echo "    make dp-up           启动数据面"
	@echo "    make dp-down         停止数据面"
	@echo "    make dp-logs         查看数据面日志"
	@echo "    make dp-scale N=3    数据面扩缩容"
	@echo ""
	@echo "  $(YELLOW)一键操作$(NC)"
	@echo "    make all-up          启动所有（dev 模式）"
	@echo "    make all-down        停止所有"
	@echo "    make status          查看所有服务状态"
	@echo ""
	@echo "  $(YELLOW)版本管理$(NC)"
	@echo "    make upgrade V=3.16.0  升级 APISIX 版本"
	@echo ""
	@echo "  $(YELLOW)路由 / 插件$(NC)"
	@echo "    make sync-routes     同步 routes/ 目录到 Admin API"
	@echo "    make plugin-reload   热重载自定义插件"
	@echo ""
	@echo "  $(YELLOW)运维$(NC)"
	@echo "    make backup          备份 etcd 配置"
	@echo "    make test            运行自动化测试套件"
	@echo ""

# ── 前置检查 ────────────────────────────────────────────────
check-env:
	@if [ ! -f .env ]; then \
		echo "$(RED)错误：.env 文件不存在$(NC)"; \
		echo "请执行：cp .env.example .env 并填写配置"; \
		exit 1; \
	fi

# ── 开发基础设施（etcd + prometheus + grafana）──────────────
dev-up: check-env
	@echo "$(GREEN)=== 启动开发基础设施 ===$(NC)"
	docker compose -f $(DEV_COMPOSE) up -d
	@bash scripts/wait-healthy.sh "apisix-dev-etcd" 30
	@echo "$(GREEN)✅ 开发基础设施就绪$(NC)"
	@echo "   etcd:       http://localhost:2379"
	@echo "   Prometheus: http://localhost:9090"
	@echo "   Grafana:    http://localhost:3000  (admin/admin)"

dev-down:
	docker compose -f $(DEV_COMPOSE) down

# ── 控制面 ──────────────────────────────────────────────────
cp-up: check-env
	@echo "$(GREEN)=== 启动控制面 ===$(NC)"
	@if [ "$(ENV)" = "dev" ]; then \
		docker compose -f $(CP_COMPOSE) -f control-plane/docker-compose.dev.yml up -d; \
	else \
		docker compose -f $(CP_COMPOSE) up -d; \
	fi
	@bash scripts/wait-admin-api.sh
	@echo "$(GREEN)✅ 控制面就绪$(NC)"
	@echo "   Admin API:  http://localhost:$(CP_ADMIN_PORT:-9180)/apisix/admin"
	@echo "   Dashboard:  http://localhost:$(DASHBOARD_PORT:-9000)"

cp-down:
	@if [ "$(ENV)" = "dev" ]; then \
		docker compose -f $(CP_COMPOSE) -f control-plane/docker-compose.dev.yml down; \
	else \
		docker compose -f $(CP_COMPOSE) down; \
	fi

cp-logs:
	@if [ "$(ENV)" = "dev" ]; then \
		docker compose -f $(CP_COMPOSE) -f control-plane/docker-compose.dev.yml logs -f apisix-cp; \
	else \
		docker compose -f $(CP_COMPOSE) logs -f apisix-cp; \
	fi

# ── 数据面 ──────────────────────────────────────────────────
dp-up: check-env
	@echo "$(GREEN)=== 启动数据面 ===$(NC)"
	@bash scripts/health-check.sh cp
	@if [ "$(ENV)" = "dev" ]; then \
		docker compose -f $(DP_COMPOSE) -f data-plane/docker-compose.dev.yml up -d; \
	else \
		docker compose -f $(DP_COMPOSE) up -d; \
	fi
	@bash scripts/health-check.sh dp
	@echo "$(GREEN)✅ 数据面就绪$(NC)"
	@echo "   HTTP:  http://localhost:$(DP_HTTP_PORT:-9080)"
	@echo "   HTTPS: https://localhost:$(DP_HTTPS_PORT:-9443)"

dp-down:
	@if [ "$(ENV)" = "dev" ]; then \
		docker compose -f $(DP_COMPOSE) -f data-plane/docker-compose.dev.yml down; \
	else \
		docker compose -f $(DP_COMPOSE) down; \
	fi

dp-logs:
	@if [ "$(ENV)" = "dev" ]; then \
		docker compose -f $(DP_COMPOSE) -f data-plane/docker-compose.dev.yml logs -f apisix-dp; \
	else \
		docker compose -f $(DP_COMPOSE) logs -f apisix-dp; \
	fi

dp-scale:
	@N=$(or $(N),2); \
	docker compose -f $(DP_COMPOSE) up -d --scale apisix-dp=$$N

# ── 一键操作 ────────────────────────────────────────────────
all-up: dev-up cp-up dp-up
	@echo ""
	@echo "$(GREEN)🚀 全部服务启动完成$(NC)"
	@make status

all-down: dp-down cp-down dev-down

status:
	@echo "$(YELLOW)=== 控制面 ===$(NC)"
	@docker compose -f $(CP_COMPOSE) ps 2>/dev/null || true
	@echo ""
	@echo "$(YELLOW)=== 数据面 ===$(NC)"
	@docker compose -f $(DP_COMPOSE) ps 2>/dev/null || true
	@echo ""
	@echo "$(YELLOW)=== 开发基础设施 ===$(NC)"
	@docker compose -f $(DEV_COMPOSE) ps 2>/dev/null || true

# ── 版本升级 ─────────────────────────────────────────────────
upgrade:
	@if [ -z "$(V)" ]; then echo "$(RED)请指定版本：make upgrade V=3.16.0$(NC)"; exit 1; fi
	@bash scripts/upgrade.sh $(V)

# ── 路由同步 ─────────────────────────────────────────────────
sync-routes: check-env
	@bash scripts/sync-routes.sh

# ── 插件热重载 ───────────────────────────────────────────────
plugin-reload:
	@echo "$(GREEN)=== 热重载插件 ===$(NC)"
	@ADMIN_URL="http://localhost:$${CP_ADMIN_PORT:-9180}"; \
	curl -s -X PUT "$$ADMIN_URL/apisix/admin/plugins/reload" \
		-H "X-API-KEY: $${APISIX_ADMIN_KEY}" | python3 -m json.tool || true
	@echo "$(GREEN)✅ 插件已重载$(NC)"

# ── 备份 ─────────────────────────────────────────────────────
backup:
	@bash scripts/backup.sh

# ── 测试 ─────────────────────────────────────────────────────
test:
	@bash tests/run-tests.sh
