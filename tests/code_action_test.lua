package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")

local function lines(...)
    return table.concat({ ... }, "\n")
end

local function whole_doc()
    return { start = { line = 0, character = 0 }, ["end"] = { line = 1000, character = 0 } }
end

local function line_range(line)
    return { start = { line = line, character = 0 }, ["end"] = { line = line, character = 1000 } }
end

local function find_action(actions, title_pattern)
    for _, a in ipairs(actions or {}) do
        if a.title:find(title_pattern) then
            return a
        end
    end
end

local function titles(actions)
    local out = {}
    for _, a in ipairs(actions or {}) do
        table.insert(out, a.title)
    end
    return table.concat(out, " | ")
end

local function codes(diags)
    local out = {}
    for _, d in ipairs(diags) do
        table.insert(out, string.format("%d:%d %s", d.range.start.line, d.range.start.character, tostring(d.code)))
    end
    return table.concat(out, ", ")
end

local client
local version

-- opens `text`, returns the published diagnostics
local function open(uri, text)
    version = 1
    client:open_document(uri, text)
    return client:wait_for_notification("textDocument/publishDiagnostics").diagnostics
end

-- applies an action's edit to `text` through didChange; returns the new text and
-- the diagnostics published for it
local function apply(uri, text, action)
    local new_text = LspClient.apply_workspace_edit(text, uri, action.edit)
    version = version + 1
    client:change_document(uri, new_text, version)
    return new_text, client:wait_for_notification("textDocument/publishDiagnostics").diagnostics
end

tested.before(function()
    client = LspClient.new("teal-language-server")
    client:initialize(nil, { workspace = { workspaceEdit = { documentChanges = true } } })
end)

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
end)

tested.test("quick fix removes an unused import and leaves valid code", function()
    local uri = "file:///tmp/tls_ca_import.tl"
    local text = lines('local str = require("string")', "local x = 1", "print(x)")
    local diags = open(uri, text)
    tested.assert({ given = "unused import", should = "be diagnosed", expected = "0:6 tl/unused", actual = codes(diags) })

    local actions = client:get_code_actions(uri, line_range(0)).result
    local action = find_action(actions, "^Remove unused import 'str'")
    tested.assert({ given = "code actions on the import line", should = "offer Remove unused import", expected = true, actual = action ~= nil })
    tested.assert({ given = "remove import action", should = "be a preferred quickfix", expected = "quickfix true", actual = action and (action.kind .. " " .. tostring(action.isPreferred)) or "" })

    local new_text, new_diags = apply(uri, text, action)
    tested.assert({ given = "applied fix", should = "delete the whole line", expected = lines("local x = 1", "print(x)"), actual = new_text })
    tested.assert({ given = "fixed document", should = "have no diagnostics", expected = "", actual = codes(new_diags) })
end)

tested.test("suggestion prefixes an unused local with an underscore", function()
    local uri = "file:///tmp/tls_ca_prefix.tl"
    local text = lines("local function f()", "  local y = 2", "end", "f()")
    open(uri, text)
    local actions = client:get_code_actions(uri, line_range(1)).result
    local action = find_action(actions, "^Prefix 'y' with an underscore")
    tested.assert({ given = "unused local", should = "offer the prefix suggestion", expected = true, actual = action ~= nil })
    tested.assert({ given = "prefix suggestion", should = "not be preferred", expected = false, actual = action and action.isPreferred == true })
    local new_text, new_diags = apply(uri, text, action)
    tested.assert({ given = "applied suggestion", should = "rename to _y", expected = lines("local function f()", "  local _y = 2", "end", "f()"), actual = new_text })
    tested.assert({ given = "renamed local", should = "no longer be reported", expected = "", actual = codes(new_diags) })
end)

