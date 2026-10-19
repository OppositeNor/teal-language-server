package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")

local function find(diags, code)
    for _, d in ipairs(diags) do
        if d.code == code then
            return d
        end
    end
end

local function codes(diags)
    local out = {}
    for _, d in ipairs(diags) do
        table.insert(out, string.format("%d:%d %s", d.range.start.line, d.range.start.character, tostring(d.code)))
    end
    return table.concat(out, ", ")
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

tested.test("diagnostics carry source, rule code, Unnecessary tags, and are ordered by position", function()
    local uri = "file:///tmp/tls_diag_codes.tl"
    client:open_document(uri, table.concat({
        "local unused = 1",
        "local n: integer = 'x'",
        "for i = 1, 2 do",
        "  break",
        "  print(i, n)",
        "end",
    }, "\n"))
    local diags = client:wait_for_notification("textDocument/publishDiagnostics").diagnostics

    tested.assert({
        given = "a document with three kinds of problems",
        should = "report them in position order with codes",
        expected = "0:6 tl/unused, 1:19 tl/type-error, 4:2 unreachable-code",
        actual = codes(diags),
    })
    for _, d in ipairs(diags) do
        tested.assert({ given = "diagnostic " .. d.code, should = "have source 'teal'", expected = "teal", actual = d.source })
    end
    local unused = find(diags, "tl/unused")
    tested.assert({ given = "unused variable", should = "be tagged Unnecessary (1)", expected = 1, actual = unused and unused.tags and unused.tags[1] or -1 })
    local unreachable = find(diags, "unreachable-code")
    tested.assert({ given = "unreachable code", should = "be a warning tagged Unnecessary", expected = "2 1", actual = unreachable and string.format("%d %d", unreachable.severity, unreachable.tags[1]) or "" })
    tested.assert({ given = "unreachable range", should = "end after print(i, n)", expected = "4:13", actual = unreachable and string.format("%d:%d", unreachable.range["end"].line, unreachable.range["end"].character) or "" })
end)

tested.test("suppression comments hide diagnostics through the LSP", function()
    local uri = "file:///tmp/tls_diag_directive.tl"
    client:open_document(uri, table.concat({
        "-- tls-disable-next-line tl/unused",
        "local unused = 1",
        "local a = 1",
        "a = a -- tls-disable-line self-assignment",
        "print(a)",
    }, "\n"))
    local diags = client:wait_for_notification("textDocument/publishDiagnostics").diagnostics
    tested.assert({ given = "suppressed problems", should = "publish nothing", expected = "", actual = codes(diags) })
end)

tested.test("rule diagnostics use UTF-16 ranges", function()
    local uri = "file:///tmp/tls_diag_utf16.tl"
    client:open_document(uri, 'local s = "日本" local a = 1\n' .. 'print(s) a = a print(a)')
    local diags = client:wait_for_notification("textDocument/publishDiagnostics").diagnostics
    local d = find(diags, "self-assignment")
    tested.assert({ given = "self-assignment on an ASCII line", should = "start at column 9", expected = 9, actual = d and d.range.start.character or -1 })

    client:change_document(uri, 'local s = "日本" local a = 1 a = a\nprint(s, a)', 2)
    diags = client:wait_for_notification("textDocument/publishDiagnostics").diagnostics
    d = find(diags, "self-assignment")
    tested.assert({ given = "self-assignment after multi-byte text", should = "start at UTF-16 column 27 (byte 31)", expected = "27-32", actual = d and string.format("%d-%d", d.range.start.character, d.range["end"].character) or "" })
end)

tested.test("published diagnostics carry the document version", function()
    local uri = "file:///tmp/tls_diag_version.tl"
    client:open_document(uri, "local x = 1\nprint(x)")
    local first = client:wait_for_notification("textDocument/publishDiagnostics")
    client:change_document(uri, "local x = 2\nprint(x)", 7)
    local second = client:wait_for_notification("textDocument/publishDiagnostics")
    tested.assert({ given = "versions", should = "be 1 then 7", expected = "1 7", actual = string.format("%d %d", first.version, second.version) })
end)

tested.test("tlconfig.lua rule settings: off, severity, tl warning kinds, and invalid entries", function()
    client:shutdown()
    local dir = project.create({
        ["tlconfig.lua"] = [[
return {
   externals = {
      teal_language_server = {
         rules = {
            ["unreachable-code"] = "off",
            ["self-assignment"] = "error",
            ["tl/unused"] = "off",
            ["no-such-rule"] = "warn",
         },
      },
   },
}
]],
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)

    local msg = client:wait_for_notification("window/showMessage", 5000)
    tested.assert({ given = "unknown rule in config", should = "produce a warning message", expected = true, actual = msg.type == 2 and msg.message:find("no-such-rule", 1, true) ~= nil })

    local uri = "file://" .. dir .. "/main.tl"
    client:open_document(uri, table.concat({
        "local unused = 1",
        "local a = 1",
        "a = a",
        "for i = 1, 2 do",
        "  break",
        "  print(i, a)",
        "end",
    }, "\n"))
    local diags = client:wait_for_notification("textDocument/publishDiagnostics").diagnostics
    tested.assert({ given = "configured rules", should = "only report self-assignment", expected = "2:0 self-assignment", actual = codes(diags) })
    tested.assert({ given = "self-assignment = error", should = "be severity 1", expected = 1, actual = diags[1] and diags[1].severity or -1 })
    project.remove(dir)
end)

return tested
