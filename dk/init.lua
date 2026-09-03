-- Dopravní kancelář entry point: draws the same track diagram as stavědlo (read-only except
-- hlavní návěstidla and Labels, which are clickable for route selection), a control panel per
-- main signal for the hradlo/závěr-výměn actions the design assigns to DK, and mirrors
-- stavědlo's state into local clonky + the diagram via the network link.
local GUI = require("grapes.GUI")
local text = require("text")
local unicode = require("unicode")
local filesystem = require("filesystem")
local component = require("component")

local routesLib = require("routes")
local componentmap = require("componentmap")
local network = require("network")
local lockboxdrv = require("hw.lockboxdrv")
local routeselect = require("interlocking.routeselect")

local DATA_DIR = "/home/dk/data"
-- Must match setup.lua's STATION_PATH; called station.lua (not layout.lua) to stay clear of
-- common/layout.lua, the graph/pathfinding module installed alongside it.
local STATION_PATH = "/home/dk/station.lua"
local ROUTES_PATH = DATA_DIR .. "/routes.json"
local MAP_PATH = DATA_DIR .. "/componentmap.json"

if not filesystem.exists(MAP_PATH) or not filesystem.exists(ROUTES_PATH) then
    io.write("Systém není nastaven. Spusť nejprve /home/dk/setup.lua.\n")
    os.exit(1)
end

local map = componentmap.load(MAP_PATH)
local routesData = routesLib.load(ROUTES_PATH)
local configChunk, chunkErr = loadfile(STATION_PATH)
if not configChunk then
    io.write("Chyba při načítání layoutu: " .. tostring(chunkErr) .. "\n")
    os.exit(1)
end
local config = configChunk()

local rsel = routeselect.new(routesData)

local function resetClonky()
    for _, entry in pairs(map.gates) do
        lockboxdrv.setAspect(entry.hradloController, entry.hradloClonkaName, entry.hradloAspects.normal)
    end
    for _, entry in pairs(map.switchlock) do
        lockboxdrv.setAspect(entry.controller, entry.clonkaName, entry.aspects.normal)
    end
end
resetClonky()

-- Display-only convenience, mirrors stavedlo/init.lua's routeDisplayText: which arrival signal
-- represents each group, so a departure route reads "6 -> LMol" instead of the raw "S4 -> T4".
-- Purely cosmetic.
local arrivalEntranceForGroup = {}
for name, entry in pairs(map.signals) do
    if entry.kind == "main" and entry.runningLine then
        arrivalEntranceForGroup[entry.runningLine] = name
    end
end

local function routeDisplayText(route)
    if routesLib.isRunningLineLabel(route.label) then
        local originTrack = route.entrance:match("^S(%d+)$") or route.entrance
        local arrivalName = arrivalEntranceForGroup[route.label] or route.label
        return originTrack .. " -> " .. arrivalName
    end
    return route.entrance .. " -> " .. route.label
end

--------------------------------------------------------------------------------
-- GUI

-- See stavedlo/init.lua's comment on why this raw GPU fill runs before grapes draws anything.
do
    local gpu = component.gpu
    local w, h = gpu.getResolution()
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
end

local workspace = GUI.workspace()
local GRAY, WHITE, RED, GREEN, YELLOW, BLUE = 0xB2B2B2, 0xFFFFFF, 0xFF4040, 0x40FF40, 0xFFFF40, 0x4090FF

workspace:addChild(GUI.label(1, 1, workspace.width, 1, WHITE, "Dopravní kancelář"):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP))

for _, t in ipairs(config.Tracks or {}) do
    workspace:addChild(GUI.text(t[1], t[2], GRAY, text.trim(t[3]) or ""))
end
for _, s in ipairs(config.Switches or {}) do
    workspace:addChild(GUI.text(s[1], s[2], GRAY, text.trim(s[3]) or ""))
end
for _, c in ipairs(config.Crossings or {}) do
    workspace:addChild(GUI.text(c[1], c[2], GRAY, text.trim(c[3]) or ""))
end

local signalObjects = {}
for _, s in ipairs(config.Signals or {}) do
    local name = s[3]
    local mapped = map.signals[name]
    local isMain = mapped and mapped.kind == "main"
    local obj = workspace:addChild(GUI.text(s[1], s[2], isMain and BLUE or GRAY, s[4]))
    signalObjects[name] = obj
    if isMain then
        obj.eventHandler = function(ws, object, event)
            if event == "touch" then
                rsel:clickEntrance(name)
                io.write("Vybrán vjezd/odjezd: " .. name .. "\n")
            end
        end
    end
end

local labelObjects = {}
for _, l in ipairs(config.Labels or {}) do
    local obj = workspace:addChild(GUI.button(
        math.ceil(l[1] - unicode.len(l[3]) / 2), l[2],
        unicode.len(l[3]) + 2, 1, 0x0000AA, WHITE, 0x0000AA, WHITE, l[3]
    ))
    labelObjects[l[3]] = obj
    obj.onTouch = function()
        local route, entranceName = rsel:clickLabel(l[3])
        if route then
            io.write("Cesta " .. route.id .. " připravena k aktivaci hradla.\n")
        elseif entranceName then
            io.write("Mezi " .. entranceName .. " a " .. l[3] .. " neexistuje cesta.\n")
        end
        workspace:draw()
    end
end

