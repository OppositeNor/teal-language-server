package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")

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

tested.test("definition of locally defined function jumps to its declaration", function()
    local uri = "file:///tmp/tls_def_1.tl"
    local doc = table.concat({
        "local function my_func(): number",
        "  return 42",
        "end",
        "local x = my_func()",
    }, "\n")
    client:open_document(uri, doc)
    client:wait_for_notification("textDocument/publishDiagnostics")

    -- line 3 "local x = my_func()": 'my_func' starts at col 10
    local response = client:get_definition(uri, 3, 10)

    tested.assert({
        given = "definition response",
        should = "have a result",
        expected = true,
        actual = response ~= nil and response.result ~= nil,
    })

    local result = response.result
    tested.assert({
        given = "definition result",
        should = "have a uri",
        expected = true,
        actual = result ~= nil and result.uri ~= nil,
    })
    tested.assert({
        given = "definition result uri",
        should = "point to the same document",
        expected = true,
        actual = result ~= nil and result.uri == uri,
    })
    tested.assert({
        given = "definition result range",
        should = "point to line 0 (where my_func is declared)",
        expected = 0,
        actual = result ~= nil and result.range ~= nil and result.range.start.line,
    })
end)

tested.test("definition of a locally defined record type jumps to its declaration", function()
    local uri = "file:///tmp/tls_def_2.tl"
    local doc = table.concat({
        "local record Point",
        "  x: number",
        "  y: number",
        "end",
        "local function make(): Point",
        "  return { x = 1, y = 2 }",
        "end",
        "local p = make()",
    }, "\n")
    client:open_document(uri, doc)
    client:wait_for_notification("textDocument/publishDiagnostics")

    -- line 7 "local p = make()": 'make' starts at col 10
    local response = client:get_definition(uri, 7, 10)

    tested.assert({
        given = "local function definition response",
        should = "have a result",
        expected = true,
        actual = response ~= nil and response.result ~= nil,
    })

    local result = response.result
    tested.assert({
        given = "local function definition result",
        should = "have a uri",
        expected = true,
        actual = result ~= nil and result.uri ~= nil,
    })
    tested.assert({
        given = "local function definition result",
        should = "point to line 4 (where make is declared)",
        expected = 4,
        actual = result ~= nil and result.range ~= nil and result.range.start.line,
    })
end)

-- "file:line:col" of a definition result
local cjson_null = require("cjson").null
local function where(response)
    local r = response and response.result
    if r == nil or r == cjson_null then
        return "none"
    end
    return string.format("%s:%d:%d", r.uri:match("([^/]+)$"), r.range.start.line, r.range.start.character)
end

local QUALIFIED = table.concat({
    "local record sort",                                                                        -- 0
    "   record RadixSortBuffers",                                                               -- 1
    "      keys: {integer}",                                                                    -- 2
    "      record Inner",                                                                       -- 3
    "         n: integer",                                                                      -- 4
    "      end",                                                                                -- 5
    "   end",                                                                                   -- 6
    "end",                                                                                      -- 7
    "",                                                                                         -- 8
    "function sort.radix_sort_task(p_id: string, p_buffers: sort.RadixSortBuffers): integer",  -- 9
    "   return #p_buffers.keys + #p_id",                                                        -- 10
    "end",                                                                                      -- 11
    "local function g(i: sort.RadixSortBuffers.Inner): integer return i.n end",                 -- 12
    "print(g)",                                                                                 -- 13
    "return sort",                                                                              -- 14
}, "\n")

