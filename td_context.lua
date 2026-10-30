-- Turns KOReader's reader state (book, selection, annotation, current page)
-- into the plain fields the history store keeps. Every lookup tolerates
-- missing pieces and errors: a field it cannot read is left nil.

local M = {}

local function nonempty(s)
    if s == nil then return nil end
    s = tostring(s)
    if s == "" then return nil end
    return s
end

local function try(f, ...)
    local ok, a = pcall(f, ...)
    if ok then return a end
    return nil
end

local function page_count(doc)
    local n = tonumber(doc and try(doc.getPageCount, doc))
    if n and n > 0 then return n end
    return nil
end

local function of(page, total)
    if page == nil or total == nil then return nil end
    page, total = nonempty(page), nonempty(total)
    if not page or not total then return nil end
    return page .. " of " .. total
end

local function wants_labels(ui)
    local pm = ui.pagemap
    return pm ~= nil and try(pm.wantsPageLabels, pm) and true or false
end

function M.book(ui)
    local out = {}
    if type(ui) ~= "table" then return out end
    local props = ui.doc_props
    if type(props) == "table" then
        out.book = nonempty(props.display_title) or nonempty(props.title)
        local authors = nonempty(props.authors)
        if authors then out.author = nonempty((authors:gsub("\n", ", "))) end
    end
    if type(ui.document) == "table" then out.file = nonempty(ui.document.file) end
    return out
end

-- Page of a position: an xpointer (rolling) or a { page = n } table (paging).
function M.page_at(ui, pos)
    if type(ui) ~= "table" or pos == nil or type(ui.document) ~= "table" then return nil end
    local doc = ui.document
    if ui.rolling then
        if type(pos) ~= "string" then return nil end
        if wants_labels(ui) then
            local pm = ui.pagemap
            return of(try(pm.getXPointerPageLabel, pm, pos, true), try(pm.getLastPageLabel, pm, true))
        end
        return of(try(doc.getPageFromXPointer, doc, pos), page_count(doc))
    end
    if type(pos) == "table" then return of(pos.page, page_count(doc)) end
    return nil
end

function M.current_page(ui)
    if type(ui) ~= "table" or type(ui.document) ~= "table" then return nil end
    local doc = ui.document
    if ui.rolling and wants_labels(ui) then
        local pm = ui.pagemap
        return of(try(pm.getCurrentPageLabel, pm, true), try(pm.getLastPageLabel, pm, true))
    end
    return of(try(ui.getCurrentPage, ui), page_count(doc))
end

local function position(ui, pos0, pos1)
    if pos0 == nil then return nil end
    if ui.rolling then
        if type(pos0) == "string" and type(pos1) == "string" then return { pos0, pos1 } end
        return nil
    end
    if type(pos0) == "table" and pos0.page then return { page = pos0.page } end
    return nil
end

local function default_cleanup(text)
    return require("util").cleanupSelectedText(text)
end

local function quote(ui, item, cleanup, with_note)
    item = item or {}
    local fields = M.book(ui)
    fields.kind = "quote"
    local raw = item.text or ""
    fields.text = nonempty(try(cleanup or default_cleanup, raw) or raw)
    fields.pos = position(ui, item.pos0, item.pos1)
    local pageref = with_note and nonempty(item.pageref)
    if pageref then
        local total
        if type(ui) == "table" and ui.rolling and wants_labels(ui) then
            total = try(ui.pagemap.getLastPageLabel, ui.pagemap, true)
        elseif type(ui) == "table" then
            total = page_count(ui.document)
        end
        fields.page = of(pageref, total)
    end
    fields.page = fields.page or M.page_at(ui, item.pos0)
    if with_note then fields.note = nonempty(item.note) end
    return fields
end

function M.from_selection(ui, selected_text, cleanup)
    return quote(ui, selected_text, cleanup, false)
end

function M.from_annotation(ui, item, cleanup)
    return quote(ui, item, cleanup, true)
end

function M.for_idea(ui, text, with_book)
    local fields = { kind = "idea", text = nonempty(text) }
    if with_book and type(ui) == "table" and type(ui.document) == "table" then
        local b = M.book(ui)
        fields.book, fields.author, fields.file = b.book, b.author, b.file
        fields.page = M.current_page(ui)
    end
    return fields
end

return M
