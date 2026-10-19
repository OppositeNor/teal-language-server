local _module_name = "handlers.code_actions"

-- textDocument/codeAction: quick fixes and suggestions attached to problems,
-- "disable rule for this line", and a fix-all source action.
--
-- Edits are always computed from the document's current text. When the client
-- supports versioned edits (workspace.workspaceEdit.documentChanges) the edit
-- carries the document version, so a client whose buffer has moved on rejects
-- it instead of applying it to the wrong text.

local handler_helper <const> = require("teal_language_server.handlers.handler_helper")
local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local Document <const> = require("teal_language_server.analysis.document")
local ServerState <const> = require("teal_language_server.server_state")
local LspReaderWriter <const> = require("teal_language_server.lsp.reader_writer")
local LspEventsManager <const> = require("teal_language_server.lsp.events_manager")
local problem <const> = require("teal_language_server.analysis.diagnostics.problem")
local Uri <const> = require("teal_language_server.util.uri")
local lsp <const> = require("teal_language_server.lsp.protocol")
local logging <const> = require("teal_language_server.logging")
local class <const> = require("teal_language_server.util.class")
local json <const> = require("cjson")

local logger = logging.get_logger(_module_name)

local FIX_ALL_KIND <const> = "source.fixAll.teal"

local record CodeActionHandlers
   _document_manager: DocumentManager
   _server_state: ServerState
   _lsp_reader_writer: LspReaderWriter
   _lsp_events_manager: LspEventsManager

   metamethod __call: function(self: CodeActionHandlers, lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager): CodeActionHandlers
end

function CodeActionHandlers:__init(lsp_events_manager: LspEventsManager, lsp_reader_writer: LspReaderWriter, server_state: ServerState, document_manager: DocumentManager)
   self._lsp_events_manager = lsp_events_manager
   self._lsp_reader_writer = lsp_reader_writer
   self._server_state = server_state
   self._document_manager = document_manager
end

local function pos_le(a: lsp.Position, b: lsp.Position): boolean
   return a.line < b.line or (a.line == b.line and a.character <= b.character)
end

local function ranges_touch(a: lsp.Range, b: lsp.Range): boolean
   return pos_le(a.start, b["end"]) and pos_le(b.start, a["end"])
end

function CodeActionHandlers:_workspace_edit(doc: Document, edits: {problem.TextEdit}): {string:any}
   local lsp_edits: {{string:any}} = {}
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

-- Whether an action of `kind` was requested by `only` (a hierarchical prefix match).
local function kind_requested(only: {string}, kind: string): boolean
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

function CodeActionHandlers:_on_code_action(params: lsp.Method.Params, id: integer)
   local doc = handler_helper.get_document(self._document_manager, params)
   if doc == nil then
      self._lsp_reader_writer:send_rpc(id, nil)
      return
   end

   local range = params.range as lsp.Range
   local context = (params.context or {}) as {string:any}
   local only = context.only as {string}

   local actions: {{string:any}} = {}
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
         -- replace the whole document: from the start to the end of the last line
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
   setmetatable(actions, json.empty_array_mt as metatable<{{string:any}}>)
   self._lsp_reader_writer:send_rpc(id, actions as {string:any})
end

function CodeActionHandlers:initialize()
   self._lsp_events_manager:set_handler("textDocument/codeAction", function(params: lsp.Method.Params, id: integer) self:_on_code_action(params, id) end)
end

class.setup(CodeActionHandlers, "CodeActionHandlers", {})

return CodeActionHandlers
