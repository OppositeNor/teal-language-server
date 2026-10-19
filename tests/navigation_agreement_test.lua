package.path = "./?.lua;" .. package.path

-- Definition, references and hover must agree about which declaration a
-- name refers to: every definition result is one of the declarations that
-- references (includeDeclaration) report.

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")

local function lines(...)
    return table.concat({ ... }, "\n")
end

local client

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
end)

local function key(uri, range)
    return string.format("%s:%d:%d-%d", uri, range.start.line, range.start.character, range["end"].character)
end

local function definitions(uri, line, character)
    local r = client:get_definition(uri, line, character)
    local result = r.result
    if type(result) ~= "table" then
        return {}
    end
    if result.uri then
        result = { result }
    end
    local out = {}
    for _, loc in ipairs(result) do
        table.insert(out, key(loc.uri, loc.range))
    end
    return out
end

local function references(uri, line, character)
    local r = client:wait_for_response(client:request("textDocument/references", {
        textDocument = { uri = uri },
        position = { line = line, character = character },
        context = { includeDeclaration = true },
    }))
    local set = {}
    for _, loc in ipairs(type(r.result) == "table" and r.result or {}) do
        set[key(loc.uri, loc.range)] = true
    end
    return set
end

local function check_agreement(given, uri, line, character, expected_count)
    local defs = definitions(uri, line, character)
    local refs = references(uri, line, character)
    tested.assert({ given = given, should = "have " .. expected_count .. " definition(s)", expected = expected_count, actual = #defs })
    for _, d in ipairs(defs) do
        tested.assert({ given = given, should = "find definition " .. d .. " among the references", expected = true, actual = refs[d] == true })
    end
    return defs
end

local TEXT = lines(
    "local record Point",                          -- 0
    "   x: number",                                 -- 1
    "   len: function(self): number",               -- 2
    "end",                                          -- 3
    "function Point:len(): number return self.x end", -- 4
    "local total = 0",                              -- 5
    "do",                                           -- 6
    "   local total = 1",                           -- 7
    "   print(total)",                              -- 8
    "end",                                          -- 9
    "local p: Point = { x = 1 }",                   -- 10
    "print(p.x, p:len(), total)")                   -- 11

tested.test("definition is one of the declarations references report", function()
    client = LspClient.new("teal-language-server")
    client:initialize()
    local uri = "file:///tmp/tls_agree.tl"
    client:open_document(uri, TEXT)
    client:wait_for_notification("textDocument/publishDiagnostics")

    local d = check_agreement("an outer local", uri, 11, 21, 1)
    tested.assert({ given = "the outer total", should = "be the declaration on line 5", expected = uri .. ":5:6-11", actual = d[1] })
    d = check_agreement("a shadowing local", uri, 8, 10, 1)
    tested.assert({ given = "the inner total", should = "be the declaration on line 7", expected = uri .. ":7:9-14", actual = d[1] })
    d = check_agreement("a field", uri, 11, 8, 1)
    tested.assert({ given = "p.x", should = "be the field declaration", expected = uri .. ":1:3-4", actual = d[1] })
    d = check_agreement("a method declared in the record and implemented", uri, 11, 13, 2)
    tested.assert({ given = "p:len()", should = "list the record-body declaration first", expected = uri .. ":2:3-6", actual = d[1] })
    tested.assert({ given = "p:len()", should = "also list the implementation", expected = uri .. ":4:15-18", actual = d[2] })
end)

tested.test("definition of a field of a record from another open module", function()
    local dir = project.create({
        ["shapes.tl"] = lines(
            "local record Shape",
            "   area: number",
            "end",
            "local M = { Shape = Shape }",
            "function M.new(): Shape return { area = 1 } end",
            "return M"),
        ["main.tl"] = lines(
            "local shapes = require(\"shapes\")",
            "local s = shapes.new()",
            "print(s.area)"),
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
    local shapes_uri = "file://" .. dir .. "/shapes.tl"
    local main_uri = "file://" .. dir .. "/main.tl"
    client:open_document(shapes_uri, project.read(dir, "shapes.tl"))
    client:wait_for_notification("textDocument/publishDiagnostics")
    client:open_document(main_uri, project.read(dir, "main.tl"))
    client:wait_for_notification("textDocument/publishDiagnostics")

    local d = check_agreement("a field of an imported record", main_uri, 2, 9, 1)
    tested.assert({ given = "s.area", should = "be the field declared in shapes.tl", expected = shapes_uri .. ":1:3-7", actual = d[1] })
    project.remove(dir)
end)

return tested
