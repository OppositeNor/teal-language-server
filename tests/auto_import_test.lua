package.path = "./?.lua;" .. package.path

-- Auto-import completion: workspace modules that are not required yet are
-- offered with an edit adding `local name = require("module")`.

local tested = require("tested")
local tl = require("tl")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")
local completion = require("teal_language_server.analysis.completion")

local function lines(...)
    return table.concat({ ... }, "\n")
end

tested.test("auto-import candidate selection and insertion point", function()
    local modules = {
        { name = "shapes", path = "/w/shapes.tl" },
        { name = "util.strings", path = "/w/util/strings.tl" },
        { name = "main", path = "/w/main.tl" },
        { name = "server", path = "/w/server.tl" },
        { name = "sockets", path = "/w/sockets.tl" },
        { name = "my-mod", path = "/w/my-mod.tl" },
    }
    local function labels(prefix, required, visible)
        local out = {}
        for _, c in ipairs(completion.auto_import_candidates(modules, "/w/main.tl", required or {}, visible or {}, prefix)) do
            table.insert(out, c.label .. "=" .. c.module)
        end
        return table.concat(out, " ")
    end
    tested.assert({ given = "prefix s", should = "offer the s modules by their last name component", expected = "shapes=shapes strings=util.strings server=server sockets=sockets", actual = labels("s") })
    tested.assert({ given = "an empty prefix", should = "offer nothing", expected = "", actual = labels("") })
    tested.assert({ given = "prefix m (the current file is main)", should = "not offer the current file", expected = "", actual = labels("m") })
    tested.assert({ given = "shapes already required", should = "not offer it", expected = false, actual = labels("s", { shapes = true }):find("shapes", 1, true) ~= nil })
    tested.assert({ given = "a visible local named server", should = "not offer the server module", expected = false, actual = labels("s", {}, { server = true }):find("server", 1, true) ~= nil })

    local function line_of(src) return completion.import_insertion_line(tl.lex(src, "x.tl")) end
    tested.assert({ given = "no requires", should = "insert before the first statement", expected = 1, actual = line_of("local x = 1\n") })
    tested.assert({ given = "a header comment", should = "insert after it", expected = 3, actual = line_of("-- header\n-- more\nlocal x = 1\n") })
    tested.assert({ given = "leading requires", should = "insert after the last one", expected = 3, actual = line_of('local a = require("a")\nlocal b = require "b".sub\nlocal x = 1\n') })
    tested.assert({ given = "a require that is not leading", should = "not count", expected = 1, actual = line_of('local x = 1\nlocal a = require("a")\n') })
end)

tested.test("auto-import through the server: the item and its require edit", function()
    local dir = project.create({
        ["shapes.tl"] = "local M = {}\nfunction M.new(): integer return 1 end\nreturn M\n",
        ["util/strings.tl"] = "local M = {}\nreturn M\n",
        ["main.tl"] = 'local other = require("util.strings")\nlocal x = sha\n',
    })
    local client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
    local uri = "file://" .. dir .. "/main.tl"
    local text = project.read(dir, "main.tl")
    client:open_document(uri, text)
    client:wait_for_notification("textDocument/publishDiagnostics")

    local r = client:get_completions(uri, 1, 13)
    local item
    for _, it in ipairs(r.result.items) do
        if it.label == "shapes" then item = it end
        tested.assert({ given = "util.strings, already required", should = "not be offered again", expected = false, actual = it.label == "strings" })
    end
    tested.assert({ given = "typing sha", should = "offer the shapes module", expected = true, actual = item ~= nil })
    tested.assert({ given = "the auto-import item", should = "be a Module", expected = 9, actual = item and math.tointeger(item.kind) })
    local edited = LspClient.apply_text_edits(text, item and item.additionalTextEdits or {})
    tested.assert({ given = "the additional edit", should = "add the require after the existing one", expected =
        'local other = require("util.strings")\nlocal shapes = require("shapes")\nlocal x = sha\n', actual = edited })

    -- once required, the module is a normal local and is not offered for import
    client:change_document(uri, 'local shapes = require("shapes")\nlocal x = sha\n', 2)
    r = client:get_completions(uri, 1, 13)
    local count = 0
    for _, it in ipairs(r.result.items) do
        if it.label == "shapes" then
            count = count + 1
            tested.assert({ given = "a required module", should = "have no import edit", expected = true, actual = it.additionalTextEdits == nil })
        end
    end
    tested.assert({ given = "a required module", should = "be offered once", expected = 1, actual = count })
    client:shutdown()
    project.remove(dir)
end)

return tested
