-- Setup wizard for the Dopravní kancelář computer. DK never touches switches/signals/crossings
-- directly (that's all stavedlo/setup.lua), so this only needs: the same signal classification
-- pass as stavedlo (to compute the identical routes.json locally -- see the note in the design
-- plan about each computer owning its files independently, no file transfer needed since both
-- start from the same layout file), DK's own local hradlo/lock clonky (mirroring network state),
-- and the peer address of the stavedlo computer.
local component = require("component")
local filesystem = require("filesystem")

local cli = require("cli")
local layout = require("layout")
local routes = require("routes")
local componentmap = require("componentmap")
local network = require("network")
local lockboxdrv = require("hw.lockboxdrv")

local DATA_DIR = "/home/dk/data"
local ROUTES_PATH = DATA_DIR .. "/routes.json"
local MAP_PATH = DATA_DIR .. "/componentmap.json"

local function loadLayout()
    local path = cli.prompt("Cesta k souboru layoutu (stejný jako na stavědle)", "/home/dk/layout.lua")
    if not filesystem.exists(path) then
        io.write("Soubor '" .. path .. "' neexistuje. Vlož tam nejprve vygenerovaný layout.\n")
        os.exit(1)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        io.write("Chyba při načítání layoutu: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    return chunk()
end

local function pickComponent(componentType, promptText)
    local items = componentmap.discover(componentType)
    if #items == 0 then
        items = componentmap.discover(nil)
    end
    cli.header(promptText)
    local chosen = cli.pick(items, function(it)
        return it.address .. "  [" .. it.type .. "]" .. (it.label and (" -- " .. it.label) or "")
    end, true)
    return chosen and chosen.address or nil
end

local function pickAspect(controllerAddress, purpose)
    local aspects = lockboxdrv.listAspects(controllerAddress)
    if type(aspects) == "table" and next(aspects) then
        io.write("Dostupné aspekty (jen orientačně, potvrď/uprav číslo ručně):\n")
        for k, v in pairs(aspects) do
            io.write("  " .. tostring(k) .. " = " .. tostring(v) .. "\n")
        end
    end
    return tonumber(cli.prompt("Číslo aspektu pro '" .. purpose .. "'"))
end

local function classifySignals(config, map)
    cli.header("Klasifikace návěstidel (stejně jako na stavědle -- musí sedět, jinak vyjdou jiné cesty)")
    map.signals = map.signals or {}
    for _, sig in ipairs(config.Signals or {}) do
        local name = sig[3]
        local suggested = layout.suggestSignalKind(name)
        local existing = map.signals[name] and map.signals[name].kind
        local kind = cli.prompt("Typ pro " .. name .. " (main/expect/shunting/repeater/inserted)", existing or suggested)
        map.signals[name] = {kind = kind}
    end
end

local function setupGateClonky(routesData, map)
    cli.header("Clonky návěstního hradla (jen ty viditelné v DK)")
    for _, entranceName in ipairs((function()
        local names, seen = {}, {}
        for _, r in ipairs(routesData.routes) do
            if not seen[r.entrance] then
                seen[r.entrance] = true
                names[#names + 1] = r.entrance
            end
        end
        return names
    end)()) do
        io.write("\n--- Hradlo pro " .. entranceName .. " ---\n")
        if map.gates[entranceName] and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end
        local controller = pickComponent(componentmap.TYPES.controllerBox, "Digital Controller Box pro clonku hradla " .. entranceName)
        local clonkaName = cli.prompt("Jméno clonky hradla (Distant Signal) v DK")
        local normal = pickAspect(controller, "červená / normální")
        local active = pickAspect(controller, "bílá / aktivní")
        map.gates[entranceName] = {
            hradloController = controller, hradloClonkaName = clonkaName,
            hradloAspects = {normal = normal, active = active},
        }
        ::continue::
    end
end

local function setupLockClonky(lockCount, map)
    cli.header("Clonky závěru výměn v DK -- " .. lockCount .. " zámek/y")
    for i = 1, lockCount do
        local key = tostring(i)
        io.write("\n--- Zámek #" .. i .. " ---\n")
        if map.switchlock[key] and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end
        local controller = pickComponent(componentmap.TYPES.controllerBox, "Digital Controller Box pro clonku závěru #" .. i .. " v DK")
        local clonkaName = cli.prompt("Jméno spárovaného Distant Signal (clonka) pro zámek #" .. i)
        local normal = pickAspect(controller, "bílá / volno")
        local locked = pickAspect(controller, "zelená / uzamčeno")
        map.switchlock[key] = {controller = controller, clonkaName = clonkaName, aspects = {normal = normal, locked = locked}}
        ::continue::
    end
end

local function setupNetwork(map)
    cli.header("Síť (propojení se stavědlem)")
    io.write("Adresa tohoto modemu: " .. tostring(component.isAvailable("modem") and component.modem.address or "(žádný modem!)") .. "\n")
    local peer = cli.prompt("Adresa modemu stavědla", map.network.peerAddress)
    local port = tonumber(cli.prompt("Port", tostring(map.network.port or network.DEFAULT_PORT)))
    map.network = {peerAddress = peer, port = port}
end

local function main()
    local config = loadLayout()
    local map = componentmap.load(MAP_PATH)

    classifySignals(config, map)

    local mainSignalNames = {}
    for name, entry in pairs(map.signals) do
        if entry.kind == "main" then
            mainSignalNames[#mainSignalNames + 1] = name
        end
    end

    io.write("\nPočítám možné vlakové cesty a potřebný počet závěrů výměn...\n")
    local routesData, err = routes.computeAndSave(config, mainSignalNames, ROUTES_PATH)
    if not routesData then
        io.write("Chyba při výpočtu cest: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    io.write("Nalezeno " .. #routesData.routes .. " cest, potřeba " .. routesData.lockCount .. " závěr(ů) výměn.\n")

    setupGateClonky(routesData, map)
    setupLockClonky(routesData.lockCount, map)
    setupNetwork(map)

    componentmap.save(MAP_PATH, map)
    io.write("\nHotovo. Mapování uloženo do " .. MAP_PATH .. ", cesty do " .. ROUTES_PATH .. ".\n")
    io.write("Spusť init.lua pro start systému.\n")
end

main()
