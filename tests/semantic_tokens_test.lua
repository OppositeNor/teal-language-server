package.path = "./?.lua;" .. package.path

local tested = require("tested")
local LspClient = require("tests.helpers.lsp_client")
local position = require("teal_language_server.util.position")
local cjson = require("cjson")

local client, initialization
local uri = "file:///tmp/tls_parameter_colors.tl"

tested.before(function()
    client = LspClient.new("teal-language-server")
    initialization = client:initialize()
end)

tested.after(function()
    if client then client:shutdown() end
end)

local function tokens()
    local id = client:request("textDocument/semanticTokens/full", { textDocument = { uri = uri } })
    local response = client:wait_for_response(id)
    assert(not response.error, cjson.encode(response.error))
    local data = response.result.data
    local out, line, column = {}, 0, 0
    for i = 1, #data, 5 do
        column = (data[i] == 0 and column or 0) + data[i + 1]
        line = line + data[i]
        assert(data[i + 3] == 0 and data[i + 4] == 0)
        out[#out + 1] = string.format("%d:%d:%d", line, column, data[i + 2])
    end
    return table.concat(out, ","), data
end

-- @ marks precisely the identifiers expected to receive parameter tokens.
local function check(marked)
    local lines, expected = {}, {}
    for line in (marked .. "\n"):gmatch("(.-)\n") do
        local clean = ""
        local cursor = 1
        while true do
            local first, last, name = line:find("@([%a_][%w_]*)", cursor)
            if not first then break end
            clean = clean .. line:sub(cursor, first - 1)
            expected[#expected + 1] = string.format("%d:%d:%d", #lines, position.byte_to_utf16(clean, #clean), #name)
            clean = clean .. name
            cursor = last + 1
        end
        lines[#lines + 1] = clean .. line:sub(cursor)
    end
    client:open_document(uri, table.concat(lines, "\n"))
    client:wait_for_notification("textDocument/publishDiagnostics")
    tested.assert({ given = "parameter declarations and uses", should = "match only marked identifiers", expected = table.concat(expected, ","), actual = (tokens()) })
end

tested.test("semantic tokens advertise a parameter legend and return empty data", function()
    local provider = initialization.result.capabilities.semanticTokensProvider
    tested.assert({ given = "server capabilities", should = "support full semantic tokens", expected = true, actual = provider and provider.full })
    tested.assert({ given = "legend", should = "contain parameter and an empty modifier array", expected = "parameter:0", actual = provider.legend.tokenTypes[1] .. ":" .. #provider.legend.tokenModifiers })
    check("local value = 1\nprint(value)")
    local _, data = tokens()
    tested.assert({ given = "no parameters", should = "return an empty token list", expected = 0, actual = #data })
end)

tested.test("parameter references in field access, assignments and constructors", function()
    check([=[local record Task
   edges: {Task}
end
local function append_edge(@producer: Task, @consumer: Task, @resource_handle: string)
   @producer.edges = @producer.edges or {}
   @producer.edges[#@producer.edges + 1] = @consumer
   local resource = { to = @consumer, resource = @resource_handle }
   @consumer = @producer
   print(resource)
end]=])
end)

tested.test("captured and callable parameters respect nested scopes and local initializers", function()
    check([=[local function outer(@value: number, @callback: function(number))
   local f = function(@other: number)
      @callback(@value + @other)
   end
   do
      local value = @value
      print(value)
   end
   local function inner(@value: string)
      print(@value)
   end
   print(@value)
   local value = @value
   print(value)
   f(1)
   inner("x")
end
local value = 3
print(value)]=])
end)

tested.test("method self, explicit self, varargs and UTF-16 positions", function()
    check([=[local record R
   value: number
end
function R:show(@value: number, ...: string)
   print(self.value, @value, ...)
end
local f = function(@self: R, @value: number)
   local text = "😀日本"; print(@self.value, @value)
end]=])
end)

tested.test("semantic tokens update after edits and tolerate unfinished code", function()
    check("local function f(@value: number) print(@value) end")
    client:change_document(uri, "local value = 1\nprint(value)", 2)
    client:wait_for_notification("textDocument/publishDiagnostics")
    tested.assert({ given = "an edit removing the parameter", should = "clear its tokens", expected = "", actual = (tokens()) })
    client:change_document(uri, "local function f(value: number)\nprint(value.\n", 3)
    client:wait_for_notification("textDocument/publishDiagnostics")
    local _, data = tokens()
    tested.assert({ given = "unfinished code", should = "return a valid token list", expected = 0, actual = #data % 5 })
end)

return tested
