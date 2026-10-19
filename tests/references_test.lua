package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")

local function lines(...)
    return table.concat({ ... }, "\n")
end

-- "file:line:col" list (file = basename) of Location results
local function locs(result, with_file)
    local out = {}
    for _, l in ipairs(result or {}) do
        local s = string.format("%d:%d", l.range.start.line, l.range.start.character)
        if with_file then
            s = l.uri:match("([^/]+)$") .. ":" .. s
        end
        table.insert(out, s)
    end
    table.sort(out)
    return table.concat(out, " ")
end

local client

local function request(method, uri, line, character, extra)
    local params = { textDocument = { uri = uri }, position = { line = line, character = character } }
    for k, v in pairs(extra or {}) do params[k] = v end
    local id = client:request(method, params)
    return client:wait_for_response(id)
end

local function open(uri, text)
    client:open_document(uri, text)
    client:wait_for_notification("textDocument/publishDiagnostics")
end

tested.before(function()
    client = LspClient.new("teal-language-server")
    client:initialize()
end)

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
end)

local SHADOW = lines(
    "local count = 1",       -- 0
    "print(count)",          -- 1
    "do",                    -- 2
    "  local count = 2",     -- 3
    "  print(count)",        -- 4
    "end",                   -- 5
    "count = count + 1",     -- 6
    "print(count)")          -- 7

tested.test("references keep shadowed locals apart", function()
    local uri = "file:///tmp/tls_ref_shadow.tl"
    open(uri, SHADOW)
    local outer = request("textDocument/references", uri, 7, 7, { context = { includeDeclaration = true } })
    tested.assert({ given = "outer count", should = "find its 5 references", expected = "0:6 1:6 6:0 6:8 7:6", actual = locs(outer.result) })
    local inner = request("textDocument/references", uri, 4, 9, { context = { includeDeclaration = true } })
    tested.assert({ given = "inner count", should = "find only the inner ones", expected = "3:8 4:8", actual = locs(inner.result) })
    local no_decl = request("textDocument/references", uri, 4, 9, { context = { includeDeclaration = false } })
    tested.assert({ given = "includeDeclaration = false", should = "omit the declaration", expected = "4:8", actual = locs(no_decl.result) })
end)

tested.test("a local's initializer refers to the outer variable of the same name", function()
    local uri = "file:///tmp/tls_ref_init.tl"
    open(uri, lines("local x = 1", "do", "  local x = x + 1", "  print(x)", "end", "print(x)"))
    local outer = request("textDocument/references", uri, 0, 6, { context = { includeDeclaration = true } })
    tested.assert({ given = "outer x", should = "include the initializer use", expected = "0:6 2:12 5:6", actual = locs(outer.result) })
end)

tested.test("references of function arguments", function()
    local uri = "file:///tmp/tls_ref_arg.tl"
    open(uri, lines("local function f(a: integer): integer", "  return a + a", "end", "print(f(1))"))
    local r = request("textDocument/references", uri, 1, 9, { context = { includeDeclaration = true } })
    tested.assert({ given = "argument a", should = "find declaration and uses", expected = "0:17 1:13 1:9", actual = locs(r.result) })
end)

tested.test("document highlight marks writes and reads", function()
    local uri = "file:///tmp/tls_ref_highlight.tl"
    open(uri, SHADOW)
    local r = request("textDocument/documentHighlight", uri, 1, 6)
    local kinds = {}
    for _, h in ipairs(r.result) do
        table.insert(kinds, string.format("%d:%d=%d", h.range.start.line, h.range.start.character, h.kind))
    end
    table.sort(kinds)
    tested.assert({ given = "outer count", should = "mark declaration/assignment as write (3), uses as read (2)", expected = "0:6=3 1:6=2 6:0=3 6:8=2 7:6=2", actual = table.concat(kinds, " ") })
end)

tested.test("rename of a local produces edits that rename only that binding", function()
    local uri = "file:///tmp/tls_ref_rename.tl"
    open(uri, SHADOW)
    local prep = request("textDocument/prepareRename", uri, 0, 8)
    tested.assert({ given = "prepareRename", should = "return the identifier range", expected = "0:6-0:11 count", actual = prep.result and string.format("%d:%d-%d:%d %s", prep.result.range.start.line, prep.result.range.start.character, prep.result.range["end"].line, prep.result.range["end"].character, prep.result.placeholder) or tostring(prep.error and prep.error.message) })
    local r = request("textDocument/rename", uri, 0, 8, { newName = "total" })
    local renamed = LspClient.apply_workspace_edit(SHADOW, uri, r.result)
    tested.assert({
        given = "rename count -> total",
        should = "leave the inner count alone",
        expected = lines("local total = 1", "print(total)", "do", "  local count = 2", "  print(count)", "end", "total = total + 1", "print(total)"),
        actual = renamed,
    })
end)

