-- Standalone diagnostic for hw/switchio.lua's ASSUMPTION about the Redstone I/O bundled-cable
-- API (getBundledInput/setBundledOutput, ProjectRed/ProjectBlue colour ordinals) -- not part of
-- the installer manifest, run it directly:
--   wget -f https://raw.githubusercontent.com/Petsox/ElMech-ORMS/master/stavedlo/tools/diag_switchio.lua diag.lua
--   diag.lua
--
-- Step 1 lists every redstone-type component on this computer's network and the exact method
-- names it exposes -- confirms whether getBundledInput/setBundledOutput actually exist (vs. a
-- differently-named or differently-shaped API).
--
-- Step 2 repeatedly polls one chosen component's getBundledInput(side, color) for every
-- side/colour combination and prints only the ones that are currently non-zero. Flip a Control
-- Panel lever while this is running and watch which (side, colour) reading changes -- that tells
-- you the REAL side/colour for that lever, which you can then compare against what was entered
-- in setup.lua.
local component = require("component")
local sides = require("sides")
local event = require("event")

local SIDE_NAMES = {"down", "up", "north", "south", "west", "east"}
local COLOR_NAMES = {
    "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
    "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}

print("== Redstone-type components on this network ==")
local addresses = {}
for address in component.list("redstone", true) do
    addresses[#addresses + 1] = address
    print(address)
    local ok, methods = pcall(component.methods, address)
    if ok then
        io.write("  methods: ")
        local names = {}
        for name in pairs(methods) do
            names[#names + 1] = name
        end
        table.sort(names)
        print(table.concat(names, ", "))
    else
        print("  (nepodařilo se zjistit metody: " .. tostring(methods) .. ")")
    end
end

if #addresses == 0 then
    print("Žádná komponenta typu 'redstone' nenalezena. Zkontroluj, že je Redstone I/O připojené k síti.")
    return
end

-- Polls every discovered redstone component (not just the first), so a lever wired to any of
-- them shows up -- each line is prefixed with the short address so you know which physical
-- Redstone I/O block it actually belongs to.
local proxies = {}
for _, address in ipairs(addresses) do
    local proxy = component.proxy(address)
    if proxy.getBundledInput then
        proxies[#proxies + 1] = {address = address, short = address:sub(1, 8), proxy = proxy}
    else
        print("\n" .. address .. " nemá metodu getBundledInput -- vynechávám ji z živého čtení.")
    end
end

if #proxies == 0 then
    print("\nŽádná z nalezených komponent nemá getBundledInput -- API je jiné, než skript předpokládá.")
    print("Podívej se na seznam metod výše a napiš mi, co tam skutečně je.")
    return
end

print("\n== Živé čtení getBundledInput(side, color) na " .. #proxies .. " komponentě/ách ==")
print("Zmáčkni páčku na Control Panelu -- sleduj, která hodnota (adresa / strana / barva) se změní. Ctrl+C pro konec.\n")

while true do
    for _, entry in ipairs(proxies) do
        for _, sideName in ipairs(SIDE_NAMES) do
            local side = sides[sideName]
            for i, colorName in ipairs(COLOR_NAMES) do
                local ok, value = pcall(entry.proxy.getBundledInput, side, i - 1)
                if ok and value and value > 0 then
                    print(os.date("%H:%M:%S") .. "  " .. entry.short .. "  " .. sideName .. " / " .. colorName
                        .. " (index " .. (i - 1) .. ") = " .. tostring(value))
                end
            end
        end
    end
    os.sleep(1)
end
