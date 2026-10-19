package.path = "./?.lua;" .. package.path

-- References and rename for globals and record fields across the workspace,
-- including files that are not open.

local tested = require("tested")
local cjson = require("cjson")
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

local FILES = {
    ["shapes.tl"] = lines(
        "local record Shape",                       -- 0
        "   area: number",                          -- 1
        "end",                                      -- 2
        "global shape_count: integer = 0",          -- 3
        "local M = { Shape = Shape }",              -- 4
        "function M.new(): Shape return { area = 1 } end", -- 5
        "return M"),                                -- 6
    ["user.tl"] = lines(
        'local shapes = require("shapes")',         -- 0
        "local s = shapes.new()",                   -- 1
        "print(s.area, shape_count)"),              -- 2
    -- a different record with a field of the same name: not a reference
    ["other.tl"] = lines(
        "local record Room",                        -- 0
        "   area: number",                          -- 1
        "end",                                      -- 2
        "local r: Room = { area = 2 }",             -- 3
        "print(r.area)"),                           -- 4
    ["main.tl"] = lines(
        'local shapes = require("shapes")',         -- 0
        "local s = shapes.new()",                   -- 1
        "s.area = 3",                               -- 2
        "shape_count = shape_count + 1"),           -- 3
}

local function start(files)
    dir = project.create(files)
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir, { workspace = { workspaceEdit = { documentChanges = true } } })
    local uri = "file://" .. dir .. "/main.tl"
    client:open_document(uri, files["main.tl"])
    client:wait_for_notification("textDocument/publishDiagnostics")
    return uri
end

local function request(method, uri, line, character, extra)
    local params = { textDocument = { uri = uri }, position = { line = line, character = character } }
    for k, v in pairs(extra or {}) do params[k] = v end
    return client:wait_for_response(client:request(method, params))
end

local function locs(result)
    local out = {}
    for _, l in ipairs(type(result) == "table" and result or {}) do
        table.insert(out, string.format("%s:%d:%d", l.uri:match("[^/]+$"), l.range.start.line, l.range.start.character))
    end
    table.sort(out)
    return table.concat(out, " ")
end

-- Applies a rename's documentChanges to the files on disk (as an editor
-- would) and returns the new contents by file name, plus the versions sent.
local function apply(edit)
    local out, versions = {}, {}
    for _, change in ipairs(edit.documentChanges) do
        local name = change.textDocument.uri:match("[^/]+$")
        out[name] = LspClient.apply_text_edits(project.read(dir, name), change.edits)
        versions[name] = change.textDocument.version
    end
    return out, versions
end

tested.test("field references include files that are not open, confirmed by record identity", function()
    local uri = start(FILES)
    local r = request("textDocument/references", uri, 2, 2, { context = { includeDeclaration = true } })
    tested.assert({ given = "s.area in main.tl (only main.tl is open)", should = "find uses in closed files and the declaration, not Room.area",
        expected = "main.tl:2:2 shapes.tl:1:3 shapes.tl:5:33 user.tl:2:8", actual = locs(r.result) })
end)

tested.test("global references include files that are not open", function()
    local uri = start(FILES)
    local r = request("textDocument/references", uri, 3, 0, { context = { includeDeclaration = true } })
    tested.assert({ given = "shape_count in main.tl", should = "find the declaration and uses in closed files",
        expected = "main.tl:3:0 main.tl:3:14 shapes.tl:3:7 user.tl:2:14", actual = locs(r.result) })
end)

tested.test("rename edits files that are not open, with no version constraint", function()
    local uri = start(FILES)
    local r = request("textDocument/rename", uri, 2, 2, { newName = "size" })
    tested.assert({ given = "rename of Shape.area", should = "succeed", expected = true, actual = r.error == nil and type(r.result) == "table" })
    local new, versions = apply(r.result)
    tested.assert({ given = "the closed declaring file", should = "rename the field and its constructor key",
        expected = lines("local record Shape", "   size: number", "end", "global shape_count: integer = 0",
            "local M = { Shape = Shape }", "function M.new(): Shape return { size = 1 } end", "return M"), actual = new["shapes.tl"] })
    tested.assert({ given = "the closed user file", should = "rename the use", expected = lines(
        'local shapes = require("shapes")', "local s = shapes.new()", "print(s.size, shape_count)"), actual = new["user.tl"] })
    tested.assert({ given = "the unrelated Room record", should = "not be edited", expected = false, actual = new["other.tl"] ~= nil })
    tested.assert({ given = "a closed file's edit", should = "carry a null version", expected = true, actual = versions["user.tl"] == cjson.null })
    tested.assert({ given = "the open file's edit", should = "carry its version", expected = 1, actual = math.tointeger(versions["main.tl"]) })
end)

tested.test("rename refuses when a file that may use the name cannot be fully analyzed", function()
    local files = {}
    for k, v in pairs(FILES) do files[k] = v end
    files["broken.tl"] = lines(
        'local shapes = require("shapes")',
        "local s = shapes.new()",
        "print(s.area",
        "local function f(")
    local uri = start(files)
    local r = request("textDocument/rename", uri, 2, 2, { newName = "size" })
    tested.assert({ given = "a candidate file with syntax errors", should = "refuse the rename", expected = true,
        actual = r.error ~= nil and r.error.message:find("broken.tl", 1, true) ~= nil })
    r = request("textDocument/references", uri, 2, 2, { context = { includeDeclaration = true } })
    tested.assert({ given = "references with the same broken file", should = "still be answered", expected = true,
        actual = locs(r.result):find("user.tl:2:8", 1, true) ~= nil })
end)

return tested
