#!/bin/bash
# 健康检查脚本
# 用法：bash scripts/health-check.sh [cp|dp|all]
set -euo pipefail

source "$(dirname "$0")/../.env" 2>/dev/null || true

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ADMIN_URL="http://localhost:${CP_ADMIN_PORT:-9180}"
DP_URL="http://localhost:${DP_HTTP_PORT:-9080}"
API_KEY="${APISIX_ADMIN_KEY:-}"

check_cp() {
    echo -e "${YELLOW}── 控制面健康检查 ──${NC}"
    CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "X-API-KEY: $API_KEY" \
        "$ADMIN_URL/apisix/admin/routes" 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ]; then
        echo -e "  Admin API     ${GREEN}✅ 正常${NC} ($ADMIN_URL)"
    else
        echo -e "  Admin API     ${RED}❌ 异常${NC} HTTP $CODE"
        return 1
    fi

    # 检查路由数量
    COUNT=$(curl -sf -H "X-API-KEY: $API_KEY" \
        "$ADMIN_URL/apisix/admin/routes" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo "?")
    echo -e "  已加载路由数    ${GREEN}$COUNT${NC}"
}

check_dp() {
    echo -e "${YELLOW}── 数据面健康检查 ──${NC}"
    CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        "$DP_URL/apisix/status" 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ]; then
        echo -e "  Gateway       ${GREEN}✅ 正常${NC} ($DP_URL)"
    else
        echo -e "  Gateway       ${RED}❌ 异常${NC} HTTP $CODE"
        return 1
    fi
}

TARGET=${1:-all}
case "$TARGET" in
    cp)  check_cp ;;
    dp)  check_dp ;;
    all) check_cp; check_dp ;;
    *)   echo "用法: health-check.sh [cp|dp|all]"; exit 1 ;;
esac
