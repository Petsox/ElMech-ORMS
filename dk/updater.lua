-- Updater for the Dopravní kancelář role. See stavedlo/updater.lua's doc comment -- identical
-- mechanism, DK's (smaller) manifest.
local shell = require("shell")
local fs = require("filesystem")
local internet = require("internet")
local json = require("json")

local repoOwner = "Petsox"
local repoName = "ElMech-ORMS"
local branch = "master"
local repo = "https://raw.githubusercontent.com/" .. repoOwner .. "/" .. repoName .. "/" .. branch .. "/"
local installRoot = "/home/dk/"
local manifestPath = installRoot .. "data/update_manifest.json"

local files = {
    {src = "common/json.lua", dest = "json.lua"},
    {src = "common/persist.lua", dest = "persist.lua"},
    {src = "common/cli.lua", dest = "cli.lua"},
    {src = "common/layout.lua", dest = "layout.lua"},
    {src = "common/routes.lua", dest = "routes.lua"},
    {src = "common/componentmap.lua", dest = "componentmap.lua"},
    {src = "common/network.lua", dest = "network.lua"},
    {src = "common/lockboxdrv.lua", dest = "hw/lockboxdrv.lua"},
    {src = "common/grapes/Color.lua", dest = "grapes/Color.lua"},
    {src = "common/grapes/Event.lua", dest = "grapes/Event.lua"},
    {src = "common/grapes/Filesystem.lua", dest = "grapes/Filesystem.lua"},
    {src = "common/grapes/GUI.lua", dest = "grapes/GUI.lua"},
    {src = "common/grapes/Image.lua", dest = "grapes/Image.lua"},
    {src = "common/grapes/Keyboard.lua", dest = "grapes/Keyboard.lua"},
    {src = "common/grapes/Number.lua", dest = "grapes/Number.lua"},
    {src = "common/grapes/Paths.lua", dest = "grapes/Paths.lua"},
    {src = "common/grapes/Screen.lua", dest = "grapes/Screen.lua"},
    {src = "common/grapes/Text.lua", dest = "grapes/Text.lua"},
    {src = "dk/interlocking/routeselect.lua", dest = "interlocking/routeselect.lua"},
    {src = "dk/setup.lua", dest = "setup.lua"},
    {src = "dk/init.lua", dest = "init.lua"},
}

print("Are you sure you want to update DK?\nThis will NOT delete your component mapping or routes. (Y - Continue/N - Cancel)")
::Update::
local input = string.lower(io.read())
if input ~= "n" and input ~= "y" then
    print("Invalid choice (Y/N)")
    goto Update
end
if input == "n" then
    print("Update won't be installed")
    os.exit()
end

local function httpGet(url, headers)
    local ok, request = pcall(internet.request, url, nil, headers)
    if not ok then
        return nil, tostring(request)
    end
    local body = {}
    local readOk, err = pcall(function()
        for chunk in request do
            body[#body + 1] = chunk
        end
    end)
    if not readOk then
        return nil, tostring(err)
    end
    return table.concat(body)
end

local function fetchRemoteHashes()
    local url = "https://api.github.com/repos/" .. repoOwner .. "/" .. repoName .. "/git/trees/" .. branch .. "?recursive=1"
    local body, err = httpGet(url, {["User-Agent"] = "ElMech-ORMS-Updater"})
    if not body then
        return nil, err
    end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or type(data.tree) ~= "table" then
        return nil, "unexpected response from GitHub API"
    end
    local hashes = {}
    for _, entry in ipairs(data.tree) do
        if entry.type == "blob" and entry.path and entry.sha then
            hashes[entry.path] = entry.sha
        end
    end
    return hashes
end

local function loadManifest()
    if not fs.exists(manifestPath) then
        return {}
    end
    local file = io.open(manifestPath, "r")
    if not file then
        return {}
    end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

local function saveManifest(manifest)
    if not fs.exists(installRoot .. "data") then
        fs.makeDirectory(installRoot .. "data")
    end
    local file = io.open(manifestPath, "w")
    if not file then
        return
    end
    file:write(json.encode(manifest))
    file:close()
end

print("Checking which files changed...")
local remoteHashes, hashErr = fetchRemoteHashes()
local previousManifest = loadManifest()

local filesToDownload = {}
if remoteHashes then
    for _, file in ipairs(files) do
        local remoteHash = remoteHashes[file.src]
        if not remoteHash or previousManifest[file.src] ~= remoteHash then
            filesToDownload[#filesToDownload + 1] = file
        end
    end
    print(#filesToDownload .. " of " .. #files .. " file(s) changed.")
else
    print("Couldn't reach GitHub's API (" .. tostring(hashErr) .. "), updating every file instead.")
    filesToDownload = files
end

if #filesToDownload == 0 then
    print("Everything is already up to date.")
else
    for _, file in ipairs(filesToDownload) do
        print("Updating " .. file.dest .. "...")
        local dir = file.dest:match("^(.*)/[^/]+$")
        if dir and not fs.exists(installRoot .. dir) then
            fs.makeDirectory(installRoot .. dir)
        end
        shell.execute("wget -f " .. repo .. file.src .. " -O " .. installRoot .. file.dest)
    end
end

if remoteHashes then
    local newManifest = {}
    for _, file in ipairs(files) do
        newManifest[file.src] = remoteHashes[file.src] or previousManifest[file.src]
    end
    saveManifest(newManifest)
end

print("Update Complete, rebooting")
os.sleep(2)
shell.execute("reboot")
