-- One-time (re-runnable) setup wizard for the Stavědlo computer: walks the layout, lets the
-- user manually wire every switch/signal/crossing/gate/lock-clonka to an OpenComputers component
-- address, confirms signal classification, computes routes.json (route enumeration + závěr
-- výměn lock count -- see common/routes.lua) and saves everything under /home/stavedlo/data/.
-- See common/cli.lua's doc comment for why this is a term wizard rather than a grapes GUI one.
local component = require("component")
local filesystem = require("filesystem")

local cli = require("cli")
local layout = require("layout")
local routes = require("routes")
local componentmap = require("componentmap")
local network = require("network")
local lockboxdrv = require("hw.lockboxdrv")
local signaldrv = require("hw.signaldrv")
local switchio = require("hw.switchio")

local DATA_DIR = "/home/stavedlo/data"
local ROUTES_PATH = DATA_DIR .. "/routes.json"
local MAP_PATH = DATA_DIR .. "/componentmap.json"
-- Fixed path, must match init.lua's STATION_PATH -- not user-configurable to avoid the two
-- ever drifting apart. (Named station.lua, not layout.lua, to stay clear of common/layout.lua,
-- the graph/pathfinding module this project installs to the same directory.)
local STATION_PATH = "/home/stavedlo/station.lua"