tested.test("disable-for-this-line inserts an indented directive that suppresses the problem", function()
    local uri = "file:///tmp/tls_ca_disable.tl"
    local text = lines("local a = 1", "if a then", "    a = a", "end")
    open(uri, text)
    local actions = client:get_code_actions(uri, line_range(2)).result
    local action = find_action(actions, "^Disable self%-assignment for this line")
    tested.assert({ given = "self-assignment", should = "offer disable action", expected = true, actual = action ~= nil })
    local new_text, new_diags = apply(uri, text, action)
    tested.assert({
        given = "applied disable action",
        should = "insert an indented directive above",
        expected = lines("local a = 1", "if a then", "    -- tls-disable-next-line self-assignment", "    a = a", "end"),
        actual = new_text,
    })
    tested.assert({ given = "suppressed document", should = "have no diagnostics", expected = "", actual = codes(new_diags) })
end)

tested.test("implicit-any suggestion annotates the parameter, on a line with multi-byte text", function()
    local uri = "file:///tmp/tls_ca_any.tl"
    local text = 'local s = "日本" local function f(x): integer print(x) return 1 end print(s, f(1))'
    open(uri, text)
    local actions = client:get_code_actions(uri, line_range(0)).result
    local action = find_action(actions, "^Annotate 'x'")
    tested.assert({ given = "implicit any parameter", should = "offer annotation", expected = true, actual = action ~= nil })
    local new_text, new_diags = apply(uri, text, action)
    tested.assert({ given = "applied suggestion", should = "insert ': any' after x", expected = 'local s = "日本" local function f(x: any): integer print(x) return 1 end print(s, f(1))', actual = new_text })
    tested.assert({ given = "annotated document", should = "have no diagnostics", expected = "", actual = codes(new_diags) })
end)

tested.test("fix-all applies every safe fix (including adjacent ones) but no suggestions", function()
    local uri = "file:///tmp/tls_ca_fixall.tl"
    local text = lines(
        'local str = require("string")',
        'local mth = require("math")',
        "local used = require('table')",
        "local a = 1",
        "a = a",
        "print(used, a)")
    open(uri, text)
    local actions = client:get_code_actions(uri, whole_doc(), { diagnostics = {}, only = { "source.fixAll" } }).result
    tested.assert({ given = "only = source.fixAll", should = "return just the fix-all action", expected = "Fix all auto-fixable problems", actual = titles(actions) })
    local new_text, new_diags = apply(uri, text, actions[1])
    tested.assert({
        given = "fix-all",
        should = "remove both unused imports and keep the self-assignment",
        expected = lines("local used = require('table')", "local a = 1", "a = a", "print(used, a)"),
        actual = new_text,
    })
    tested.assert({ given = "fixed document", should = "only report the self-assignment", expected = "2:0 self-assignment", actual = codes(new_diags) })
end)

tested.test("fix-all is not offered when nothing is fixable; only = quickfix excludes it", function()
    local uri = "file:///tmp/tls_ca_nofix.tl"
    local text = lines("local a = 1", "a = a", "print(a)")
    open(uri, text)
    local actions = client:get_code_actions(uri, whole_doc()).result
    tested.assert({ given = "no safe fixes", should = "not offer fix-all", expected = false, actual = find_action(actions, "^Fix all") ~= nil })
    actions = client:get_code_actions(uri, whole_doc(), { diagnostics = {}, only = { "quickfix" } }).result
    for _, a in ipairs(actions) do
        tested.assert({ given = "only = quickfix", should = "only return quickfixes", expected = "quickfix", actual = a.kind })
    end
end)

tested.test("edits are versioned with the current document version", function()
    local uri = "file:///tmp/tls_ca_version.tl"
    local text = lines('local str = require("string")', "print(1)")
    open(uri, text)
    version = 5
    client:change_document(uri, text, version)
    client:wait_for_notification("textDocument/publishDiagnostics")
    local action = find_action(client:get_code_actions(uri, line_range(0)).result, "^Remove unused import")
    local change = action and action.edit.documentChanges and action.edit.documentChanges[1]
    tested.assert({ given = "documentChanges capability", should = "carry version 5", expected = 5, actual = change and math.tointeger(change.textDocument.version) or -1 })
end)

tested.test("code actions on a document with syntax errors do not fail", function()
    local uri = "file:///tmp/tls_ca_broken.tl"
    open(uri, "local x = = 1")
    local response = client:get_code_actions(uri, whole_doc())
    tested.assert({ given = "broken document", should = "return a result, not an error", expected = true, actual = response.error == nil and response.result ~= nil })
end)

return tested
