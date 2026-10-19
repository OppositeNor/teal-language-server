package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")
local declarations = require("tests.helpers.declarations")

local function lines(...)
    return table.concat({ ... }, "\n")
end

local function has_label(items, label)
    for _, item in ipairs(items or {}) do
        if item.label == label then
            return true
        end
    end
    return false
end

local function messages(diags)
    local out = {}
    for _, d in ipairs(diags or {}) do
        table.insert(out, d.message)
    end
    return table.concat(out, " | ")
end

local client

-- waits for the next diagnostics published for `uri` (others are skipped)
local function diagnostics_for(uri)
    for _ = 1, 20 do
        local n = client:wait_for_notification("textDocument/publishDiagnostics")
        if n.uri == uri then
            return n.diagnostics
        end
    end
    error("no diagnostics for " .. uri)
end

-- waits until diagnostics for `uri` satisfy `pred` (an env rebuild publishes
-- for every open document, possibly more than once)
local function diagnostics_until(uri, pred)
    for _ = 1, 20 do
        local diags = diagnostics_for(uri)
        if pred(diags) then
            return diags, true
        end
    end
    return nil, false
end

local MOD_V1 = lines(
    "local record M",
    "   a: integer",
    "end",
    "local inst: M = { a = 1 }",
    "return inst")

local MOD_V2 = lines(
    "local record M",
    "   a: integer",
    "   b: integer",
    "end",
    "local inst: M = { a = 1, b = 2 }",
    "return inst")

local MAIN = lines(
    'local mod = require("mod")',
    "print(mod.a, mod.b)")

local dir

tested.before(function()
    dir = project.create({
        ["mod.tl"] = MOD_V1,
        ["main.tl"] = MAIN,
        ["shaders/blur.tl"] = lines("local record BlurPass", "   radius: number", "end", "return BlurPass"),
        ["shaders/init.tl"] = "return {}",
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)
end)

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
    project.remove(dir)
end)

