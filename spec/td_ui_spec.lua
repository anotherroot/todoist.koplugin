local td_ui = require("td_ui")

describe("td_ui text helpers", function()
    describe("blank", function()
        it("is true for nil, empty and whitespace-only text", function()
            assert.is_true(td_ui.blank(nil))
            assert.is_true(td_ui.blank(""))
            assert.is_true(td_ui.blank("  \n\t "))
        end)
        it("is false when there is something to send", function()
            assert.is_false(td_ui.blank(" a "))
            assert.is_false(td_ui.blank("idea"))
        end)
    end)

    describe("token_from", function()
        it("prefers the file, trimmed", function()
            assert.same({ "abc123", "file" }, { td_ui.token_from("  abc123\n", "setkey") })
        end)
        it("falls back to the setting when the file is missing or blank", function()
            assert.same({ "setkey", "setting" }, { td_ui.token_from(nil, " setkey ") })
            assert.same({ "setkey", "setting" }, { td_ui.token_from(" \n", "setkey") })
        end)
        it("is nil when neither has a key", function()
            assert.is_nil(td_ui.token_from(nil, nil))
            assert.is_nil(td_ui.token_from("", "  "))
            assert.is_nil(td_ui.token_from(nil, false))
        end)
    end)

    describe("key_label", function()
        local key = "0123456789abcdef0123456789abcdefWXYZ"
        it("shows only the last 4 characters and where the key comes from", function()
            assert.equal("from file todoist_token.txt (…WXYZ)", td_ui.key_label(key, "file"))
            assert.equal("set here (…WXYZ)", td_ui.key_label(key, "setting"))
            assert.is_nil(td_ui.key_label(key, "file"):find("0123", 1, true))
        end)
        it("says when there is no key", function()
            assert.equal("not set", td_ui.key_label(nil))
            assert.equal("not set", td_ui.key_label(""))
        end)
    end)

    describe("menu_label", function()
        it("shows the count only when something is not sent", function()
            assert.equal("Todoist", td_ui.menu_label(0))
            assert.equal("Todoist", td_ui.menu_label(nil))
            assert.equal("Todoist (2 not sent)", td_ui.menu_label(2))
        end)
    end)

    describe("history_title", function()
        it("names the filter", function()
            assert.equal("Todoist: sent items", td_ui.history_title(nil))
            assert.equal("Todoist: not sent", td_ui.history_title("unsent"))
        end)
    end)

    describe("row", function()
        it("marks quotes and ideas and puts the status word on the right", function()
            local q = td_ui.row({ kind = "quote", text = "Fear is the mind-killer.", status = "failed" })
            assert.equal(td_ui.QUOTE_MARK .. " Fear is the mind-killer.", q.text)
            assert.equal("failed", q.mandatory)
            local i = td_ui.row({ kind = "idea", text = "a thought", status = "sent" })
            assert.equal(td_ui.IDEA_MARK .. " a thought", i.text)
            assert.equal("sent", i.mandatory)
        end)
        it("cuts the preview at 60 characters", function()
            local r = td_ui.row({ kind = "quote", text = string.rep("x", 80), status = "waiting" })
            assert.equal(td_ui.QUOTE_MARK .. " " .. string.rep("x", 60) .. "…", r.text)
        end)
        it("copes with an item without text", function()
            assert.equal(td_ui.QUOTE_MARK .. " ", td_ui.row({ status = "waiting" }).text)
        end)
    end)

    describe("details", function()
        local created = os.time({ year = 2026, month = 10, day = 30, hour = 9, min = 5 })
        it("lists what is known, the status, and the error of a failed item", function()
            local text = td_ui.details({
                kind = "quote", text = "Full text here.", book = "Dune", author = "Frank Herbert",
                page = "142 of 380", note = "my note", created = created,
                status = "failed", last_error = "API key rejected (401). Check the key in Settings.",
            })
            assert.equal(table.concat({
                "Full text here.",
                "",
                "Book: Dune",
                "Author: Frank Herbert",
                "Page: 142 of 380",
                "Note: my note",
                "Captured: 2026-10-30 09:05",
                "Status: failed",
                "Error: API key rejected (401). Check the key in Settings.",
            }, "\n"), text)
        end)
        it("leaves out missing fields and old errors of items not failed", function()
            local text = td_ui.details({
                kind = "idea", text = "An idea", created = created, status = "sent",
                sent_at = created + 60, last_error = "old",
            })
            assert.equal("An idea\n\nCaptured: 2026-10-30 09:05\nStatus: sent\nSent: 2026-10-30 09:06", text)
        end)
    end)

    describe("alert_text", function()
        it("counts the items and adds the error", function()
            assert.equal("Todoist: 3 items not sent.\n\nNo connection.",
                td_ui.alert_text({ count = 3, message = "No connection." }))
            assert.equal("Todoist: 1 item not sent.\n\nAPI key rejected (401).",
                td_ui.alert_text({ count = 1, message = "API key rejected (401)." }))
        end)
        it("leaves out a missing message", function()
            assert.equal("Todoist: 2 items not sent.", td_ui.alert_text({ count = 2 }))
        end)
    end)

    describe("recovered_text", function()
        local bad = "/mnt/onboard/.adds/koreader/settings/todoist_history.json.bad-20261030-091500"
        it("names the .bad file and says the backup copy was used", function()
            assert.equal("Todoist: the history file was damaged and was set aside as\n" .. bad
                .. "\n\nRestored from the backup copy.",
                td_ui.recovered_text({ bad = bad, used_old = true }))
        end)
        it("says the history started empty when there was no backup", function()
            assert.equal("Todoist: the history file was damaged and was set aside as\n" .. bad
                .. "\n\nThe history started empty.",
                td_ui.recovered_text({ bad = bad, used_old = false }))
        end)
    end)
end)
