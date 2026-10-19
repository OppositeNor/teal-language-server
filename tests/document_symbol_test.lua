package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local declarations = require("tests.helpers.declarations")

local KIND = { Class = 5, Method = 6, Field = 8, Enum = 10, Interface = 11, Function = 12, Variable = 13, Constant = 14, EnumMember = 22, TypeParameter = 26 }

-- "name:kind(child, child...)" outline string for compact assertions
local function outline(syms)
    local parts = {}
    for _, s in ipairs(syms or {}) do
        local kind_name = "?"
        for k, v in pairs(KIND) do
            if v == s.kind then kind_name = k end
        end
        local str = s.name .. ":" .. kind_name
        if s.children and #s.children > 0 then
            str = str .. "(" .. outline(s.children) .. ")"
        end
        table.insert(parts, str)
    end
    return table.concat(parts, ", ")
end

local function contains(outer, inner)
    local function le(a, b)
        return a.line < b.line or (a.line == b.line and a.character <= b.character)
    end
    return le(outer.start, inner.start) and le(inner["end"], outer["end"])
end

local function all_nested(syms, parent_range)
    for _, s in ipairs(syms or {}) do
        if not contains(s.range, s.selectionRange) then
            return false, s.name .. ": selectionRange outside range"
        end
        if parent_range and not contains(parent_range, s.range) then
            return false, s.name .. ": range outside parent"
        end
        local ok, why = all_nested(s.children, s.range)
        if not ok then
            return false, why
        end
    end
    return true
end

local client

local function document_symbols(uri)
    local id = client:request("textDocument/documentSymbol", { textDocument = { uri = uri } })
    return client:wait_for_response(id)
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

tested.test("outline of a declaration file (.d.tl)", function()
    local uri = "file:///tmp/tls_sym_shapes.d.tl"
    client:open_document(uri, declarations.SHAPES_DTL)
    client:wait_for_notification("textDocument/publishDiagnostics")

    local syms = document_symbols(uri).result
    tested.assert({
        given = "shapes.d.tl",
        should = "produce a nested outline of records, enums, fields and methods",
        expected = "shapes:Class("
            .. "Color:Enum(blue:EnumMember, green:EnumMember, red:EnumMember), "
            .. "Style:Class(color:Field, width:Field), "
            .. "Point:Class(x:Field, y:Field), "
            .. "Path:Class(move_to:Method, line_to:Method, close:Method), "
            .. "Canvas:Class(new_path:Method, draw:Method, flush:Method), "
            .. "new:Method)",
        actual = outline(syms),
    })
    local ok, why = all_nested(syms)
    tested.assert({ given = "all symbol ranges", should = "nest properly", expected = true, actual = ok or why })

    local path_sym = syms[1].children[4]
    tested.assert({
        given = "Path selection range",
        should = "be the name on (0-based) line 18",
        expected = "18:10-18:14",
        actual = string.format("%d:%d-%d:%d", path_sym.selectionRange.start.line, path_sym.selectionRange.start.character,
            path_sym.selectionRange["end"].line, path_sym.selectionRange["end"].character),
    })
end)

tested.test("outline of a module with record methods, module functions, locals and constants", function()
    local uri = "file:///tmp/tls_sym_module.tl"
    client:open_document(uri, table.concat({
        "local M = {}",
        "local record Point",
        "   x: number",
        "   y: number",
        "end",
        "function Point:len(): number return self.x end",
        "function M.helper(): integer return 1 end",
        "local function util() end",
        "local VERSION <const> = \"1\"",
        "local interface Shape end",
        "local type Names = {string}",
        "util()",
        "print(VERSION)",
        "return M",
    }, "\n"))
    client:wait_for_notification("textDocument/publishDiagnostics")

    local syms = document_symbols(uri).result
    tested.assert({
        given = "module file",
        should = "nest methods under their owners",
        expected = "M:Variable(helper:Function), Point:Class(x:Field, y:Field, len:Method), util:Function, VERSION:Constant, Shape:Interface, Names:TypeParameter",
        actual = outline(syms),
    })
    local ok, why = all_nested(syms)
    tested.assert({ given = "all symbol ranges", should = "nest properly", expected = true, actual = ok or why })
end)

tested.test("outline of incomplete code does not fail", function()
    local uri = "file:///tmp/tls_sym_broken.tl"
    client:open_document(uri, "local record R\n  x: integer\nlocal function f(")
    client:wait_for_notification("textDocument/publishDiagnostics")
    local response = document_symbols(uri)
    tested.assert({ given = "broken code", should = "return a list, not an error", expected = "table", actual = response.error == nil and type(response.result) or "error" })
end)

tested.test("outline uses UTF-16 columns", function()
    local uri = "file:///tmp/tls_sym_utf16.tl"
    client:open_document(uri, 'local s = "日本" local function after() end\nafter() print(s)')
    client:wait_for_notification("textDocument/publishDiagnostics")
    local syms = document_symbols(uri).result
    local after = syms[2]
    tested.assert({ given = "function after multi-byte text", should = "start its name at UTF-16 column 30", expected = 30, actual = after and math.tointeger(after.selectionRange.start.character) or -1 })
end)

return tested