tested.test("unsaved edits to an imported module are visible to its importers", function()
    local mod_uri, main_uri = "file://" .. dir .. "/mod.tl", "file://" .. dir .. "/main.tl"
    client:open_document(mod_uri, MOD_V1)
    diagnostics_for(mod_uri)
    client:open_document(main_uri, MAIN)
    local diags = diagnostics_for(main_uri)
    tested.assert({ given = "main.tl using mod.b before it exists", should = "report an error", expected = true, actual = messages(diags):find("'b'", 1, true) ~= nil })

    -- edit mod.tl in the editor without saving
    client:change_document(mod_uri, MOD_V2, 2)
    local _, cleared = diagnostics_until(main_uri, function(d) return #d == 0 end)
    tested.assert({ given = "unsaved edit adding field b", should = "clear main.tl's error", expected = true, actual = cleared })

    local response = client:get_completions_triggered(main_uri, 1, 17, ".")
    tested.assert({ given = "completion on mod. after the unsaved edit", should = "include b", expected = true, actual = has_label(response.result and response.result.items, "b") })

    -- closing the unsaved buffer reverts importers to the file on disk
    client:notify("textDocument/didClose", { textDocument = { uri = mod_uri } })
    local _, reverted = diagnostics_until(main_uri, function(d) return messages(d):find("'b'", 1, true) ~= nil end)
    tested.assert({ given = "closing mod.tl without saving", should = "bring back main.tl's error", expected = true, actual = reverted })
end)

tested.test("workspace/symbol finds symbols in files that are not open", function()
    local id = client:request("workspace/symbol", { query = "blurp" })
    local result = client:wait_for_response(id).result
    local first = result and result[1]
    tested.assert({ given = "query 'blurp'", should = "find BlurPass first", expected = "BlurPass", actual = first and first.name or "none" })
    tested.assert({ given = "BlurPass location", should = "be in shaders/blur.tl, line 0", expected = "shaders/blur.tl:0:13", actual = first and (first.location.uri:match("(shaders/[^/]+)$") .. string.format(":%d:%d", first.location.range.start.line, first.location.range.start.character)) or "" })

    id = client:request("workspace/symbol", { query = "radius" })
    result = client:wait_for_response(id).result
    tested.assert({ given = "query 'radius'", should = "find the field with its container", expected = "radius in BlurPass", actual = result[1] and (result[1].name .. " in " .. tostring(result[1].containerName)) or "none" })

    id = client:request("workspace/symbol", { query = "zzzqqq" })
    result = client:wait_for_response(id).result
    tested.assert({ given = "a query matching nothing", should = "return an empty list", expected = 0, actual = #result })
end)

tested.test("workspace/symbol sees new files and unsaved buffers", function()
    project.write(dir, "late.tl", "local function late_helper() end\nlate_helper()")
    local id = client:request("workspace/symbol", { query = "late_helper" })
    local result = client:wait_for_response(id).result
    tested.assert({ given = "a file created after startup", should = "be indexed", expected = "late_helper", actual = result[1] and result[1].name or "none" })

    local uri = "file://" .. dir .. "/late.tl"
    client:open_document(uri, "local function renamed_helper() end\nrenamed_helper()")
    diagnostics_for(uri)
    id = client:request("workspace/symbol", { query = "renamed_helper" })
    result = client:wait_for_response(id).result
    tested.assert({ given = "an unsaved buffer", should = "be indexed from the editor text", expected = "renamed_helper", actual = result[1] and result[1].name or "none" })
end)

tested.test("require(\"...\") completes workspace module names", function()
    local uri = "file://" .. dir .. "/main.tl"
    local text = 'local x = require("sh'
    client:open_document(uri, text)
    diagnostics_for(uri)
    local response = client:get_completions_triggered(uri, 0, #text, '"')
    local items = response.result and response.result.items or {}
    tested.assert({ given = "require completion", should = "offer shaders.blur", expected = true, actual = has_label(items, "shaders.blur") })
    tested.assert({ given = "require completion", should = "offer shaders (init.tl)", expected = true, actual = has_label(items, "shaders") })
    tested.assert({ given = "require completion", should = "offer mod", expected = true, actual = has_label(items, "mod") })
    local edit = items[1] and items[1].textEdit
    tested.assert({ given = "textEdit", should = "replace from after the quote to the cursor", expected = "19-21", actual = edit and string.format("%d-%d", edit.range.start.character, edit.range["end"].character) or "" })
end)

tested.test("declaration files (.d.tl): completion, signatures, diagnostics, navigation", function()
    client:shutdown()
    local root = project.create({
        ["tlconfig.lua"] = "return { include_dir = { \".\" } }",
        ["shapes.d.tl"] = declarations.SHAPES_DTL,
        ["main.tl"] = declarations.MAIN_TL,
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. root)

    local main_text = declarations.MAIN_TL
    local uri = "file://" .. root .. "/main.tl"
    client:open_document(uri, main_text)
    local diags = diagnostics_for(uri)
    tested.assert({ given = "main.tl using the declared API", should = "have no diagnostics", expected = "", actual = messages(diags) })

    -- line 4: canvas:draw(path, function(p: shapes.Path)
    local r = client:get_completions_triggered(uri, 4, 7, ":")
    local items = r.result and r.result.items or {}
    for _, m in ipairs({ "new_path", "draw", "flush" }) do
        tested.assert({ given = "canvas: completion", should = "include " .. m, expected = true, actual = has_label(items, m) })
    end

    -- line 5: p:move_to({ x = 0, y = 0 }):line_to({ x = 1, y = 1 })
    r = client:get_completions_triggered(uri, 5, 5, ":")
    items = r.result and r.result.items or {}
    for _, m in ipairs({ "move_to", "line_to", "close" }) do
        tested.assert({ given = "p: completion", should = "include " .. m, expected = true, actual = has_label(items, m) })
    end

    -- signature help inside canvas:new_path( on line 3
    local line3 = "local path = canvas:new_path("
    local sig = client:get_signature_help(uri, 3, #line3)
    local label = sig.result and sig.result.signatures and sig.result.signatures[1] and sig.result.signatures[1].label or ""
    tested.assert({ given = "new_path signature", should = "show parameter names and types", expected = true, actual = label:find("name: string", 1, true) ~= nil and label:find("style: Style", 1, true) ~= nil })

    -- go to definition of new_path lands in the declaration file
    local def = client:get_definition(uri, 3, 22)
    tested.assert({ given = "definition of new_path", should = "be in shapes.d.tl line 25", expected = "shapes.d.tl:25", actual = def.result and (def.result.uri:match("([^/]+)$") .. ":" .. math.tointeger(def.result.range.start.line)) or "none" })

    -- a wrong enum value is a type error
    client:change_document(uri, (main_text:gsub('"red"', '"purple"')), 2)
    diags = diagnostics_for(uri)
    tested.assert({ given = "color = \"purple\"", should = "be reported", expected = true, actual = messages(diags):find("purple", 1, true) ~= nil })
    project.remove(root)
end)

return tested
