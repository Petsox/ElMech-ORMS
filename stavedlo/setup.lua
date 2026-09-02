-- One-time (re-runnable) setup wizard for the Stavědlo computer: walks the layout, lets the
-- user manually wire every switch/signal/crossing/gate/lock-clonka to an OpenComputers component
-- address, confirms signal classification, computes routes.json (route enumeration + traťová
-- kolej grouping -- see common/routes.lua) and saves everything under /home/stavedlo/data/.
-- See common/cli.lua's doc comment for why this is a term wizard rather than a grapes GUI one.
--
-- Auto-detection: for every entity whose name is already known from the layout (switch code,
-- signal name, crossing name) or chosen earlier in this same run (a clonka name), the wizard
-- first searches all components of the right type for one that already reports that name among
-- its paired receivers/signals (component.getReceiverNames()/getSignalNames()) and uses it
-- without asking, only falling back to the manual picker when nothing matches. This assumes the
-- user names things in-game to match the layout/clonka names -- if that's not the convention for
-- some entity, the manual fallback still lets it be named/picked freely.
local component = require("component")
local filesystem = require("filesystem")

local cli = require("cli")
local layout = require("layout")
local routes = require("routes")
local componentmap = require("componentmap")
local network = require("network")
local lockboxdrv = require("hw.lockboxdrv")
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

-- Tries auto-detection first (see module doc comment), falls back to pickComponent.
local function autoOrPickComponent(componentType, listMethod, wantedName, promptText, entityLabel)
    local auto = componentmap.findByPairedName(componentType, listMethod, wantedName)
    if auto then
        io.write("Nalezeno automaticky: " .. entityLabel .. " '" .. wantedName .. "' už spárováno na " .. auto .. ".\n")
        return auto
    end
    return pickComponent(componentType, promptText)
end

