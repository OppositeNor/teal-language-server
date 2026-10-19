package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")

local function lines(...)
    return table.concat({ ... }, "\n")
end

local function find_item(items, label)
    for _, item in ipairs(items or {}) do
        if item.label == label then
            return item
        end
    end
end

local client

local function open(uri, text)
    client:open_document(uri, text)
    client:wait_for_notification("textDocument/publishDiagnostics")
end

local function start(capabilities, root)
    client = LspClient.new("teal-language-server")
    client:initialize(root, capabilities)
end

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
end)

local VEC = lines(
    "local record Vec",                                         -- 0
    "   x: number",                                             -- 1
    "   scale: function(self, factor: number): Vec",            -- 2
    "end",                                                      -- 3
    "local v: Vec = { x = 1 }",                                 -- 4
    "local w = v:scale(2)",                                     -- 5
    "print(w)")                                                 -- 6

tested.test("completion items carry type detail and signature documentation", function()
    start()
    local uri = "file:///tmp/tls_erg_detail.tl"
    open(uri, VEC)
    local r = client:get_completions_triggered(uri, 5, 12, ":")
    local item = find_item(r.result and r.result.items, "scale")
    tested.assert({ given = "method completion", should = "include scale", expected = true, actual = item ~= nil })
    tested.assert({ given = "scale item", should = "be a Method (2)", expected = 2, actual = item and math.tointeger(item.kind) or -1 })
    tested.assert({ given = "scale item detail", should = "be its type", expected = "function(self, number): Vec", actual = item and item.detail or "" })
    tested.assert({ given = "scale item documentation", should = "show parameter names", expected = true, actual = item ~= nil and item.documentation ~= nil and item.documentation.value:find("factor: number", 1, true) ~= nil })
    tested.assert({ given = "client without snippet support", should = "get no snippet", expected = true, actual = item ~= nil and item.insertText == nil })
end)

tested.test("snippet insert text omits self for method calls when the client supports snippets", function()
    start({ textDocument = { completion = { completionItem = { snippetSupport = true } } } })
    local uri = "file:///tmp/tls_erg_snippet.tl"
    open(uri, VEC)
    local r = client:get_completions_triggered(uri, 5, 12, ":")
    local item = find_item(r.result and r.result.items, "scale")
    tested.assert({ given = "snippet-capable client", should = "get placeholders for the parameters", expected = "scale(${1:factor}) 2", actual = item and (tostring(item.insertText) .. " " .. tostring(math.tointeger(item.insertTextFormat))) or "" })
end)

tested.test("keywords are offered when completing a bare identifier", function()
    start()
    local uri = "file:///tmp/tls_erg_keyword.tl"
    open(uri, "loc")
    local id = client:request("textDocument/completion", { textDocument = { uri = uri }, position = { line = 0, character = 3 }, context = { triggerKind = 1 } })
    local items = client:wait_for_response(id).result.items
    local kw = find_item(items, "local")
    tested.assert({ given = "completion on 'loc'", should = "offer the local keyword (kind 14)", expected = 14, actual = kw and math.tointeger(kw.kind) or -1 })
    local member_uri = "file:///tmp/tls_erg_keyword_member.tl"
    open(member_uri, "math.")
    local r = client:get_completions_triggered(member_uri, 0, 5, ".")
    tested.assert({ given = "member completion on math.", should = "offer members but no keywords", expected = "abs, no local", actual = (find_item(r.result and r.result.items, "abs") and "abs" or "no abs") .. ", " .. (find_item(r.result and r.result.items, "local") and "local" or "no local") })
end)

local function sig_at(uri, line, character)
    local r = client:get_signature_help(uri, line, character)
    return r.result
end

local function param_text(sig)
    local s = sig.signatures[1]
    local p = s.parameters[s.activeParameter + 1]
    return p and s.label:sub(p.label[1] + 1, p.label[2]) or "none"
end

