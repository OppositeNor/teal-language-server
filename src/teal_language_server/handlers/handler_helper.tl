local _module_name = "handlers.handler_helper"

local DocumentManager <const> = require("teal_language_server.analysis.document_manager")
local Document <const> = require("teal_language_server.analysis.document")
local Uri <const> = require("teal_language_server.util.uri")
local lsp <const> = require("teal_language_server.lsp.protocol")
local references <const> = require("teal_language_server.analysis.references")
local symbols <const> = require("teal_language_server.analysis.symbols")
local ast_walk <const> = require("teal_language_server.analysis.diagnostics.ast_walk")
local tl <const> = require("tl")
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

-- Outline of a file: from its open document, else parsed from disk.
function handler_helper.load_symbols(document_manager: DocumentManager, path: string): {symbols.Symbol}
   local doc = document_manager:get(Uri.uri_from_path(path))
   if doc then
      return doc:get_symbols()
   end
   local fd = io.open(path, "rb")
   if not fd then
      return {}
   end
   local text = fd:read("*a")
   fd:close()
   local tokens = tl.lex(text, path)
   local errs: {tl.Error} = {}
   local ast = ast_walk.parse_program(tokens, errs, path)
   local ok, result = pcall(symbols.document_symbols, tokens, ast as ast_walk.AstNode)
   return ok and result as {symbols.Symbol} or {}
end

-- What the symbol resolver (analysis/references) needs from a document.
function handler_helper.view(doc: Document): references.View
   -- make sure the document has been type checked so its by_pos data is current
   doc:get_problems()
   return {
      path = doc.uri.path,
      tokens = doc:get_tokens(),
      ast = doc:get_ast() as ast_walk.AstNode,
      report = doc:get_type_report(),
      declaration_of = function(name: string, y: integer, x: integer): integer, integer
         return doc:symbol_declaration_position(name, y, x)
      end,
      get_symbols = function(): {symbols.Symbol}
         return doc:get_symbols()
      end,
   }
end

return handler_helper
