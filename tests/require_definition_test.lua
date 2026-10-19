package.path = "./?.lua;" .. package.path

-- Go to definition on `require("a.b.c")` opens the module file (Neovim's
-- CTRL-] goes through textDocument/definition at the cursor).

local tested = require("tested")
local tl = require("tl")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")
local semantic = require("teal_language_server.analysis.semantic")

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

tested.test("the require call under the cursor", function()
    local src = 'local a = require("x.y")\nlocal b = require "z"\nlocal c = f("w")\nlocal require_me = 1\n'
    local tokens = tl.lex(src, "r.tl")
    local cases = {
        { 1, 20, "x.y", "the module string" },
        { 1, 11, "x.y", "the require name" },
        { 2, 19, "z", "a string call without parentheses" },
        { 3, 14, nil, "a string passed to another function" },
        { 1, 7, nil, "the local's name" },
        { 4, 7, nil, "an identifier that only starts with require" },
    }
    for _, c in ipairs(cases) do
        tested.assert({ given = c[4], should = "give " .. tostring(c[3]), expected = c[3] or "none",
            actual = semantic.required_module_at(tokens, c[1], c[2]) or "none" })
    end
end)

local function start(files, root_files)
    dir = project.create(files)
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
    local uri = "file://" .. dir .. "/" .. root_files
    client:open_document(uri, files[root_files])
    client:wait_for_notification("textDocument/publishDiagnostics")
    return uri
end

local function target(uri, line, character)
    local r = client:get_definition(uri, line, character)
    return type(r.result) == "table" and r.result.uri and r.result.uri:sub(#("file://" .. dir) + 2) or "none"
end

tested.test("definition on a nested module's require opens its file", function()
    local uri = start({
        ["render/features/voxel.tl"] = "local record Voxel\n   size: number\nend\nreturn Voxel\n",
        ["main.tl"] = 'local type voxel = require("render.features.voxel")\nlocal v: voxel = { size = 1 }\nprint(v.size)\n',
    }, "main.tl")
    tested.assert({ given = "the cursor in the module string", should = "open the module", expected = "render/features/voxel.tl", actual = target(uri, 0, 35) })
    tested.assert({ given = "the cursor on require", should = "open the module", expected = "render/features/voxel.tl", actual = target(uri, 0, 21) })
    tested.assert({ given = "the stdlib function print", should = "not point at tl's built-in declarations", expected = "none", actual = target(uri, 2, 1) })
end)

tested.test("definition on require follows tlconfig.lua's source_dir and init.tl modules", function()
    local uri = start({
        ["tlconfig.lua"] = 'return { source_dir = "src" }\n',
        ["src/app/util.tl"] = "return {}\n",
        ["src/app/net/init.tl"] = "return {}\n",
        ["src/main.tl"] = 'local util = require("app.util")\nlocal net = require("app.net")\nprint(util, net)\n',
    }, "src/main.tl")
    tested.assert({ given = "a module under source_dir", should = "open it", expected = "src/app/util.tl", actual = target(uri, 0, 24) })
    tested.assert({ given = "a package with init.tl", should = "open its init.tl", expected = "src/app/net/init.tl", actual = target(uri, 1, 23) })
end)

return tested