-- colorKey ("white"/"green"/"red"/"black") supplies the default from lockboxdrv.DEFAULT_ASPECT
-- (confirmed stable across the user's boxes in-game), so this is normally just Enter-to-accept
-- rather than typing a number blind; still shows the live aspects list and allows overriding it.
local function pickAspect(controllerAddress, purpose, colorKey)
    local aspects = lockboxdrv.listAspects(controllerAddress)
    if type(aspects) == "table" and next(aspects) then
        io.write("Dostupné aspekty (jen orientačně):\n")
        for k, v in pairs(aspects) do
            io.write("  " .. tostring(k) .. " = " .. tostring(v) .. "\n")
        end
    end
    local default = lockboxdrv.DEFAULT_ASPECT[colorKey]
    local raw = cli.prompt("Číslo aspektu pro '" .. purpose .. "'", default and tostring(default))
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

local function findSwitchConfig(config, code)
    for _, s in ipairs(config.Switches or {}) do
        if s[5] == code then
            return s
        end
    end
    return nil
end

-- Every colour already used on (rioAddress, side) by some OTHER entry of the same kind --
-- excludeSwitchCode/excludeRouteId skip the entry currently being (re)configured, so remapping a
-- switch back onto its own existing colour still works.
--
-- kind="lever": scans switch levers + kolejové závěrníky (they're both a plain input on the
-- Control Panel, sharing one 16-colour bundled cable per (address, side)).
-- kind="indicator": scans switch INDICATOR lights only, a separate namespace -- confirmed in
-- practice that reusing a switch's own lever (redstoneIO, side, color) for its indicator output
-- can feed the output back into the input reading and permanently stick it (see
-- componentmap.lua's schema comment), so indicator colours must never be checked against, or
-- picked from, the lever/routeLock namespace.
local function usedColorsFor(map, rioAddress, side, kind, excludeSwitchCode, excludeRouteId)
    local used = {}
    if kind == "indicator" then
        for code, entry in pairs(map.switches) do
            local ind = entry.indicator
            if code ~= excludeSwitchCode and ind and ind.redstoneIO == rioAddress and ind.side == side and ind.color then
                used[ind.color] = true
            end
        end
    else
        for code, entry in pairs(map.switches) do
            if code ~= excludeSwitchCode and entry.redstoneIO == rioAddress and entry.side == side and entry.color then
                used[entry.color] = true
            end
        end
        for routeId, entry in pairs(map.routeLocks) do
            if routeId ~= excludeRouteId and entry.redstoneIO == rioAddress and entry.side == side and entry.color then
                used[entry.color] = true
            end
        end
    end
    return used
end

-- Shared by switch levers, kolejový závěrník levers, and switch indicators -- all three are a
-- plain redstoneIO/side/color Control Panel connection, just input vs. output and different
-- colour namespaces (see usedColorsFor's doc comment on why kind matters).
local function promptLever(map, promptText, kind, excludeSwitchCode, excludeRouteId)
    local rioAddress = pickComponent(componentmap.TYPES.redstone, promptText)
    if not rioAddress then
        return nil
    end
    local side = cli.pick(switchio.SIDE_NAMES, function(n) return n end)

    local used = usedColorsFor(map, rioAddress, side, kind, excludeSwitchCode, excludeRouteId)
    local available = {}
    for _, c in ipairs(switchio.COLOR_NAMES) do
        if not used[c] then
            available[#available + 1] = c
        end
    end
    if #available == 0 then
        io.write("Všech 16 barev na " .. rioAddress .. " (" .. side .. ") už je obsazeno -- zvol jinou stranu/adresu.\n")
        return nil
    end
    local color = cli.pick(available, function(n) return n end)
    return rioAddress, side, color
end

local function promptSwitchLever(map, excludeSwitchCode)
    return promptLever(map, "Redstone I/O pro páčku (vstup)", "lever", excludeSwitchCode, nil)
end

-- Separate physical Control Panel (per the design: levers on one panel, indicator lights on a
-- second one next to it) -- must never reuse the lever's own (redstoneIO, side, color).
-- Skippable: an unmapped indicator just means the light never lights up, lever/motor still work.
local function promptSwitchIndicator(map, code)
    io.write("Kontrolka pro výhybku " .. code .. " (druhý Control Panel se světly, výstup):\n")
    local rioAddress, side, color = promptLever(map, "Redstone I/O pro kontrolku (výstup)", "indicator", code, nil)
    if not rioAddress then
        io.write("Přeskočeno -- výhybka " .. code .. " zůstane bez kontrolky.\n")
        return nil
    end
    return {redstoneIO = rioAddress, side = side, color = color}
end

local function promptSwitchDrive(code)
    local controller = componentmap.findByPairedName(componentmap.TYPES.universalController, "getReceiverNames", code)
    if controller then
        io.write("Nalezeno automaticky: výhybka '" .. code .. "' už spárována na " .. controller .. ".\n")
        return controller, code
    end
    controller = pickComponent(componentmap.TYPES.universalController, "digitalUnivController pro pohon výhybky")
    local receiverName = cli.prompt("Jméno Universal Receiveru (v SignalCraft) pro výhybku " .. code, code)
    return controller, receiverName
end

-- Called when a "spojená výhybka" names a target that isn't mapped yet. Rather than force the
-- user to abort and re-run the wizard in the right order, offers to map the target right here as
-- a lever owner (its own redstoneIO/side/color + controller/receiverName). Returns true once
-- map.switches[code] exists (already did, or was just filled in), false if the user declined or
-- skipped -- caller should leave the referencing switch unmapped in that case.
local function setupOwnerInline(config, map, code)
    if map.switches[code] then
        return true
    end
    local s = findSwitchConfig(config, code)
    local label = s and (" (" .. s[1] .. "," .. s[2] .. ")") or ""
    io.write("Výhybka '" .. code .. "' zatím není namapovaná.\n")
    if not cli.confirm("Namapovat ji teď jako vlastníka páčky?", true) then
        return false
    end

    io.write("\n--- Výhybka " .. code .. label .. " (vlastník páčky) ---\n")
    local rioAddress, side, color = promptSwitchLever(map, code)
    if not rioAddress then
        io.write("Přeskočeno -- výhybka '" .. code .. "' zůstane nenamapovaná.\n")
        return false
    end
    local controller, receiverName = promptSwitchDrive(code)
    local indicator = promptSwitchIndicator(map, code)
    map.switches[code] = {
        redstoneIO = rioAddress, side = side, color = color, indicator = indicator,
        controller = controller, receiverName = receiverName,
    }
    return true
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

        -- Retry loop: a typo or wrong pick just now can be corrected immediately (choice
        -- "retry") without restarting the whole wizard -- see cli.reviewChoice's doc comment.
        while true do
            local rioAddress, side, color, leverOwner, indicator
            if cli.confirm("Je tato výhybka spojená s jinou (společná páčka)?", false) then
                local otherCode = cli.prompt("Kód výhybky, se kterou sdílí páčku")
                if not setupOwnerInline(config, map, otherCode) then
                    io.write("Výhybka '" .. tostring(otherCode) .. "' zůstává nenamapovaná -- výhybka " .. code .. " přeskočena.\n")
                    break
                end
                leverOwner = rootLeverOwner(map, otherCode)
                io.write("Sdílí páčku i kontrolku s výhybkou " .. leverOwner .. ".\n")
                -- indicator stays nil -- resolved through leverOwner at runtime (one physical
                -- lamp for the shared lever, just like the lever itself), never asked here.
            else
                rioAddress, side, color = promptSwitchLever(map, code)
                if not rioAddress then
                    io.write("Přeskočeno -- výhybka zůstane nenamapovaná.\n")
                    break
                end
                indicator = promptSwitchIndicator(map, code)
            end

            local controller, receiverName = promptSwitchDrive(code)

            -- Built up rather than as one table literal -- a literal nil in the middle of an
            -- array constructor would make ipairs (inside cli.reviewChoice) stop early and
            -- silently drop every line after it.
            local summary = {"Výhybka " .. code .. ":"}
            if leverOwner then
                summary[#summary + 1] = "  páčka + kontrolka: sdílené s výhybkou " .. leverOwner
            else
                summary[#summary + 1] = "  páčka: " .. tostring(rioAddress) .. " / " .. tostring(side) .. " / " .. tostring(color)
                summary[#summary + 1] = indicator
                    and ("  kontrolka: " .. indicator.redstoneIO .. " / " .. indicator.side .. " / " .. indicator.color)
                    or "  kontrolka: (nenamapováno)"
            end
            summary[#summary + 1] = "  pohon: " .. tostring(controller) .. " / receiver '" .. tostring(receiverName) .. "'"

            local choice = cli.reviewChoice(summary)
            if choice == "save" then
                map.switches[code] = {
                    redstoneIO = rioAddress, side = side, color = color, leverOwner = leverOwner, indicator = indicator,
                    controller = controller, receiverName = receiverName,
                }
                break
            elseif choice == "skip" then
                break
            end
        end
        ::continue::
    end
end

-- No prompt for state names anywhere here -- checked against ORMS, which hardcodes the fixed
-- SignalCraft state vocabulary ("Stuj"/"Volno"/"R40Volno"/...) rather than asking per station.
-- interlocking/signals.lua uses those same constants directly at runtime (querying
-- getValidStatesForSignal live only to confirm R40Volno is actually offered, never storing
-- anything here) -- see its module doc comment.
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
        while true do
            io.write("Odhad typu (dle jména): " .. suggested .. "\n")
            local kind = cli.prompt("Typ (main/expect/shunting/repeater/inserted)", suggested)

            local controller = autoOrPickComponent(
                componentmap.TYPES.signalController, "getSignalNames", name,
                "digitalController obsluhující toto návěstidlo", "návěstidlo"
            )

            local choice = cli.reviewChoice({
                "Návěstidlo " .. name .. ": typ=" .. kind .. ", controller=" .. tostring(controller),
            })
            if choice == "save" then
                map.signals[name] = {
                    controller = controller, kind = kind,
                    runningLine = existing and existing.runningLine or nil,
                }
                break
            elseif choice == "skip" then
                break
            end
        end
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
        while true do
            local controller = autoOrPickComponent(
                componentmap.TYPES.crossingController, "getReceiverNames", name,
                "digitalCrossController obsluhující tento přejezd", "přejezd"
            )
            local choice = cli.reviewChoice({"Přejezd " .. name .. ": controller=" .. tostring(controller)})
            if choice == "save" then
                map.crossings[name] = {controller = controller}
                break
            elseif choice == "skip" then
                break
            end
        end
        ::continue::
    end
end

-- Which traťová kolej (running line, e.g. "T1"/"T2"/"T4") a main signal belongs to -- decides
-- routes.lua's lock grouping for its ARRIVAL routes (one závěr výměn per line, confirmed by the
-- user against their real station design). Only asked for signals that actually need it: a
-- signal whose every route ends at a running-line Label (an odjezdové/departure signal facing
-- back across the whole switch ladder -- confirmed against a real layout where one such signal
-- can reach several different lines depending on the route) derives its group per-route from
-- that destination instead (see common/routes.lua), and is never asked here.
local function setupRunningLines(config, map)
    cli.header("Traťové koleje (skupiny závěrů výměn)")
    local candidates = {}
    for _, l in ipairs(config.Labels or {}) do
        if tostring(l[3]):match("^T%d") then
            candidates[#candidates + 1] = l[3]
        end
    end

    local graph = layout.buildGraph(config)
    local mainSignalNames = {}
    for name, entry in pairs(map.signals) do
        if entry.kind == "main" then
            mainSignalNames[#mainSignalNames + 1] = name
        end
    end
    local routeList = routes.enumerate(graph, mainSignalNames, config.Labels or {})

    local needsAssignment = {}
    for _, r in ipairs(routeList) do
        if not routes.isRunningLineLabel(r.label) then
            needsAssignment[r.entrance] = true
        end
    end

    for name, entry in pairs(map.signals) do
        if entry.kind == "main" and needsAssignment[name] then
            io.write("\n--- " .. name .. " ---\n")
            if entry.runningLine and not cli.confirm("Už má traťovou kolej '" .. entry.runningLine .. "', přemapovat?", false) then
                goto continue
            end
            local chosen
            if #candidates > 0 then
                chosen = cli.pick(candidates, function(c) return c end, true)
            end
            entry.runningLine = chosen or cli.prompt("Traťová kolej (Label) pro " .. name, entry.runningLine)
            ::continue::
        end
    end
end

-- One clonka per traťová kolej group (not per route) -- addresses request to show which routes a
-- given lock actually serves before asking to map it.
local function setupGroupLocks(routesData, map)
    cli.header("Závěr výměn -- " .. #routesData.groups .. " skupina/y (podle traťových kolejí)")
    for _, group in ipairs(routesData.groups) do
        io.write("\n--- Zámek pro " .. group .. " ---\nCesty v této skupině:\n")
        for _, r in ipairs(routesData.routes) do
            if r.group == group then
                io.write("  - " .. r.id .. "\n")
            end
        end
        if map.switchlock[group] and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end
        while true do
            local clonkaName = cli.prompt("Jméno spárovaného Distant Signal (clonka) pro zámek " .. group)
            local controller = autoOrPickComponent(
                componentmap.TYPES.controllerBox, "getSignalNames", clonkaName,
                "Digital Controller Box pro clonku závěru " .. group, "clonka"
            )
            local normal = pickAspect(controller, "bílá / volno", "white")
            local locked = pickAspect(controller, "zelená / uzamčeno", "green")

            local choice = cli.reviewChoice({
                "Zámek " .. group .. ": clonka='" .. tostring(clonkaName) .. "', controller=" .. tostring(controller),
                "  aspekty: volno=" .. tostring(normal) .. ", uzamčeno=" .. tostring(locked),
            })
            if choice == "save" then
                map.switchlock[group] = {controller = controller, clonkaName = clonkaName, aspects = {normal = normal, locked = locked}}
                break
            elseif choice == "skip" then
                break
            end
        end
        ::continue::
    end
end

-- Kolejový závěrník: a real mechanical route-lock lever per route (not per group) -- signalista
-- must engage it (after setting the switches) before switchlock:confirmLock will lock the
-- závěr výměn for that specific route. Input-only, reuses hw/switchio.lua's generic bundled-cable
-- lever reading (no motor/indicator needed here, unlike a switch).
local function setupRouteLocks(routesData, map)
    cli.header("Kolejové závěrníky (páčka na Control Panelu pro každou vlakovou cestu)")
    for _, r in ipairs(routesData.routes) do
        io.write("\n--- Kolejový závěrník pro cestu " .. r.id .. " (skupina " .. tostring(r.group) .. ") ---\n")
        if map.routeLocks[r.id] and not cli.confirm("Už namapováno, přemapovat?", false) then
            goto continue
        end
        while true do
            local rioAddress, side, color = promptLever(map, "Redstone I/O pro páčku kolejového závěrníku", "lever", nil, r.id)
            if not rioAddress then
                io.write("Přeskočeno -- cesta zůstane bez kolejového závěrníku (nepůjde zamknout závěr výměn).\n")
                break
            end
            local choice = cli.reviewChoice({
                "Kolejový závěrník " .. r.id .. ": " .. rioAddress .. " / " .. side .. " / " .. color,
            })
            if choice == "save" then
                map.routeLocks[r.id] = {redstoneIO = rioAddress, side = side, color = color}
                break
            elseif choice == "skip" then
                break
            end
        end
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

            while true do
                local hradloClonkaName = cli.prompt("Jméno clonky hradla (Distant Signal)")
                local hradloController = autoOrPickComponent(
                    componentmap.TYPES.controllerBox, "getSignalNames", hradloClonkaName,
                    "Digital Controller Box pro clonku hradla " .. name, "clonka"
                )
                local hradloNormal = pickAspect(hradloController, "červená / normální", "red")
                local hradloActive = pickAspect(hradloController, "bílá / aktivní", "white")

                local zarazkaClonkaName = cli.prompt("Jméno clonky hradlové zarážky (Distant Signal)")
                local zarazkaController = autoOrPickComponent(
                    componentmap.TYPES.controllerBox, "getSignalNames", zarazkaClonkaName,
                    "Digital Controller Box pro clonku hradlové zarážky " .. name, "clonka"
                )
                local zarazkaNormal = pickAspect(zarazkaController, "černá / normální", "black")
                local zarazkaActive = pickAspect(zarazkaController, "bílá / aktivní", "white")

                local detectorAddress = pickComponent(componentmap.TYPES.detector, "Digital Detector pro hradlovou zarážku " .. name)

                local choice = cli.reviewChoice({
                    "Hradlo " .. name .. ":",
                    "  hradlo clonka: '" .. tostring(hradloClonkaName) .. "' na " .. tostring(hradloController),
                    "  zarážka clonka: '" .. tostring(zarazkaClonkaName) .. "' na " .. tostring(zarazkaController),
                    "  detektor: " .. tostring(detectorAddress),
                })
                if choice == "save" then
                    map.gates[name] = {
                        hradloController = hradloController, hradloClonkaName = hradloClonkaName,
                        hradloAspects = {normal = hradloNormal, active = hradloActive},
                        zarazkaController = zarazkaController, zarazkaClonkaName = zarazkaClonkaName,
                        zarazkaAspects = {normal = zarazkaNormal, active = zarazkaActive},
                        detectorAddress = detectorAddress,
                    }
                    break
                elseif choice == "skip" then
                    break
                end
            end
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

-- Saved after every section (not just once at the end) so an interrupted or aborted run never
-- loses earlier progress -- re-running setup.lua afterwards will offer "already mapped,
-- remap?" for everything already done, and skipping through those is the practical way to go
-- back and fix just the one entity that was wrong without redoing the whole wizard.
local function save(map)
    componentmap.save(MAP_PATH, map)
    io.write("(uloženo)\n")
end

local function main()
    local config = loadLayout()
    local map = componentmap.load(MAP_PATH)

    setupSwitches(config, map)
    save(map)
    setupSignals(config, map)
    save(map)
    setupCrossings(config, map)
    save(map)
    setupRunningLines(config, map)
    save(map)

    local mainSignalNames, entranceRunningLine = {}, {}
    for name, entry in pairs(map.signals) do
        if entry.kind == "main" then
            mainSignalNames[#mainSignalNames + 1] = name
            if entry.runningLine then
                entranceRunningLine[name] = entry.runningLine
            end
        end
    end

    io.write("\nPočítám možné vlakové cesty...\n")
    local routesData, err = routes.computeAndSave(config, mainSignalNames, entranceRunningLine, ROUTES_PATH)
    if not routesData then
        io.write("Chyba při výpočtu cest: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    io.write("Nalezeno " .. #routesData.routes .. " cest v " .. #routesData.groups .. " skupinách: "
        .. table.concat(routesData.groups, ", ") .. "\n")

    setupGroupLocks(routesData, map)
    save(map)
    setupRouteLocks(routesData, map)
    save(map)
    setupGates(config, map)
    save(map)
    setupNetwork(map)
    save(map)

    io.write("\nHotovo. Mapování uloženo do " .. MAP_PATH .. ", cesty do " .. ROUTES_PATH .. ".\n")
    io.write("Spusť init.lua pro start systému.\n")
end

main()
