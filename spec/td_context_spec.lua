local ctx = require("td_context")

local function cleanup(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Fake rolling (EPUB) reader. opts.labels turns the page-label map on.
local function epub(opts)
    opts = opts or {}
    local ui = {
        rolling = {},
        doc_props = { display_title = "Dune", title = "Dune (raw)", authors = "Frank Herbert" },
        document = {
            file = "/books/dune.epub",
            getPageFromXPointer = function(_, xp) return xp == "xp1" and 142 or 7 end,
            getPageCount = function() return 380 end,
            getCurrentPage = function() return 150 end,
        },
        getCurrentPage = function() return 150 end,
    }
    if opts.labels then
        ui.pagemap = {
            wantsPageLabels = function() return true end,
            getXPointerPageLabel = function(_, xp) return xp == "xp1" and "xii" or "xiii" end,
            getLastPageLabel = function() return "380" end,
            getCurrentPageLabel = function() return "xx" end,
        }
    end
    return ui
end

local function pdf()
    return {
        paging = { current_page = 7 },
        doc_props = { display_title = "Paper", authors = "A\nB" },
        document = { file = "/books/p.pdf", getPageCount = function() return 20 end },
        getCurrentPage = function() return 7 end,
    }
end

describe("td_context", function()
    describe("book", function()
        it("reads title, author and file", function()
            assert.same({ book = "Dune", author = "Frank Herbert", file = "/books/dune.epub" }, ctx.book(epub()))
        end)
        it("joins several authors with commas", function()
            assert.equals("A, B", ctx.book(pdf()).author)
        end)
        it("falls back to title", function()
            local ui = epub()
            ui.doc_props.display_title = nil
            assert.equals("Dune (raw)", ctx.book(ui).book)
        end)
        it("leaves missing or empty pieces nil", function()
            local ui = epub()
            ui.doc_props = { display_title = "", authors = "" }
            local b = ctx.book(ui)
            assert.is_nil(b.book)
            assert.is_nil(b.author)
            assert.equals("/books/dune.epub", b.file)
        end)
        it("copes with no doc_props and no document", function()
            assert.same({}, ctx.book({}))
            assert.same({}, ctx.book(nil))
        end)
    end)

    describe("page_at", function()
        it("uses page labels when the book has them", function()
            assert.equals("xii of 380", ctx.page_at(epub({ labels = true }), "xp1"))
        end)
        it("uses real pages without labels", function()
            assert.equals("142 of 380", ctx.page_at(epub(), "xp1"))
        end)
        it("handles a PDF position", function()
            assert.equals("7 of 20", ctx.page_at(pdf(), { page = 7 }))
        end)
        it("is nil without a position, a page count, or a document", function()
            assert.is_nil(ctx.page_at(epub(), nil))
            local ui = epub()
            ui.document.getPageCount = function() return 0 end
            assert.is_nil(ctx.page_at(ui, "xp1"))
            assert.is_nil(ctx.page_at({}, "xp1"))
        end)
        it("is nil when KOReader raises", function()
            local ui = epub()
            ui.document.getPageFromXPointer = function() error("boom") end
            assert.is_nil(ctx.page_at(ui, "xp1"))
        end)
    end)

    describe("current_page", function()
        it("labels, real pages, and PDF", function()
            assert.equals("xx of 380", ctx.current_page(epub({ labels = true })))
            assert.equals("150 of 380", ctx.current_page(epub()))
            assert.equals("7 of 20", ctx.current_page(pdf()))
        end)
        it("is nil without a document", function()
            assert.is_nil(ctx.current_page({}))
        end)
    end)

    describe("from_selection", function()
        it("builds a quote for an EPUB", function()
            local f = ctx.from_selection(epub(), { text = "  hello \n", pos0 = "xp1", pos1 = "xp2" }, cleanup)
            assert.same({
                kind = "quote", text = "hello", book = "Dune", author = "Frank Herbert",
                file = "/books/dune.epub", page = "142 of 380", pos = { "xp1", "xp2" },
            }, f)
        end)
        it("builds a quote for a PDF", function()
            local f = ctx.from_selection(pdf(), { text = "x", pos0 = { page = 7 }, pos1 = { page = 7 } }, cleanup)
            assert.same({ page = 7 }, f.pos)
            assert.equals("7 of 20", f.page)
        end)
        it("tolerates a selection without positions", function()
            local f = ctx.from_selection(epub(), { text = "x" }, cleanup)
            assert.is_nil(f.pos)
            assert.is_nil(f.page)
        end)
    end)

    describe("from_annotation", function()
        it("keeps the note and prefers pageref", function()
            local item = { text = "t", note = "my note", pos0 = "xp1", pos1 = "xp2", pageref = "12" }
            local f = ctx.from_annotation(epub({ labels = true }), item, cleanup)
            assert.equals("my note", f.note)
            assert.equals("12 of 380", f.page)
            assert.same({ "xp1", "xp2" }, f.pos)
        end)
        it("falls back to the position and drops an empty note", function()
            local f = ctx.from_annotation(epub(), { text = "t", note = "", pos0 = "xp1", pos1 = "xp2" }, cleanup)
            assert.is_nil(f.note)
            assert.equals("142 of 380", f.page)
        end)
        it("uses the page number for a PDF annotation", function()
            local f = ctx.from_annotation(pdf(), { text = "t", pos0 = { page = 7 }, page = 7 }, cleanup)
            assert.same({ page = 7 }, f.pos)
            assert.equals("7 of 20", f.page)
        end)
    end)

    describe("for_idea", function()
        it("adds book details and the current page", function()
            local f = ctx.for_idea(epub(), "an idea", true)
            assert.same({
                kind = "idea", text = "an idea", book = "Dune", author = "Frank Herbert",
                file = "/books/dune.epub", page = "150 of 380",
            }, f)
        end)
        it("leaves the book out when not asked", function()
            assert.same({ kind = "idea", text = "an idea" }, ctx.for_idea(epub(), "an idea", false))
        end)
        it("works with no document open", function()
            assert.same({ kind = "idea", text = "an idea" }, ctx.for_idea(nil, "an idea", true))
            assert.same({ kind = "idea", text = "an idea" }, ctx.for_idea({}, "an idea", true))
        end)
    end)
end)
