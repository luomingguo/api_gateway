#!/bin/bash
# ============================================================
# APISIX 自动化测试主入口
# 
# 功能：
#   1. 自动启动独立测试环境（etcd + CP + DP + Mock上游）
#   2. 运行冒烟测试和集成测试
#   3. 输出测试报告
#   4. 无论成功/失败，自动清理测试环境
#
# 用法：
#   bash tests/run-tests.sh              # 运行全部测试
#   bash tests/run-tests.sh smoke        # 只运行冒烟测试
#   bash tests/run-tests.sh integration  # 只运行集成测试
#   bash tests/run-tests.sh --no-cleanup # 失败时保留环境便于调试
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.test.yml"

# 测试参数
TEST_SUITE="${1:-all}"       # all | smoke | integration
NO_CLEANUP="${2:-}"          # --no-cleanup 时保留环境

# 测试环境配置（独立端口，不影响正在运行的开发环境）
export TEST_ADMIN_KEY="test-admin-key-for-testing-only"
export TEST_HTTP_PORT="19080"
export TEST_ADMIN_PORT="19180"
export TEST_ETCD_PORT="12379"
export APISIX_VERSION="${APISIX_VERSION:-3.16.0-debian}"

ADMIN_URL="http://localhost:$TEST_ADMIN_PORT"
GW_URL="http://localhost:$TEST_HTTP_PORT"

# ── 颜色 ────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── 测试统计 ─────────────────────────────────────────────────
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# ── 测试工具函数 ─────────────────────────────────────────────

# 断言：HTTP 状态码
assert_status() {
    local desc="$1"
    local expected="$2"
    local url="$3"
    shift 3
    local extra_args=("$@")

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    local actual
    actual=$(curl -sf -o /dev/null -w "%{http_code}" "${extra_args[@]}" "$url" 2>/dev/null || echo "000")

    if [ "$actual" = "$expected" ]; then
        echo -e "  ${GREEN}✅ PASS${NC} $desc (HTTP $actual)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}❌ FAIL${NC} $desc — 期望 HTTP $expected，实际 HTTP $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$desc")
    fi
}

# 断言：响应体包含指定字符串
assert_body_contains() {
    local desc="$1"
    local url="$2"
    local expected_str="$3"
    shift 3
    local extra_args=("$@")

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    local body
    body=$(curl -sf "${extra_args[@]}" "$url" 2>/dev/null || echo "CURL_FAILED")

    if echo "$body" | grep -q "$expected_str"; then
        echo -e "  ${GREEN}✅ PASS${NC} $desc (包含: $expected_str)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}❌ FAIL${NC} $desc — 响应中未找到: $expected_str"
        echo -e "       响应内容: $(echo "$body" | head -c 200)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$desc")
    fi
}

# 断言：响应头包含指定值
assert_header() {
    local desc="$1"
    local url="$2"
    local header_name="$3"
    shift 3
    local extra_args=("$@")

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    local headers
    headers=$(curl -sf -I "${extra_args[@]}" "$url" 2>/dev/null || echo "CURL_FAILED")

    if echo "$headers" | grep -qi "$header_name"; then
        echo -e "  ${GREEN}✅ PASS${NC} $desc (Header: $header_name 存在)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}❌ FAIL${NC} $desc — 响应头中未找到: $header_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$desc")
    fi
}

# Admin API 辅助：创建资源
admin_put() {
    local resource="$1"
    local id="$2"
    local payload="$3"
    curl -sf -X PUT "$ADMIN_URL/apisix/admin/${resource}/${id}" \
        -H "X-API-KEY: $TEST_ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null
}

# ── 环境管理 ─────────────────────────────────────────────────

