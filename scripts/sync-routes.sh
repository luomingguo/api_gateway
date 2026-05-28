#!/bin/bash
# ============================================================
# 路由同步脚本
# 将 routes/ 目录下的 YAML 声明同步到 APISIX Admin API
# 同步顺序：upstreams → services → consumers → routes
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/.env" 2>/dev/null || true

ADMIN_URL="http://localhost:${CP_ADMIN_PORT:-9180}"
API_KEY="${APISIX_ADMIN_KEY:?"缺少 APISIX_ADMIN_KEY 环境变量"}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── 工具函数 ────────────────────────────────────────────────

# 将 YAML 中的单条记录 PUT 到 Admin API
sync_resource() {
    local resource_type="$1"  # routes / upstreams / services / consumers
    local id="$2"
    local payload="$3"

    local url="$ADMIN_URL/apisix/admin/${resource_type}/${id}"
    local resp
    resp=$(curl -sf -X PUT "$url" \
        -H "X-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        echo -e "  ${RED}❌ 同步失败 [$resource_type/$id]${NC}: $resp"
        return 1
    }
    echo -e "  ${GREEN}✅ ${resource_type}/${id}${NC}"
}

# 用 python3 解析 YAML 并逐条调用 sync_resource
sync_yaml_file() {
    local resource_type="$1"
    local yaml_file="$2"
    local top_key="$3"    # YAML 文件中的顶层 key，如 routes / upstreams

    if [ ! -f "$yaml_file" ]; then
        echo -e "${YELLOW}⚠️  $yaml_file 不存在，跳过${NC}"
        return
    fi

    echo -e "${YELLOW}── 同步 $resource_type ($yaml_file) ──${NC}"

    # 用 Python 解析 YAML → JSON，逐条同步
    python3 - <<EOF
import yaml, json, subprocess, sys

with open("$yaml_file") as f:
    data = yaml.safe_load(f)

items = data.get("$top_key", [])
if not items:
    print("  (空，无需同步)")
    sys.exit(0)

for item in items:
    item_id = item.get("id")
    if not item_id:
        print(f"  ⚠️  记录缺少 id 字段，跳过: {item}")
        continue

    # consumers 用 username 作为 id
    if "$resource_type" == "consumers":
        item_id = item.get("username", item_id)

    payload = json.dumps(item)
    result = subprocess.run(
        ["bash", "$SCRIPT_DIR/sync-routes.sh", "--single",
         "$resource_type", item_id, payload],
        capture_output=True, text=True
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        print(result.stderr, end="", file=sys.stderr)
        sys.exit(1)
EOF
}

# ── 单条同步模式（被 Python 子进程调用）─────────────────────
if [ "${1:-}" = "--single" ]; then
    sync_resource "$2" "$3" "$4"
    exit $?
fi

# ── 主流程：按顺序同步全部资源 ──────────────────────────────
echo ""
echo -e "${GREEN}🚀 开始同步路由配置到 $ADMIN_URL${NC}"
echo ""

sync_yaml_file "upstreams" "$ROOT_DIR/routes/upstreams.yaml" "upstreams"
sync_yaml_file "services"  "$ROOT_DIR/routes/services.yaml"  "services"
sync_yaml_file "consumers" "$ROOT_DIR/routes/consumers.yaml" "consumers"
sync_yaml_file "routes"    "$ROOT_DIR/routes/routes.yaml"    "routes"

echo ""
echo -e "${GREEN}✅ 路由同步完成${NC}"
