-- ============================================================
-- 插件单元测试：my-auth-validator
-- 使用 busted 框架运行：busted tests/
-- ============================================================

local plugin = require("plugins.my-auth-validator")

describe("my-auth-validator", function()

    describe("check_schema", function()
        it("合法配置应通过校验", function()
            local ok = plugin.check_schema({ app_id = "app1,app2" })
            assert.is_true(ok)
        end)

        it("缺少 app_id 应返回 false", function()
            local ok = plugin.check_schema({})
            assert.is_false(ok)
        end)
    end)

    -- 集成测试请参考 tests/integration/ 目录
end)