start_test_env() {
    echo -e "${BLUE}${BOLD}🐳 启动测试环境...${NC}"
    docker compose -f "$COMPOSE_FILE" up -d

    echo "  等待 etcd..."
    local elapsed=0
    while ! docker exec apisix-test-etcd etcdctl \
            --endpoints=http://localhost:2379 endpoint health \
            > /dev/null 2>&1; do
        sleep 2; elapsed=$((elapsed+2))
        [ $elapsed -gt 60 ] && echo -e "${RED}etcd 启动超时${NC}" && exit 1
    done
    echo -e "  ${GREEN}✅ etcd 就绪${NC}"

    echo "  等待控制面..."
    elapsed=0
    while ! curl -sf "$ADMIN_URL/apisix/admin/routes" \
            -H "X-API-KEY: $TEST_ADMIN_KEY" > /dev/null 2>&1; do
        sleep 3; elapsed=$((elapsed+3))
        [ $elapsed -gt 90 ] && echo -e "${RED}控制面启动超时${NC}" && exit 1
    done
    echo -e "  ${GREEN}✅ 控制面就绪${NC}"

    echo "  等待数据面..."
    elapsed=0
    while ! curl -sf "$GW_URL/apisix/status" > /dev/null 2>&1; do
        sleep 2; elapsed=$((elapsed+2))
        [ $elapsed -gt 60 ] && echo -e "${RED}数据面启动超时${NC}" && exit 1
    done
    echo -e "  ${GREEN}✅ 数据面就绪${NC}"

    echo "  等待 Mock 上游..."
    elapsed=0
    while ! docker exec apisix-test-upstream \
            curl -sf http://localhost/status/200 > /dev/null 2>&1; do
        sleep 2; elapsed=$((elapsed+2))
        [ $elapsed -gt 30 ] && echo -e "${YELLOW}⚠️  Mock 上游未就绪，部分测试可能跳过${NC}" && break
    done
    echo ""
}

cleanup_test_env() {
    echo -e "${BLUE}🧹 清理测试环境...${NC}"
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    echo -e "  ${GREEN}✅ 清理完成${NC}"
}

# ── 测试 Fixtures（初始化测试数据）─────────────────────────

setup_fixtures() {
    echo -e "${YELLOW}── 初始化测试数据 ──${NC}"

    # 上游：指向 mock-upstream 容器
    admin_put "upstreams" "test-upstream" '{
        "id": "test-upstream",
        "type": "roundrobin",
        "nodes": {"mock-upstream:80": 1}
    }'
    echo -e "  ${GREEN}✅ 上游: test-upstream${NC}"

    # 基础路由（无鉴权）
    admin_put "routes" "test-basic-route" '{
        "id": "test-basic-route",
        "uri": "/test/basic/*",
        "upstream_id": "test-upstream",
        "plugins": {
            "proxy-rewrite": {"regex_uri": ["/test/basic/(.*)", "/$1"]}
        }
    }'
    echo -e "  ${GREEN}✅ 路由: test-basic-route${NC}"

    # 带 key-auth 的路由
    admin_put "consumers" "test-consumer" '{
        "username": "test-consumer",
        "plugins": {
            "key-auth": {"key": "test-api-key-12345"}
        }
    }'
    admin_put "routes" "test-auth-route" '{
        "id": "test-auth-route",
        "uri": "/test/auth/*",
        "upstream_id": "test-upstream",
        "plugins": {
            "key-auth": {},
            "proxy-rewrite": {"regex_uri": ["/test/auth/(.*)", "/$1"]}
        }
    }'
    echo -e "  ${GREEN}✅ 路由: test-auth-route (key-auth)${NC}"

    # 带限流的路由
    admin_put "routes" "test-ratelimit-route" '{
        "id": "test-ratelimit-route",
        "uri": "/test/ratelimit",
        "upstream_id": "test-upstream",
        "plugins": {
            "limit-count": {
                "count": 3,
                "time_window": 60,
                "rejected_code": 429,
                "key": "remote_addr"
            },
            "proxy-rewrite": {"uri": "/status/200"}
        }
    }'
    echo -e "  ${GREEN}✅ 路由: test-ratelimit-route (limit-count)${NC}"

    # 带自定义插件的路由
    admin_put "routes" "test-custom-plugin-route" '{
        "id": "test-custom-plugin-route",
        "uri": "/test/custom-auth",
        "upstream_id": "test-upstream",
        "plugins": {
            "my-auth-validator": {
                "app_id": "test-app-001",
                "header_name": "X-App-ID"
            },
            "request-id-enhancer": {
                "include_in_response": true
            },
            "proxy-rewrite": {"uri": "/status/200"}
        }
    }'
    echo -e "  ${GREEN}✅ 路由: test-custom-plugin-route (自定义插件)${NC}"

    # 带 CORS 的路由
    admin_put "routes" "test-cors-route" '{
        "id": "test-cors-route",
        "uri": "/test/cors",
        "upstream_id": "test-upstream",
        "plugins": {
            "cors": {
                "allow_origins": "https://test.example.com",
                "allow_methods": "GET,POST",
                "allow_headers": "Content-Type,X-App-ID"
            },
            "proxy-rewrite": {"uri": "/status/200"}
        }
    }'
    echo -e "  ${GREEN}✅ 路由: test-cors-route (cors)${NC}"

    # 等待数据面同步配置（etcd watch 延迟）
    echo "  等待数据面同步配置..."
    sleep 3
    echo ""
}

