#!/bin/bash
# ============================================================
# APISIX 版本升级脚本
# 用法：bash scripts/upgrade.sh <new_version>
# 示例：bash scripts/upgrade.sh 3.16.0
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/.env" 2>/dev/null || true

NEW_VERSION="${1:?"用法: upgrade.sh <version>，例如: upgrade.sh 3.16.0"}"
CURRENT_VERSION="${APISIX_VERSION:-unknown}"

get_distro_suffix() {
    if [ -r /etc/lsb-release ]; then
        # shellcheck disable=SC1091
        . /etc/lsb-release
        echo "${DISTRIB_ID:-debian}" | tr '[:upper:]' '[:lower:]'
    elif [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-debian}" | tr '[:upper:]' '[:lower:]'
    else
        echo "debian"
    fi
}

DISTRO_SUFFIX="$(get_distro_suffix)"
TARGET_VERSION="${NEW_VERSION}-${DISTRO_SUFFIX}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$ROOT_DIR/backups/$TIMESTAMP"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${GREEN}🔄 APISIX 升级：$CURRENT_VERSION → $TARGET_VERSION${NC}"
echo ""

# ── Step 1: 备份 ─────────────────────────────────────────────
echo -e "${YELLOW}[1/5] 备份当前配置...${NC}"
mkdir -p "$BACKUP_DIR"
cp -r "$ROOT_DIR/control-plane/conf" "$BACKUP_DIR/control-plane-conf"
cp -r "$ROOT_DIR/data-plane/conf"    "$BACKUP_DIR/data-plane-conf"
cp "$ROOT_DIR/.env"                  "$BACKUP_DIR/.env.backup" 2>/dev/null || true

# 备份 etcd 中的路由配置
echo "  备份 etcd 路由..."
bash "$SCRIPT_DIR/backup.sh" "$BACKUP_DIR/etcd-routes.json" 2>/dev/null \
    && echo -e "  ${GREEN}✅ 配置已备份到 $BACKUP_DIR${NC}" \
    || echo -e "  ${YELLOW}⚠️  etcd 备份跳过（可能服务未运行）${NC}"

# ── Step 2: 拉取新镜像 ───────────────────────────────────────
echo -e "${YELLOW}[2/5] 拉取新版本镜像...${NC}"
docker pull "apache/apisix:${TARGET_VERSION}"
echo -e "  ${GREEN}✅ 镜像拉取完成${NC}"

# ── Step 3: 更新版本号 ───────────────────────────────────────
echo -e "${YELLOW}[3/5] 更新 .env 版本号...${NC}"
if grep -q "^APISIX_VERSION=" "$ROOT_DIR/.env" 2>/dev/null; then
    sed -i.bak "s/^APISIX_VERSION=.*/APISIX_VERSION=${TARGET_VERSION}/" "$ROOT_DIR/.env"
else
    echo "APISIX_VERSION=${TARGET_VERSION}" >> "$ROOT_DIR/.env"
fi
echo -e "  ${GREEN}✅ APISIX_VERSION=${TARGET_VERSION}${NC}"

# ── Step 4: 滚动升级（先升控制面，再升数据面）───────────────
echo -e "${YELLOW}[4/5] 滚动升级服务...${NC}"

# 先升级控制面
echo "  升级控制面..."
docker compose -f "$ROOT_DIR/control-plane/docker-compose.yml" \
    pull apisix-cp 2>/dev/null || true
docker compose -f "$ROOT_DIR/control-plane/docker-compose.yml" \
    up -d --no-deps apisix-cp

echo "  等待控制面就绪..."
bash "$SCRIPT_DIR/wait-admin-api.sh"
echo -e "  ${GREEN}✅ 控制面升级完成${NC}"

# 再升级数据面
echo "  升级数据面..."
docker compose -f "$ROOT_DIR/data-plane/docker-compose.yml" \
    pull apisix-dp 2>/dev/null || true
docker compose -f "$ROOT_DIR/data-plane/docker-compose.yml" \
    up -d --no-deps apisix-dp

sleep 5

# ── Step 5: 健康检查 ─────────────────────────────────────────
echo -e "${YELLOW}[5/5] 健康检查...${NC}"
bash "$SCRIPT_DIR/health-check.sh" all

echo ""
echo -e "${GREEN}🎉 升级完成：$CURRENT_VERSION → $NEW_VERSION${NC}"
echo -e "   备份位置：$BACKUP_DIR"
echo ""
echo -e "如需回滚，执行："
echo -e "  bash scripts/upgrade.sh $CURRENT_VERSION"
