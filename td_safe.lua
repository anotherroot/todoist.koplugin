-- Crash guards for everything KOReader calls into: an error becomes a
-- message (or a log line), never a crash while reading.
local M = {}

-- Default report: log it and show it. Loaded lazily so tests need no KOReader.
local function show(err)
    local ok, logger = pcall(require, "logger")
    if ok then logger.err("Todoist:", err) end
    local ok2 = pcall(function()
        local InfoMessage = require("ui/widget/infomessage")
        require("ui/uimanager"):show(InfoMessage:new{ text = "Todoist error: " .. tostring(err) })
    end)
    if not ok2 then io.stderr:write("Todoist: ", tostring(err), "\n") end
end

local function log_only(err)
    local ok, logger = pcall(require, "logger")
    if ok then logger.err("Todoist:", err) end
end

--- For actions (callbacks): run f; on error report it (default: a message).
function M.guarded(f, report)
    return function(...)
        local ok, err = pcall(f, ...)
        if not ok then (report or show)(err) end
    end
end

--- For text_func / enabled_func: f's value, or fallback after an error
-- (logged only: a menu that pops up messages while drawing is worse).
function M.quietly(f, fallback, report)
    return function(...)
        local ok, value = pcall(f, ...)
        if ok then return value end
        ;(report or log_only)(value)
        return fallback
    end
end

return M