# ── 冒烟测试 ─────────────────────────────────────────────────

run_smoke_tests() {
    echo -e "${YELLOW}${BOLD}🔥 冒烟测试（基础功能验证）${NC}"
    echo ""

    # 1. 数据面存活检查
    echo -e "${BLUE}[1] 数据面状态${NC}"
    assert_status "数据面 /apisix/status 返回 200" "200" \
        "$GW_URL/apisix/status"

    # 2. 控制面 Admin API
    echo -e "${BLUE}[2] 控制面 Admin API${NC}"
    assert_status "Admin API 返回 200（含密钥）" "200" \
        "$ADMIN_URL/apisix/admin/routes" \
        -H "X-API-KEY: $TEST_ADMIN_KEY"
    assert_status "Admin API 无密钥返回 401" "401" \
        "$ADMIN_URL/apisix/admin/routes"

    # 3. 基础路由转发
    echo -e "${BLUE}[3] 路由转发${NC}"
    assert_status "基础路由转发 /test/basic/status/200" "200" \
        "$GW_URL/test/basic/status/200"
    assert_status "未注册路径返回 404" "404" \
        "$GW_URL/nonexistent-path-xyz"

    # 4. 认证插件
    echo -e "${BLUE}[4] 认证（key-auth）${NC}"
    assert_status "key-auth 无密钥返回 401" "401" \
        "$GW_URL/test/auth/status/200"
    assert_status "key-auth 错误密钥返回 401" "401" \
        "$GW_URL/test/auth/status/200" \
        -H "apikey: wrong-key"
    assert_status "key-auth 正确密钥返回 200" "200" \
        "$GW_URL/test/auth/status/200" \
        -H "apikey: test-api-key-12345"

    echo ""
}

# ── 集成测试 ─────────────────────────────────────────────────

