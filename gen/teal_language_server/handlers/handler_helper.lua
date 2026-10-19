local _module_name = "handlers.handler_helper"

local DocumentManager = require("teal_language_server.analysis.document_manager")
local Document = require("teal_language_server.analysis.document")
local Uri = require("teal_language_server.util.uri")
local lsp = require("teal_language_server.lsp.protocol")
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

return handler_helper
