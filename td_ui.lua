--[[--
The plugin's screens: history list, item popup, alert, "Go to".
The text helpers at the top are plain functions (tested without KOReader);
KOReader widgets are required inside the functions that show them.
]]

local td_format = require("td_format")
local td_safe = require("td_safe")
local guarded = td_safe.guarded

local _
do
    local ok, gettext = pcall(require, "gettext")
    _ = ok and gettext or function(s) return s end
end

local M = {}

-- KOReader's bundled fonts have no 📖 (U+1F4D6); its symbol fallback font
-- (nerdfonts) has Font Awesome's book and lightbulb, so the list uses those.
M.QUOTE_MARK = "\u{F02D}"
M.IDEA_MARK = "\u{F0EB}"
M.TOKEN_FILE = "todoist_token.txt"

---------------------------------------------------------------- text helpers

--- True when there is nothing worth sending (nil, empty, only whitespace).
function M.blank(text)
    return text == nil or not tostring(text):find("%S")
end

--- The API key: the file wins over the setting. Returns key, "file"|"setting"; nil when neither has one.
function M.token_from(file_text, setting)
    local function trim(s)
        return type(s) == "string" and s:match("^%s*(.-)%s*$") or ""
    end
    local t = trim(file_text)
    if t ~= "" then return t, "file" end
    t = trim(setting)
    if t ~= "" then return t, "setting" end
    return nil
end

--- Where the key comes from, showing only its last 4 characters.
function M.key_label(token, source)
    if type(token) ~= "string" or token == "" then return _("not set") end
    local tail = "(…" .. token:sub(-4) .. ")"
    if source == "file" then
        return _("from file") .. " " .. M.TOKEN_FILE .. " " .. tail
    end
    return _("set here") .. " " .. tail
end

function M.menu_label(unsent)
    unsent = tonumber(unsent) or 0
    if unsent <= 0 then return _("Todoist") end
    return string.format(_("Todoist (%d not sent)"), unsent)
end

function M.history_title(filter)
    return filter == "unsent" and _("Todoist: not sent") or _("Todoist: sent items")
end

--- One history row: marker + preview, status word on the right.
function M.row(item)
    local mark = item.kind == "idea" and M.IDEA_MARK or M.QUOTE_MARK
    return {
        text = mark .. " " .. td_format.preview(item.text or "", 60),
        mandatory = item.status,
    }
end

local function stamp(t)
    if tonumber(t) then return os.date("%Y-%m-%d %H:%M", tonumber(t)) end
    return nil
end

