-- Small JSON file persistence helper shared by componentmap.lua, routes.lua and the
-- setup wizards. Keeps every module that needs to save/load state off ad-hoc io.open calls.
local json = require("json")
local filesystem = require("filesystem")

local persist = {}

function persist.readJSON(path)
    if not filesystem.exists(path) then
        return nil
    end

    local file, err = io.open(path, "r")
    if not file then
        return nil, err
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return nil
    end

    local ok, decoded = pcall(json.decode, content)
    if not ok then
        return nil, decoded
    end

    return decoded
end

function persist.writeJSON(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and not filesystem.exists(dir) then
        filesystem.makeDirectory(dir)
    end

    local file, err = io.open(path, "w")
    if not file then
        return false, err
    end

    file:write(json.encode(data))
    file:close()

    return true
end

return persist
