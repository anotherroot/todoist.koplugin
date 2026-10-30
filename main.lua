--[[--
Todoist: send quotes and ideas to your Todoist Inbox.

@module koplugin.Todoist
--]]--
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local td_context = require("td_context")
local td_history = require("td_history")
local td_queue = require("td_queue")
local td_safe = require("td_safe")
local td_ui = require("td_ui")
local guarded, quietly = td_safe.guarded, td_safe.quietly

local Todoist = WidgetContainer:extend{
    name = "todoist",
    is_doc_only = false,
}

local KEY_HELP = _("Get it at app.todoist.com/app/settings/integrations → Developer. Or copy it into settings/todoist_token.txt.")

---------------------------------------------------------------- settings

local function settings()
    return G_reader_settings:readSetting("todoist") or {}
end

local function save_settings(s)
    G_reader_settings:saveSetting("todoist", s)
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- The API key and where it comes from ("file" | "setting"), or nil.
local function current_token()
    local file = read_file(DataStorage:getSettingsDir() .. "/" .. td_ui.TOKEN_FILE)
    return td_ui.token_from(file, settings().token)
end

local function with_book()
    return settings().ideas_with_book == true
end

local function online()
    -- isConnected first: it's cheap, isOnline asks DNS.
    return NetworkMgr:isConnected() and NetworkMgr:isOnline() and true or false
end

local function reader()
    return require("apps/reader/readerui").instance
end

---------------------------------------------------------------- the queue
-- Module level, so it outlives plugin instances (one per book or file browser).

local store, queue

-- UIManager runs scheduled functions unprotected: wrap the queue's timers, and
-- remember each wrapper (until it ran or was unscheduled) so unschedule() finds it.
local scheduled = {}

local function schedule(seconds, fn)
    local w = scheduled[fn]
    if not w then
        local run = guarded(fn)
        w = function()
            scheduled[fn] = nil
            run()
        end
        scheduled[fn] = w
    end
    UIManager:scheduleIn(seconds, w)
end

local function unschedule(fn)
    local w = scheduled[fn]
    if w then
        scheduled[fn] = nil
        UIManager:unschedule(w)
    end
end

local show_alert -- defined below (needs the history and the key dialog)

local function get_queue()
    if queue then return queue end
    local json = require("json")
    store = td_history.open(DataStorage:getSettingsDir() .. "/todoist_history.json", json)
    queue = td_queue.new{
        store = store,
        json = json,
        now = os.time,
        token = function() return (current_token()) end,
        with_book = with_book,
        online = online,
        run = td_queue.real_run(json),
        schedule = schedule,
        unschedule = unschedule,
        -- With no book open the alert waits: pending_alert() shows it at the next book open.
        alert = guarded(function(info)
            local ui = reader()
            if ui then show_alert(info, ui) end
        end),
        notify = guarded(td_ui.notify),
    }
    return queue
end

--- Only a hash of the key is kept here (the key itself never twice). When the
-- key changed since it was last seen (file copied over USB, or Settings),
-- items that failed on the old key go back to waiting. `force`: tell the queue anyway.
local function check_key(force)
    local q = get_queue()
    local hash = require("ffi/sha2").sha256(current_token() or "")
    local s = settings()
    if s.token_hash ~= hash then
        s.token_hash = hash
        save_settings(s)
        force = true
    end
    if force then q:key_changed() end
end

--- The queue, started on first use: key check, then send whatever is waiting.
local function start()
    local first = queue == nil
    local q = get_queue()
    if first then
        check_key()
        q:kick()
    end
    return q
end

local function kick()
    local q = start()
    check_key()
    q:kick()
end

--- Saves a new item, then sends it (asking for Wi-Fi the way KOReader is set to).
local function send(fields)
    if td_ui.blank(fields and fields.text) then
        return td_ui.notify(_("Nothing to send."))
    end
    local q = start()
    check_key()
    local item, saved, err = store:add(fields)
    if not saved then
        td_ui.info(_("Saved in memory only: the history file couldn't be written.")
            .. (err and ("\n\n" .. tostring(err)) or ""))
    end
    local id = item.id
    -- Saved before Wi-Fi is asked for, so cancelling the prompt loses nothing.
    -- Offline, submit says "Saved, will send when Wi-Fi is on".
    if online() then return q:submit(id) end
    q:submit(id)
    NetworkMgr:runWhenOnline(guarded(function() get_queue():submit(id) end))
end

---------------------------------------------------------------- screens

--- `ui`: the open reader (for "Go to"), or nil in the file browser.
local function open_history(ui, filter)
    local q = start() -- first, so `store` exists
    td_ui.history(store, q, ui, filter)
end

local function edit_key(touchmenu)
    local InputDialog = require("ui/widget/inputdialog")
    local token, source = current_token()
    local description = _("Now:") .. " " .. td_ui.key_label(token, source) .. "\n\n" .. KEY_HELP
    if source == "file" then
        description = description .. "\n\n" .. _("The key in todoist_token.txt wins over one set here.")
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Todoist API key"),
        input = "", -- never put the key on screen
        input_hint = _("Paste or type the key (empty: remove)"),
        description = description,
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = guarded(function() UIManager:close(dialog) end),
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = guarded(function()
                    local typed = td_ui.token_from(nil, dialog:getInputText())
                    UIManager:close(dialog)
                    local s = settings()
                    s.token = typed
                    save_settings(s)
                    check_key(true)
                    if touchmenu then touchmenu:updateItems() end
                end),
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

