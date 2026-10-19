local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = pcall(require, 'compat53.module'); if p then _tl_compat = m end end; local io = _tl_compat and _tl_compat.io or io; local string = _tl_compat and _tl_compat.string or string; local table = _tl_compat and _tl_compat.table or table











local position = {}




local function sequence_info(b)
   if b < 0x80 then
      return 1, 1
   elseif b >= 0xF0 and b < 0xF8 then
      return 4, 2
   elseif b >= 0xE0 then
      return 3, 1
   elseif b >= 0xC0 then
      return 2, 1
   end

   return 1, 1
end




function position.byte_to_utf16(line, byte_col)
   if byte_col <= 0 then
      return 0
   end
   local len = #line
   local i = 1
   local units = 0
   while i <= byte_col and i <= len do
      local size, width = sequence_info(line:byte(i))
      if i + size - 1 > byte_col then

         break
      end
      i = i + size
      units = units + width
   end
   if byte_col > len then
      units = units + (byte_col - len)
   end
   return units
end




function position.utf16_to_byte(line, utf16_col)
   if utf16_col <= 0 then
      return 0
   end
   local len = #line
   local i = 1
   local units = 0
   while i <= len do
      local size, width = sequence_info(line:byte(i))
      if units + width > utf16_col then
         break
      end
      units = units + width
      i = i + size
   end
   if i - 1 > len then
      return len
   end
   return i - 1
end



function position.split_lines(text)
   local lines = {}
   local start = 1
   while true do
      local nl = text:find("\n", start, true)
      if not nl then
         table.insert(lines, text:sub(start))
         break
      end
      table.insert(lines, text:sub(start, nl - 1))
      start = nl + 1
   end
   return lines
end




function position.read_file_line(path, line)
   local fd = io.open(path, "rb")
   if not fd then
      return ""
   end
   local n = 0
   for l in fd:lines() do
      if n == line then
         fd:close()
         return l
      end
      n = n + 1
   end
   fd:close()
   return ""
end

return position
