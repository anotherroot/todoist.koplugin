--[[--
The retry queue: sends history items to Todoist one at a time and keeps their
status honest. An item is `sent` only after Todoist confirmed it; anything
else (no answer, timeout, crash) leaves it unsent and it is tried again with
the same uuid, so Todoist never adds it twice.

    local queue = td_queue.new(deps)
    queue:submit(id)      -- the owner just saved it
    queue:kick()          -- on start, on NetworkConnected, by its own timer

`deps`: store, json, now(), token(), with_book(), online(),
run(req, on_done, uuid), schedule(seconds, fn), unschedule(fn),
alert({ count, message, kind }), notify(text).
Everything KOReader-specific comes in through `deps`, so the queue runs in tests.
]]

local td_api = require("td_api")
local td_format = require("td_format")
local td_history = require("td_history")

local NONE = td_history.NONE

local M = {}

M.BACKOFF = { 60, 120, 300, 900, 1800 } -- seconds; the last one repeats forever
M.WATCHDOG = 60 -- seconds without an answer before a request counts as lost
M.ALERT_AFTER = 3 -- temporary failures in a row before the owner is alerted
M.NO_KEY = "No Todoist API key. Add it in Settings."
M.CANT_PREPARE = "Couldn't prepare the task."

-- KOReader's logger when there is one (not in tests). Never pass the token.
local function warn(...)
    local ok, logger = pcall(require, "logger")
    if ok and type(logger) == "table" and logger.warn then pcall(logger.warn, ...) end
end

