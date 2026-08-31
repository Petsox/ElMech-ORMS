-- Installer for the Dopravní kancelář role. See stavedlo/installer.lua's doc comment -- same
-- pattern, different (smaller) manifest since DK never talks to switches/signals/crossings
-- hardware directly.
local repoOwner = "Petsox"
local repoName = "ElMech-ORMS"
local branch = "master"
local repo = "https://raw.githubusercontent.com/" .. repoOwner .. "/" .. repoName .. "/" .. branch .. "/"

local installRoot = "/home/dk/"

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

local filesystem = require("filesystem")
local shell = require("shell")

local overwriteAll = false

if not filesystem.exists(installRoot) then
    filesystem.makeDirectory(installRoot)
end

local function ensureDir(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not filesystem.exists(installRoot .. dir) then
        filesystem.makeDirectory(installRoot .. dir)
    end
end

local function confirmOverwrite(dest)
    if overwriteAll or not filesystem.exists(installRoot .. dest) then
        return true
    end
    io.write(dest .. " už existuje, přepsat? (a)no / (n)e / (v)še: ")
    local answer = (io.read("l") or ""):lower()
    if answer == "v" then
        overwriteAll = true
        return true
    end
    return answer == "a" or answer == "y"
end

io.write("Instaluji Dopravní kancelář do " .. installRoot .. " ...\n")
for _, file in ipairs(files) do
    if confirmOverwrite(file.dest) then
        ensureDir(file.dest)
        local ok = shell.execute("wget -f " .. repo .. file.src .. " -O " .. installRoot .. file.dest)
        io.write((ok and "OK  " or "FAIL ") .. file.dest .. "\n")
    end
end

local launcherOk = true
if filesystem.exists("/bin/dk.lua") and not overwriteAll then
    io.write("/bin/dk.lua už existuje, přepsat? (a)no / (n)e: ")
    launcherOk = ((io.read("l") or ""):lower()) == "a"
end
if launcherOk then
    shell.execute("wget -f " .. repo .. "dk/launcher.lua -O /bin/dk.lua")
end

io.write("\nHotovo. Vlož " .. installRoot .. "layout.lua (stejný jako na stavědle), pak spusť " .. installRoot .. "setup.lua.\n")
io.write("Program se pak spouští příkazem 'dk'.\n")
