-- Request latency benchmark over JSON-RPC.
--
--   lua scripts/bench_latency.lua [server-binary] [iterations]
--
-- Run from the repository root with the luarocks tree on LUA_PATH /
-- LUA_CPATH (see docs/engineering/performance-baseline.md). For each
-- synthetic document size it measures, through a real stdio server:
--
--   * open: didOpen until the first publishDiagnostics (cold check)
--   * completion after an edit that leaves the buffer unparsable (`p.`)
--   * completion after an edit that keeps the buffer valid
--   * hover and definition after a valid edit
--
-- Each timed request follows a didChange, so it includes the on-demand
-- re-analysis of the new text (what an editor sees while typing). The
-- server's resident memory is read from /proc at the end (Linux only).

package.path = "./?.lua;" .. package.path

local LspClient = require("tests.helpers.lsp_client")
local uv = require("luv")

local server = arg[1] or "teal-language-server"
local iterations = tonumber(arg[2]) or 30

-- A domain-neutral module: `n` records with fields and methods, functions
-- using them, and a final line `tail` that the benchmark edits.
local function make_doc(n, tail)
   local out = {}
   for i = 1, n do
      out[#out + 1] = ("local record R%d\n   a: integer\n   b: string\n   items: {R%d}\nend"):format(i, i)
      out[#out + 1] = ("function R%d:total(k: integer): integer\n   local s = self.a + k\n   for _, it in ipairs(self.items) do s = s + it.a end\n   return s\nend"):format(i, i)
      out[#out + 1] = ("local function make%d(): R%d return { a = %d, b = \"x\", items = {} } end"):format(i, i, i)
   end
   out[#out + 1] = ("local p = make%d()"):format(n)
   out[#out + 1] = tail
   return table.concat(out, "\n")
end

local function line_count(text)
   return select(2, text:gsub("\n", "")) + 1
end

local function percentile(samples, p)
   local sorted = {}
   for i, v in ipairs(samples) do sorted[i] = v end
   table.sort(sorted)
   local idx = math.max(1, math.ceil(#sorted * p))
   return sorted[idx]
end

local function now_ms()
   return uv.hrtime() / 1e6
end

local function rss_kb(pid)
   local f = io.open("/proc/" .. tostring(pid) .. "/status", "r")
   if not f then return nil end
   local text = f:read("*a")
   f:close()
   return tonumber(text:match("VmRSS:%s*(%d+)"))
end

local function bench(n)
   -- without --coverage: luacov instrumentation dominates the timings
   local client = LspClient.new(server, {})
   client:initialize()
   local uri = "file:///tmp/tls_bench_" .. n .. ".tl"
   local valid = make_doc(n, "local _ = p.a")
   local last = line_count(valid) - 1

   local t0 = now_ms()
   client:open_document(uri, valid)
   client:wait_for_notification("textDocument/publishDiagnostics", 120000)
   local open_ms = now_ms() - t0

   local version = 1
   local function timed(text, method, params)
      version = version + 1
      client:change_document(uri, text, version)
      local start = now_ms()
      local id = client:request(method, params)
      client:wait_for_response(id, 120000)
      return now_ms() - start
   end

   local results = { broken = {}, valid = {}, hover = {}, definition = {} }
   for i = 1, iterations do
      -- alternate the text so that every request sees a new version
      local broken = make_doc(n, "local _ = p." .. ("\n"):rep(i % 2))
      table.insert(results.broken, timed(broken, "textDocument/completion", {
         textDocument = { uri = uri }, position = { line = last, character = 12 },
         context = { triggerKind = 2, triggerCharacter = "." },
      }))
      local ok = make_doc(n, "local _ = p.a" .. ("\n"):rep(i % 2))
      table.insert(results.valid, timed(ok, "textDocument/completion", {
         textDocument = { uri = uri }, position = { line = last, character = 12 },
         context = { triggerKind = 2, triggerCharacter = "." },
      }))
      ok = make_doc(n, "local _ = p.a" .. (" "):rep(i % 2))
      table.insert(results.hover, timed(ok, "textDocument/hover", {
         textDocument = { uri = uri }, position = { line = last, character = 10 },
      }))
      ok = make_doc(n, "local _ = p.a" .. (" "):rep((i + 1) % 2))
      table.insert(results.definition, timed(ok, "textDocument/definition", {
         textDocument = { uri = uri }, position = { line = last, character = 10 },
      }))
   end
   local rss = rss_kb(client._pid)
   client:shutdown()

   print(("| %5d | %8.1f | %s | %s | %s | %s | %s |"):format(
      line_count(valid), open_ms,
      ("%.1f / %.1f"):format(percentile(results.broken, 0.5), percentile(results.broken, 0.95)),
      ("%.1f / %.1f"):format(percentile(results.valid, 0.5), percentile(results.valid, 0.95)),
      ("%.1f / %.1f"):format(percentile(results.hover, 0.5), percentile(results.hover, 0.95)),
      ("%.1f / %.1f"):format(percentile(results.definition, 0.5), percentile(results.definition, 0.95)),
      rss and ("%d"):format(rss // 1024) or "?"))
end

-- References of a record field used in `n` closed files of a workspace: the
-- first request type checks the candidate files (cold), the next ones reuse
-- them (warm).
local function bench_workspace(n)
   local project = require("tests.helpers.project")
   local files = {
      ["lib.tl"] = "local record Item\n   weight: number\nend\nlocal M = { Item = Item }\nfunction M.make(): Item return { weight = 1 } end\nreturn M\n",
   }
   for i = 1, n do
      local body = { 'local lib = require("lib")' }
      for j = 1, 20 do
         body[#body + 1] = ("local it%d = lib.make()\nlocal w%d = it%d.weight + %d"):format(j, j, j, i)
      end
      files[("user%03d.tl"):format(i)] = table.concat(body, "\n") .. "\n"
   end
   files["main.tl"] = 'local lib = require("lib")\nlocal it = lib.make()\nprint(it.weight)\n'
   local dir = project.create(files)
   local client = LspClient.new(server, {})
   client:initialize("file://" .. dir)
   local uri = "file://" .. dir .. "/main.tl"
   client:open_document(uri, files["main.tl"])
   client:wait_for_notification("textDocument/publishDiagnostics", 120000)
   local samples = {}
   local count = 0
   for i = 1, 6 do
      local start = now_ms()
      local r = client:wait_for_response(client:request("textDocument/references", {
         textDocument = { uri = uri }, position = { line = 2, character = 9 },
         context = { includeDeclaration = true },
      }), 120000)
      samples[i] = now_ms() - start
      count = type(r.result) == "table" and #r.result or -1
   end
   local warm = {}
   for i = 2, #samples do warm[#warm + 1] = samples[i] end
   local rss = rss_kb(client._pid)
   client:shutdown()
   project.remove(dir)
   print(("| %4d | %6d | %8.1f | %s | %s |"):format(n, count, samples[1],
      ("%.1f / %.1f"):format(percentile(warm, 0.5), percentile(warm, 0.95)), rss and ("%d"):format(rss // 1024) or "?"))
end

-- An unsaved edit to an open module with one open importer, while `k`
-- unrelated documents are open: time from didChange until the server has
-- rebuilt the env and re-checked what it re-checks (measured by polling
-- teal/serverStats, which is answered once that work is done).
local function bench_module_edit(k)
   local project = require("tests.helpers.project")
   local files = {
      ["m.tl"] = "local M = {}\nM.v = 1\nreturn M\n",
      ["user.tl"] = 'local m = require("m")\nlocal n: integer = m.v\nprint(n)\n',
   }
   local open = { "m.tl", "user.tl" }
   for i = 1, k do
      local name = ("doc%02d.tl"):format(i)
      files[name] = make_doc(30, "print(p)")
      table.insert(open, name)
   end
   local dir = project.create(files)
   local client = LspClient.new(server, {})
   client:initialize("file://" .. dir)
   for _, name in ipairs(open) do
      client:open_document("file://" .. dir .. "/" .. name, files[name])
      client:wait_for_notification("textDocument/publishDiagnostics", 120000)
   end
   local function stats()
      return client:wait_for_response(client:request("teal/serverStats", {}), 120000).result
   end
   local samples = {}
   for i = 1, 5 do
      local before = stats().envRebuilds
      local start = now_ms()
      client:change_document("file://" .. dir .. "/m.tl", ("local M = {}\nM.v = %d\nreturn M\n"):format(i + 1), i + 1)
      while stats().envRebuilds <= before do
         local t = uv.new_timer()
         local done = false
         uv.timer_start(t, 5, 0, function() done = true end)
         while not done do uv.run("once") end
         uv.close(t)
      end
      samples[i] = now_ms() - start
   end
   client:shutdown()
   project.remove(dir)
   print(("| %3d | %s |"):format(k, ("%.1f / %.1f"):format(percentile(samples, 0.5), percentile(samples, 1.0))))
end

print(("server: %s, %d iterations per size; latencies in ms (P50 / P95)"):format(server, iterations))
print("| lines | open (ms) | completion, broken buffer | completion, valid buffer | hover | definition | RSS (MB) |")
print("|---|---|---|---|---|---|---|")
for _, n in ipairs({ 10, 100, 500 }) do
   bench(n)
end

print()
print("references of a record field used in closed workspace files (1 cold request, then 5 warm)")
print("| closed files | locations | cold (ms) | warm P50 / P95 (ms) | RSS (MB) |")
print("|---|---|---|---|---|")
for _, n in ipairs({ 10, 50, 150 }) do
   bench_workspace(n)
end

print()
print("unsaved edit to an open module (1 open importer) until the env rebuild is done; includes the 150 ms diagnostics debounce and the 100 ms rebuild debounce")
print("| unrelated open documents (331 lines each) | P50 / max of 5 (ms) |")
print("|---|---|")
for _, k in ipairs({ 5, 20 }) do
   bench_module_edit(k)
end