local function redact(s, secret)
    if type(secret) ~= "string" or secret == "" then return s end
    local out, i = {}, 1
    while true do
        local a, b = s:find(secret, i, true)
        if not a then break end
        out[#out + 1] = s:sub(i, a - 1) .. "***"
        i = b + 1
    end
    out[#out + 1] = s:sub(i)
    return table.concat(out)
end

local function no_connection()
    return { ok = false, kind = "temporary", message = "No connection." }
end

local function backoff(attempts)
    return M.BACKOFF[math.min(math.max(attempts, 1), #M.BACKOFF)]
end

-- Blocked items wait for the owner (new key or "Send again"), never the timer.
local function blocked(item)
    return item.error_kind == "auth" or item.error_kind == "permanent"
end

local CLEARED = { last_error = NONE, error_kind = NONE, next_try = NONE }

local function cleared(changes)
    for k, v in pairs(CLEARED) do changes[k] = v end
    return changes
end

local Queue = {}
Queue.__index = Queue

function M.new(deps)
    local self = setmetatable({
        deps = deps,
        store = deps.store,
        in_flight = nil,   -- { id, watchdog } of the one request out
        auth_blocked = false,
        fresh = {},        -- ids the owner submitted just now: they get a toast
        alerted = 0,       -- unsent count at the last alert
    }, Queue)
    self.tick = function() self:kick() end
    return self
end

--- Unsent items oldest first (creation order).
function Queue:_oldest_first()
    local list = self.store:list("unsent")
    local out = {}
    for i = #list, 1, -1 do out[#out + 1] = list[i] end
    return out
end

function Queue:unsent_count()
    return #self.store:list("unsent")
end

--- What the owner should be told about, or nil: any failed item with a key
-- error, a permanent error, or ALERT_AFTER+ attempts. Key errors win (the
-- alert then offers Settings), then permanent, then the newest stuck item.
function Queue:pending_alert()
    local unsent = self.store:list("unsent") -- newest first
    local pick, rank = nil, 0
    for _, item in ipairs(unsent) do
        if item.status == "failed" then
            local r = (item.error_kind == "auth" and 3)
                or (item.error_kind == "permanent" and 2)
                or ((item.attempts or 0) >= M.ALERT_AFTER and 1)
                or 0
            if r > rank then pick, rank = item, r end
        end
    end
    if not pick then return nil end
    return { count = #unsent, message = pick.last_error, kind = pick.error_kind }
end

function Queue:alert_shown()
    self.alerted = self:unsent_count()
end

--- Alerts when something is stuck and (unless `always`) more items are unsent
-- than at the last alert. Returns true if it alerted.
function Queue:_maybe_alert(always)
    local info = self:pending_alert()
    if not info then return false end
    if not always and info.count <= self.alerted then return false end
    self.alerted = info.count
    local ok, err = pcall(self.deps.alert, info)
    if not ok then warn("Todoist: alert failed:", tostring(err)) end
    return true
end

function Queue:submit(item_id)
    if not self.store:get(item_id) then return end
    if not self.deps.online() then
        self:_notify("Saved, will send when Wi-Fi is on")
        return
    end
    if self.auth_blocked then
        if not self:_maybe_alert() then
            self:_notify("Saved, not sent: check the API key in Settings")
        end
        return
    end
    self.fresh[item_id] = true
    self:kick()
end

--- Sends the oldest due item, if none is out yet; otherwise (re)arms the timer
-- for the earliest retry. Safe to call any number of times.
function Queue:kick()
    if self.in_flight or self.auth_blocked then return end
    self.deps.unschedule(self.tick)
    if not self.deps.online() then return end
    local now = self.deps.now()
    local earliest
    for _, item in ipairs(self:_oldest_first()) do
        if item.status == "waiting" then
            return self:_start(item)
        end
        if item.status == "failed" and not blocked(item) then
            local at = item.next_try or 0
            if at <= now then return self:_start(item) end
            if not earliest or at < earliest then earliest = at end
        end
    end
    if earliest then self.deps.schedule(earliest - now, self.tick) end
end

function Queue:_start(item)
    local id = item.id
    self.store:update(id, {
        status = "sending",
        last_attempt = self.deps.now(),
        attempts = (item.attempts or 0) + 1,
    })
    -- Anything that raises before the request is out must not leave the item
    -- `sending` or the slot taken: it ends as a permanent failure (alerted).
    local flight = { id = id }
    local ok, err = pcall(self._launch, self, item, flight)
    if ok then return end
    warn("Todoist: couldn't prepare the task:", redact(tostring(err), flight.token))
    if flight.settled then return end -- the attempt had already ended; the error came after
    flight.settled = true
    if flight.watchdog then pcall(self.deps.unschedule, flight.watchdog) end
    self:_finish(id, { ok = false, kind = "permanent", message = M.CANT_PREPARE })
end

function Queue:_launch(item, flight)
    local id = item.id
    local token = self.deps.token()
    flight.token = token
    if type(token) ~= "string" or token == "" then
        flight.settled = true
        return self:_finish(id, { ok = false, kind = "auth", message = M.NO_KEY })
    end
    local req = td_api.add_request(self.deps.json, token, id,
        td_format.task(item, { with_book = self.deps.with_book() and true or false }))

    local function on_done(result)
        if flight.settled or self.in_flight ~= flight then return end -- late answer to a lost attempt
        flight.settled = true
        pcall(self.deps.unschedule, flight.watchdog)
        self:_finish(id, result)
    end
    flight.watchdog = function()
        if flight.settled or self.in_flight ~= flight then return end
        flight.settled = true
        self:_finish(id, no_connection())
    end
    self.in_flight = flight
    self.deps.schedule(M.WATCHDOG, flight.watchdog)
    if not pcall(self.deps.run, req, on_done, id) then on_done(no_connection()) end
end

--- notify/alert come from the UI: if one raises, the queue still moves on.
function Queue:_notify(text)
    local ok, err = pcall(self.deps.notify, text)
    if not ok then warn("Todoist: notify failed:", tostring(err)) end
end

function Queue:_finish(id, result)
    self.in_flight = nil
    local was_fresh = self.fresh[id]
    self.fresh[id] = nil
    if type(result) ~= "table" then result = no_connection() end
    local now = self.deps.now()
    local item = self.store:get(id)

    if item and result.ok then
        local saved = select(2, self.store:update(id, cleared({
            status = "sent", task_id = result.task_id or "", sent_at = now,
        })))
        if not saved then
            self:_notify("Sent, but the history couldn't be saved.")
        elseif was_fresh then
            self:_notify("Sent to Todoist")
        end
    elseif item then
        local kind = result.kind
        if kind ~= "auth" and kind ~= "permanent" then kind = "temporary" end
        local changes = {
            status = "failed",
            error_kind = kind,
            last_error = result.message or "No connection.",
            next_try = NONE,
        }
        if kind == "temporary" then
            changes.next_try = now + math.max(backoff(item.attempts or 1), tonumber(result.retry_after) or 0)
        end
        self.store:update(id, changes)
        if kind == "auth" then self.auth_blocked = true end
        if kind == "temporary" then
            if was_fresh then self:_notify("Saved, will send later") end
            self:_maybe_alert()
        else
            self:_maybe_alert(true)
        end
    end

    local n = self:unsent_count()
    if n < self.alerted then self.alerted = n end
    self:kick()
end

--- "Send again": a sent item gets a new copy (new uuid); any other item is
-- retried as itself, with the same uuid. Returns the id that was submitted.
function Queue:resend(item_id)
    local item = self.store:get(item_id)
    if not item then return nil end
    if item.status == "sent" then
        local copy = self.store:copy(item_id)
        if not copy then return nil end
        self:submit(copy.id)
        return copy.id
    end
    if self.in_flight and self.in_flight.id == item_id then return item_id end
    if item.error_kind == "auth" then self.auth_blocked = false end
    self.store:update(item_id, cleared({ status = "waiting", attempts = 0 }))
    self:submit(item_id)
    return item_id
end

--- The API key changed: key-failed items go back to waiting and are sent.
function Queue:key_changed()
    self.auth_blocked = false
    for _, item in ipairs(self:_oldest_first()) do
        if item.status == "failed" and item.error_kind == "auth" then
            self.store:update(item.id, cleared({ status = "waiting", attempts = 0 }))
        end
    end
    self:kick()
end

--- The real `deps.run`: the request goes out in a child process (td_request),
-- and the answer is sorted by td_api.parse_add. Anything without an HTTP code
-- (timeout, dead child, no process) is a temporary "No connection.".
-- Needs KOReader, so td_request is required here, not at load.
function M.real_run(json)
    return function(req, on_done, uuid)
        local td_request = require("td_request")
        local function done(raw)
            if type(raw) == "table" and raw.code ~= nil then
                on_done(td_api.parse_add(json, uuid, raw.code, raw.body))
            else
                on_done(td_api.parse_add(json, uuid, nil, nil))
            end
        end
        local handle = td_request.start(function()
            local code, body = td_api.send(req, 15)
            return { code = code, body = body }
        end, done, { timeout = 15 })
        if not handle then done(nil) end
    end
end

return M
