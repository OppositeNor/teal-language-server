local _module_name = "handlers.handler_helper"

local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local Document <const> = require("teal_language_server.analysis.document")
local Uri <const> = require("teal_language_server.util.uri")
local lsp <const> = require("teal_language_server.lsp.protocol")
local logging <const> = require("teal_language_server.logging")

local logger = logging.get_logger(_module_name)

local record handler_helper
   indexable_parent_types: {string:boolean}
end

handler_helper.indexable_parent_types = {
   ["index"] = true,
   ["method_index"] = true,
   ["function_name"] = true,
}

-- The request's document, analyzed against its current text. Diagnostics are
-- published with a delay after edits, but requests must never see stale type
-- information, so the (cached) analysis is brought up to date here.
function handler_helper.get_document(document_manager: DocumentManager, params: lsp.Method.Params): Document
   local td <const> = params.textDocument as lsp.TextDocument
   if not td then
      return nil
   end
   local doc = document_manager:get(Uri.parse(td.uri))
   if doc then
      doc:get_problems()
   end
   return doc
end

-- Returns the request's position converted from LSP UTF-16 columns into the
-- 0-based byte columns used by tree-sitter and the analysis code. The returned
-- table is a copy, so handlers may adjust it freely.
function handler_helper.byte_position(document_manager: DocumentManager, params: lsp.Method.Params): lsp.Position
   local pos <const> = params.position as lsp.Position
   local doc <const> = handler_helper.get_document(document_manager, params)
   if doc == nil then
      return lsp.position(pos.line, pos.character)
   end
   return doc:to_byte_position(pos)
end

-- `pos` must already be a byte position (see `byte_position`)
function handler_helper.get_node_info(document_manager: DocumentManager, params: lsp.Method.Params, pos: lsp.Position): Document.NodeInfo, Document
   local doc <const> = handler_helper.get_document(document_manager, params)

   if not doc then
      logger:warning("No doc found for request")
      return nil
   end

   if pos.character < 0 then
      return nil
   end

   logger:debug("Looking up node info at position: %s", pos)
   local node_info = doc:tree_sitter_token(pos.line, pos.character)
   if node_info == nil then
      logger:info("Unable to retrieve node info from tree-sitter parser")
      return nil
   end
   logger:debug("Found node info: %s", node_info)
   return node_info, doc
end

return handler_helper
