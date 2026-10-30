local safe = require("td_safe")

describe("td_safe.guarded", function()
    it("passes arguments through when nothing goes wrong", function()
        local got
        safe.guarded(function(a, b) got = a + b end)(2, 3)
        assert.equal(5, got)
    end)

    it("turns an error into a report instead of raising it", function()
        local reported
        local f = safe.guarded(function() error("boom") end, function(err) reported = err end)
        assert.has_no.errors(function() f() end)
        assert.matches("boom", reported)
    end)

    it("survives calling a method on nil (a button pressed before setup finished)", function()
        local reported
        local run = {}
        safe.guarded(function() run.session:cancel() end, function(err) reported = err end)()
        assert.matches("attempt to index", reported)
    end)
end)

describe("td_safe.quietly", function()
    it("returns the value, or the fallback after an error", function()
        assert.equal("Send (2)", safe.quietly(function() return "Send (2)" end, "Send")())
        local reported
        local f = safe.quietly(function() error("bad") end, "Send", function(err) reported = err end)
        assert.equal("Send", f())
        assert.matches("bad", reported)
        assert.is_false(safe.quietly(function() error("x") end, false, function() end)())
    end)
end)
