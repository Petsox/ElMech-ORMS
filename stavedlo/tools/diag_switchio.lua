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

local address = addresses[1]
if #addresses > 1 then
    print("\nNalezeno více komponent, používám první: " .. address)
    print("(pokud chceš jinou, uprav 'address' na začátku skriptu -- řádek 'local address = addresses[1]')")
end
local proxy = component.proxy(address)

if not proxy.getBundledInput then
    print("\nTato komponenta vůbec nemá metodu getBundledInput -- API je jiné, než skript předpokládá.")
    print("Podívej se na seznam metod výše a napiš mi, co tam skutečně je.")
    return
end

print("\n== Živé čtení getBundledInput(side, color) pro " .. address .. " ==")
print("Zmáčkni páčku na Control Panelu -- sleduj, která hodnota (strana / barva) se změní. Ctrl+C pro konec.\n")

while true do
    for _, sideName in ipairs(SIDE_NAMES) do
        local side = sides[sideName]
        for i, colorName in ipairs(COLOR_NAMES) do
            local ok, value = pcall(proxy.getBundledInput, side, i - 1)
            if ok and value and value > 0 then
                print(os.date("%H:%M:%S") .. "  " .. sideName .. " / " .. colorName .. " (index " .. (i - 1) .. ") = " .. tostring(value))
            end
        end
    end
    os.sleep(1)
end
