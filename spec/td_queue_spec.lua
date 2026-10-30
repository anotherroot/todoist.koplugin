local kojson = require("spec/support/kojson")
assert(kojson.json, "KOReader json not available (run via scripts/test.sh): " .. tostring(kojson.why))
local json = kojson.json
local history = require("td_history")
local api = require("td_api")
local td_queue = require("td_queue")

local function tmpdir()
    local p = io.popen("mktemp -d")
    local d = p:read("*l")
    p:close()
    return d
end

local function urldecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- The uuid the request body actually carries (what Todoist dedupes on).
local function body_uuid(req)
    local cmds = json.decode(urldecode(req.body:match("^commands=(.*)$")))
    return cmds[1].uuid
end

local function ok_body(uuid, task_id)
    return json.encode({ sync_status = { [uuid] = "ok" }, temp_id_mapping = { [uuid] = task_id } })
end

describe("td_queue", function()
    local dir, path, env, store, queue

    -- Fake KOReader: a clock, a scheduler, a network that the test answers.
    local function fresh_env()
        env = {
            clock = 1000, online = true, token = "secrettoken1234", with_book = false,
            requests = {}, notes = {}, alerts = {}, timers = {},
        }
    end

    local function deps_for(s)
        return {
            store = s, json = json,
            now = function() return env.clock end,
            token = function() return env.token end,
            with_book = function() return env.with_book end,
            online = function() return env.online end,
            run = function(req, on_done, uuid)
                env.requests[#env.requests + 1] = { req = req, on_done = on_done, uuid = uuid }
            end,
            schedule = function(seconds, fn)
                env.timers[#env.timers + 1] = { at = env.clock + seconds, fn = fn }
            end,
            unschedule = function(fn)
                for i = #env.timers, 1, -1 do
                    if env.timers[i].fn == fn then table.remove(env.timers, i) end
                end
            end,
            alert = function(info) env.alerts[#env.alerts + 1] = info end,
            notify = function(text) env.notes[#env.notes + 1] = text end,
        }
    end

    local function open_store() return history.open(path, json, function() return env.clock end) end
    local function new_queue(s) return td_queue.new(deps_for(s)) end

    -- Moves the clock and fires due timers, like UIManager would.
    local function advance(seconds)
        env.clock = env.clock + seconds
        local due = {}
        for i = #env.timers, 1, -1 do
            if env.timers[i].at <= env.clock then
                due[#due + 1] = env.timers[i]
                table.remove(env.timers, i)
            end
        end
        for i = #due, 1, -1 do due[i].fn() end
    end

    -- Answers request n the way the real runner would: through parse_add.
    local function answer(n, code, body)
        local r = env.requests[n]
        r.on_done(api.parse_add(json, body_uuid(r.req), code, body))
    end
    local function answer_ok(n, task_id)
        answer(n, 200, ok_body(body_uuid(env.requests[n].req), task_id or "T" .. n))
    end
    local function answer_temp(n) env.requests[n].on_done({ ok = false, kind = "temporary", message = "No connection." }) end

    local function add(text) return (store:add({ kind = "idea", text = text or "An idea" })) end

    before_each(function()
        dir = tmpdir()
        path = dir .. "/todoist_history.json"
        fresh_env()
        store = open_store()
        queue = new_queue(store)
    end)
    after_each(function()
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("submit online sends one request and marks the item sent", function()
        local item = add()
        queue:submit(item.id)
        assert.equal(1, #env.requests)
        assert.equal(item.id, body_uuid(env.requests[1].req))
        assert.equal("Bearer secrettoken1234", env.requests[1].req.headers.Authorization)
        local now = store:get(item.id)
        assert.equal("sending", now.status)
        assert.equal(1, now.attempts)
        assert.equal(1000, now.last_attempt)
        assert.same({}, env.notes) -- nothing claimed before Todoist answers
        env.clock = 1003
        answer_ok(1, "8123")
        now = store:get(item.id)
        assert.equal("sent", now.status)
        assert.equal("8123", now.task_id)
        assert.equal(1003, now.sent_at)
        assert.same({ "Sent to Todoist" }, env.notes)
        assert.equal("sent", open_store():get(item.id).status) -- saved
        assert.equal(0, queue:unsent_count())
    end)

    it("submit offline leaves the item waiting and says so", function()
        env.online = false
        local item = add()
        queue:submit(item.id)
        assert.equal(0, #env.requests)
        assert.equal("waiting", store:get(item.id).status)
        assert.same({ "Saved, will send when Wi-Fi is on" }, env.notes)
        assert.equal(1, queue:unsent_count())
    end)

    it("temporary failures back off 60, 120, 300, 900, 1800, then 1800", function()
        local item = add()
        queue:submit(item.id)
        local waits = {}
        for n = 1, 7 do
            assert.equal(n, #env.requests)
            local before = env.clock
            answer_temp(n)
            local now = store:get(item.id)
            assert.equal("failed", now.status)
            assert.equal("temporary", now.error_kind)
            assert.equal("No connection.", now.last_error)
            assert.equal(n, now.attempts)
            waits[n] = now.next_try - before
            advance(waits[n] - 1)
            assert.equal(n, #env.requests) -- not before it's due
            advance(1)
        end
        assert.same({ 60, 120, 300, 900, 1800, 1800, 1800 }, waits)
    end)

    it("a fresh submit that fails temporarily says it will send later, once", function()
        local item = add()
        queue:submit(item.id)
        answer_temp(1)
        assert.same({ "Saved, will send later" }, env.notes)
        advance(60)
        answer_temp(2)
        advance(120)
        answer_ok(3)
        assert.same({ "Saved, will send later" }, env.notes) -- background retries stay quiet
        assert.equal("sent", store:get(item.id).status)
        assert.is_nil(store:get(item.id).last_error)
        assert.is_nil(store:get(item.id).error_kind)
        assert.is_nil(store:get(item.id).next_try)
    end)

    it("alerts on the 3rd temporary failure in a row, not again on the 4th", function()
        local item = add()
        queue:submit(item.id)
        answer_temp(1); advance(60)
        answer_temp(2); advance(120)
        assert.same({}, env.alerts)
        assert.is_nil(queue:pending_alert())
        answer_temp(3)
        assert.same({ { count = 1, message = "No connection.", kind = "temporary" } }, env.alerts)
        advance(300)
        answer_temp(4)
        assert.equal(1, #env.alerts)
        assert.same({ count = 1, message = "No connection.", kind = "temporary" }, queue:pending_alert())
    end)

    it("alerts again when the count of unsent items grows", function()
        local a = add("a")
        queue:submit(a.id)
        answer_temp(1); advance(60)
        answer_temp(2); advance(120)
        answer_temp(3)
        assert.equal(1, #env.alerts)
        env.online = false
        queue:submit(add("b").id)
        env.online = true
        advance(300)
        answer_temp(4)
        assert.equal(2, #env.alerts)
        assert.equal(2, env.alerts[2].count)
    end)

    it("retry_after beats the backoff", function()
        local item = add()
        queue:submit(item.id)
        answer(1, 429, json.encode({ error_extra = { retry_after = 600 } }))
        local now = store:get(item.id)
        assert.equal("failed", now.status)
        assert.equal(1600, now.next_try)
        advance(599)
        assert.equal(1, #env.requests)
        advance(1)
        assert.equal(2, #env.requests)
    end)

    it("auth error stops queue", function()
        local a, b, c = add("a"), add("b"), add("c")
        queue:kick()
        assert.equal(1, #env.requests)
        answer(1, 401, "")
        assert.equal(1, #env.requests)
        assert.equal(1, #env.alerts)
        assert.equal("auth", env.alerts[1].kind)
        assert.equal(3, env.alerts[1].count)
        assert.equal("API key rejected (401). Check the key in Settings.", env.alerts[1].message)
        assert.equal("failed", store:get(a.id).status)
        assert.equal("auth", store:get(a.id).error_kind)
        assert.equal("waiting", store:get(b.id).status)
        assert.equal("waiting", store:get(c.id).status)
        queue:kick()
        advance(3600)
        assert.equal(1, #env.requests)
        assert.equal(1, #env.alerts)
        assert.equal(3, queue:unsent_count())
        assert.equal("auth", queue:pending_alert().kind)
    end)

    it("key change requeues", function()
        local a, b, c = add("a"), add("b"), add("c")
        queue:kick()
        answer(1, 401, "")
        queue:key_changed()
        assert.equal("sending", store:get(a.id).status) -- requeued and sent straight away
        assert.equal(1, store:get(a.id).attempts)
        assert.is_nil(store:get(a.id).error_kind)
        assert.is_nil(store:get(a.id).last_error)
        assert.equal(2, #env.requests)
        assert.equal(a.id, body_uuid(env.requests[2].req))
        answer_ok(2)
        answer_ok(3)
        answer_ok(4)
        assert.equal(4, #env.requests)
        for _, it_ in ipairs({ a, b, c }) do assert.equal("sent", store:get(it_.id).status) end
        assert.is_nil(queue:pending_alert())
        assert.same({}, env.notes) -- background sends stay quiet
    end)

    it("no API key is an auth failure without a request", function()
        env.token = nil
        local item = add()
        queue:submit(item.id)
        assert.equal(0, #env.requests)
        local now = store:get(item.id)
        assert.equal("failed", now.status)
        assert.equal("auth", now.error_kind)
        assert.equal("No Todoist API key. Add it in Settings.", now.last_error)
        assert.same({ { count = 1, message = "No Todoist API key. Add it in Settings.", kind = "auth" } }, env.alerts)
        env.token = "newkey"
        queue:key_changed()
        assert.equal(1, #env.requests)
        assert.equal("Bearer newkey", env.requests[1].req.headers.Authorization)
    end)

    it("submit while the key is blocked raises the alert instead of sending", function()
        queue:kick()
        queue:submit(add("a").id)
        answer(1, 403, "")
        assert.equal(1, #env.alerts)
        queue:submit(add("b").id)
        assert.equal(1, #env.requests)
        assert.equal(2, #env.alerts)
        assert.equal(2, env.alerts[2].count)
    end)

    it("permanent error is not retried by kick, and alerts", function()
        local item = add()
        queue:submit(item.id)
        answer(1, 400, "")
        local now = store:get(item.id)
        assert.equal("failed", now.status)
        assert.equal("permanent", now.error_kind)
        assert.is_nil(now.next_try)
        assert.equal(1, #env.alerts)
        assert.equal("permanent", env.alerts[1].kind)
        queue:kick()
        advance(7200)
        queue:kick()
        assert.equal(1, #env.requests)
        assert.equal("permanent", queue:pending_alert().kind)
    end)

    it("a permanent command error inside a 200 answer is permanent too", function()
        local item = add()
        queue:submit(item.id)
        answer(1, 200, json.encode({ sync_status = { [item.id] = { error = "Invalid argument", error_code = 20 } } }))
        assert.equal("permanent", store:get(item.id).error_kind)
        assert.equal(1, #env.alerts)
    end)

    it("resend on a sent item makes a new item and leaves the old one sent", function()
        local item = add("same text")
        queue:submit(item.id)
        answer_ok(1)
        local new_id = queue:resend(item.id)
        assert.is_string(new_id)
        assert.not_equal(item.id, new_id)
        assert.equal("sent", store:get(item.id).status)
        assert.equal(2, #env.requests)
        assert.equal(new_id, body_uuid(env.requests[2].req))
        assert.equal("same text", store:get(new_id).text)
        answer_ok(2)
        assert.equal("sent", store:get(new_id).status)
        assert.same({ "Sent to Todoist", "Sent to Todoist" }, env.notes)
    end)

    it("resend on a failed item reuses the same uuid and resets attempts", function()
        local item = add()
        queue:submit(item.id)
        answer(1, 400, "")
        assert.equal(item.id, queue:resend(item.id))
        assert.equal(2, #env.requests)
        assert.equal(item.id, body_uuid(env.requests[2].req))
        local now = store:get(item.id)
        assert.equal("sending", now.status)
        assert.equal(1, now.attempts)
        assert.is_nil(now.error_kind)
        answer_ok(2)
        assert.equal("sent", store:get(item.id).status)
    end)

    it("resend on an auth-failed item tries again despite the block", function()
        local item = add()
        queue:submit(item.id)
        answer(1, 401, "")
        queue:resend(item.id)
        assert.equal(2, #env.requests)
        assert.equal(item.id, body_uuid(env.requests[2].req))
    end)

    it("restart resends with same uuid", function()
        local item = add()
        store:update(item.id, { status = "sending", attempts = 1, last_attempt = 999 })
        local store2 = open_store()
        assert.equal("waiting", store2:get(item.id).status)
        local queue2 = new_queue(store2)
        queue2:kick()
        assert.equal(1, #env.requests)
        assert.equal(item.id, body_uuid(env.requests[1].req))
        answer_ok(1)
        assert.equal("sent", store2:get(item.id).status)
        assert.same({}, env.notes)
    end)

    it("only one request in flight at a time, in creation order", function()
        local a = add("a")
        env.clock = 1001
        local b = add("b")
        env.clock = 1002
        local c = add("c")
        queue:kick()
        queue:kick()
        queue:submit(c.id)
        queue:submit(b.id)
        assert.equal(1, #env.requests)
        assert.equal(a.id, body_uuid(env.requests[1].req))
        answer_ok(1)
        assert.equal(2, #env.requests)
        assert.equal(b.id, body_uuid(env.requests[2].req))
        queue:kick()
        assert.equal(2, #env.requests)
        answer_ok(2)
        assert.equal(c.id, body_uuid(env.requests[3].req))
        answer_ok(3)
        assert.equal(3, #env.requests)
        assert.same({ "Sent to Todoist", "Sent to Todoist" }, env.notes) -- b and c were submitted
    end)

    it("a failing item does not hold up the others", function()
        local a = add("a")
        env.clock = 1001
        local b = add("b")
        queue:kick()
        answer_temp(1)
        assert.equal(2, #env.requests)
        assert.equal(b.id, body_uuid(env.requests[2].req))
        answer_ok(2)
        assert.equal("failed", store:get(a.id).status)
        assert.equal("sent", store:get(b.id).status)
    end)

    it("repeated kicks don't stack retry timers", function()
        local item = add()
        queue:submit(item.id)
        answer_temp(1)
        queue:kick()
        queue:kick()
        queue:kick()
        assert.equal(1, #env.timers)
        assert.equal(1060, env.timers[1].at)
        assert.equal(item.id, store:get(item.id).id)
    end)

    it("no retry timer while offline; kick on reconnect sends", function()
        local item = add()
        queue:submit(item.id)
        answer_temp(1)
        env.online = false
        queue:kick()
        assert.equal(0, #env.timers)
        advance(3600)
        assert.equal(1, #env.requests)
        env.online = true
        queue:kick()
        assert.equal(2, #env.requests)
    end)

    it("watchdog: no answer after 60 s is a temporary failure, late answers are ignored", function()
        local a = add("a")
        env.clock = 1001
        local b = add("b")
        queue:kick()
        advance(59)
        assert.equal("sending", store:get(a.id).status)
        advance(1)
        local now = store:get(a.id)
        assert.equal("failed", now.status)
        assert.equal("temporary", now.error_kind)
        assert.equal("No connection.", now.last_error)
        assert.equal(2, #env.requests) -- slot released, b goes out
        answer_ok(1) -- the lost answer turns up late
        assert.equal("failed", store:get(a.id).status)
        assert.equal(2, #env.requests)
        answer_ok(2)
        assert.equal("sent", store:get(b.id).status)
    end)

    it("an answer cancels the watchdog", function()
        local item = add()
        queue:submit(item.id)
        answer_ok(1)
        advance(120)
        assert.equal("sent", store:get(item.id).status)
        assert.same({}, env.timers)
    end)

    it("a runner that raises counts as a temporary failure", function()
        local item = add()
        local deps = deps_for(store)
        deps.run = function() error("boom") end
        local q = td_queue.new(deps)
        q:submit(item.id)
        assert.equal("failed", store:get(item.id).status)
        assert.equal("temporary", store:get(item.id).error_kind)
        assert.same({ "Saved, will send later" }, env.notes)
    end)

    it("says so when Todoist got it but the history couldn't be saved", function()
        local item = add()
        queue:submit(item.id)
        os.execute("rm -rf '" .. dir .. "'")
        answer_ok(1)
        assert.equal("sent", store:get(item.id).status)
        assert.same({ "Sent, but the history couldn't be saved." }, env.notes)
    end)

    it("pending_alert is nil when nothing is stuck, and alert_shown records the count", function()
        assert.is_nil(queue:pending_alert())
        local item = add()
        queue:submit(item.id)
        answer(1, 400, "")
        local info = queue:pending_alert()
        assert.equal(1, info.count)
        assert.equal(1, #env.alerts)
        env.online = false
        queue:submit(add("b").id)
        assert.equal(2, queue:pending_alert().count) -- main.lua shows it on book open...
        queue:alert_shown()                          -- ...and records it
        env.online = true
        queue:kick()
        env.requests[2].on_done({ ok = false, kind = "temporary", message = "No connection." })
        assert.equal(1, #env.alerts) -- 2 unsent were already shown
    end)

    it("an error while preparing the request fails the item permanently and frees the queue", function()
        local deps = deps_for(store)
        local broken = true
        deps.with_book = function()
            if broken then error("x") end
            return false
        end
        local q = td_queue.new(deps)
        local a = add("a")
        q:submit(a.id)
        assert.equal(0, #env.requests)
        local now = store:get(a.id)
        assert.equal("failed", now.status)
        assert.equal("permanent", now.error_kind)
        assert.equal("Couldn't prepare the task.", now.last_error)
        assert.equal(1, #env.alerts)
        assert.equal("permanent", env.alerts[1].kind)
        assert.same({}, env.timers) -- no watchdog left behind
        broken = false
        local b = add("b")
        q:submit(b.id)
        assert.equal(1, #env.requests)
        assert.equal(b.id, body_uuid(env.requests[1].req))
    end)

    it("a scheduler that raises on the watchdog doesn't jam the queue", function()
        local deps = deps_for(store)
        local real_schedule = deps.schedule
        local fail_once = true
        deps.schedule = function(seconds, fn)
            if fail_once then
                fail_once = false
                error("no timers")
            end
            return real_schedule(seconds, fn)
        end
        local q = td_queue.new(deps)
        local a = add("a")
        q:submit(a.id)
        assert.equal("failed", store:get(a.id).status)
        assert.equal("permanent", store:get(a.id).error_kind)
        assert.equal(0, #env.requests)
        local b = add("b")
        q:submit(b.id)
        assert.equal(1, #env.requests)
        assert.equal(b.id, body_uuid(env.requests[1].req))
        answer_ok(1)
        assert.equal("sent", store:get(b.id).status)
    end)

    it("a notify that raises doesn't stop the next item", function()
        local deps = deps_for(store)
        deps.notify = function() error("toast broke") end
        local q = td_queue.new(deps)
        local a = add("a")
        env.clock = 1001
        local b = add("b")
        q:submit(a.id)
        assert.equal(1, #env.requests)
        answer_ok(1)
        assert.equal("sent", store:get(a.id).status)
        assert.equal(2, #env.requests)
        assert.equal(b.id, body_uuid(env.requests[2].req))
        answer_ok(2)
        assert.equal("sent", store:get(b.id).status)
    end)
end)