local function loadLayout()
    if not filesystem.exists(STATION_PATH) then
        io.write("Soubor '" .. STATION_PATH .. "' neexistuje. Vlož tam nejprve výstup ORMS Layout Generatoru.\n")
        os.exit(1)
    end
    local chunk, err = loadfile(STATION_PATH)
    if not chunk then
        io.write("Chyba při načítání layoutu: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    return chunk()
end

local function pickComponent(componentType, promptText)
    local items = componentmap.discover(componentType)
    if #items == 0 then
        io.write("(žádná komponenta typu '" .. componentType .. "' nenalezena -- zkusím vypsat vše)\n")
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
    local raw = cli.prompt("Číslo aspektu pro '" .. purpose .. "'")
    return tonumber(raw)
end

-- Follows leverOwner to the switch that actually holds redstoneIO/side/color, in case the user
-- names an already-linked switch as the target -- keeps componentmap.resolveLeverEntry O(1) at
-- runtime (never has to chase a chain itself).
local function rootLeverOwner(map, code)
    local seen = {}
    while map.switches[code] and map.switches[code].leverOwner do
        if seen[code] then
            return code -- shouldn't happen, but avoid an infinite loop over a corrupt mapping
        end
        seen[code] = true
        code = map.switches[code].leverOwner
    end
    return code
end

local function setupSwitches(config, map)
    cli.header("Výhybky")
    for _, s in ipairs(config.Switches or {}) do
        local code = s[5]
        io.write("\n--- Výhybka " .. code .. " (" .. s[1] .. "," .. s[2] .. ") ---\n")
        local existing = map.switches[code]
        if existing and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end

        local rioAddress, side, color, leverOwner
        if cli.confirm("Je tato výhybka spojená s jinou (společná páčka)?", false) then
            local otherCode = cli.prompt("Kód výhybky, se kterou sdílí páčku")
            if not map.switches[otherCode] then
                io.write("Výhybka '" .. tostring(otherCode) .. "' zatím není namapovaná -- namapuj ji nejdřív samostatně, pak se na ni dá odkázat.\n")
                goto continue
            end
            leverOwner = rootLeverOwner(map, otherCode)
            io.write("Sdílí páčku s výhybkou " .. leverOwner .. ".\n")
        else
            rioAddress = pickComponent(componentmap.TYPES.redstone, "Redstone I/O pro páčku/světlo")
            if not rioAddress then
                io.write("Přeskočeno -- výhybka zůstane nenamapovaná.\n")
                goto continue
            end
            side = cli.pick(switchio.SIDE_NAMES, function(n) return n end)
            color = cli.pick(switchio.COLOR_NAMES, function(n) return n end)
        end

        local controller = pickComponent(componentmap.TYPES.universalController, "digitalUnivController pro pohon výhybky")
        local receiverName = cli.prompt("Jméno Universal Receiveru (v SignalCraft) pro výhybku " .. code)

        map.switches[code] = {
            redstoneIO = rioAddress, side = side, color = color, leverOwner = leverOwner,
            controller = controller, receiverName = receiverName,
        }
        ::continue::
    end
end

local function setupSignals(config, map)
    cli.header("Návěstidla")
    for _, sig in ipairs(config.Signals or {}) do
        local name = sig[3]
        io.write("\n--- Návěstidlo " .. name .. " (" .. sig[1] .. "," .. sig[2] .. ") ---\n")
        local existing = map.signals[name]
        if existing and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end

        local suggested = layout.suggestSignalKind(name)
        io.write("Odhad typu (dle jména): " .. suggested .. "\n")
        local kind = cli.prompt("Typ (main/expect/shunting/repeater/inserted)", suggested)

        local controller = pickComponent(componentmap.TYPES.signalController, "digitalController obsluhující toto návěstidlo")

        local stopState, clearStraight, clearDiverging = nil, nil, nil
        if kind == "main" and controller then
            local ok, proxy = pcall(component.proxy, controller)
            if ok then
                local okStates, states = pcall(proxy.getValidStatesForSignal, name)
                if okStates and type(states) == "table" then
                    io.write("Platné stavy pro " .. name .. ":\n")
                    for _, st in pairs(states) do
                        io.write("  " .. tostring(st) .. "\n")
                    end
                end
            end
            stopState = cli.prompt("Název stavu 'Stůj' pro toto návěstidlo")
            clearStraight = cli.prompt("Název stavu pro 'volno, přímý směr' (Route.allStraight = true)")
            clearDiverging = cli.prompt("Název stavu pro 'volno, odbočka' (Route.allStraight = false)", clearStraight)
        end

        map.signals[name] = {
            controller = controller, kind = kind, stopState = stopState,
            clearStraight = clearStraight, clearDiverging = clearDiverging,
        }
        ::continue::
    end
end

local function setupCrossings(config, map)
    cli.header("Přejezdy")
    for _, c in ipairs(config.Crossings or {}) do
        local name = c[5]
        io.write("\n--- Přejezd " .. name .. " (" .. c[1] .. "," .. c[2] .. ") ---\n")
        if map.crossings[name] and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end
        local controller = pickComponent(componentmap.TYPES.crossingController, "digitalCrossController obsluhující tento přejezd")
        map.crossings[name] = {controller = controller}
        ::continue::
    end
end

local function setupSwitchLocks(lockCount, map)
    cli.header("Závěr výměn -- " .. lockCount .. " zámek/y potřeba (dle výpočtu z routes.lua)")
    for i = 1, lockCount do
        local key = tostring(i)
        io.write("\n--- Zámek #" .. i .. " ---\n")
        if map.switchlock[key] and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end
        local controller = pickComponent(componentmap.TYPES.controllerBox, "Digital Controller Box pro clonku závěru #" .. i)
        local clonkaName = cli.prompt("Jméno spárovaného Distant Signal (clonka) pro zámek #" .. i)
        local normal = pickAspect(controller, "bílá / volno")
        local locked = pickAspect(controller, "zelená / uzamčeno")
        map.switchlock[key] = {controller = controller, clonkaName = clonkaName, aspects = {normal = normal, locked = locked}}
        ::continue::
    end
end

local function setupGates(config, map)
    cli.header("Návěstní hradlo + hradlová zarážka (jen pro hlavní návěstidla)")
    for _, sig in ipairs(config.Signals or {}) do
        local name = sig[3]
        if map.signals[name] and map.signals[name].kind == "main" then
            io.write("\n--- Hradlo pro " .. name .. " ---\n")
            if map.gates[name] and not cli.confirm("Už namapováno, přemapovat?", false) then
                goto continue
            end

            local hradloController = pickComponent(componentmap.TYPES.controllerBox, "Digital Controller Box pro clonku hradla " .. name)
            local hradloClonkaName = cli.prompt("Jméno clonky hradla (Distant Signal)")
            local hradloNormal = pickAspect(hradloController, "červená / normální")
            local hradloActive = pickAspect(hradloController, "bílá / aktivní")

            local zarazkaController = pickComponent(componentmap.TYPES.controllerBox, "Digital Controller Box pro clonku hradlové zarážky " .. name)
            local zarazkaClonkaName = cli.prompt("Jméno clonky hradlové zarážky (Distant Signal)")
            local zarazkaNormal = pickAspect(zarazkaController, "černá / normální")
            local zarazkaActive = pickAspect(zarazkaController, "bílá / aktivní")

            local detectorAddress = pickComponent(componentmap.TYPES.detector, "Digital Detector pro hradlovou zarážku " .. name)

            map.gates[name] = {
                hradloController = hradloController, hradloClonkaName = hradloClonkaName,
                hradloAspects = {normal = hradloNormal, active = hradloActive},
                zarazkaController = zarazkaController, zarazkaClonkaName = zarazkaClonkaName,
                zarazkaAspects = {normal = zarazkaNormal, active = zarazkaActive},
                detectorAddress = detectorAddress,
            }
        end
        ::continue::
    end
end

local function setupNetwork(map)
    cli.header("Síť (propojení s DK)")
    io.write("Adresa tohoto modemu: " .. tostring(component.isAvailable("modem") and component.modem.address or "(žádný modem!)") .. "\n")
    local peer = cli.prompt("Adresa modemu DK počítače", map.network.peerAddress)
    local port = tonumber(cli.prompt("Port", tostring(map.network.port or network.DEFAULT_PORT)))
    map.network = {peerAddress = peer, port = port}
end

local function main()
    local config = loadLayout()
    local map = componentmap.load(MAP_PATH)

    setupSwitches(config, map)
    setupSignals(config, map)
    setupCrossings(config, map)

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

    setupSwitchLocks(routesData.lockCount, map)
    setupGates(config, map)
    setupNetwork(map)

    componentmap.save(MAP_PATH, map)
    io.write("\nHotovo. Mapování uloženo do " .. MAP_PATH .. ", cesty do " .. ROUTES_PATH .. ".\n")
    io.write("Spusť init.lua pro start systému.\n")
end

main()
