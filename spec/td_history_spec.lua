local kojson = require("spec/support/kojson")
assert(kojson.json, "KOReader json not available (run via scripts/test.sh): " .. tostring(kojson.why))
local json = kojson.json
local history = require("td_history")

local function tmpdir()
    local p = io.popen("mktemp -d")
    local d = p:read("*l")
    p:close()
    return d
end

local function slurp(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

describe("td_history", function()
    local dir, path, clock
    local function now() return clock end
    local function open() return history.open(path, json, now) end

    before_each(function()
        dir = tmpdir()
        path = dir .. "/todoist_history.json"
        clock = 1000
    end)
    after_each(function()
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("starts empty when the file is missing", function()
        local s = open()
        assert.same({}, s:list())
        assert.same({ waiting = 0, sending = 0, sent = 0, failed = 0 }, s:counts())
    end)

    it("add fills id, created, status, attempts and saves a reloadable file", function()
        local s = open()
        local item = s:add({
            kind = "quote", text = "Hello", book = "B", author = "A", file = "/b.epub",
            page = "142 of 380", pos = { pos0 = "/x[1]", pos1 = "/x[2]" }, note = "n",
        })
        assert.equal("waiting", item.status)
        assert.equal(0, item.attempts)
        assert.equal(1000, item.created)
        assert.is_true(exists(path))
        local again = open():get(item.id)
        assert.same(item, again)
        assert.same({ pos0 = "/x[1]", pos1 = "/x[2]" }, again.pos)
        assert.same({ version = 1, items = { item } }, json.decode(slurp(path)))
    end)

    it("ids are canonical UUID v4 and unique over 1000 adds", function()
        local s = open()
        local seen, n = {}, 0
        for i = 1, 1000 do
            local id = s:add({ kind = "idea", text = "t" .. i }).id
            assert.is_truthy(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), id)
            assert.equal(id:lower(), id)
            assert.equal(36, #id)
            assert.is_nil(seen[id])
            seen[id] = true
            n = n + 1
        end
        assert.equal(1000, n)
    end)

    it("list is newest first, ties broken by insertion order, and filters unsent", function()
        local s = open()
        local a = s:add({ kind = "idea", text = "a" })
        clock = 2000
        local b = s:add({ kind = "idea", text = "b" })
        local c = s:add({ kind = "idea", text = "c" }) -- same second as b
        local d = s:add({ kind = "idea", text = "d" })
        s:update(a.id, { status = "sent" })
        s:update(b.id, { status = "failed" })
        s:update(c.id, { status = "sending" })
        local ids = {}
        for _, it in ipairs(s:list()) do ids[#ids + 1] = it.text end
        assert.same({ "d", "c", "b", "a" }, ids)
        ids = {}
        for _, it in ipairs(open():list("unsent")) do ids[#ids + 1] = it.text end
        assert.same({ "d", "c", "b" }, ids)
        assert.equal(d.id, s:list()[1].id)
    end)

    it("get returns nil for unknown ids", function()
        assert.is_nil(open():get("nope"))
    end)

    it("update merges, persists, and rejects unknown ids and bad statuses", function()
        local s = open()
        local item = s:add({ kind = "quote", text = "q" })
        local up = s:update(item.id, { status = "failed", attempts = 2, last_error = "No connection.", error_kind = "temporary", next_try = 1060 })
        assert.equal("failed", up.status)
        local back = open():get(item.id)
        assert.equal("failed", back.status)
        assert.equal(2, back.attempts)
        assert.equal("No connection.", back.last_error)
        assert.equal("q", back.text)
        assert.is_nil(s:update("nope", { status = "sent" }))
        local bad = s:update(item.id, { status = "done" })
        assert.is_nil(bad)
        assert.equal("failed", open():get(item.id).status)
    end)

    it("recover turns sending into waiting and keeps ids", function()
        local s = open()
        local a = s:add({ kind = "idea", text = "a" })
        local b = s:add({ kind = "idea", text = "b" })
        s:update(a.id, { status = "sending" })
        s:update(b.id, { status = "sent" })
        local s2 = open()
        s2:recover()
        assert.equal("waiting", s2:get(a.id).status)
        assert.equal("sent", s2:get(b.id).status)
        assert.equal("waiting", open():get(a.id).status)
    end)

    it("counts per status", function()
        local s = open()
        local a = s:add({ kind = "idea", text = "a" })
        local b = s:add({ kind = "idea", text = "b" })
        s:add({ kind = "idea", text = "c" })
        s:update(a.id, { status = "sent" })
        s:update(b.id, { status = "failed" })
        assert.same({ waiting = 1, sending = 0, sent = 1, failed = 1 }, s:counts())
    end)

    it("copy makes a fresh waiting item with a new id", function()
        local s = open()
        local a = s:add({ kind = "quote", text = "q", book = "B", author = "A", file = "/f", page = "1 of 2", pos = { page = 1 }, note = "n" })
        s:update(a.id, { status = "sent", task_id = "T1", sent_at = 1100, attempts = 1 })
        clock = 3000
        local c = s:copy(a.id)
        assert.not_equal(a.id, c.id)
        assert.equal("waiting", c.status)
        assert.equal(0, c.attempts)
        assert.equal(3000, c.created)
        assert.is_nil(c.task_id)
        assert.is_nil(c.sent_at)
        for _, k in ipairs({ "kind", "text", "book", "author", "file", "page", "note" }) do
            assert.equal(a[k], c[k])
        end
        assert.same({ page = 1 }, c.pos)
        assert.equal("sent", open():get(a.id).status)
        assert.equal("waiting", open():get(c.id).status)
        assert.is_nil(s:copy("nope"))
    end)

    it("clear_sent removes only sent items", function()
        local s = open()
        local a = s:add({ kind = "idea", text = "a" })
        local b = s:add({ kind = "idea", text = "b" })
        s:update(a.id, { status = "sent" })
        s:clear_sent()
        assert.is_nil(open():get(a.id))
        assert.is_truthy(open():get(b.id))
    end)

    it("leaves no .tmp file after saving", function()
        local s = open()
        s:add({ kind = "idea", text = "a" })
        assert.is_false(exists(path .. ".tmp"))
        assert.is_true(exists(path))
    end)

    it("a corrupt file gives an empty history and is moved to .bad", function()
        local f = io.open(path, "wb")
        f:write('{"items": [')
        f:close()
        local s = open()
        assert.same({}, s:list())
        assert.is_true(exists(path .. ".bad"))
        assert.is_false(exists(path))
        assert.equal('{"items": [', slurp(path .. ".bad"))
        s:add({ kind = "idea", text = "after" })
        assert.equal(1, #open():list())
    end)

    it("valid JSON of the wrong shape counts as corrupt too", function()
        local f = io.open(path, "wb")
        f:write('{"version":1,"items":"oops"}')
        f:close()
        assert.same({}, open():list())
        assert.is_true(exists(path .. ".bad"))
    end)
end)
