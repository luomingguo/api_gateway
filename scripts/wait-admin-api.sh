#!/bin/bash
# 等待 APISIX Admin API 就绪
set -euo pipefail

source "$(dirname "$0")/../.env" 2>/dev/null || true

ADMIN_URL="http://localhost:${CP_ADMIN_PORT:-9180}"
API_KEY="${APISIX_ADMIN_KEY:-}"
TIMEOUT=60
ELAPSED=0

echo "⏳ 等待 Admin API 就绪：$ADMIN_URL"

while true; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "X-API-KEY: $API_KEY" \
        "$ADMIN_URL/apisix/admin/routes" 2>/dev/null || echo "000")

    if [ "$CODE" = "200" ]; then
        echo "✅ Admin API 就绪"
        exit 0
    fi

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "❌ Admin API 超时（${TIMEOUT}s），HTTP $CODE"
        exit 1
    fi

    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo "   ... ${ELAPSED}s  HTTP $CODE"
done
