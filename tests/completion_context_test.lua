package.path = "./?.lua;" .. package.path

-- Completion on incomplete code, and the context / receiver / scope queries
-- it is built on. The in-process tests run the analysis modules directly;
-- the rest go through the server over JSON-RPC.

local tested = require("tested")
local tl = require("tl")
local LspClient = require("tests.helpers.lsp_client")
local completion = require("teal_language_server.analysis.completion")
local semantic = require("teal_language_server.analysis.semantic")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")

local function lines(...)
    return table.concat({ ... }, "\n")
end

-- Context at the "|" marker of `text` (the marker is removed).
local function context_at(text, hint)
    local marker = text:find("|", 1, true)
    local before = text:sub(1, marker - 1)
    local source = before .. text:sub(marker + 1)
    local y = select(2, before:gsub("\n", "")) + 1
    local line_start = before:match(".*\n()") or 1
    local x = marker - line_start + 1
    local tokens = tl.lex(source, "ctx.tl")
    local line_after = source:sub(marker):match("^[^\n]*")
    return completion.context(tokens, y, x, hint or "code", line_after)
end

local function check(file, src)
    local env = tl.new_env({ defaults = { feat_lax = "off", feat_arity = "on" } })
    env.report_types = true
    local tokens = tl.lex(src, file)
    local ast = tl.parse_program(tokens, {}, file)
    tl.check(ast, file, { feat_lax = "off" }, env)
    return env.reporter:get_report(), tokens, ast
end

tested.test("completion context: member access, annotations and declarations", function()
    local cases = {
        { "local q = p.|", "member", "." },
        { "local q = p.na|", "member", "." },
        { "p:|", "member", ":" },
        { "local _ = b:foo():|", "member", ":" },
        { "local x: |", "type" },
        { "local a, b: |", "type" },
        { "local function f(a: |", "type" },
        { "local function f(a: number, ?b: |", "type" },
        { "local function f(): |", "type" },
        { "function M.f<T>(x: |", "type" },
        { "local y = x as |", "type" },
        { "local x: Outer.|", "member" },
        { "if x is |", "type" },
        { "local |", "declaration" },
        { "local function |", "none" },
        { "for i| = 1, 2 do end", "none" },
        { "local a, b|", "none" },
        { "local n = 12|", "none" },
        -- a literal: its expected type (string here) decides, see the enum tests
        { "local s = 'abc|'", "literal", nil, "string" },
        { "-- comment |", "none", nil, "comment" },
        { "  name|: string", "none", nil, "name" },
        { "local v = ab|", "scope" },
        { "print(|)", "scope" },
    }
    for _, c in ipairs(cases) do
        local ctx = context_at(c[1], c[4])
        tested.assert({ given = c[1], should = "be a " .. c[2] .. " context", expected = c[2], actual = ctx.kind })
        if c[3] then
            tested.assert({ given = c[1], should = "use operator " .. c[3], expected = c[3], actual = ctx.op })
        end
    end
    local ctx = context_at("local x: Outer.|")
    tested.assert({ given = "local x: Outer.", should = "be a qualified type position", expected = true, actual = ctx.in_type })
    ctx = context_at("local q = p.na|me")
    tested.assert({ given = "cursor inside a member name", should = "use the typed part as prefix", expected = "na", actual = ctx.prefix })
    ctx = context_at("local _ = v:|scale(2)")
    tested.assert({ given = "a member followed by an argument list", should = "know a call follows", expected = true, actual = ctx.followed_by_call })
end)

tested.test("string literal contexts know where their expected type comes from", function()
    local cases = {
        { 'f("|")', "argument" },
        { 'f(1, "o|n")', "argument" },
        { 'f("|', "argument" },
        { 'local m: Mode = "|"', "expression" },
        { 'd.mode = "|"', "expression" },
        { 'if m == "|" then end', "expression" },
        { 'local o: Opts = { mode = "|" }', "constructor_field" },
    }
    for _, c in ipairs(cases) do
        local ctx = context_at(c[1], "string")
        tested.assert({ given = c[1], should = "be a literal context", expected = "literal", actual = ctx.kind })
        tested.assert({ given = c[1], should = "take the expected type from the " .. c[2], expected = c[2], actual = ctx.literal_source })
    end
    local ctx = context_at('f(1, "o|n")', "string")
    tested.assert({ given = "a partially typed literal", should = "replace the whole content", expected = "7-9", actual = ctx.content_x .. "-" .. ctx.content_xend })
    ctx = context_at('local t = { "a|" }', "string")
    tested.assert({ given = "an array constructor entry", should = "offer nothing", expected = "none", actual = ctx.kind })
end)

