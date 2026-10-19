package.path = "./?.lua;" .. package.path

-- Dependency-aware invalidation: an edit to an open module re-checks the
-- open documents that depend on it (also through modules that are not
-- open), and only those.

local tested = require("tested")
local uv = require("luv")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")

local function lines(...)
    return table.concat({ ... }, "\n")
end

local client, dir

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
    if dir then
        project.remove(dir)
        dir = nil
    end
end)

local function sleep_ms(ms)
    local done = false
    local timer = uv.new_timer()
    uv.timer_start(timer, ms, 0, function() done = true end)
    while not done do
        uv.run("once")
    end
    uv.close(timer)
end

local function stats()
    return client:wait_for_response(client:request("teal/serverStats", {})).result
end

-- Waits until the server has finished an env rebuild after `before`.
local function wait_for_rebuild(before)
    for _ = 1, 600 do
        if stats().envRebuilds > before then
            return true
        end
        sleep_ms(50)
    end
    return false
end

local function drain_diagnostics()
    client._notifications["textDocument/publishDiagnostics"] = {}
end

local function published_uris()
    local out = {}
    for _, n in ipairs(client._notifications["textDocument/publishDiagnostics"] or {}) do
        out[n.uri] = n
    end
    return out
end

local function start(files, open)
    dir = project.create(files)
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
    local uris = {}
    for _, name in ipairs(open) do
        uris[name] = "file://" .. dir .. "/" .. name
        client:open_document(uris[name], files[name])
        client:wait_for_notification("textDocument/publishDiagnostics")
    end
    return uris
end

tested.test("an unsaved edit reaches importers through a module that is not open", function()
    local uris = start({
        ["c.tl"] = lines("local M = {}", "M.v = 1", "return M"),
        ["b.tl"] = lines('local c = require("c")', "local M = { c = c }", "return M"),
        ["a.tl"] = lines('local b = require("b")', "local n: integer = b.c.v", "print(n)"),
    }, { "c.tl", "a.tl" })
    local before = stats().envRebuilds
    drain_diagnostics()
    -- v becomes a string: a.tl's `local n: integer = b.c.v` is now an error
    client:change_document(uris["c.tl"], lines("local M = {}", 'M.v = "one"', "return M"), 2)
    tested.assert({ given = "an edit to c.tl", should = "rebuild the env", expected = true, actual = wait_for_rebuild(before) })
    local a = published_uris()[uris["a.tl"]]
    tested.assert({ given = "a.tl, which reaches c.tl through the closed b.tl", should = "be re-published", expected = true, actual = a ~= nil })
    local messages = {}
    for _, d in ipairs(a and a.diagnostics or {}) do
        table.insert(messages, d.message)
    end
    tested.assert({ given = "a.tl after the edit", should = "report the new type mismatch", expected = true,
        actual = table.concat(messages, "\n"):find("string", 1, true) ~= nil })
end)

tested.test("an edit re-checks the module's dependents, not unrelated open documents", function()
    local files = {
        ["m.tl"] = lines("local M = {}", "M.v = 1", "return M"),
        ["user.tl"] = lines('local m = require("m")', "local n: integer = m.v", "print(n)"),
    }
    local open = { "m.tl", "user.tl" }
    for i = 1, 3 do
        local name = "unrelated" .. i .. ".tl"
        files[name] = lines("local record R", "   x: number", "end", "local r: R = { x = " .. i .. " }", "print(r.x)")
        table.insert(open, name)
    end
    local uris = start(files, open)
    local before = stats()
    drain_diagnostics()
    client:change_document(uris["m.tl"], lines("local M = {}", 'M.v = "one"', "return M"), 2)
    tested.assert({ given = "an edit to m.tl", should = "rebuild the env", expected = true, actual = wait_for_rebuild(before.envRebuilds) })
    sleep_ms(300)
    local published = published_uris()
    tested.assert({ given = "the importer user.tl", should = "be re-published", expected = true, actual = published[uris["user.tl"]] ~= nil })
    for i = 1, 3 do
        local uri = uris["unrelated" .. i .. ".tl"]
        tested.assert({ given = "unrelated" .. i .. ".tl", should = "not be re-checked and re-published", expected = false, actual = published[uri] ~= nil })
    end
    local after = stats()
    -- m.tl (debounced analysis, then after the rebuild) and user.tl
    tested.assert({ given = "the edit", should = "check at most m.tl twice and user.tl once", expected = true,
        actual = after.documentChecks - before.documentChecks <= 3 })

    -- an unrelated document is re-checked on demand and still answers
    local r = client:get_hover(uris["unrelated2.tl"], 4, 6)
    local value = type(r.result) == "table" and r.result.contents and r.result.contents.value or ""
    tested.assert({ given = "hover on an unrelated document after the rebuild", should = "still show the type", expected = true, actual = value:find("R", 1, true) ~= nil })
end)

return tested
