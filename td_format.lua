-- Turns a history item into the Todoist task title and description.
-- The nightly sorter recognises items by the description's first line.
local M = {}

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function split(s)
    local t = {}
    for c in s:gmatch(CHAR) do t[#t + 1] = c end
    return t
end

local function oneline(s)
    return (tostring(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function M.title(text, max)
    max = max or 250
    local s = oneline(text)
    local c = split(s)
    if #c <= max then return s, false end
    local keep = max - 1
    if c[max] ~= " " then
        for i = keep, 1, -1 do
            if c[i] == " " then
                if i > keep / 2 then keep = i - 1 end
                break
            end
        end
    end
    local out = table.concat(c, "", 1, keep):gsub(" +$", "")
    return out .. "…", true
end

function M.preview(text, n)
    local c = split(oneline(text))
    if #c <= n then return table.concat(c) end
    return table.concat(c, "", 1, n) .. "…"
end

function M.task(item, opts)
    local content, cut = M.title(item.text)
    local quote = item.kind == "quote"
    local lines = { quote and "📖 Kobo quote" or "💡 Kobo idea" }
    if quote or (opts and opts.with_book) then
        if item.book then lines[#lines + 1] = "Book: " .. item.book end
        if item.author then lines[#lines + 1] = "Author: " .. item.author end
        if item.page then lines[#lines + 1] = "Page: " .. item.page end
    end
    lines[#lines + 1] = "Captured: " .. os.date("%Y-%m-%d %H:%M", item.created)
    if item.note then lines[#lines + 1] = "Note: " .. item.note end
    local description = table.concat(lines, "\n")
    if cut then description = description .. "\n\n" .. item.text end
    return { content = content, description = description }
end

return M