run_integration_tests() {
    echo -e "${YELLOW}${BOLD}🧪 集成测试（业务场景验证）${NC}"
    echo ""

    # 1. 限流测试
    echo -e "${BLUE}[1] 限流（limit-count: 3次/60s）${NC}"
    assert_status "限流第 1 次请求 200" "200" "$GW_URL/test/ratelimit"
    assert_status "限流第 2 次请求 200" "200" "$GW_URL/test/ratelimit"
    assert_status "限流第 3 次请求 200" "200" "$GW_URL/test/ratelimit"
    assert_status "限流第 4 次请求 429" "429" "$GW_URL/test/ratelimit"

    # 2. 自定义插件 my-auth-validator
    echo -e "${BLUE}[2] 自定义插件 my-auth-validator${NC}"
    assert_status "无 X-App-ID 返回 403" "403" \
        "$GW_URL/test/custom-auth"
    assert_status "错误 X-App-ID 返回 403" "403" \
        "$GW_URL/test/custom-auth" \
        -H "X-App-ID: wrong-app"
    assert_status "正确 X-App-ID 返回 200" "200" \
        "$GW_URL/test/custom-auth" \
        -H "X-App-ID: test-app-001"

    # 3. 自定义插件 request-id-enhancer
    echo -e "${BLUE}[3] 自定义插件 request-id-enhancer${NC}"
    assert_header "响应含 X-Request-ID 头" \
        "$GW_URL/test/custom-auth" \
        "X-Request-ID" \
        -H "X-App-ID: test-app-001"

    # 4. CORS 插件
    echo -e "${BLUE}[4] CORS 插件${NC}"
    assert_status "CORS 预检请求返回 200" "200" \
        "$GW_URL/test/cors" \
        -X OPTIONS \
        -H "Origin: https://test.example.com" \
        -H "Access-Control-Request-Method: GET"
    assert_header "CORS 响应含 Access-Control-Allow-Origin" \
        "$GW_URL/test/cors" \
        "Access-Control-Allow-Origin" \
        -H "Origin: https://test.example.com"

    # 5. 动态路由创建/更新（Admin API）
    echo -e "${BLUE}[5] Admin API 动态操作${NC}"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if admin_put "routes" "test-dynamic-route" '{
        "id": "test-dynamic-route",
        "uri": "/test/dynamic",
        "upstream_id": "test-upstream",
        "plugins": {"proxy-rewrite": {"uri": "/status/201"}}
    }'; then
        sleep 2  # 等待数据面同步
        assert_status "动态创建路由后转发返回 201" "201" \
            "$GW_URL/test/dynamic"
        echo -e "  ${GREEN}✅ PASS${NC} 动态创建路由成功"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}❌ FAIL${NC} 动态创建路由失败"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("动态创建路由")
    fi

    # 6. 插件热重载
    echo -e "${BLUE}[6] 插件热重载${NC}"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    RELOAD_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X PUT "$ADMIN_URL/apisix/admin/plugins/reload" \
        -H "X-API-KEY: $TEST_ADMIN_KEY" 2>/dev/null || echo "000")
    if [ "$RELOAD_CODE" = "200" ]; then
        echo -e "  ${GREEN}✅ PASS${NC} 插件热重载返回 200"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}❌ FAIL${NC} 插件热重载返回 $RELOAD_CODE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("插件热重载")
    fi

    # 7. Prometheus metrics 端点
    echo -e "${BLUE}[7] Prometheus Metrics${NC}"
    assert_body_contains "数据面 metrics 包含 apisix 指标" \
        "http://localhost:9192/apisix/prometheus/metrics" \
        "apisix_nginx_http_current_connections" 2>/dev/null \
        || echo -e "  ${YELLOW}⚠️  metrics 端口未暴露，跳过${NC}"

    echo ""
}

# ── 测试报告 ─────────────────────────────────────────────────

print_report() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BOLD}📊 测试报告${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  总计：$TESTS_TOTAL   ${GREEN}通过：$TESTS_PASSED${NC}   ${RED}失败：$TESTS_FAILED${NC}"

    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}失败的测试：${NC}"
        for t in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $t"
        done
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── 主流程 ───────────────────────────────────────────────────

# 注册清理钩子
trap_cleanup() {
    print_report
    if [ "$NO_CLEANUP" != "--no-cleanup" ] || [ "$TESTS_FAILED" -eq 0 ]; then
        cleanup_test_env
    else
        echo -e "${YELLOW}⚠️  --no-cleanup 模式，测试环境保留，手动清理：${NC}"
        echo "  docker compose -f tests/docker-compose.test.yml down -v"
    fi
}
trap trap_cleanup EXIT

echo ""
echo -e "${BOLD}${GREEN}=====================================${NC}"
echo -e "${BOLD}${GREEN}   APISIX 自动化测试套件             ${NC}"
echo -e "${BOLD}${GREEN}=====================================${NC}"
echo ""

start_test_env
setup_fixtures

case "$TEST_SUITE" in
    smoke)
        run_smoke_tests
        ;;
    integration)
        run_smoke_tests   # 集成测试依赖冒烟通过
        run_integration_tests
        ;;
    all|*)
        run_smoke_tests
        run_integration_tests
        ;;
esac

# 退出码：有失败则非 0
[ "$TESTS_FAILED" -eq 0 ]