tested.test("definition of a qualified type name in an annotation (mod.Record)", function()
    local uri = "file:///tmp/tls_def_qualified.tl"
    client:open_document(uri, QUALIFIED)
    client:wait_for_notification("textDocument/publishDiagnostics")

    -- line 9: `p_buffers: sort.RadixSortBuffers`; "RadixSortBuffers" starts at col 60
    tested.assert({ given = "cursor on RadixSortBuffers", should = "jump to the nested record's name", expected = "tls_def_qualified.tl:1:10", actual = where(client:get_definition(uri, 9, 65)) })
    tested.assert({ given = "type definition on RadixSortBuffers", should = "jump to the nested record's name", expected = "tls_def_qualified.tl:1:10", actual = where(client:get_type_definition(uri, 9, 65)) })
    tested.assert({ given = "cursor on the qualifier sort", should = "jump to the outer record", expected = "tls_def_qualified.tl:0:13", actual = where(client:get_definition(uri, 9, 57)) })
    -- line 12: `i: sort.RadixSortBuffers.Inner`; "Inner" starts at col 42
    tested.assert({ given = "cursor on a doubly nested type", should = "jump to Inner", expected = "tls_def_qualified.tl:3:13", actual = where(client:get_definition(uri, 12, 44)) })
end)

tested.test("definition of a qualified type from another module", function()
    client:shutdown()
    local dir = project.create({
        ["sort.tl"] = QUALIFIED,
        ["main.tl"] = 'local sort = require("sort")\nlocal function f(b: sort.RadixSortBuffers): integer return #b.keys end\nprint(f)',
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
    local uri = "file://" .. dir .. "/main.tl"
    client:open_document(uri, project.read(dir, "main.tl"))
    client:wait_for_notification("textDocument/publishDiagnostics")

    -- line 1: `b: sort.RadixSortBuffers`; "RadixSortBuffers" starts at col 25 (sort.tl is not open)
    tested.assert({ given = "qualified type from a required module", should = "jump into sort.tl", expected = "sort.tl:1:10", actual = where(client:get_definition(uri, 1, 28)) })
    project.remove(dir)
end)

local NESTED_TYPES = table.concat({
    "local record shapes",                                                          -- 0
    "    record Point",                                                             -- 1
    "        x: number",                                                            -- 2
    "        offset: function(self: Point, p_by?: number): Point",                  -- 3
    "    end",                                                                      -- 4
    "    record Style",                                                             -- 5
    "        anchors: {Point}",                                                     -- 6
    "    end",                                                                      -- 7
    "    interface DrawParams",                                                     -- 8
    "        at: Point",                                                            -- 9
    "    end",                                                                      -- 10
    "    record Canvas",                                                            -- 11
    "        draw: function(self: Canvas, p_id: string, p_params: DrawParams,",     -- 12
    "            p_style?: Style): Layer",                                          -- 13
    "    end",                                                                      -- 14
    "    record Layer",                                                             -- 15
    "        canvas: Canvas",                                                       -- 16
    "    end",                                                                      -- 17
    "    new: function(): Canvas",                                                  -- 18
    "end",                                                                          -- 19
    "return shapes",                                                                -- 20
}, "\n")

tested.test("definition of nested type names used inside record bodies", function()
    local uri = "file:///tmp/tls_def_nested_types.d.tl"
    client:open_document(uri, NESTED_TYPES)
    client:wait_for_notification("textDocument/publishDiagnostics")
    local f = "tls_def_nested_types.d.tl"

    tested.assert({ given = "a sibling interface in a field's function type", should = "jump to it", expected = f .. ":8:14", actual = where(client:get_definition(uri, 12, 62)) })
    tested.assert({ given = "a sibling record on a continuation line", should = "jump to it", expected = f .. ":5:11", actual = where(client:get_definition(uri, 13, 24)) })
    tested.assert({ given = "a record declared later (forward reference)", should = "jump to it", expected = f .. ":15:11", actual = where(client:get_definition(uri, 13, 30)) })
    tested.assert({ given = "the enclosing record's own name", should = "jump to it", expected = f .. ":11:11", actual = where(client:get_definition(uri, 12, 33)) })
    tested.assert({ given = "a record named inside its own body", should = "jump to it", expected = f .. ":1:11", actual = where(client:get_definition(uri, 3, 32)) })
    tested.assert({ given = "a nested type inside an array type", should = "jump to it", expected = f .. ":1:11", actual = where(client:get_definition(uri, 6, 19)) })
    tested.assert({ given = "type definition of the sibling interface", should = "jump to it", expected = f .. ":8:14", actual = where(client:get_type_definition(uri, 12, 62)) })
    -- a field name is not hijacked by a type of a similar name
    tested.assert({ given = "the field name canvas", should = "not jump to the record Canvas", expected = true, actual = where(client:get_definition(uri, 16, 9)) ~= f .. ":11:11" })
end)

-- Location(s) of a definition/implementation result as "file:line:col", sorted
local function wheres(response)
    local r = response and response.result
    if r == nil or r == cjson_null then
        return "none"
    end
    if r.uri then
        r = { r }
    end
    local out = {}
    for _, l in ipairs(r) do
        table.insert(out, string.format("%s:%d:%d", l.uri:match("([^/]+)$"), l.range.start.line, l.range.start.character))
    end
    table.sort(out)
    return table.concat(out, " ")
end

tested.test("definition on a field declaration jumps to its implementation (same file)", function()
    local uri = "file:///tmp/tls_def_impl_same.tl"
    client:open_document(uri, table.concat({
        "local record Shape",                                    -- 0
        "   area: function(self: Shape): number",                -- 1
        "   scale: function(self: Shape, by: number)",           -- 2
        "   name: function(self: Shape): string",                -- 3
        "   w: number",                                          -- 4
        "end",                                                   -- 5
        "function Shape:area(): number",                         -- 6
        "   return self.w",                                      -- 7
        "end",                                                   -- 8
        "Shape.scale = function(self: Shape, by: number)",       -- 9
        "   self.w = self.w * by",                               -- 10
        "end",                                                   -- 11
        "return Shape",                                          -- 12
    }, "\n"))
    client:wait_for_notification("textDocument/publishDiagnostics")
    local f = "tls_def_impl_same.tl"
    tested.assert({ given = "declaration of area", should = "jump to function Shape:area", expected = f .. ":6:15", actual = wheres(client:get_definition(uri, 1, 4)) })
    tested.assert({ given = "declaration of scale", should = "jump to the Shape.scale = function assignment", expected = f .. ":9:6", actual = wheres(client:get_definition(uri, 2, 4)) })
    tested.assert({ given = "a declared method without implementation", should = "stay on its declaration", expected = f .. ":3:3", actual = wheres(client:get_definition(uri, 3, 4)) })
    tested.assert({ given = "a plain field", should = "stay on its declaration", expected = f .. ":4:3", actual = wheres(client:get_definition(uri, 4, 3)) })
end)

tested.test("declaration in a .d.tl jumps to the implementation in a file that is not open", function()
    client:shutdown()
    local dir = project.create({
        ["graph.d.tl"] = table.concat({
            "local record graph",                                -- 0
            "   record Graph",                                   -- 1
            "      compute: function(self: Graph, n: integer): integer", -- 2
            "   end",                                            -- 3
            "   new: function(): Graph",                         -- 4
            "end",                                               -- 5
            "return graph",                                      -- 6
        }, "\n"),
        ["graph_impl.tl"] = table.concat({
            'local graph = require("graph")',                    -- 0
            "local Graph = graph.Graph",                         -- 1
            "function Graph:compute(n: integer): integer",       -- 2
            "   return n",                                       -- 3
            "end",                                               -- 4
            "return Graph",                                      -- 5
        }, "\n"),
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
    local uri = "file://" .. dir .. "/graph.d.tl"
    client:open_document(uri, project.read(dir, "graph.d.tl"))
    client:wait_for_notification("textDocument/publishDiagnostics")

    tested.assert({ given = "declaration of compute (implementation file closed)", should = "jump into graph_impl.tl", expected = "graph_impl.tl:2:15", actual = wheres(client:get_definition(uri, 2, 9)) })
    local id = client:request("textDocument/implementation", { textDocument = { uri = uri }, position = { line = 2, character = 9 } })
    tested.assert({ given = "textDocument/implementation on compute", should = "list the implementation", expected = "graph_impl.tl:2:15", actual = wheres(client:wait_for_response(id)) })
    id = client:request("textDocument/implementation", { textDocument = { uri = uri }, position = { line = 1, character = 11 } })
    tested.assert({ given = "textDocument/implementation on a record name", should = "return an empty list", expected = "", actual = wheres(client:wait_for_response(id)) })
    project.remove(dir)
end)

return tested
