-- Setup wizard for the Dopravní kancelář computer. DK never touches switches/signals/crossings
-- directly (that's all stavedlo/setup.lua), so this only needs: the same signal classification +
-- traťová kolej grouping pass as stavedlo (to compute the identical routes.json locally -- see
-- the note in the design plan about each computer owning its files independently, no file
-- transfer needed since both start from the same layout file), DK's own local hradlo/lock clonky
-- (mirroring network state), and the peer address of the stavedlo computer.
--
-- Auto-detection: once a clonka name is chosen, the wizard searches every Digital Controller Box
-- for one that already reports that name paired and uses it without asking (see
-- componentmap.findByPairedName) -- only falls back to a manual picker if nothing matches.
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
-- Fixed path, must match init.lua's STATION_PATH -- see stavedlo/setup.lua's note on why this
-- isn't user-configurable and isn't called layout.lua.
local STATION_PATH = "/home/dk/station.lua"

local function loadLayout()
    if not filesystem.exists(STATION_PATH) then
        io.write("Soubor '" .. STATION_PATH .. "' neexistuje. Vlož tam nejprve stejný layout jako na stavědle.\n")
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
        items = componentmap.discover(nil)
    end
    cli.header(promptText)
    local chosen = cli.pick(items, function(it)
        return it.address .. "  [" .. it.type .. "]" .. (it.label and (" -- " .. it.label) or "")
    end, true)
    return chosen and chosen.address or nil
end

local function autoOrPickComponent(componentType, listMethod, wantedName, promptText)
    local auto = componentmap.findByPairedName(componentType, listMethod, wantedName)
    if auto then
        io.write("Nalezeno automaticky: clonka '" .. wantedName .. "' už spárována na " .. auto .. ".\n")
        return auto
    end
    return pickComponent(componentType, promptText)
end

-- colorKey ("white"/"green"/"red"/"black") supplies the default from lockboxdrv.DEFAULT_ASPECT
-- (confirmed stable across the user's boxes in-game).
local function pickAspect(controllerAddress, purpose, colorKey)
    local aspects = lockboxdrv.listAspects(controllerAddress)
    if type(aspects) == "table" and next(aspects) then
        io.write("Dostupné aspekty (jen orientačně):\n")
        for k, v in pairs(aspects) do
            io.write("  " .. tostring(k) .. " = " .. tostring(v) .. "\n")
        end
    end
    local default = lockboxdrv.DEFAULT_ASPECT[colorKey]
    return tonumber(cli.prompt("Číslo aspektu pro '" .. purpose .. "'", default and tostring(default)))
end

local function classifySignals(config, map)
    cli.header("Klasifikace návěstidel (stejně jako na stavědle -- musí sedět, jinak vyjdou jiné cesty)")
    map.signals = map.signals or {}
    for _, sig in ipairs(config.Signals or {}) do
        local name = sig[3]
        local suggested = layout.suggestSignalKind(name)
        local existing = map.signals[name] and map.signals[name].kind
        local kind = cli.prompt("Typ pro " .. name .. " (main/expect/shunting/repeater/inserted)", existing or suggested)
        local runningLine = map.signals[name] and map.signals[name].runningLine
        map.signals[name] = {kind = kind, runningLine = runningLine}
    end
end

-- Must match stavedlo/setup.lua's setupRunningLines exactly, or the two computers compute
-- different routes.json (different groups/lock counts). Only asked for signals that actually
-- need it -- see that function's doc comment (a departure signal reaching several different
-- lines derives its group per-route instead, from its own destination Label).
local function setupRunningLines(config, map)
    cli.header("Traťové koleje (skupiny závěrů výměn -- stejně jako na stavědle)")
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

local function setupGateClonky(routesData, map)
    cli.header("Clonky návěstního hradla (jen ty viditelné v DK)")
    local seen = {}
    for _, r in ipairs(routesData.routes) do
        if not seen[r.entrance] then
            seen[r.entrance] = true
            local entranceName = r.entrance
            io.write("\n--- Hradlo pro " .. entranceName .. " ---\n")
            if map.gates[entranceName] and not cli.confirm("Už namapováno, přemapovat?", false) then
                goto continue
            end
            -- Retry loop: a typo or wrong pick just now can be corrected immediately (choice
            -- "retry") without restarting the whole wizard -- see cli.reviewChoice's doc comment.
            while true do
                local clonkaName = cli.prompt("Jméno clonky hradla (Distant Signal) v DK")
                local controller = autoOrPickComponent(
                    componentmap.TYPES.controllerBox, "getSignalNames", clonkaName,
                    "Digital Controller Box pro clonku hradla " .. entranceName
                )
                local normal = pickAspect(controller, "červená / normální", "red")
                local active = pickAspect(controller, "bílá / aktivní", "white")

                local choice = cli.reviewChoice({
                    "Hradlo " .. entranceName .. ": clonka='" .. tostring(clonkaName) .. "', controller=" .. tostring(controller),
                })
                if choice == "save" then
                    map.gates[entranceName] = {
                        hradloController = controller, hradloClonkaName = clonkaName,
                        hradloAspects = {normal = normal, active = active},
                    }
                    break
                elseif choice == "skip" then
                    break
                end
            end
            ::continue::
        end
    end
end

-- One clonka per traťová kolej group, matching stavedlo's setupGroupLocks -- also prints which
-- routes the group covers.
local function setupGroupLocks(routesData, map)
    cli.header("Clonky závěru výměn v DK -- " .. #routesData.groups .. " skupina/y")
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
                "Digital Controller Box pro clonku závěru " .. group .. " v DK"
            )
            local normal = pickAspect(controller, "bílá / volno", "white")
            local locked = pickAspect(controller, "zelená / uzamčeno", "green")

            local choice = cli.reviewChoice({
                "Zámek " .. group .. ": clonka='" .. tostring(clonkaName) .. "', controller=" .. tostring(controller),
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

local function setupNetwork(map)
    cli.header("Síť (propojení se stavědlem)")
    io.write("Adresa tohoto modemu: " .. tostring(component.isAvailable("modem") and component.modem.address or "(žádný modem!)") .. "\n")
    local peer = cli.prompt("Adresa modemu stavědla", map.network.peerAddress)
    local port = tonumber(cli.prompt("Port", tostring(map.network.port or network.DEFAULT_PORT)))
    map.network = {peerAddress = peer, port = port}
end

-- Saved after every section (not just once at the end) -- see stavedlo/setup.lua's save()
-- comment: re-running afterwards only requires answering "remap?" for whatever was wrong.
local function save(map)
    componentmap.save(MAP_PATH, map)
    io.write("(uloženo)\n")
end

local function main()
    local config = loadLayout()
    local map = componentmap.load(MAP_PATH)

    classifySignals(config, map)
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

    setupGateClonky(routesData, map)
    save(map)
    setupGroupLocks(routesData, map)
    save(map)
    setupNetwork(map)
    save(map)

    io.write("\nHotovo. Mapování uloženo do " .. MAP_PATH .. ", cesty do " .. ROUTES_PATH .. ".\n")
    io.write("Spusť init.lua pro start systému.\n")
end

main()
