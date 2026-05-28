#!/bin/bash
# 等待 Docker 容器进入 healthy 状态
# 用法：bash scripts/wait-healthy.sh <container_name> <timeout_seconds>

set -euo pipefail

CONTAINER=${1:?"用法: wait-healthy.sh <container_name> <timeout>"}
TIMEOUT=${2:-60}
ELAPSED=0

echo "⏳ 等待容器 [$CONTAINER] 进入 healthy 状态（超时 ${TIMEOUT}s）..."

while true; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "not_found")

    case "$STATUS" in
        healthy)
            echo "✅ [$CONTAINER] 已就绪"
            exit 0
            ;;
        unhealthy)
            echo "❌ [$CONTAINER] 状态为 unhealthy，请检查日志："
            docker logs --tail 20 "$CONTAINER" 2>&1 || true
            exit 1
            ;;
        not_found)
            echo "❌ 容器 [$CONTAINER] 不存在"
            exit 1
            ;;
    esac

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "❌ 超时（${TIMEOUT}s），[$CONTAINER] 当前状态：$STATUS"
        exit 1
    fi

    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo "   ... ${ELAPSED}s / ${TIMEOUT}s  (状态: $STATUS)"
done