show_alert = function(info, ui)
    td_ui.alert(info,
        function() open_history(ui or reader(), "unsent") end,
        info.kind == "auth" and function() edit_key() end or nil)
end

local function test_connection()
    local token = current_token()
    if not token then return td_ui.info(td_queue.NO_KEY) end
    NetworkMgr:runWhenOnline(guarded(function()
        local json = require("json")
        local td_api = require("td_api")
        local td_request = require("td_request")
        local InfoMessage = require("ui/widget/infomessage")
        local req = td_api.user_request(json, token)
        local waiting = InfoMessage:new{ text = _("Testing the connection…") }
        UIManager:show(waiting)
        local done = guarded(function(raw)
            UIManager:close(waiting)
            local code, body
            if type(raw) == "table" then code, body = raw.code, raw.body end
            local result = td_api.parse_user(json, code, body)
            if result.ok then
                td_ui.info(_("Connected as") .. " " .. result.name)
            else
                td_ui.info(_("Connection failed:") .. " " .. tostring(result.message))
            end
        end)
        local handle = td_request.start(function()
            local code, body = td_api.send(req, 15)
            return { code = code, body = body }
        end, done, { timeout = 15 })
        if not handle then done(nil) end
    end))
end

local function clear_sent()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Remove all sent items from the history?\nItems not sent yet are kept."),
        ok_text = _("Clear"),
        ok_callback = guarded(function()
            start()
            local ok, err = store:clear_sent()
            if not ok then td_ui.info(_("Couldn't save the history:") .. " " .. tostring(err)) end
        end),
    })
end

---------------------------------------------------------------- plugin

function Todoist:init()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self:addHighlightButton()
    end
    -- The first instance starts the queue; later ones find it running.
    UIManager:nextTick(guarded(start))
end

function Todoist:addHighlightButton()
    -- Sorts after "12_h_wormhole" and before "12_search" (always last).
    -- `index` is set when the dialog comes from an existing highlight ("…").
    self.ui.highlight:addToHighlightDialog("12_i_todoist", quietly(function(this, index)
        return {
            text = _("Send to Todoist"),
            callback = guarded(function()
                local ui = this.ui
                local annotation = index and ui.annotation and ui.annotation.annotations[index]
                local fields
                if annotation then
                    fields = td_context.from_annotation(ui, annotation)
                else
                    fields = td_context.from_selection(ui, this.selected_text)
                end
                this:onClose() -- clears the selection; never saves a highlight
                send(fields)
            end),
        }
    end, { text = _("Send to Todoist"), enabled = false }))
end

function Todoist:newIdea()
    local InputDialog = require("ui/widget/inputdialog")
    local ui = self.ui
    local dialog
    dialog = InputDialog:new{
        title = _("New idea"),
        allow_newline = true,
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = guarded(function() UIManager:close(dialog) end),
            },
            {
                text = _("Send"),
                is_enter_default = true,
                callback = guarded(function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    send(td_context.for_idea(ui, text, with_book()))
                end),
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Todoist:addToMainMenu(menu_items)
    menu_items.todoist = {
        text_func = quietly(function() return td_ui.menu_label(start():unsent_count()) end, _("Todoist")),
        sorting_hint = "tools",
        sub_item_table_func = quietly(function() return self:menuItems() end, {}),
    }
end

function Todoist:menuItems()
    return {
        {
            text = _("New idea…"),
            callback = guarded(function() self:newIdea() end),
        },
        {
            text = _("Sent items"),
            callback = guarded(function() open_history(reader()) end),
        },
        {
            text = _("Settings"),
            sub_item_table = {
                {
                    text_func = quietly(function()
                        return _("API key:") .. " " .. td_ui.key_label(current_token())
                    end, _("API key")),
                    help_text = KEY_HELP,
                    keep_menu_open = true,
                    callback = guarded(function(touchmenu) edit_key(touchmenu) end),
                },
                {
                    text = _("Test connection"),
                    keep_menu_open = true,
                    callback = guarded(test_connection),
                },
                {
                    text = _("Add book and page to ideas"),
                    checked_func = quietly(with_book, false),
                    callback = guarded(function()
                        local s = settings()
                        s.ideas_with_book = (not with_book()) or nil
                        save_settings(s)
                    end),
                    separator = true,
                },
                {
                    text = _("Clear sent items…"),
                    keep_menu_open = true,
                    callback = guarded(clear_sent),
                },
            },
        },
    }
end

-- Event handlers: guarded, and they never return true (others need these events too).
Todoist.onNetworkConnected = guarded(function()
    kick()
end)

Todoist.onReaderReady = guarded(function(self)
    local ui = self.ui
    td_ui.apply_pending_jump(ui)
    UIManager:nextTick(guarded(function()
        local q = start()
        local info = q:pending_alert()
        if info then
            show_alert(info, ui)
            q:alert_shown()
        end
    end))
end)

return Todoist
