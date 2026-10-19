local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local ipairs = _tl_compat and _tl_compat.ipairs or ipairs; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table; local _module_name = "handlers.code_actions"









local handler_helper = require("teal_language_server.handlers.handler_helper")
local DocumentManager = require("teal_language_server.analysis.document_manager")
local Document = require("teal_language_server.analysis.document")
local ServerState = require("teal_language_server.server_state")
local LspReaderWriter = require("teal_language_server.lsp.reader_writer")
local LspEventsManager = require("teal_language_server.lsp.events_manager")
local problem = require("teal_language_server.analysis.diagnostics.problem")
local Uri = require("teal_language_server.util.uri")
local lsp = require("teal_language_server.lsp.protocol")
local logging = require("teal_language_server.logging")
local class = require("teal_language_server.util.class")
local json = require("cjson")

local logger = logging.get_logger(_module_name)

local FIX_ALL_KIND = "source.fixAll.teal"

local CodeActionHandlers = {}








function CodeActionHandlers:__init(lsp_events_manager, lsp_reader_writer, server_state, document_manager)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
end

local function pos_le(a, b)
   return a.line < b.line or (a.line == b.line and a.character <= b.character)
end

local function ranges_touch(a, b)
   return pos_le(a.start, b["end"]) and pos_le(b.start, a["end"])
end

function CodeActionHandlers:_workspace_edit(doc, edits)
   local lsp_edits = {}
   for _, e in ipairs(edits) do
      table.insert(lsp_edits, {
         range = doc:to_lsp_range(e.y, e.x, e.yend, e.xend),
         newText = e.text,
      })
   end
   local uri = Uri.tostring(doc.uri)
   if self._server_state:client_capability("workspace", "workspaceEdit", "documentChanges") then
      return {
         documentChanges = {
            {
               textDocument = { uri = uri, version = doc.version },
               edits = lsp_edits,
            },
         },
      }
   end
   return { changes = { [uri] = lsp_edits } }
end


local function kind_requested(only, kind)
   if only == nil then
      return true
   end
   for _, o in ipairs(only) do
      if kind == o or kind:sub(1, #o + 1) == o .. "." then
         return true
      end
   end
   return false
end

function CodeActionHandlers:_on_code_action(params, id)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local range = params.range
   local context = (params.context or {})
   local only = context.only

   local actions = {}
   local problems = doc:get_problems()

   if kind_requested(only, "quickfix") then
      for _, p in ipairs(problems) do
         local diag = doc:problem_to_diagnostic(p)
         if range == nil or ranges_touch(diag.range, range) then
            local diagnostics = { diag }
            if p.fix then
               table.insert(actions, {
                  title = p.fix.title,
                  kind = "quickfix",
                  diagnostics = diagnostics,
                  isPreferred = true,
                  edit = self:_workspace_edit(doc, p.fix.edits),
               })
            end
            for _, s in ipairs(p.suggestions or {}) do
               table.insert(actions, {
                  title = s.title,
                  kind = "quickfix",
                  diagnostics = diagnostics,
                  edit = self:_workspace_edit(doc, s.edits),
               })
            end
            if p.rule_id ~= "tls/unused-directive" then
               local line = doc:get_line(p.y - 1)
               local indent = line:match("^[ \t]*")
               table.insert(actions, {
                  title = "Disable " .. p.rule_id .. " for this line",
                  kind = "quickfix",
                  diagnostics = diagnostics,
                  edit = self:_workspace_edit(doc, {
                     { y = p.y, x = 1, yend = p.y, xend = 1, text = indent .. "-- tls-disable-next-line " .. p.rule_id .. "\n" },
                  }),
               })
            end
         end
      end
   end

   if kind_requested(only, FIX_ALL_KIND) then
      local fixed = doc:compute_fix_all()
      if fixed then

         local _, newlines = doc.content:gsub("\n", "")
         local last_line = doc:get_line(newlines)
         table.insert(actions, {
            title = "Fix all auto-fixable problems",
            kind = FIX_ALL_KIND,
            edit = self:_workspace_edit(doc, {
               { y = 1, x = 1, yend = newlines + 1, xend = #last_line + 1, text = fixed },
            }),
         })
      end
   end

   logger:debug("Returning %d code actions", #actions)
   setmetatable(actions, json.empty_array_mt)
   self._lsp_reader_writer:send_rpc(id, actions)
end

function CodeActionHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/codeAction", function(params, id) self:_on_code_action(params, id) end)
end

class.setup(CodeActionHandlers, "CodeActionHandlers", {})

return CodeActionHandlers
