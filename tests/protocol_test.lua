package.path = "./?.lua;" .. package.path

local tested = require("tested")
local cjson = require("cjson")
local LspClient = require("tests.helpers.lsp_client")
local position = require("teal_language_server.util.position")

local function has_label(items, label)
    for _, item in ipairs(items) do
        if item.label == label then
            return true
        end
    end
    return false
end

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

-- util.position unit tests -----------------------------------------------------

tested.test("position: ASCII columns are identical in bytes and UTF-16", function()
    tested.assert({ given = "ascii", should = "map byte 5 to unit 5", expected = 5, actual = position.byte_to_utf16("hello world", 5) })
    tested.assert({ given = "ascii", should = "map unit 5 to byte 5", expected = 5, actual = position.utf16_to_byte("hello world", 5) })
end)

tested.test("position: multi-byte BMP characters count as one UTF-16 unit", function()
    -- "é" is 2 bytes, "日" is 3 bytes; both are one UTF-16 unit
    local line = "aé日b"
    tested.assert({ given = "byte offset of b", should = "be UTF-16 column 3", expected = 3, actual = position.byte_to_utf16(line, 6) })
    tested.assert({ given = "UTF-16 column of b", should = "be byte offset 6", expected = 6, actual = position.utf16_to_byte(line, 3) })
end)

tested.test("position: astral characters count as two UTF-16 units", function()
    -- U+1F600 is 4 bytes in UTF-8 and a surrogate pair (2 units) in UTF-16
    local line = "x\240\159\152\128y"
    tested.assert({ given = "byte offset of y", should = "be UTF-16 column 3", expected = 3, actual = position.byte_to_utf16(line, 5) })
    tested.assert({ given = "UTF-16 column of y", should = "be byte offset 5", expected = 5, actual = position.utf16_to_byte(line, 3) })
    -- a column pointing between the two surrogates rounds down to the code point start
    tested.assert({ given = "column inside surrogate pair", should = "round down", expected = 1, actual = position.utf16_to_byte(line, 2) })
end)

tested.test("position: columns past the end of a line stay monotonic", function()
    tested.assert({ given = "byte past end", should = "extend by bytes", expected = 5, actual = position.byte_to_utf16("abc", 5) })
    tested.assert({ given = "unit past end", should = "clamp to line length", expected = 3, actual = position.utf16_to_byte("abc", 10) })
end)

-- protocol behavior ----------------------------------------------------------------

tested.test("completion with triggerKind Invoked (as sent by VS Code / Neovim) returns scope symbols", function()
    local uri = "file:///tmp/tls_proto_invoked.tl"
    client:open_document(uri, "local x = ma")
    client:wait_for_notification("textDocument/publishDiagnostics")

    local id = client:request("textDocument/completion", {
        textDocument = { uri = uri },
        position = { line = 0, character = 12 },
        context = { triggerKind = 1 },
    })
    local response = client:wait_for_response(id)
    local items = response.result and response.result.items or {}
    tested.assert({
        given = "Invoked completion after 'ma'",
        should = "include 'math'",
        expected = true,
        actual = has_label(items, "math"),
    })
end)

tested.test("completion never offers a '(none)' placeholder item", function()
    local uri = "file:///tmp/tls_proto_none.tl"
    client:open_document(uri, "local n = 1\nlocal _ = n.")
    client:wait_for_notification("textDocument/publishDiagnostics")

    local response = client:get_completions_triggered(uri, 1, 12, ".")
    local items = response.result and response.result.items or {}
    tested.assert({
        given = "completion on a number value",
        should = "not contain a placeholder item",
        expected = false,
        actual = has_label(items, "(none)"),
    })
end)

tested.test("unknown request methods get a MethodNotFound error instead of no response", function()
    local id = client:request("textDocument/nonexistentFeature", { textDocument = { uri = "file:///tmp/x.tl" } })
    local response = client:wait_for_response(id, 5000)
    tested.assert({
        given = "an unknown request",
        should = "respond with error code -32601",
        expected = -32601,
        actual = response.error and response.error.code or cjson.null,
    })
end)

