#!/bin/bash
# etcd 路由配置备份
# 用法：bash scripts/backup.sh [output_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/.env" 2>/dev/null || true

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT="${1:-$ROOT_DIR/backups/routes-$TIMESTAMP.json}"
ADMIN_URL="http://localhost:${CP_ADMIN_PORT:-9180}"
API_KEY="${APISIX_ADMIN_KEY:?"缺少 APISIX_ADMIN_KEY"}"

mkdir -p "$(dirname "$OUTPUT")"

echo "📦 备份 APISIX 路由配置..."

python3 - <<EOF
import urllib.request, json, os

base = "$ADMIN_URL/apisix/admin"
headers = {"X-API-KEY": "$API_KEY"}
resources = ["routes", "upstreams", "services", "consumers", "global_rules", "plugin_configs"]

backup = {}
for res in resources:
    url = f"{base}/{res}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            backup[res] = json.loads(resp.read())
            print(f"  ✅ {res}: {backup[res].get('total', '?')} 条")
    except Exception as e:
        print(f"  ⚠️  {res} 跳过: {e}")
        backup[res] = {}

with open("$OUTPUT", "w") as f:
    json.dump(backup, f, ensure_ascii=False, indent=2)

print(f"\n✅ 备份完成: $OUTPUT")
EOF
