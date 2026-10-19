package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local project = require("tests.helpers.project")
local uv = require("luv")

local function has_label(items, label)
    for _, item in ipairs(items or {}) do
        if item.label == label then
            return true
        end
    end
    return false
end

local client

local function stats()
    return client:wait_for_response(client:request("teal/serverStats", {})).result
end

local function sleep_ms(ms)
    local done = false
    local timer = uv.new_timer()
    uv.timer_start(timer, ms, 0, function() done = true end)
    while not done do
        uv.run("once")
    end
    uv.close(timer)
end

local function record_doc(field_count)
    local fields = {}
    for i = 1, field_count do
        fields[#fields + 1] = "   f" .. i .. ": integer"
    end
    return "local record R\n" .. table.concat(fields, "\n") .. "\nend\nlocal r: R = { f1 = 1 }\nprint(r.f1)\n"
end

tested.after(function()
    if client then
        client:shutdown()
        client = nil
    end
end)

tested.test("type report growth from repeated edits is bounded by an env rebuild", function()
    local dir = project.create({
        ["tlconfig.lua"] = "return { externals = { teal_language_server = { type_report_limit = 30 } } }",
    })
    client = LspClient.new("teal-language-server")
    client:initialize("file://" .. dir)

    local text = record_doc(10)
    local uri = "file://" .. dir .. "/main.tl"
    client:open_document(uri, text)
    client:wait_for_notification("textDocument/publishDiagnostics")
    local before = stats()

    -- each edit + hover forces a re-check, which adds entries to the type report
    for v = 2, 41 do
        client:change_document(uri, text .. "-- edit " .. v, v)
        client:get_hover(uri, 12, 6)
    end

    local after
    for _ = 1, 30 do
        after = stats()
        if after.envRebuilds >= 1 then break end
        sleep_ms(100)
    end
    tested.assert({ given = "edits past type_report_limit", should = "trigger an env rebuild", expected = true, actual = after.envRebuilds >= 1 })
    tested.assert({ given = "after the rebuild", should = "keep growth within the limit", expected = true, actual = after.typeCount - after.typeBaseline <= 30 })
    tested.assert({ given = "after the rebuild", should = "reset loaded_order", expected = true, actual = after.loadedOrder < before.loadedOrder + 10 })

    -- the server still answers correctly after the rebuild
    local hover = client:get_hover(uri, 12, 6)
    local value = hover.result and hover.result.contents and hover.result.contents.value or ""
    tested.assert({ given = "hover after rebuild", should = "still resolve r to record R", expected = true, actual = value:find("record R", 1, true) ~= nil })
    project.remove(dir)
end)

tested.test("without a rebuild the type report keeps growing (the leak being bounded)", function()
    client = LspClient.new("teal-language-server")
    client:initialize()
    local text = record_doc(10)
    local uri = "file:///tmp/tls_perf_growth.tl"
    client:open_document(uri, text)
    client:wait_for_notification("textDocument/publishDiagnostics")
    local before = stats()
    for v = 2, 41 do
        client:change_document(uri, text .. "-- edit " .. v, v)
        client:get_hover(uri, 12, 6)
    end
    local after = stats()
    tested.assert({ given = "40 re-checks under the default limit", should = "grow the report without rebuilding", expected = "grew, 0 rebuilds", actual = (after.typeCount > before.typeCount + 40 and "grew" or "flat") .. ", " .. math.tointeger(after.envRebuilds) .. " rebuilds" })
end)

tested.test("a burst of edits publishes diagnostics once, for the latest version", function()
    client = LspClient.new("teal-language-server")
    client:initialize()
    local uri = "file:///tmp/tls_perf_burst.tl"
    client:open_document(uri, "local x = 1\nprint(x)")
    client:wait_for_notification("textDocument/publishDiagnostics")

    local batch = {}
    for v = 2, 21 do
        table.insert(batch, {
            method = "textDocument/didChange",
            params = { textDocument = { uri = uri, version = v }, contentChanges = { { text = "local x: integer = " .. (v == 21 and "'oops'" or tostring(v)) .. "\nprint(x)" } } },
        })
    end
    client:send_batch(batch)

    local n = client:wait_for_notification("textDocument/publishDiagnostics")
    tested.assert({ given = "20 rapid edits", should = "publish for version 21", expected = 21, actual = math.tointeger(n.version) })
    tested.assert({ given = "the final text", should = "be the one diagnosed", expected = 1, actual = #n.diagnostics })
    local extra_ok = pcall(client.wait_for_notification, client, "textDocument/publishDiagnostics", 500)
    tested.assert({ given = "superseded versions", should = "not be published", expected = false, actual = extra_ok })
end)

tested.test("requests right after an edit see the new text (no stale types)", function()
    client = LspClient.new("teal-language-server")
    client:initialize()
    local uri = "file:///tmp/tls_perf_fresh.tl"
    client:open_document(uri, "local record P\n   a: integer\nend\nlocal p: P = {}\nprint(p.a)")
    client:wait_for_notification("textDocument/publishDiagnostics")
    -- add a field and immediately ask for completion, before the debounced publish
    client:change_document(uri, "local record P\n   a: integer\n   fresh: integer\nend\nlocal p: P = {}\nprint(p.a)", 2)
    local r = client:get_completions_triggered(uri, 5, 8, ".")
    tested.assert({ given = "completion immediately after an edit", should = "include the new field", expected = true, actual = has_label(r.result and r.result.items, "fresh") })
end)

tested.test("$/cancelRequest cancels a request that has not been handled yet", function()
    client = LspClient.new("teal-language-server")
    client:initialize()
    local uri = "file:///tmp/tls_perf_cancel.tl"
    local big = { "local record Big" }
    for i = 1, 400 do big[#big + 1] = "   f" .. i .. ": integer" end
    big[#big + 1] = "end"
    for i = 1, 400 do big[#big + 1] = "local v" .. i .. ": Big = { f1 = " .. i .. " }\nprint(v" .. i .. ".f1)" end
    local text = table.concat(big, "\n")

    -- the open (slow type check), two requests and a cancellation for the first
    -- arrive together; the cancellation is read before the request is handled
    local ids = client:send_batch({
        { method = "textDocument/didOpen", params = { textDocument = { uri = uri, languageId = "teal", version = 1, text = text } } },
        { method = "textDocument/hover", request = true, params = { textDocument = { uri = uri }, position = { line = 402, character = 7 } } },
        { method = "textDocument/hover", request = true, params = { textDocument = { uri = uri }, position = { line = 402, character = 7 } } },
    })
    client:notify("$/cancelRequest", { id = ids[1] })

    local cancelled = client:wait_for_response(ids[1])
    local answered = client:wait_for_response(ids[2])
    tested.assert({ given = "the cancelled request", should = "fail with RequestCancelled (-32800)", expected = -32800, actual = cancelled.error and math.tointeger(cancelled.error.code) or 0 })
    tested.assert({ given = "the other request", should = "be answered normally", expected = true, actual = answered.error == nil and answered.result ~= nil })
end)

return tested
