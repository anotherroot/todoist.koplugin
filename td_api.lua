--[[--
The Todoist Sync API: builds the request for one task and sorts the answer
into ok / auth / permanent / temporary. The retry queue relies on that sorting:
only "temporary" is retried, and nothing is "ok" unless Todoist said so.
Pure functions (KOReader's `json` is passed in), except `send`.
]]

local M = {}

M.URL = "https://api.todoist.com/api/v1/sync"

local function urlencode(s)
    return (tostring(s):gsub("[^A-Za-z0-9%-_.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function request(token, body)
    return {
        url = M.URL,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        body = body,
    }
end

--- Request that adds one task. No project_id: Todoist files it in the Inbox.
-- @tparam table json KOReader's json module
-- @tparam string uuid fixed per history item, so a resend never doubles the task
-- @tparam table task { content, description }
function M.add_request(json, token, uuid, task)
    local commands = { {
        type = "item_add",
        uuid = uuid,
        temp_id = uuid,
        args = { content = task.content, description = task.description },
    } }
    return request(token, "commands=" .. urlencode(json.encode(commands)))
end

--- Request that returns the user (for "Test connection").
function M.user_request(json, token)
    return request(token, "sync_token=" .. urlencode("*")
        .. "&resource_types=" .. urlencode(json.encode({ "user" })))
end

local function fail(kind, message, retry_after)
    return { ok = false, kind = kind, message = message, retry_after = retry_after }
end

local function decode(json, body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

local function retry_after_of(t)
    local extra = type(t) == "table" and t.error_extra
    local n = type(extra) == "table" and tonumber(extra.retry_after)
    return n or nil
end

--- Sorts a failed HTTP answer; nil when the code is 200.
local function classify_http(json, code, body)
    if code == nil then return fail("temporary", "No connection.") end
    if code == 401 or code == 403 then
        return fail("auth", string.format("API key rejected (%d). Check the key in Settings.", code))
    end
    if code == 429 then
        return fail("temporary", "Todoist is busy (429), will retry.", retry_after_of(decode(json, body)))
    end
    if code == 408 or code == 425 or code >= 500 then
        return fail("temporary", string.format("Todoist is not answering (%d), will retry.", code),
            retry_after_of(decode(json, body)))
    end
    if code ~= 200 then
        if code >= 400 and code < 500 then
            return fail("permanent", string.format("Todoist refused the request (%d).", code))
        end
        return fail("temporary", string.format("Unexpected answer from Todoist (%d), will retry.", code))
    end
    return nil
end

local function unreadable()
    return fail("temporary", "Todoist sent an answer that could not be read, will retry.")
end

--- Sorts the answer to an add_request.
-- @return { ok = true, task_id } or { ok = false, kind = "auth"|"permanent"|"temporary", message, retry_after? }
function M.parse_add(json, uuid, code, body)
    local failure = classify_http(json, code, body)
    if failure then return failure end
    local data = decode(json, body)
    local status = data and data.sync_status
    if type(status) ~= "table" or status[uuid] == nil then return unreadable() end
    local s = status[uuid]
    if s == "ok" then
        local id = type(data.temp_id_mapping) == "table" and data.temp_id_mapping[uuid]
        return { ok = true, task_id = id and tostring(id) or "" }
    end
    if type(s) == "table" then
        local why = type(s.error) == "string" and s.error or "unknown error"
        local n = s.error_code and (" (" .. tostring(s.error_code) .. ")") or ""
        return fail("permanent", "Todoist refused the task: " .. why .. n .. ".", retry_after_of(s))
    end
    return unreadable()
end

--- Sorts the answer to a user_request.
-- @return { ok = true, name } or a failure like parse_add
function M.parse_user(json, code, body)
    local failure = classify_http(json, code, body)
    if failure then return failure end
    local data = decode(json, body)
    local user = data and data.user
    if type(user) ~= "table" then return unreadable() end
    local name = user.full_name
    if type(name) ~= "string" or name == "" then name = user.email end
    if type(name) ~= "string" or name == "" then return unreadable() end
    return { ok = true, name = name }
end

-- Patterns (on the lowercased error) -> the only words that reach the log.
local REASONS = {
    { "timeout", "timeout" }, { "timed out", "timeout" },
    { "host not found", "host not found" }, { "name resolution", "host not found" },
    { "name or service not known", "host not found" }, { "no address associated", "host not found" },
    { "refused", "connection refused" },
    { "ssl", "TLS" }, { "tls", "TLS" }, { "certificate", "TLS" }, { "handshake", "TLS" },
    { "wrong version number", "TLS" },
    { "closed", "closed" },
}

--- A short, fixed reason for a failed `send` (its second return value), safe
-- to log: timeout / host not found / connection refused / TLS / closed / other.
-- The raw text never passes through: it could contain request data.
function M.failure_reason(err)
    if type(err) ~= "string" then return "other" end
    local s = err:lower()
    for _, r in ipairs(REASONS) do
        if s:find(r[1], 1, true) then return r[2] end
    end
    return "other"
end

--- One HTTP request. Child process only (blocks); the requires are lazy so the
-- module loads in tests.
-- @tparam table req { url, method, headers, body }
-- @int timeout seconds
-- @return status code and body, or nil and an error message
function M.send(req, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local headers = {}
    for k, v in pairs(req.headers or {}) do headers[k] = v end
    headers["Content-Length"] = tostring(#(req.body or ""))
    local sink = {}
    socketutil:set_timeout(timeout, timeout)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = req.url, method = req.method or "POST", headers = headers,
        source = ltn12.source.string(req.body or ""), sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if resp_headers == nil or type(code) ~= "number" then
        return nil, tostring(status or code or "network unreachable")
    end
    return code, table.concat(sink)
end

return M
