local kojson = require("spec/support/kojson")
assert(kojson.json, "KOReader json not available (run via scripts/test.sh): " .. tostring(kojson.why))
local json = kojson.json
local api = require("td_api")

local TOKEN = "secrettoken1234"
local UUID = "0b1c2d3e-4f50-4a61-8b72-93a4b5c6d7e8"

local function urldecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function commands_of(req)
    local raw = req.body:match("^commands=(.*)$")
    assert.is_truthy(raw, "body must be commands=<encoded json>")
    assert.is_nil(raw:find("[^A-Za-z0-9%%%-_.~]"), "body must be fully url-encoded")
    return json.decode(urldecode(raw))
end

local function reply(t) return json.encode(t) end

describe("td_api.add_request", function()
    it("posts one item_add with the uuid, content and description", function()
        local req = api.add_request(json, TOKEN, UUID, { content = "Title", description = "Body" })
        assert.equal("https://api.todoist.com/api/v1/sync", req.url)
        assert.equal(api.URL, req.url)
        assert.equal("POST", req.method)
        assert.equal("Bearer " .. TOKEN, req.headers.Authorization)
        assert.equal("application/x-www-form-urlencoded", req.headers["Content-Type"])
        local cmds = commands_of(req)
        assert.equal(1, #cmds)
        assert.equal("item_add", cmds[1].type)
        assert.equal(UUID, cmds[1].uuid)
        assert.equal(UUID, cmds[1].temp_id)
        assert.equal("Title", cmds[1].args.content)
        assert.equal("Body", cmds[1].args.description)
        assert.is_nil(cmds[1].args.project_id)
    end)

    it("encodes awkward text", function()
        local text = 'He said "a & b = c+d"\n🙂 Čačak 漢字'
        local req = api.add_request(json, TOKEN, UUID, { content = text, description = text })
        local args = commands_of(req)[1].args
        assert.equal(text, args.content)
        assert.equal(text, args.description)
    end)

    it("keeps the token out of the body", function()
        local req = api.add_request(json, TOKEN, UUID, { content = "a", description = "b" })
        assert.is_nil(req.body:find(TOKEN, 1, true))
    end)
end)

describe("td_api.user_request", function()
    it("asks for the user resource only, with no commands", function()
        local req = api.user_request(json, TOKEN)
        assert.equal(api.URL, req.url)
        assert.equal("POST", req.method)
        assert.equal("Bearer " .. TOKEN, req.headers.Authorization)
        assert.is_nil(req.body:find("commands", 1, true))
        assert.is_truthy(req.body:find("sync_token=*", 1, true) or req.body:find("sync_token=%2A", 1, true))
        local rt = req.body:match("resource_types=([^&]*)")
        assert.same({ "user" }, json.decode(urldecode(rt)))
    end)
end)

describe("td_api.parse_add", function()
    it("accepts an ok status and returns the task id", function()
        local r = api.parse_add(json, UUID, 200,
            reply({ sync_status = { [UUID] = "ok" }, temp_id_mapping = { [UUID] = "123" } }))
        assert.is_true(r.ok)
        assert.equal("123", r.task_id)
    end)

    it("treats an error object for the command as permanent", function()
        local r = api.parse_add(json, UUID, 200,
            reply({ sync_status = { [UUID] = { error = "Invalid argument", error_code = 20 } } }))
        assert.is_false(r.ok)
        assert.equal("permanent", r.kind)
        assert.matches("Invalid argument", r.message)
    end)

    it("does not believe a 200 that says nothing about this command", function()
        local r = api.parse_add(json, UUID, 200, reply({ sync_status = {} }))
        assert.is_false(r.ok)
        assert.equal("temporary", r.kind)
        r = api.parse_add(json, UUID, 200, reply({ sync_status = { other = "ok" } }))
        assert.equal("temporary", r.kind)
    end)

    it("classifies 401 and 403 as auth", function()
        for _, code in ipairs({ 401, 403 }) do
            local r = api.parse_add(json, UUID, code, "{}")
            assert.is_false(r.ok)
            assert.equal("auth", r.kind)
            assert.matches(tostring(code), r.message)
        end
    end)

    it("classifies 400 as permanent", function()
        local r = api.parse_add(json, UUID, 400, "bad request")
        assert.equal("permanent", r.kind)
    end)

    it("classifies 429 as temporary and passes retry_after on", function()
        local r = api.parse_add(json, UUID, 429, reply({ error = "slow down", error_extra = { retry_after = 30 } }))
        assert.is_false(r.ok)
        assert.equal("temporary", r.kind)
        assert.equal(30, r.retry_after)
        assert.matches("429", r.message)
    end)

    it("passes retry_after from a command error too", function()
        local r = api.parse_add(json, UUID, 200, reply({ sync_status = { [UUID] =
            { error = "Busy", error_code = 1, error_extra = { retry_after = 7 } } } }))
        assert.equal(7, r.retry_after)
    end)

    it("classifies 5xx as temporary", function()
        local r = api.parse_add(json, UUID, 503, "<html>")
        assert.equal("temporary", r.kind)
        assert.is_nil(r.retry_after)
    end)

    it("classifies no response as no connection", function()
        local r = api.parse_add(json, UUID, nil, "timeout")
        assert.is_false(r.ok)
        assert.equal("temporary", r.kind)
        assert.equal("No connection.", r.message)
    end)

    it("classifies an unparsable 200 as temporary", function()
        assert.equal("temporary", api.parse_add(json, UUID, 200, "<html>").kind)
        assert.equal("temporary", api.parse_add(json, UUID, 200, "").kind)
        assert.equal("temporary", api.parse_add(json, UUID, 200, nil).kind)
        assert.equal("temporary", api.parse_add(json, UUID, 200, "[1,2]").kind)
    end)

    it("never puts the token in a message", function()
        local bodies = { "{}", "<html>", TOKEN, reply({ sync_status = { [UUID] = { error = "x" } } }) }
        for _, code in ipairs({ 200, 400, 401, 403, 404, 429, 500, 503 }) do
            for _, body in ipairs(bodies) do
                local r = api.parse_add(json, UUID, code, body)
                if not r.ok then
                    assert.is_string(r.message)
                    assert.is_nil(r.message:find(TOKEN, 1, true))
                end
            end
        end
        local r = api.parse_add(json, UUID, nil, "connect to " .. "host failed")
        assert.is_nil(r.message:find(TOKEN, 1, true))
    end)
end)

describe("td_api.parse_user", function()
    it("returns the name", function()
        local r = api.parse_user(json, 200, reply({ user = { full_name = "Ada Reader", email = "a@b.c" } }))
        assert.is_true(r.ok)
        assert.equal("Ada Reader", r.name)
    end)

    it("falls back to the email", function()
        local r = api.parse_user(json, 200, reply({ user = { email = "a@b.c" } }))
        assert.equal("a@b.c", r.name)
    end)

    it("fails like parse_add", function()
        assert.equal("auth", api.parse_user(json, 401, "{}").kind)
        assert.equal("temporary", api.parse_user(json, nil, "timeout").kind)
        assert.equal("temporary", api.parse_user(json, 429, "{}").kind)
        assert.equal("temporary", api.parse_user(json, 200, "<html>").kind)
        assert.equal("temporary", api.parse_user(json, 200, "{}").kind)
    end)
end)
