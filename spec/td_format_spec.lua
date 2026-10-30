local fmt = require("td_format")

local T = 1793394300
local stamp = os.date("%Y-%m-%d %H:%M", T)

local function chars(s)
    local n = 0
    for _ in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n
end

describe("td_format.title", function()
    it("collapses whitespace and trims", function()
        local t, cut = fmt.title("  a \n\t b   c  ")
        assert.equal("a b c", t)
        assert.is_false(cut)
    end)

    it("cuts long text on a word boundary and appends an ellipsis", function()
        local text = string.rep("abcd efgh ", 30)
        local t, cut = fmt.title(text)
        assert.is_true(cut)
        assert.is_true(chars(t) <= 250)
        assert.equal("…", t:sub(-3))
        local body = t:sub(1, -4)
        assert.equal(body, text:sub(1, #body))
        assert.equal(" ", text:sub(#body + 1, #body + 1))
    end)

    it("cuts multi-byte text on a character boundary", function()
        local t, cut = fmt.title(string.rep("č", 260))
        assert.is_true(cut)
        assert.equal(string.rep("č", 249) .. "…", t)
    end)
end)

describe("td_format.task", function()
    it("formats a quote with every field", function()
        local r = fmt.task({
            kind = "quote", text = "Short quote", book = "Dune", author = "Frank Herbert",
            page = "142 of 380", created = T, note = "my thought",
        }, { with_book = false })
        assert.equal("Short quote", r.content)
        assert.equal("📖 Kobo quote\nBook: Dune\nAuthor: Frank Herbert\nPage: 142 of 380\nCaptured: "
            .. stamp .. "\nNote: my thought", r.description)
    end)

    it("leaves out author and note when missing", function()
        local r = fmt.task({ kind = "quote", text = "Q", book = "Dune", created = T }, {})
        assert.is_nil(r.description:find("Author:", 1, true))
        assert.is_nil(r.description:find("Note:", 1, true))
        assert.equal("📖 Kobo quote\nBook: Dune\nCaptured: " .. stamp, r.description)
    end)

    it("leaves book lines out of an idea unless asked", function()
        local item = { kind = "idea", text = "Idea", book = "Dune", author = "FH", page = "1 of 2", created = T }
        assert.equal("💡 Kobo idea\nCaptured: " .. stamp, fmt.task(item, { with_book = false }).description)
        assert.equal("💡 Kobo idea\nBook: Dune\nAuthor: FH\nPage: 1 of 2\nCaptured: " .. stamp,
            fmt.task(item, { with_book = true }).description)
    end)

    it("puts the full text in the description when the title is cut", function()
        local text = string.rep("abcd efgh ", 30)
        local r = fmt.task({ kind = "quote", text = text, book = "B", created = T }, {})
        assert.equal("…", r.content:sub(-3))
        assert.is_true(chars(r.content) <= 250)
        assert.equal("\n\n" .. text, r.description:sub(-(#text + 2)))
    end)
end)

describe("td_format.preview", function()
    it("makes one line", function()
        assert.equal("a b c", fmt.preview("a\nb  c", 10))
    end)

    it("cuts with an ellipsis", function()
        assert.equal("abc…", fmt.preview("abcdefgh", 3))
    end)
end)
