-- On-device history of everything sent, with a status per item.
--
-- Saving: write .tmp and fsync it, keep the current file as .old, rename .tmp
-- over, fsync the folder. A power cut then leaves the new file or the previous
-- one (.old) readable.
-- Loading: a file that can't be read is moved aside to .bad-<date-time> (never
-- over an older .bad) and .old is used instead; `store.recovered_from` =
-- { bad = path, used_old = bool } tells the owner. No usable .old: empty.
local M = {}

local STATUSES = { waiting = true, sending = true, sent = true, failed = true }
local COPY_FIELDS = { "kind", "text", "book", "author", "file", "page", "pos", "note" }

local seeded = false

--- Sentinel for update(): a field set to NONE is removed.
M.NONE = setmetatable({}, { __tostring = function() return "NONE" end })

-- Canonical UUID v4 (lowercase), bytes from /dev/urandom, math.random fallback.
local function uuid4()
    local bytes
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(16)
        f:close()
        if s and #s == 16 then bytes = { s:byte(1, 16) } end
    end
    if not bytes then
        if not seeded then
            math.randomseed(os.time() + math.floor(os.clock() * 1000000))
            seeded = true
        end
        bytes = {}
        for i = 1, 16 do bytes[i] = math.random(0, 255) end
    end
    bytes[7] = bytes[7] % 16 + 0x40 -- version 4
    bytes[9] = bytes[9] % 64 + 0x80 -- variant 8..b
    local hex = {}
    for i = 1, 16 do hex[i] = string.format("%02x", bytes[i]) end
    local h = table.concat(hex)
    return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

local Store = {}
Store.__index = Store

function Store:_save()
    local ok, err = self:_write()
    self.last_save_error = (not ok) and tostring(err) or nil
    return ok, self.last_save_error
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- The fsync hooks are optional (KOReader's ffi/util ones on the device) and
-- never stop a save: without them it's as safe as the filesystem alone.
local function sync(fn, arg)
    if fn then pcall(fn, arg) end
end

function Store:_write()
    local ok, data = pcall(self.json.encode, { version = 1, items = self.items })
    if not ok or type(data) ~= "string" then return false, tostring(data) end
    local tmp = self.path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    local wrote, werr = f:write(data)
    if wrote then wrote, werr = f:flush() end
    if wrote then sync(self.fsync_file, f) end
    f:close()
    if not wrote then
        os.remove(tmp)
        return false, werr
    end
    -- The file being replaced was written and synced by an earlier save: keep it
    -- (unless it is a damaged one that couldn't be moved aside).
    if not self.main_damaged and exists(self.path) then os.rename(self.path, self.path .. ".old") end
    local renamed, rerr = os.rename(tmp, self.path)
    if not renamed then
        os.remove(tmp)
        return false, rerr
    end
    sync(self.fsync_dir, self.path)
    self.main_damaged = nil
    return true
end

function Store:_find(id)
    for _, item in ipairs(self.items) do
        if item.id == id then return item end
    end
end

function Store:add(fields)
    local item = {}
    for k, v in pairs(fields or {}) do item[k] = v end
    item.id = uuid4()
    item.created = self.now()
    item.status = "waiting"
    item.attempts = 0
    self.items[#self.items + 1] = item
    local ok, err = self:_save()
    return item, ok, err
end

function Store:get(id)
    return self:_find(id)
end

--- Newest first; items from the same second keep newest-added first.
-- filter "unsent" = waiting + sending + failed.
function Store:list(filter)
    local picked = {}
    for index, item in ipairs(self.items) do
        if filter ~= "unsent" or item.status ~= "sent" then
            picked[#picked + 1] = { item = item, index = index }
        end
    end
    table.sort(picked, function(a, b)
        local ca, cb = a.item.created or 0, b.item.created or 0
        if ca ~= cb then return ca > cb end
        return a.index > b.index
    end)
    local out = {}
    for i, p in ipairs(picked) do out[i] = p.item end
    return out
end

--- Merge changes into an item and save (a field set to M.NONE is removed).
-- Returns item, ok, err; nil for an unknown id or a bad status.
function Store:update(id, changes)
    local item = self:_find(id)
    if not item then return nil, "unknown id" end
    if changes.status ~= nil and not STATUSES[changes.status] then
        return nil, "bad status"
    end
    for k, v in pairs(changes) do
        if k ~= "id" then
            if v == M.NONE then item[k] = nil else item[k] = v end
        end
    end
    local ok, err = self:_save()
    return item, ok, err
end

--- After a crash or restart nothing is really in flight: sending -> waiting.
function Store:recover()
    local changed = false
    for _, item in ipairs(self.items) do
        if item.status == "sending" then
            item.status = "waiting"
            changed = true
        end
    end
    if changed then return self:_save() end
    return true
end

function Store:counts()
    local c = { waiting = 0, sending = 0, sent = 0, failed = 0 }
    for _, item in ipairs(self.items) do
        if c[item.status] then c[item.status] = c[item.status] + 1 end
    end
    return c
end

--- "Send again": a new waiting item with the same content.
function Store:copy(id)
    local src = self:_find(id)
    if not src then return nil end
    local fields = {}
    for _, k in ipairs(COPY_FIELDS) do fields[k] = src[k] end
    return self:add(fields)
end

function Store:clear_sent()
    local kept = {}
    for _, item in ipairs(self.items) do
        if item.status ~= "sent" then kept[#kept + 1] = item end
    end
    self.items = kept
    return self:_save()
end

--- The items in a history file; nil, "missing" | "unreadable" otherwise.
local function read_items(path, json)
    local f = io.open(path, "rb")
    if not f then return nil, "missing" end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, raw or "")
    if ok and type(data) == "table" and type(data.items) == "table" then
        local items = {}
        for _, item in ipairs(data.items) do
            if type(item) == "table" and type(item.id) == "string" then items[#items + 1] = item end
        end
        return items
    end
    return nil, "unreadable"
end

--- Moves an unreadable file aside to a new .bad-<date-time>[-n]; returns that path.
local function set_aside(path, now)
    local base = path .. ".bad-" .. os.date("%Y%m%d-%H%M%S", now)
    local bad, n = base, 1
    while exists(bad) do
        n = n + 1
        bad = base .. "-" .. n
    end
    if not os.rename(path, bad) then return path, true end -- couldn't move: still there
    return bad
end

--- `opts` (optional): fsync_file(file), fsync_dir(path), e.g. KOReader's
-- ffiutil.fsyncOpenedFile and ffiutil.fsyncDirectory.
function M.open(path, json, now_fn, opts)
    opts = opts or {}
    local store = setmetatable({
        path = path,
        json = json,
        now = now_fn or os.time,
        fsync_file = opts.fsync_file,
        fsync_dir = opts.fsync_dir,
    }, Store)
    local items, why = read_items(path, json)
    local bad
    if why == "unreadable" then bad, store.main_damaged = set_aside(path, store.now()) end
    local used_old = false
    if not items then
        -- Damaged, or missing (a cut between the two renames of a save, or a first start).
        items = read_items(path .. ".old", json)
        used_old = items ~= nil
    end
    store.items = items or {}
    if bad then store.recovered_from = { bad = bad, used_old = used_old } end
    if used_old then store:_save() end -- the main file again; .old stays as it is
    store:recover()
    return store
end

return M
