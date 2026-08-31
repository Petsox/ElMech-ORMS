#!/usr/bin/env lua
-- Installer for the Stavědlo role. Adapted from Open-Rail-Management-System's installer.lua
-- (github.com/Petsox/Open-Rail-Management-System, automatic-route-building branch) -- same
-- wget-loop-with-overwrite-prompt approach, generalised so a repo source path can land at a
-- different on-device destination (needed because common/*.lua files live flat in the repo's
-- common/ folder but install flat into /home/stavedlo/, while common/grapes/ and
-- common/lockboxdrv.lua keep/move into subfolders -- see the manifest below).
--
-- repoOwner/repoName/branch are placeholders until this project actually has a GitHub remote --
-- update them once it's pushed (see the design plan's "Odloženo" section: publishing the repo
-- was explicitly left to the user, not done automatically here).
local repoOwner = "Petsox"
local repoName = "ElMech-ORMS"
local branch = "main"
local repo = "https://raw.githubusercontent.com/" .. repoOwner .. "/" .. repoName .. "/" .. branch .. "/"

local installRoot = "/home/stavedlo/"

-- {src = path in repo, dest = path relative to installRoot}
local files = {
    -- shared (common/)
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
    -- stavedlo-specific
    {src = "stavedlo/hw/switchio.lua", dest = "hw/switchio.lua"},
    {src = "stavedlo/hw/switchdrv.lua", dest = "hw/switchdrv.lua"},
    {src = "stavedlo/hw/signaldrv.lua", dest = "hw/signaldrv.lua"},
    {src = "stavedlo/hw/crossingdrv.lua", dest = "hw/crossingdrv.lua"},
    {src = "stavedlo/hw/detector.lua", dest = "hw/detector.lua"},
    {src = "stavedlo/interlocking/switchlock.lua", dest = "interlocking/switchlock.lua"},
    {src = "stavedlo/interlocking/gate.lua", dest = "interlocking/gate.lua"},
    {src = "stavedlo/interlocking/signals.lua", dest = "interlocking/signals.lua"},
    {src = "stavedlo/setup.lua", dest = "setup.lua"},
    {src = "stavedlo/init.lua", dest = "init.lua"},
}

local filesystem = require("filesystem")
local shell = require("shell")

local overwriteAll = false

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

io.write("Instaluji Stavědlo do " .. installRoot .. " ...\n")
for _, file in ipairs(files) do
    if confirmOverwrite(file.dest) then
        ensureDir(file.dest)
        local ok = shell.execute("wget -f " .. repo .. file.src .. " -O " .. installRoot .. file.dest)
        io.write((ok and "OK  " or "FAIL ") .. file.dest .. "\n")
    end
end

local launcherOk = true
if filesystem.exists("/bin/stavedlo.lua") and not overwriteAll then
    io.write("/bin/stavedlo.lua už existuje, přepsat? (a)no / (n)e: ")
    launcherOk = ((io.read("l") or ""):lower()) == "a"
end
if launcherOk then
    shell.execute("wget -f " .. repo .. "stavedlo/launcher.lua -O /bin/stavedlo.lua")
end

io.write("\nHotovo. Vlož " .. installRoot .. "layout.lua (výstup ORMS Layout Generatoru), pak spusť " .. installRoot .. "setup.lua.\n")
io.write("Program se pak spouští příkazem 'stavedlo'.\n")