tested.test("rename rejects keywords, invalid names, types and standard library globals", function()
    local uri = "file:///tmp/tls_ref_reject.tl"
    open(uri, lines("local record R", "  v: integer", "end", "local r: R = { v = 1 }", "print(r.v, R)"))
    local bad = request("textDocument/rename", uri, 3, 6, { newName = "end" })
    tested.assert({ given = "keyword as new name", should = "be rejected with InvalidParams", expected = -32602, actual = bad.error and math.tointeger(bad.error.code) or 0 })
    bad = request("textDocument/rename", uri, 3, 6, { newName = "1abc" })
    tested.assert({ given = "invalid identifier", should = "be rejected", expected = -32602, actual = bad.error and math.tointeger(bad.error.code) or 0 })
    local typ = request("textDocument/prepareRename", uri, 4, 11)
    tested.assert({ given = "a type name", should = "not be renameable", expected = true, actual = typ.error ~= nil and typ.error.message:find("types", 1, true) ~= nil })
    local std = request("textDocument/prepareRename", uri, 4, 1)
    tested.assert({ given = "stdlib global print", should = "not be renameable", expected = true, actual = std.error ~= nil })
end)

tested.test("record field references and rename across open files, including table constructors", function()
    client:shutdown()
    local mod = lines(
        "local record Vec",                        -- 0
        "   x: number",                            -- 1
        "   y: number",                            -- 2
        "   length: function(self): number",       -- 3
        "end",                                     -- 4
        "function Vec:length(): number",           -- 5
        "   return self.x + self.y",               -- 6
        "end",                                     -- 7
        "function Vec.origin(): Vec",              -- 8
        "   return { x = 0, y = 0 }",              -- 9
        "end",                                     -- 10
        "return Vec")                              -- 11
    local main = lines(
        'local Vec = require("mod")',              -- 0
        "local v: Vec = { x = 1, y = 2 }",         -- 1
        "print(v.x, v:length())",                  -- 2
        "v.x = 3",                                 -- 3
        "local other = { x = 1 }",                 -- 4 (unrelated table)
        "print(other.x, Vec.origin())")            -- 5
    local dir = project.create({ ["mod.tl"] = mod, ["main.tl"] = main })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir, { workspace = { workspaceEdit = { documentChanges = true } } })
    local mod_uri, main_uri = "file://" .. dir .. "/mod.tl", "file://" .. dir .. "/main.tl"
    open(mod_uri, mod)
    open(main_uri, main)

    local r = request("textDocument/references", main_uri, 2, 8, { context = { includeDeclaration = true } })
    tested.assert({
        given = "field x used in main.tl",
        should = "find the declaration, uses and typed constructor keys in both files",
        expected = "main.tl:1:17 main.tl:2:8 main.tl:3:2 mod.tl:1:3 mod.tl:6:15 mod.tl:9:12",
        actual = locs(r.result, true),
    })

    local m = request("textDocument/references", mod_uri, 5, 14, { context = { includeDeclaration = true } })
    tested.assert({
        given = "method length (from its implementation)",
        should = "find declaration, implementation and call",
        expected = "main.tl:2:13 mod.tl:3:3 mod.tl:5:13",
        actual = locs(m.result, true),
    })

    local rn = request("textDocument/rename", main_uri, 2, 8, { newName = "px" })
    local new_main, new_mod = main, mod
    for _, change in ipairs(rn.result.documentChanges) do
        if change.textDocument.uri == main_uri then
            new_main = LspClient.apply_text_edits(main, change.edits)
        else
            new_mod = LspClient.apply_text_edits(mod, change.edits)
        end
    end
    tested.assert({ given = "renamed main.tl", should = "rename typed uses only", expected = lines(
        'local Vec = require("mod")', "local v: Vec = { px = 1, y = 2 }", "print(v.px, v:length())", "v.px = 3", "local other = { x = 1 }", "print(other.x, Vec.origin())"), actual = new_main })
    tested.assert({ given = "renamed mod.tl", should = "rename declaration, self use and constructor", expected = lines(
        "local record Vec", "   px: number", "   y: number", "   length: function(self): number", "end", "function Vec:length(): number",
        "   return self.px + self.y", "end", "function Vec.origin(): Vec", "   return { px = 0, y = 0 }", "end", "return Vec"), actual = new_mod })
    local msg = client:wait_for_notification("window/showMessage", 5000)
    tested.assert({ given = "cross-file rename", should = "warn that closed files are not updated", expected = true, actual = msg.message:find("not open", 1, true) ~= nil })
    project.remove(dir)
end)

tested.test("references on positions with multi-byte text use UTF-16 columns", function()
    local uri = "file:///tmp/tls_ref_utf16.tl"
    open(uri, 'local s = "日本" local n = 1 print(s, n)')
    -- '日本' is 6 bytes but 2 UTF-16 units: n is at UTF-16 columns 21 and 36 (bytes 25 and 40)
    local r = request("textDocument/references", uri, 0, 36, { context = { includeDeclaration = true } })
    tested.assert({ given = "n after multi-byte text", should = "be found at UTF-16 columns", expected = "0:21 0:36", actual = locs(r.result) })
end)

return tested