--- The item popup's text: everything kept about the item.
function M.details(item)
    local lines = { item.text or "", "" }
    local function add(label, value)
        if value ~= nil and value ~= "" then lines[#lines + 1] = label .. " " .. tostring(value) end
    end
    add(_("Book:"), item.book)
    add(_("Author:"), item.author)
    add(_("Page:"), item.page)
    add(_("Note:"), item.note)
    add(_("Captured:"), stamp(item.created))
    add(_("Status:"), item.status)
    if item.status == "sent" then add(_("Sent:"), stamp(item.sent_at)) end
    if item.status == "failed" then add(_("Error:"), item.last_error) end
    return table.concat(lines, "\n")
end

function M.alert_text(info)
    local n = tonumber(info.count) or 0
    local head = n == 1 and _("Todoist: 1 item not sent.")
        or string.format(_("Todoist: %d items not sent."), n)
    if M.blank(info.message) then return head end
    return head .. "\n\n" .. tostring(info.message)
end

-------------------------------------------------------------------- widgets

local function show(widget)
    require("ui/uimanager"):show(widget)
end

local function close(widget)
    if widget then require("ui/uimanager"):close(widget) end
end

local function info(text)
    local InfoMessage = require("ui/widget/infomessage")
    show(InfoMessage:new{ text = text })
end
M.info = info

--- A short toast, shown whatever the notification settings say.
function M.notify(text)
    local Notification = require("ui/widget/notification")
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

--- The alert: a dialog that stays until tapped away.
-- open_settings is only offered for key errors.
function M.alert(info_, open_history, open_settings)
    local ConfirmBox = require("ui/widget/confirmbox")
    local other
    if info_.kind == "auth" and open_settings then
        other = { { { text = _("Settings"), callback = guarded(open_settings) } } }
    end
    show(ConfirmBox:new{
        text = M.alert_text(info_),
        icon = "notice-warning",
        ok_text = _("Show items"),
        ok_callback = guarded(open_history),
        cancel_text = _("Close"),
        other_buttons = other,
        flush_events_on_show = true, -- it can pop up mid-tap; don't let that tap dismiss it
    })
end

-- "Go to" a book that isn't open yet: kept here (module level) until that
-- book's ReaderReady.
local pending_jump

local function jump(ui, pos)
    local Event = require("ui/event")
    if ui.rolling and type(pos[1]) == "string" then
        ui:handleEvent(Event:new("GotoXPointer", pos[1], pos[1]))
    elseif ui.paging and tonumber(pos.page) then
        ui:handleEvent(Event:new("GotoPage", tonumber(pos.page)))
    end
end

--- Called on ReaderReady: jump if this is the book a "Go to" opened.
function M.apply_pending_jump(ui)
    local p = pending_jump
    if not p or type(ui) ~= "table" or type(ui.document) ~= "table" then return end
    pending_jump = nil
    if ui.document.file ~= p.file then return end
    require("ui/uimanager"):nextTick(guarded(function() jump(ui, p.pos) end))
end

--- Jump to where a quote came from, opening its book if needed.
-- `ui` is the open ReaderUI or nil (file browser).
function M.go_to(item, ui)
    local file, pos = item.file, item.pos
    if type(file) ~= "string" or type(pos) ~= "table" then return end
    if ui and type(ui.document) == "table" and ui.document.file == file then
        return jump(ui, pos)
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(file, "mode") ~= "file" then
        return info(_("This book isn't on the device any more:") .. "\n" .. file)
    end
    pending_jump = { file = file, pos = pos }
    if ui and ui.switchDocument then
        ui:switchDocument(file)
    else
        require("apps/reader/readerui"):showReader(file)
    end
end

local function can_go_to(item)
    return item.kind == "quote" and type(item.file) == "string" and type(item.pos) == "table"
end

--- The popup for one item, built from its current state.
-- on_change() runs after "Send again"; leave() closes the history (before "Go to").
function M.item_popup(store, queue, ui, id, on_change, leave)
    local item = store:get(id)
    if not item then return end
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local row = {
        {
            text = _("Send again"),
            callback = guarded(function()
                close(viewer)
                queue:resend(id)
                if on_change then on_change() end
            end),
        },
    }
    if can_go_to(item) then
        row[#row + 1] = {
            text = _("Go to"),
            callback = guarded(function()
                close(viewer)
                if leave then leave() end
                M.go_to(item, ui)
            end),
        }
    end
    row[#row + 1] = { text = _("Close"), callback = guarded(function() close(viewer) end) }
    viewer = TextViewer:new{
        title = item.kind == "idea" and _("Idea") or _("Quote"),
        text = M.details(item),
        buttons_table = { row },
    }
    show(viewer)
end

--- The history list, newest first. filter "unsent" = waiting + sending + failed.
function M.history(store, queue, ui, filter)
    local Menu = require("ui/widget/menu")
    local menu
    local refresh

    local function leave() close(menu) end

    local function rows()
        local out = {}
        for __, item in ipairs(store:list(filter)) do
            local row = M.row(item)
            local id = item.id
            row.callback = guarded(function()
                M.item_popup(store, queue, ui, id, refresh, leave)
            end)
            out[#out + 1] = row
        end
        if #out == 0 then
            out[1] = {
                text = filter == "unsent" and _("Nothing waiting: everything was sent.") or _("Nothing here yet."),
                select_enabled = false,
            }
        end
        return out
    end

    refresh = function()
        local items = rows()
        -- Same length: stay on this page; otherwise start from the top.
        local keep = (#items == #menu.item_table) and -1 or nil
        menu:switchItemTable(nil, items, keep)
    end

    menu = Menu:new{
        title = M.history_title(filter),
        item_table = rows(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
    }
    show(menu)
    return menu
end

return M
