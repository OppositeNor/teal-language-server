package.path = "./?.lua;" .. package.path

-- Hover shows the documentation comment written above a declaration.

local tested = require("tested")
local tl = require("tl")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")
local semantic = require("teal_language_server.analysis.semantic")

local function lines(...)
    return table.concat({ ... }, "\n")
end

tested.test("documentation comments: contiguous own-line blocks above a declaration", function()
    local src = lines(
        "local x = 1 -- trailing",          -- 1
        "-- Adds one.",                      -- 2
        "--   Returns the sum.",             -- 3
        "local function inc() end",          -- 4
        "--[[ Block",                        -- 5
        "  doc ]]",                          -- 6
        "local y = 2",                       -- 7
        "-- detached",                       -- 8
        "",                                  -- 9
        "local z = 3",                       -- 10
        "-- tls-disable-next-line implicit-any", -- 11
        "local function w(a) end",           -- 12
        "local v = 4")                       -- 13
    local tokens = tl.lex(src .. "\n", "doc.tl")
    tested.assert({ given = "two comment lines above a function", should = "be its documentation", expected = "Adds one.\n  Returns the sum.", actual = semantic.doc_comment(tokens, 4) })
    tested.assert({ given = "a block comment above a local", should = "be its documentation", expected = "Block\n  doc", actual = semantic.doc_comment(tokens, 7) })
    tested.assert({ given = "a comment separated by a blank line", should = "not be documentation", expected = "none", actual = semantic.doc_comment(tokens, 10) or "none" })
    tested.assert({ given = "a suppression directive", should = "not be documentation", expected = "none", actual = semantic.doc_comment(tokens, 12) or "none" })
    tested.assert({ given = "a declaration right after code", should = "have no documentation", expected = "none", actual = semantic.doc_comment(tokens, 13) or "none" })
end)

local client

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
end)

local function hover_text(uri, line, character)
    local r = client:get_hover(uri, line, character)
    return type(r.result) == "table" and r.result.contents and r.result.contents.value or ""
end

tested.test("hover shows the documentation of locals, functions, fields and methods", function()
    client = LspClient.new("teal-language-server")
    client:initialize()
    local uri = "file:///tmp/tls_hover_docs.tl"
    client:open_document(uri, lines(
        "-- A point in the plane.",           -- 0
        "local record Point",                 -- 1
        "   -- Horizontal position.",         -- 2
        "   x: number",                       -- 3
        "end",                                -- 4
        "-- Length of the vector.",           -- 5
        "function Point:len(): number return self.x end", -- 6
        "local count = 0 -- not documentation", -- 7
        "local p: Point = { x = 1 }",         -- 8
        "print(p.x, p:len(), count)"))        -- 9
    client:wait_for_notification("textDocument/publishDiagnostics")

    local text = hover_text(uri, 9, 8)
    tested.assert({ given = "hover on the field p.x", should = "show its comment", expected = true, actual = text:find("Horizontal position.", 1, true) ~= nil })
    tested.assert({ given = "hover on the field p.x", should = "still show its type", expected = true, actual = text:find("number", 1, true) ~= nil })
    text = hover_text(uri, 9, 13)
    tested.assert({ given = "hover on the method p:len", should = "show its comment", expected = true, actual = text:find("Length of the vector.", 1, true) ~= nil })
    text = hover_text(uri, 8, 9)
    tested.assert({ given = "hover on the type name Point in an annotation", should = "not show a wrong comment", expected = false, actual = text:find("Length", 1, true) ~= nil })
    text = hover_text(uri, 9, 20)
    tested.assert({ given = "hover on count, which has a trailing comment only", should = "show no documentation", expected = false, actual = text:find("not documentation", 1, true) ~= nil })
end)

tested.test("hover shows documentation written in another open module", function()
    local dir = project.create({
        ["util.tl"] = lines(
            "local M = {}",
            "-- Doubles a number.",
            "function M.double(n: number): number return n * 2 end",
            "return M"),
        ["main.tl"] = lines(
            "local util = require(\"util\")",
            "print(util.double(2))"),
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
    local util_uri = "file://" .. dir .. "/util.tl"
    local main_uri = "file://" .. dir .. "/main.tl"
    client:open_document(util_uri, project.read(dir, "util.tl"))
    client:wait_for_notification("textDocument/publishDiagnostics")
    client:open_document(main_uri, project.read(dir, "main.tl"))
    client:wait_for_notification("textDocument/publishDiagnostics")
    local text = hover_text(main_uri, 1, 12)
    tested.assert({ given = "hover on util.double", should = "show the comment from util.tl", expected = true, actual = text:find("Doubles a number.", 1, true) ~= nil })
    project.remove(dir)
end)

local function resolve_doc(items, label)
    for _, item in ipairs(items) do
        if item.label == label then
            local r = client:wait_for_response(client:request("completionItem/resolve", item))
            local d = type(r.result) == "table" and r.result.documentation
            return type(d) == "table" and d.value or (type(d) == "string" and d) or ""
        end
    end
    return "<no item " .. label .. ">"
end

tested.test("completionItem/resolve adds the documentation of locals, fields and methods", function()
    client = LspClient.new("teal-language-server")
    local init = client:initialize()
    tested.assert({ given = "the server capabilities", should = "advertise completion resolve", expected = true,
        actual = init.result.capabilities.completionProvider.resolveProvider == true })
    local uri = "file:///tmp/tls_resolve_docs.tl"
    client:open_document(uri, lines(
        "local record Point",                  -- 0
        "   -- Horizontal position.",          -- 1
        "   x: number",                        -- 2
        "end",                                 -- 3
        "-- Length of the vector.",            -- 4
        "function Point:len(): number return self.x end", -- 5
        "-- How many points exist.",           -- 6
        "local count = 0",                     -- 7
        "local undocumented = 1",              -- 8
        "local p: Point = { x = 1 }",          -- 9
        "local _ = p.",                        -- 10
        "local _ = cou"))                      -- 11
    client:wait_for_notification("textDocument/publishDiagnostics")

    local r = client:get_completions_triggered(uri, 10, 12, ".")
    local items = r.result.items
    tested.assert({ given = "the field x", should = "resolve to its comment", expected = true, actual = resolve_doc(items, "x"):find("Horizontal position.", 1, true) ~= nil })
    local len_doc = resolve_doc(items, "len")
    tested.assert({ given = "the method len", should = "resolve to its comment", expected = true, actual = len_doc:find("Length of the vector.", 1, true) ~= nil })
    tested.assert({ given = "the method len", should = "keep its signature", expected = true, actual = len_doc:find("```teal", 1, true) ~= nil })

    r = client:get_completions(uri, 11, 13)
    items = r.result.items
    tested.assert({ given = "the local count", should = "resolve to its comment", expected = true, actual = resolve_doc(items, "count"):find("How many points exist.", 1, true) ~= nil })
    tested.assert({ given = "an undocumented local", should = "resolve without documentation", expected = "", actual = resolve_doc(items, "undocumented") })
end)

return tested
