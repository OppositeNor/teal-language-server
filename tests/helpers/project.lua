-- Creates throwaway project directories for tests that need a workspace root
-- (tlconfig.lua, multiple modules, ...).

local lfs = require("lfs")

local project = {}

local function mkdir_p(path)
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        if not lfs.attributes(acc) then
            assert(lfs.mkdir(acc))
        end
    end
end

-- `files` maps relative paths to contents. Returns the absolute directory path.
function project.create(files)
    local dir = os.tmpname()
    os.remove(dir)
    assert(lfs.mkdir(dir))
    for rel, content in pairs(files or {}) do
        local full = dir .. "/" .. rel
        local parent = full:match("^(.*)/[^/]+$")
        mkdir_p(parent)
        local f = assert(io.open(full, "w"))
        f:write(content)
        f:close()
    end
    return dir
end

function project.write(dir, rel, content)
    local f = assert(io.open(dir .. "/" .. rel, "w"))
    f:write(content)
    f:close()
end

function project.read(dir, rel)
    local f = assert(io.open(dir .. "/" .. rel, "r"))
    local content = f:read("*a")
    f:close()
    return content
end

function project.remove(dir)
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. "/" .. entry
            if lfs.attributes(full, "mode") == "directory" then
                project.remove(full)
            else
                os.remove(full)
            end
        end
    end
    lfs.rmdir(dir)
end

return project
