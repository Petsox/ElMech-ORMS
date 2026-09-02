-- Standalone diagnostic for one specific switch code -- dumps what's actually stored for it in
-- componentmap.json, then walks the exact same steps stavedlo/init.lua's pollSwitches takes
-- (resolve lever entry -> read lever -> check isSwitchLocked -> drive motor), printing each
-- result, so a break anywhere in that chain shows up directly instead of just "nothing happens".
--
-- Usage: wget -f https://raw.githubusercontent.com/Petsox/ElMech-ORMS/master/stavedlo/tools/diag_switch.lua diag_switch.lua
--        diag_switch.lua 18
local componentmap = require("componentmap")
local switchio = require("hw.switchio")
local switchdrv = require("hw.switchdrv")
local routesLib = require("routes")
local switchlock = require("interlocking.switchlock")

local code = ...
if not code then
    print("Použití: diag_switch.lua <kód výhybky>   (např. diag_switch.lua 18)")
    return
end

local MAP_PATH = "/home/stavedlo/data/componentmap.json"
local ROUTES_PATH = "/home/stavedlo/data/routes.json"

local map = componentmap.load(MAP_PATH)
local entry = map.switches[code]

print("== Uložený záznam pro výhybku " .. code .. " ==")
if not entry then
    print("Žádný záznam -- výhybka není namapovaná vůbec.")
    return
end
for k, v in pairs(entry) do
    print("  " .. k .. " = " .. tostring(v))
end

local leverEntry = componentmap.resolveLeverEntry(map, code)
print("\n== Vlastník páčky (resolveLeverEntry) ==")
if not leverEntry then
    print("resolveLeverEntry vrátilo nil -- chybí redstoneIO/side/color i po vyřešení leverOwner.")
    return
end
for k, v in pairs(leverEntry) do
    print("  " .. k .. " = " .. tostring(v))
end

print("\n== Čtení páčky (switchio.readLever) ==")
local reading, err = switchio.readLever(leverEntry)
print("  reading = " .. tostring(reading) .. (err and ("  err = " .. tostring(err)) or ""))

print("\n== Stav zámku (switchlock:isSwitchLocked) ==")
local routesData = routesLib.load(ROUTES_PATH)
if not routesData then
    print("  routes.json se nepodařilo načíst.")
else
    local lock = switchlock.new(routesData, map)
    print("  isSwitchLocked = " .. tostring(lock:isSwitchLocked(code)))
end

print("\n== Přímé zavolání switchdrv.setPosition(entry, true) ==")
local ok, driveErr = switchdrv.setPosition(entry, true)
print("  ok = " .. tostring(ok) .. (driveErr and ("  err = " .. tostring(driveErr)) or ""))
print("\nZkontroluj, jestli se výhybka teď fyzicky přestavila.")