-- Control panel: one row per traťová kolej GROUP -- a hradlo is shared between every arrival and
-- departure signal on that line (confirmed by the user against the real hradlo count), so what's
-- actually requested/released is "this group's hradlo", not a specific signal's. Route SELECTION
-- still happens by clicking individual signals/labels on the diagram above; the row for whichever
-- group the selected route belongs to is what shows it and sends the request.
local panelY = 40
workspace:addChild(GUI.label(1, panelY, workspace.width, 1, WHITE, "Vlakové cesty (traťové koleje)"))

local rows = {}
for i, group in ipairs(routesData.groups) do
    local y = panelY + i
    local row = {}
    row.nameLabel = workspace:addChild(GUI.label(1, y, 10, 1, WHITE, group))
    row.stateLabel = workspace:addChild(GUI.label(12, y, 30, 1, GRAY, "-"))
    row.hradloBtn = workspace:addChild(GUI.button(44, y, 16, 1, 0x333333, WHITE, 0x555555, WHITE, "Aktivovat hradlo"))
    row.releaseBtn = workspace:addChild(GUI.button(61, y, 16, 1, 0x333333, WHITE, 0x555555, WHITE, "Uvolnit závěr"))

    row.hradloBtn.onTouch = function()
        local routeId = rsel:pendingRouteFor(group)
        if not routeId then
            io.write("Pro " .. group .. " není vybrána žádná cesta (klikni na návěstidlo, pak na cílovou kolej).\n")
            return
        end
        network.send(map.network.peerAddress, map.network.port, "HRADLO_REQUEST", {routeId = routeId})
        rsel:markSent(group, routeId)
        rsel:clearPending(group)
        workspace:draw()
    end

    row.releaseBtn.onTouch = function()
        local routeId = rsel:activeRouteFor(group)
        if not routeId then
            return
        end
        if rsel:isGateActive(group) then
            io.write("Hradlo pro " .. group .. " je ještě aktivní na stavědle.\n")
            return
        end
        network.send(map.network.peerAddress, map.network.port, "LOCK_REQUEST", {routeId = routeId, action = "release"})
        workspace:draw()
    end

    rows[group] = row
end

--------------------------------------------------------------------------------
-- Network

-- GUI.label's draw doesn't clear its own background before drawing new text (see
-- grapes/GUI.lua's drawLabel), so setting a SHORTER string than what was there before leaves the
-- old text's tail visible past the end of the new one. Pad to the label's own width instead of
-- setting .text directly wherever it changes repeatedly.
local function setLabelText(label, str)
    local pad = label.width - unicode.len(str)
    label.text = pad > 0 and (str .. string.rep(" ", pad)) or str
end

local function driveGateClonka(group, active)
    local entry = map.gates[group]
    if not entry then
        return
    end
    lockboxdrv.setAspect(entry.hradloController, entry.hradloClonkaName, active and entry.hradloAspects.active or entry.hradloAspects.normal)
end

-- group (a running-line label like "T4") comes straight from the LOCK_STATE payload (see
-- stavedlo/init.lua) so DK can address its own local copy of that same line's clonka.
local function driveLockClonka(group, state)
    if not group then
        return
    end
    local entry = map.switchlock[group]
    if not entry then
        return
    end
    local aspectKey = (state == "locked") and "locked" or "normal"
    lockboxdrv.setAspect(entry.controller, entry.clonkaName, entry.aspects[aspectKey])
end

local function onNetworkMessage(msgType, payload, senderAddress)
    if msgType == "GATE_STATE" then
        rsel:onGateState(payload.group, payload.active)
        driveGateClonka(payload.group, payload.active)
        if not payload.active then
            local row = rows[payload.group]
            if row then
                setLabelText(row.stateLabel, "hradlo neaktivní")
            end
        end
    elseif msgType == "LOCK_STATE" then
        rsel:onLockState(payload.routeId, payload.state)
        driveLockClonka(payload.group, payload.state)
        if payload.state == "free" then
            for group, id in pairs(rsel.activeRouteByGroup) do
                if id == payload.routeId then
                    rsel:clearActive(group)
                end
            end
        end
    end
    workspace:draw()
end

if not component.isAvailable("modem") then
    io.write("Nenalezen žádný modem -- propojení se stavědlem nebude fungovat.\n")
else
    network.open(map.network.port)
end
network.install(workspace, map.network.port, onNetworkMessage)

--------------------------------------------------------------------------------

local routesById = {}
for _, r in ipairs(routesData.routes) do
    routesById[r.id] = r
end

-- See stavedlo/init.lua's comment: grapes/GUI.lua's own loop uses OpenComputers' built-in
-- "event" library internally, not grapes.Event, so the periodic tick has to be registered
-- through event.timer to actually run.
local event = require("event")
event.timer(1, function()
    for _, group in ipairs(routesData.groups) do
        local row = rows[group]
        local pending = rsel:pendingRouteFor(group)
        local active = rsel:activeRouteFor(group)
        if pending then
            local route = routesById[pending]
            setLabelText(row.stateLabel, "vybráno: " .. (route and routeDisplayText(route) or pending))
            row.stateLabel.colors.text = YELLOW
        elseif active then
            local route = routesById[active]
            local displayText = route and routeDisplayText(route) or active
            setLabelText(row.stateLabel, displayText .. " (" .. tostring(rsel.lockState[active] or "reserved") .. ")")
            row.stateLabel.colors.text = rsel:isGateActive(group) and GREEN or GRAY
        else
            setLabelText(row.stateLabel, "-")
            row.stateLabel.colors.text = GRAY
        end
    end
    workspace:draw()
end, math.huge)

workspace:draw()
workspace:start()