tested.test("a request whose handler raises gets an InternalError response", function()
    -- hover without textDocument/position makes the handler fail
    local id = client:request("textDocument/hover", {})
    local response = client:wait_for_response(id, 5000)
    tested.assert({
        given = "a malformed hover request",
        should = "respond with error code -32603",
        expected = -32603,
        actual = response.error and response.error.code or cjson.null,
    })
end)

tested.test("diagnostic columns are reported in UTF-16 code units", function()
    local uri = "file:///tmp/tls_proto_utf16_diag.tl"
    -- 'é' is 2 bytes but 1 UTF-16 unit, so 'n' sits at byte 25 but UTF-16 column 24
    client:open_document(uri, 'local s = "héllo" local n: number = "x"\nprint(s, n)')
    local diags = client:wait_for_notification("textDocument/publishDiagnostics").diagnostics

    local found
    for _, d in ipairs(diags) do
        if d.message:find("in local declaration: n") then
            found = d
        end
    end
    tested.assert({ given = "type error diagnostic", should = "exist", expected = true, actual = found ~= nil })
    -- the error is reported at the value "x" which follows `local n: number = `
    local line = 'local s = "héllo" local n: number = "x"'
    local expected_col = position.byte_to_utf16(line, (line:find('"x"', 1, true)) - 1)
    tested.assert({ given = "diagnostic start", should = "be the UTF-16 column of the value", expected = expected_col, actual = found and found.range.start.character or -1 })
    tested.assert({ given = "computed UTF-16 column", should = "be 36 (byte 37)", expected = 36, actual = expected_col })
end)

tested.test("request positions in UTF-16 are mapped to the right identifier", function()
    local uri = "file:///tmp/tls_proto_utf16_hover.tl"
    -- '日本' is 6 bytes but 2 UTF-16 units; `num` inside print() is at UTF-16 column 35
    client:open_document(uri, 'local t = "日本" local num = 1 print(t, num)')
    client:wait_for_notification("textDocument/publishDiagnostics")

    local response = client:get_hover(uri, 0, 38)
    local value = response.result and response.result.contents and response.result.contents.value or ""
    tested.assert({
        given = "hover at UTF-16 column 38",
        should = "describe 'num'",
        expected = true,
        actual = value:find("num: integer", 1, true) ~= nil,
    })
    tested.assert({
        given = "hover range",
        should = "start at the identifier's UTF-16 column",
        expected = 38,
        actual = response.result and response.result.range.start.character or -1,
    })
end)

tested.test("invalid tlconfig.lua is reported via showMessage and the server keeps working", function()
    -- replace the default client with one rooted in a project with a broken config
    client:shutdown()

    local dir = os.tmpname()
    os.remove(dir)
    assert(require("lfs").mkdir(dir))
    local f = assert(io.open(dir .. "/tlconfig.lua", "w"))
    f:write('return { gen_target = "9.9" }')
    f:close()

    client = LspClient.new("teal-language-server")
    local init = client:initialize("file://" .. dir)
    tested.assert({ given = "initialize with bad config", should = "succeed", expected = true, actual = init.result ~= nil and init.result.capabilities ~= nil })

    local msg = client:wait_for_notification("window/showMessage", 5000)
    tested.assert({ given = "showMessage", should = "be an error", expected = 1, actual = msg.type })
    tested.assert({ given = "showMessage", should = "mention tlconfig.lua", expected = true, actual = msg.message:find("tlconfig.lua", 1, true) ~= nil })

    local uri = "file://" .. dir .. "/a.tl"
    client:open_document(uri, "local x: integer = 'no'\nprint(x)")
    local diags = client:wait_for_notification("textDocument/publishDiagnostics").diagnostics
    tested.assert({ given = "type error after bad config", should = "still be diagnosed", expected = true, actual = #diags > 0 })

    os.remove(dir .. "/tlconfig.lua")
    os.remove(dir)
end)

return tested
