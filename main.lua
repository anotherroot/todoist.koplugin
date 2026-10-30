--[[--
Todoist: send quotes and ideas to your Todoist Inbox.

@module koplugin.Todoist
--]]--
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Todoist = WidgetContainer:extend{
    name = "todoist",
    is_doc_only = false,
}

function Todoist:init()
    self.ui.menu:registerToMainMenu(self)
end

function Todoist:addToMainMenu(menu_items)
    menu_items.todoist = {
        text = _("Todoist"),
        sorting_hint = "tools",
        sub_item_table = {}, -- filled in Task 8
    }
end

return Todoist
