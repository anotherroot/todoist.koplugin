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

local function write(p, s)
    local f = assert(io.open(p, "wb"))
    f:write(s)
    f:close()
end

describe("td_history", function()
    local dir, path, clock
    local function now() return clock end
    local function open() return history.open(path, json, now) end

    local function bad_files()
        local out = {}
        local p = io.popen("ls -1 '" .. dir .. "'")
        for line in p:lines() do
            if line:find("^todoist_history%.json%.bad") then out[#out + 1] = line end
        end
        p:close()
        return out
    end

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

    it("a corrupt file with no backup gives an empty history, set aside with a timestamp", function()
        write(path, '{"items": [')
        local s = open()
        assert.same({}, s:list())
        local bad = s.recovered_from.bad
        assert.is_truthy(bad:find(path .. ".bad-", 1, true) == 1, bad)
        assert.is_truthy(bad:match("%.bad%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$"), bad)
        assert.is_false(s.recovered_from.used_old)
        assert.is_false(exists(path))
        assert.equal('{"items": [', slurp(bad))
        s:add({ kind = "idea", text = "after" })
        local again = open()
        assert.equal(1, #again:list())
        assert.is_nil(again.recovered_from)
    end)

    it("valid JSON of the wrong shape counts as corrupt too", function()
        write(path, '{"version":1,"items":"oops"}')
        local s = open()
        assert.same({}, s:list())
        assert.is_true(exists(s.recovered_from.bad))
    end)

    it("each save keeps the previous file as .old", function()
        local s = open()
        s:add({ kind = "idea", text = "a" })
        s:add({ kind = "idea", text = "b" })
        assert.equal(2, #json.decode(slurp(path)).items)
        assert.equal(1, #json.decode(slurp(path .. ".old")).items)
    end)

    it("an empty file (power cut) is restored from .old", function()
        local s = open()
        local a = s:add({ kind = "idea", text = "a" })
        local b = s:add({ kind = "idea", text = "b" })
        s:update(b.id, { status = "sent" })
        write(path, "") -- the last save never reached the card
        local back = open()
        assert.equal("a", back:get(a.id).text)
        assert.equal("b", back:get(b.id).text)
        assert.is_true(back.recovered_from.used_old)
        assert.equal("", slurp(back.recovered_from.bad))
        assert.is_true(exists(path)) -- the restored items are saved again at once
        assert.equal(2, #json.decode(slurp(path)).items)
        assert.is_nil(open().recovered_from)
    end)

    it("a missing file next to a good .old (cut between the renames) is restored quietly", function()
        local s = open()
        local a = s:add({ kind = "idea", text = "a" })
        s:add({ kind = "idea", text = "b" })
        os.rename(path, path .. ".old")
        local back = open()
        assert.equal(2, #back:list())
        assert.is_truthy(back:get(a.id))
        assert.is_nil(back.recovered_from)
    end)

    it("both files unreadable: starts empty and says so", function()
        write(path, "")
        write(path .. ".old", "{nope")
        local s = open()
        assert.same({}, s:list())
        assert.is_false(s.recovered_from.used_old)
        assert.is_true(exists(s.recovered_from.bad))
    end)

    it("two corruptions keep two .bad files", function()
        write(path, "first")
        local one = open().recovered_from.bad
        write(path, "second")
        local two = open().recovered_from.bad -- same clock second
        assert.not_equal(one, two)
        assert.equal("first", slurp(one))
        assert.equal("second", slurp(two))
        assert.equal(2, #bad_files())
    end)

    it("calls the fsync hooks on the file and the folder", function()
        local files, dirs = {}, {}
        local s = history.open(path, json, now, {
            fsync_file = function(f) files[#files + 1] = io.type(f) end,
            fsync_dir = function(p) dirs[#dirs + 1] = p end,
        })
        s:add({ kind = "idea", text = "a" })
        assert.same({ "file" }, files) -- still open when synced
        assert.same({ path }, dirs)
    end)

    it("an fsync hook that raises doesn't stop the save", function()
        local s = history.open(path, json, now, {
            fsync_file = function() error("no fsync") end,
            fsync_dir = function() error("no fsync") end,
        })
        local _, ok = s:add({ kind = "idea", text = "a" })
        assert.is_true(ok)
        assert.equal(1, #open():list())
    end)
    it("open recovers a sending item left by a crash, and persists it", function()
        local f = io.open(path, "wb")
        f:write(json.encode({ version = 1, items = { { id = "abc", kind = "idea", text = "t", created = 5, status = "sending", attempts = 1 } } }))
        f:close()
        local s = open()
        assert.equal("waiting", s:get("abc").status)
        assert.equal("waiting", json.decode(slurp(path)).items[1].status)
    end)

    it("update removes fields set to NONE", function()
        local s = open()
        local item = s:add({ kind = "idea", text = "t" })
        s:update(item.id, { status = "failed", last_error = "x", next_try = 99 })
        s:update(item.id, { status = "waiting", last_error = history.NONE, next_try = history.NONE })
        local back = open():get(item.id)
        assert.is_nil(back.last_error)
        assert.is_nil(back.next_try)
        assert.equal("waiting", back.status)
    end)

    it("reports save failures instead of pretending, and leaves no .tmp", function()
        local bad = dir .. "/missing/todoist_history.json"
        local s = history.open(bad, json, now)
        local item, ok, err = s:add({ kind = "idea", text = "t" })
        assert.equal("t", item.text)
        assert.is_false(ok)
        assert.is_string(err)
        assert.equal(err, s.last_save_error)
        assert.is_false(exists(bad .. ".tmp"))
        local _, ok2 = s:update(item.id, { status = "sent" })
        assert.is_false(ok2)
        assert.is_false((s:clear_sent()))
        -- a good save clears the error
        os.execute("mkdir -p '" .. dir .. "/missing'")
        local item2 = s:add({ kind = "idea", text = "u" })
        local _, ok3 = s:update(item2.id, { status = "failed" })
        assert.is_true(ok3)
        assert.is_nil(s.last_save_error)
        assert.is_true(s:recover())
    end)
end)