tested.test("parsing keeps the caller's tokens unchanged", function()
    -- tl's parser inserts a synthetic ")" while recovering from `f("o`
    local tokens = tl.lex('f("o\n', "mut.tl")
    local before = #tokens
    ast_walk.parse_program(tokens, {}, "mut.tl")
    tested.assert({ given = "an unterminated call", should = "leave the token list as lexed", expected = before, actual = #tokens })
end)

tested.test("expression keys locate where tl records each receiver's type", function()
    local src = lines(
        "local record P",
        "  x: number",
        "  q: {P}",
        "end",
        "function P:me(): P return self end",
        "local function mk(): function(): P return nil end",
        "local p: P = {}",
        "local a = p:me().x",
        "local b = p.q[1].x",
        "local c = mk()().x",
        "local d = (p).x")
    local report, tokens = check("keys.tl", src)
    local function receiver_before_dot(line)
        -- the last "." on the line
        local dot
        for i, t in ipairs(tokens) do
            if t.y == line and t.tk == "." then dot = i end
        end
        return semantic.expression_key(tokens, dot - 1)
    end
    for _, line in ipairs({ 8, 9, 10, 11 }) do
        local key = receiver_before_dot(line)
        local ti = key and semantic.type_at_key(report, "keys.tl", key.y, key.x, key.ret_depth)
        tested.assert({ given = "receiver on line " .. line, should = "resolve to P", expected = "P", actual = ti and ti.str or "nil" })
    end
end)

tested.test("visible symbols honour shadowing and closed sibling scopes", function()
    local src = lines(
        "local v: {number} = {}",
        "do",
        "   local hidden = 1",
        "end",
        "do",
        "   local v: string = 'a'",
        "   local w = v",
        "end")
    local report = check("scope.tl", src)
    local seen = {}
    for _, s in ipairs(semantic.visible_symbols(report, "scope.tl", 7, 14)) do
        seen[s.name] = report.types[s.type_id] and report.types[s.type_id].str
    end
    tested.assert({ given = "an inner v shadowing an outer v", should = "see the inner one", expected = "string", actual = seen.v })
    tested.assert({ given = "a local of a closed sibling block", should = "not be visible", expected = false, actual = seen.hidden ~= nil })
end)

-- Through the server ---------------------------------------------------------

local client

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

local n = 0
local function complete(text, line, character, trigger)
    n = n + 1
    local uri = "file:///tmp/tls_ctx_" .. n .. ".tl"
    client:open_document(uri, text)
    client:wait_for_notification("textDocument/publishDiagnostics")
    local r
    if trigger then
        r = client:get_completions_triggered(uri, line, character, trigger)
    else
        r = client:get_completions(uri, line, character)
    end
    local items = type(r.result) == "table" and r.result.items or {}
    local by_label = {}
    for _, item in ipairs(items) do
        by_label[item.label] = item
    end
    return by_label, items, uri
end

local POINT = lines(
    "local record Point",                                   -- 0
    "   x: number",                                          -- 1
    "   y: number",                                          -- 2
    "   name: string",                                       -- 3
    "end",                                                   -- 4
    "function Point:len(): number return 0 end",             -- 5
    "local function make(): Point return { x = 1, y = 2, name = 'a' } end", -- 6
    "")

tested.test("'.' completion inside an unfinished statement offers the receiver's members", function()
    -- the buffer does not parse: the statement after `pt.` is missing
    local items = complete(POINT .. lines(
        "local function f(pt: Point)",
        "   pt.",
        "end"), 8, 6, ".")
    for _, label in ipairs({ "x", "y", "name", "len" }) do
        tested.assert({ given = "pt. in a broken buffer", should = "offer " .. label, expected = true, actual = items[label] ~= nil })
    end
    tested.assert({ given = "pt. in a broken buffer", should = "not offer scope names", expected = false, actual = items.print ~= nil })
end)

tested.test("':' completion inside an unfinished statement offers only methods", function()
    local items = complete(POINT .. lines(
        "local p = make()",
        "local _ = p:"), 8, 12, ":")
    tested.assert({ given = "p: in a broken buffer", should = "offer the method len", expected = true, actual = items.len ~= nil })
    tested.assert({ given = "p: in a broken buffer", should = "not offer the field x", expected = false, actual = items.x ~= nil })
end)

tested.test("completion sees a local declared in the same unsaved, unfinished edit", function()
    local items = complete(POINT .. lines(
        "local function f()",
        "   local brandnew: Point = make()",
        "   brandnew.",
        "end"), 9, 12, ".")
    tested.assert({ given = "a local declared in the broken buffer", should = "resolve its type", expected = true, actual = items.name ~= nil })
end)

tested.test("member completion on a generic record field uses the instantiated type", function()
    -- `b.item` is a string: the members are string methods, not Box's
    local items = complete(lines(
        "local record Box<T>",
        "   item: T",
        "   get: function(Box<T>): T",
        "end",
        "local b: Box<string> = { item = 'a' }",
        "local _ = b.item:"), 5, 17, ":")
    tested.assert({ given = "b.item: with item: string", should = "offer string methods", expected = true, actual = items.upper ~= nil })
    tested.assert({ given = "b.item: with item: string", should = "not offer Box members", expected = false, actual = items.get ~= nil })
end)

tested.test("member completion follows the innermost declaration of a shadowed name", function()
    local items = complete(lines(
        "local v: {number} = {}",
        "do",
        "   local v: string = 'a'",
        "   local _ = v:",
        "end"), 3, 15, ":")
    tested.assert({ given = "an inner string v shadowing an array v", should = "offer string methods", expected = true, actual = items.upper ~= nil })
end)

tested.test("type positions offer type names, not values", function()
    local items = complete(POINT .. lines(
        "local enum Mode",
        "   \"on\"",
        "end",
        "local function g(a: "), 10, 20, nil)
    for _, label in ipairs({ "Point", "Mode", "number", "string" }) do
        tested.assert({ given = "a parameter annotation", should = "offer the type " .. label, expected = true, actual = items[label] ~= nil })
    end
    for _, label in ipairs({ "make", "print", "local" }) do
        tested.assert({ given = "a parameter annotation", should = "not offer " .. label, expected = false, actual = items[label] ~= nil })
    end
    tested.assert({ given = "the record type Point", should = "be a Class item", expected = 7, actual = items.Point and math.tointeger(items.Point.kind) })
    tested.assert({ given = "the enum type Mode", should = "be an Enum item", expected = 13, actual = items.Mode and math.tointeger(items.Mode.kind) })
end)

tested.test("record field types and qualified types are type positions", function()
    local items = complete(lines(
        "local record Outer",
        "   record Inner",
        "      z: integer",
        "   end",
        "   value: integer",
        "end",
        "local record R",
        "   f: ",
        "end"), 7, 6, nil)
    tested.assert({ given = "a record field's type", should = "offer the type Outer", expected = true, actual = items.Outer ~= nil })
    tested.assert({ given = "a record field's type", should = "offer integer", expected = true, actual = items.integer ~= nil })
    tested.assert({ given = "a record field's type", should = "not offer keywords", expected = false, actual = items["while"] ~= nil })

    items = complete(lines(
        "local record Outer",
        "   record Inner",
        "      z: integer",
        "   end",
        "   value: integer",
        "end",
        "local x: Outer.In"), 6, 17, nil)
    tested.assert({ given = "Outer. in a type position", should = "offer the nested type Inner", expected = true, actual = items.Inner ~= nil })
    tested.assert({ given = "Outer. in a type position", should = "not offer the value field", expected = false, actual = items.value ~= nil })
end)

tested.test("nothing is offered in comments, strings or new declaration names", function()
    local _, list = complete("local x = 1 -- some comm", 0, 24, nil)
    tested.assert({ given = "a comment", should = "offer nothing", expected = 0, actual = #list })
    _, list = complete("local s = 'some str", 0, 19, nil)
    tested.assert({ given = "an unterminated string", should = "offer nothing", expected = 0, actual = #list })
    _, list = complete("local x = 1\nlocal function ", 1, 15, nil)
    tested.assert({ given = "after `local function `", should = "offer nothing", expected = 0, actual = #list })
end)

tested.test("scope completion ranks locals before globals before keywords", function()
    local items = complete(POINT .. lines(
        "local function f(pt: Point)",
        "   local zeta = 1",
        "   ze",
        "end"), 9, 5, nil)
    tested.assert({ given = "a local in an unfinished function body", should = "be offered", expected = true, actual = items.zeta ~= nil })
    tested.assert({ given = "a parameter", should = "be offered", expected = true, actual = items.pt ~= nil })
    local zeta = items.zeta and items.zeta.sortText or ""
    local print_ = items.print and items.print.sortText or ""
    local kw = items["while"] and items["while"].sortText or ""
    tested.assert({ given = "local zeta vs global print", should = "sort the local first", expected = true, actual = zeta < print_ })
    tested.assert({ given = "global print vs keyword while", should = "sort the global first", expected = true, actual = print_ < kw })
end)

tested.test("an edit that breaks the buffer does not leave the previous version's types", function()
    n = n + 1
    local uri = "file:///tmp/tls_ctx_stale.tl"
    client:open_document(uri, POINT .. lines(
        "local s: string = ''",
        "local p: Point = make()"))
    client:wait_for_notification("textDocument/publishDiagnostics")
    -- swap the names and start typing a member access: `p` is now the string
    client:change_document(uri, POINT .. lines(
        "local p: string = ''",
        "local s: Point = make()",
        "local _ = p."), 2)
    local r = client:get_completions_triggered(uri, 9, 12, ".")
    local items = {}
    for _, item in ipairs(r.result and r.result.items or {}) do
        items[item.label] = true
    end
    tested.assert({ given = "p redeclared as a string in an unfinished edit", should = "offer string methods", expected = true, actual = items.upper ~= nil })
    tested.assert({ given = "p redeclared as a string in an unfinished edit", should = "not offer Point's fields", expected = false, actual = items.x ~= nil })
end)

tested.test("hover answers from the current text while it does not parse", function()
    n = n + 1
    local uri = "file:///tmp/tls_ctx_hover.tl"
    client:open_document(uri, POINT .. lines(
        "local p = make()",
        "local _ = p."))
    client:wait_for_notification("textDocument/publishDiagnostics")
    local r = client:get_hover(uri, 7, 6)
    local value = r.result and r.result.contents and (r.result.contents.value or tostring(r.result.contents)) or ""
    tested.assert({ given = "hover on p in a broken buffer", should = "show its type Point", expected = true, actual = value:find("Point", 1, true) ~= nil })
end)

tested.test("record constructors offer the record's missing fields, also when unclosed", function()
    local items, list = complete(POINT .. "local p: Point = { x = 1, }", 7, 26, nil)
    for _, label in ipairs({ "y", "name" }) do
        tested.assert({ given = "a Point constructor", should = "offer " .. label, expected = true, actual = items[label] ~= nil })
    end
    tested.assert({ given = "a Point constructor with x written", should = "not offer x again", expected = false, actual = items.x ~= nil })
    tested.assert({ given = "a Point constructor", should = "not offer scope names", expected = false, actual = items.print ~= nil })
    tested.assert({ given = "a constructor field", should = "insert `name = `", expected = "y = ", actual = items.y and items.y.insertText })
    tested.assert({ given = "data fields vs the method len", should = "rank data fields first", expected = true,
        actual = items.y ~= nil and items.len ~= nil and items.y.sortText < items.len.sortText })

    items = complete(POINT .. "local p: Point = { x = 1, \n", 7, 26, nil)
    tested.assert({ given = "an unclosed Point constructor", should = "offer y", expected = true, actual = items.y ~= nil })

    items = complete(POINT .. "local function take(p: Point) end\ntake({ })", 8, 6, nil)
    tested.assert({ given = "a constructor passed to a Point parameter", should = "offer x", expected = true, actual = items.x ~= nil })

    items = complete(POINT .. "local arr: {integer} = { }", 7, 25, nil)
    tested.assert({ given = "an array constructor", should = "offer values from the scope", expected = true, actual = items.print ~= nil })
end)

local function signature(text, line, character)
    n = n + 1
    local uri = "file:///tmp/tls_ctx_sig_" .. n .. ".tl"
    client:open_document(uri, text)
    client:wait_for_notification("textDocument/publishDiagnostics")
    local r = client:wait_for_response(client:request("textDocument/signatureHelp", {
        textDocument = { uri = uri }, position = { line = line, character = character },
    }))
    if type(r.result) ~= "table" then
        return nil
    end
    return r.result.signatures[1].label, math.tointeger(r.result.activeParameter)
end

tested.test("signature help on unfinished and higher-order calls", function()
    local text = POINT .. "local function take(p: Point, n: integer): string return '' end\n"
    local label, active = signature(text .. "local p = make()\ntake(p, ", 9, 8)
    tested.assert({ given = "an unfinished call", should = "show the callee's signature", expected = "take(p: Point, n: integer): string", actual = label })
    tested.assert({ given = "an unfinished call after one comma", should = "mark the second parameter", expected = 1, actual = active })

    label, active = signature(text .. "take(make(), #take(make(), 1))", 8, 25)
    tested.assert({ given = "the cursor in a nested call", should = "show the inner call's parameter 0", expected = 0, actual = active })

    -- the callee is the result of a generic call: its type is only known
    -- after instantiation
    label = signature(text .. "local function id<T>(x: T): T return x end\nid(take)(make(), ", 9, 17)
    tested.assert({ given = "calling a generic call's result", should = "show the instantiated function type", expected = true,
        actual = label ~= nil and label:find("Point", 1, true) ~= nil and label:find("integer", 1, true) ~= nil })
end)

local ENUMS = lines(
    "local enum Mode",                                       -- 0
    "   \"on\"",                                             -- 1
    "   \"off\"",                                            -- 2
    "end",                                                   -- 3
    "local enum Size",                                       -- 4
    "   \"big\"",                                            -- 5
    "   \"small\"",                                          -- 6
    "end",                                                   -- 7
    "local record Opts",                                     -- 8
    "   mode: Mode",                                         -- 9
    "   name: string",                                       -- 10
    "end",                                                   -- 11
    "local function set(m: Mode, s: Size | integer) end",    -- 12
    "local record Dev",                                      -- 13
    "   mode: Mode",                                         -- 14
    "end",                                                   -- 15
    "function Dev:switch(m: Mode) end",                      -- 16
    "local d: Dev = { mode = \"on\" }",                       -- 17
    "")

tested.test("string literals complete the values of their expected enum type", function()
    local function labels(text, character)
        local items, list = complete(ENUMS .. text, 18, character, nil)
        local out = {}
        for _, item in ipairs(list) do
            table.insert(out, item.label)
        end
        table.sort(out)
        return table.concat(out, ","), items
    end
    local cases = {
        { 'set("")', 5, "off,on", "a Mode argument" },
        { 'set("on", "")', 11, "big,small", "an argument of type Size | integer" },
        { 'd:switch("")', 10, "off,on", "a method argument (self is implicit)" },
        { 'local m: Mode = ""', 17, "off,on", "a declaration with a Mode annotation" },
        { 'd.mode = ""', 10, "off,on", "an assignment to a Mode field" },
        { 'if d.mode == "" then end', 14, "off,on", "a comparison with a Mode value" },
        { 'local o: Opts = { mode = "" }', 26, "off,on", "a Mode field in a constructor" },
        { 'set("o', 6, "off,on", "an unterminated literal" },
        { 'print("")', 7, "", "a parameter of type any" },
        { 'local o: Opts = { name = "" }', 26, "", "a string field" },
    }
    for _, c in ipairs(cases) do
        tested.assert({ given = c[4], should = "offer " .. (c[3] == "" and "nothing" or c[3]), expected = c[3], actual = (labels(c[1], c[2])) })
    end
    local _, items = labels('set("o")', 6)
    local edit = items.on and items.on.textEdit
    tested.assert({ given = 'set("o|")', should = "replace the literal's content",
        expected = "18:5-18:6", actual = edit and string.format("%d:%d-%d:%d", edit.range.start.line, edit.range.start.character, edit.range["end"].line, edit.range["end"].character) })
end)

return tested