tested.test("signature help tracks the active parameter anywhere inside the call", function()
    start()
    local uri = "file:///tmp/tls_erg_sig.tl"
    local text = lines(
        "local function add(a: integer, b: integer): integer return a + b end",
        "print(add(1, 2))",
        "print(add(add(3, 4), 5))")
    open(uri, text)

    local s = sig_at(uri, 1, 10)
    tested.assert({ given = "cursor on the first argument", should = "highlight a", expected = "a: integer", actual = s and param_text(s) or "nil" })
    s = sig_at(uri, 1, 13)
    tested.assert({ given = "cursor on the second argument", should = "highlight b", expected = "b: integer", actual = s and param_text(s) or "nil" })
    tested.assert({ given = "parameters", should = "list both", expected = 2, actual = s and #s.signatures[1].parameters or 0 })
    s = sig_at(uri, 2, 21)
    tested.assert({ given = "after a nested call with its own comma", should = "highlight the outer b", expected = "b: integer", actual = s and param_text(s) or "nil" })
    s = sig_at(uri, 2, 17)
    tested.assert({ given = "inside the nested call", should = "highlight the inner b", expected = "b: integer", actual = s and param_text(s) or "nil" })
end)

tested.test("signature help for a ':' method call skips the implicit self", function()
    start()
    local uri = "file:///tmp/tls_erg_sig_method.tl"
    open(uri, lines(
        "local record Graph",
        "   create_texture: function(self, name: string, width: integer): integer",
        "end",
        "local g: Graph = {}",
        'print(g:create_texture("color", 1920))'))
    local s = sig_at(uri, 4, 31)
    tested.assert({ given = "second explicit argument of a method call", should = "highlight width", expected = "width: integer", actual = s and param_text(s) or "nil" })
end)

tested.test("signature help inside a table constructor argument", function()
    start()
    local uri = "file:///tmp/tls_erg_sig_table.tl"
    open(uri, lines(
        "local record Desc",
        "   w: integer",
        "   h: integer",
        "end",
        "local function make(name: string, desc: Desc): integer return #name + desc.w end",
        'print(make("tex", { w = 1, h = 2 }))'))
    -- cursor after "h = " inside the table: still the second argument of make
    local s = sig_at(uri, 5, 31)
    tested.assert({ given = "cursor inside a table constructor argument", should = "highlight desc", expected = "desc: Desc", actual = s and param_text(s) or "nil" })
end)

tested.test("inlay hints show inferred types of unannotated locals", function()
    start()
    local uri = "file:///tmp/tls_erg_inlay.tl"
    open(uri, lines(
        "local record P",                                 -- 0
        "   x: number",                                   -- 1
        "end",                                            -- 2
        "local function mk(): P return { x = 1 } end",    -- 3
        "local p = mk()",                                 -- 4
        "local n = 5",                                    -- 5
        "local q: P = mk()",                              -- 6
        "local s = '日本' local t = mk()",                -- 7
        "print(p, n, q, s, t)"))
    local id = client:request("textDocument/inlayHint", { textDocument = { uri = uri }, range = { start = { line = 0, character = 0 }, ["end"] = { line = 9, character = 0 } } })
    local hints = client:wait_for_response(id).result
    local got = {}
    for _, h in ipairs(hints) do
        table.insert(got, string.format("%d:%d%s", h.position.line, h.position.character, h.label))
    end
    tested.assert({ given = "locals with and without annotations", should = "hint only inferred, non-literal ones (UTF-16 positions)", expected = "4:7: P 7:22: P", actual = table.concat(got, " ") })
end)

tested.test("inlay hints can be disabled in tlconfig.lua", function()
    local dir = project.create({ ["tlconfig.lua"] = "return { externals = { teal_language_server = { inlay_hints = false } } }" })
    start(nil, "file://" .. dir)
    local uri = "file://" .. dir .. "/a.tl"
    open(uri, "local function f(): integer return 1 end\nlocal x = f()\nprint(x)")
    local id = client:request("textDocument/inlayHint", { textDocument = { uri = uri }, range = { start = { line = 0, character = 0 }, ["end"] = { line = 3, character = 0 } } })
    tested.assert({ given = "inlay_hints = false", should = "return no hints", expected = 0, actual = #client:wait_for_response(id).result })
    project.remove(dir)
end)

tested.test("record hover lists fields in a stable order", function()
    start()
    local uri = "file:///tmp/tls_erg_hover.tl"
    open(uri, lines("local record R", "   zeta: integer", "   alpha: string", "   mid: boolean", "end", "local r: R = {}", "print(r)"))
    local h = client:get_hover(uri, 5, 6)
    local value = h.result and h.result.contents.value or ""
    tested.assert({ given = "record hover", should = "list fields sorted", expected = true, actual = value:find("alpha.*mid.*zeta") ~= nil })
end)

return tested
