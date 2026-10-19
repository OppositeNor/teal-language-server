local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local pcall = _tl_compat and _tl_compat.pcall or pcall; local _module_name = "handlers.handler_helper"

local DocumentManager = require("teal_language_server.analysis.document_manager")
local Document = require("teal_language_server.analysis.document")
local Uri = require("teal_language_server.util.uri")
local lsp = require("teal_language_server.lsp.protocol")
local references = require("teal_language_server.analysis.references")
local symbols = require("teal_language_server.analysis.symbols")
local ast_walk = require("teal_language_server.analysis.diagnostics.ast_walk")
local tl = require("tl")
local logging = require("teal_language_server.logging")

local logger = logging.get_logger(_module_name)

local handler_helper = {}



handler_helper.indexable_parent_types = {
   ["index"] = true,
   ["method_index"] = true,
   ["function_name"] = true,
}




function handler_helper.get_document(document_manager, params)
   local td = params.textDocument
   if not td then
      return nil
   end
   local doc = document_manager:get(Uri.parse(td.uri))
   if doc then
      doc:get_problems()
   end
   return doc
end




function handler_helper.byte_position(document_manager, params)
   local pos = params.position
   local doc = handler_helper.get_document(document_manager, params)
   if doc == nil then
      return lsp.position(pos.line, pos.character)
   end
   return doc:to_byte_position(pos)
end


function handler_helper.get_node_info(document_manager, params, pos)
   local doc = handler_helper.get_document(document_manager, params)

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


function handler_helper.load_symbols(document_manager, path)
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
   local errs = {}
   local ast = ast_walk.parse_program(tokens, errs, path)
   local ok, result = pcall(symbols.document_symbols, tokens, ast)
   return ok and result or {}
end


function handler_helper.view(doc)

   doc:get_problems()
   return {
      path = doc.uri.path,
      tokens = doc:get_tokens(),
      ast = doc:get_ast(),
      report = doc:get_type_report(),
      declaration_of = function(name, y, x)
         return doc:symbol_declaration_position(name, y, x)
      end,
      symbols = doc:get_symbols(),
   }
end

return handler_helper
