--[[--
Runs one network task in a background process, so KOReader never freezes
while Todoist answers.

    local handle = td_request.start(task, on_done, { timeout = 20 })
    handle.cancel()  -- kills the child; on_done is never called

`task` runs in the child (a fork of KOReader) and must return one plain table
(no functions or cdata). It must not touch the UI, settings or Wi-Fi.
`on_done(result)` runs in KOReader with that table, or with
{ ok = false, kind = "temporary", message = "No connection." } when the child
timed out, died or sent garbage. The message is fixed on purpose: it never
carries raw error text, which could contain request data. The reason goes to
the log only (never request headers or body: the token is in the headers).

The child pattern is KOReader's own (Trapper:dismissableRunInSubprocess), without
its modal "tap anywhere to cancel" box.
]]

local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffiutil = require("ffi/util")
local logger = require("logger")

local M = {}

local POLL = 0.2       -- seconds between checks (positive: KOReader keeps reading input)
local COLLECT = 5      -- seconds between tries to reap a killed child
local GRACE = 5        -- seconds past the task's own timeout before the child is killed
local DEFAULT_TIMEOUT = 20

local function no_connection()
    return { ok = false, kind = "temporary", message = "No connection." }
end

--- Wait for a killed or finished child in the background so it never stays a zombie.
local function collect(pid, fd)
    local function try()
        if ffiutil.isSubProcessDone(pid) then
            if fd then ffiutil.readAllFromFD(fd) end -- closes it
            return
        end
        if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            ffiutil.readAllFromFD(fd) -- lets a child blocked on write() exit
            fd = nil
        end
        UIManager:scheduleIn(COLLECT, try)
    end
    UIManager:scheduleIn(COLLECT, try)
end

--- Start `task` in a child process. Returns a handle, or nil and an error.
-- @tparam function task returns a plain table
-- @tparam function on_done called with the result table (never after cancel)
-- @tparam table opts { timeout = seconds the task itself may take (default 20) }
function M.start(task, on_done, opts)
    local timeout = (opts and opts.timeout or DEFAULT_TIMEOUT) + GRACE
    local pid, fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local ok, result = pcall(task)
        if not ok then
            -- The error text is not logged or sent: it could contain request data.
            logger.warn("Todoist: request task raised an error")
            result = no_connection()
        end
        local sok, str = pcall(buffer.encode, result)
        if not sok then
            logger.warn("Todoist: request result could not be encoded")
            str = buffer.encode(no_connection())
        end
        ffiutil.writeToFD(write_fd, str, true)
    end, true)
    if not pid then
        logger.warn("Todoist: could not start the request process")
        return nil, fd
    end

    local handle = { done = false }
    local started = os.time()
    local poll

    local function finish(result)
        handle.done = true
        local ok, err = pcall(on_done, result)
        if not ok then logger.warn("Todoist: request callback failed:", err) end
    end

    poll = function()
        if handle.done then return end
        local exited = ffiutil.isSubProcessDone(pid)
        local readable = ffiutil.getNonBlockingReadSize(fd) ~= 0
        if readable or exited then
            local data = ffiutil.readAllFromFD(fd)
            if not exited then collect(pid, nil) end
            local ok, result = pcall(buffer.decode, data)
            if not ok or type(result) ~= "table" then
                logger.warn("Todoist: request process gave no usable answer")
                result = no_connection()
            end
            finish(result)
        elseif os.time() - started > timeout then
            logger.warn("Todoist: request timed out")
            ffiutil.terminateSubProcess(pid)
            collect(pid, fd)
            finish(no_connection())
        else
            UIManager:scheduleIn(POLL, poll)
        end
    end
    UIManager:scheduleIn(POLL, poll)

    function handle.cancel()
        if handle.done then return end
        handle.done = true
        UIManager:unschedule(poll)
        ffiutil.terminateSubProcess(pid)
        collect(pid, fd)
    end
    return handle
end

return M
