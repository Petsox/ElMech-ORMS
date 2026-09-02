-- Stavědlo entry point: loads the layout + saved mapping/routes (setup.lua must have run
-- already), resets everything to idle, draws a diagnostic track diagram + a hlavní návěstidla
-- control panel, and runs the poll loop that both mirrors hardware state into the GUI and
-- applies Control Panel lever movements to the actual SignalCraft switch motors.
--
-- Per the design: the diagram itself is NOT how switches are operated (that's the physical
-- Control Panel, see hw/switchio.lua) -- it is read-only diagnostics. The few actions that the
-- user's spec didn't explicitly tie to a Control Panel (uzamčení závěru výměn, signal levers,
-- hradlo deactivation) are implemented as GUI buttons in the control panel below the diagram;
-- if a physical panel is wanted for those too they can be wired the same way switches are, this
-- was a scope simplification for the first iteration -- flagged in the design plan's
-- verification section.
local GUI = require("grapes.GUI")
local screen = require("grapes.Screen")
local text = require("text")
local unicode = require("unicode")
local filesystem = require("filesystem")
local component = require("component")

local layout = require("layout")
local routesLib = require("routes")
local componentmap = require("componentmap")
local network = require("network")
local switchio = require("hw.switchio")
local switchdrv = require("hw.switchdrv")
local crossingdrv = require("hw.crossingdrv")
local detector = require("hw.detector")
local switchlock = require("interlocking.switchlock")
local gate = require("interlocking.gate")
local signalsCtl = require("interlocking.signals")

local DATA_DIR = "/home/stavedlo/data"
-- Must match setup.lua's STATION_PATH; called station.lua (not layout.lua) to stay clear of
-- common/layout.lua, the graph/pathfinding module installed alongside it.
local STATION_PATH = "/home/stavedlo/station.lua"
local ROUTES_PATH = DATA_DIR .. "/routes.json"
local MAP_PATH = DATA_DIR .. "/componentmap.json"

if not filesystem.exists(MAP_PATH) or not filesystem.exists(ROUTES_PATH) then
    io.write("Systém není nastaven. Spusť nejprve /home/stavedlo/setup.lua.\n")
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

local lock = switchlock.new(routesData, map)
local gateCtl = gate.new(map, lock)
local sig = signalsCtl.new(map, lock)

lock:reset()
gateCtl:reset()
sig:reset()

local mainSignals = {}
for _, s in ipairs(config.Signals or {}) do
    local mapped = map.signals[s[3]]
    if mapped and mapped.kind == "main" then
        mainSignals[#mainSignals + 1] = s
    end
end

--------------------------------------------------------------------------------
-- GUI

-- grapes' own double-buffer diffing assumes the physical screen already matches its internal
-- "blank" state, which is only true right after a fresh OC boot -- restarting the program within
-- the same session (e.g. after the installer's own shell output) leaves stale text on screen that
-- grapes never notices needs overwriting. A raw GPU fill bypasses that diffing and forces an
-- actual blank screen before grapes draws anything.
do
    local gpu = component.gpu
    local w, h = gpu.getResolution()
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
end

local workspace = GUI.workspace()
local GRAY, WHITE, RED, GREEN, YELLOW, BLUE = 0xB2B2B2, 0xFFFFFF, 0xFF4040, 0x40FF40, 0xFFFF40, 0x4090FF

workspace:addChild(GUI.label(1, 1, workspace.width, 1, WHITE, "Stavědlo -- diagnostika"):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP))

local switchObjects = {}     -- [code] = gui text object
local crossingObjects = {}    -- [name] = array of gui text objects
local signalObjects = {}       -- [name] = gui text object

for _, t in ipairs(config.Tracks or {}) do
    workspace:addChild(GUI.text(t[1], t[2], GRAY, text.trim(t[3]) or ""))
end

for _, s in ipairs(config.Switches or {}) do
    local obj = workspace:addChild(GUI.text(s[1], s[2], GRAY, text.trim(s[3]) or ""))
    switchObjects[s[5]] = {obj = obj, cfg = s}
end

for _, c in ipairs(config.Crossings or {}) do
    local obj = workspace:addChild(GUI.text(c[1], c[2], GRAY, text.trim(c[3]) or ""))
    crossingObjects[c[5]] = crossingObjects[c[5]] or {}
    table.insert(crossingObjects[c[5]], {obj = obj, cfg = c})
end

for _, s in ipairs(config.Signals or {}) do
    local mapped = map.signals[s[3]]
    local color = (mapped and mapped.kind == "main") and BLUE or GRAY
    local obj = workspace:addChild(GUI.text(s[1], s[2], color, s[4]))
    signalObjects[s[3]] = obj
end

for _, l in ipairs(config.Labels or {}) do
    workspace:addChild(GUI.text(l[1], l[2], WHITE, l[3]))
end

-- Control panel: one row per hlavní návěstidlo, placed below the diagram.
local panelY = 40
workspace:addChild(GUI.label(1, panelY, workspace.width, 1, WHITE, "Hlavní návěstidla"))

local rows = {}
for i, s in ipairs(mainSignals) do
    local name = s[3]
    local y = panelY + i
    local row = {}
    row.nameLabel = workspace:addChild(GUI.label(1, y, 10, 1, WHITE, name))
    row.stateLabel = workspace:addChild(GUI.label(12, y, 22, 1, GRAY, "-"))
    row.lockBtn = workspace:addChild(GUI.button(35, y, 8, 1, 0x333333, WHITE, 0x555555, WHITE, "Zámek"))
    row.stopBtn = workspace:addChild(GUI.button(44, y, 8, 1, 0x333333, WHITE, 0x555555, WHITE, "Stůj"))
    row.clearBtn = workspace:addChild(GUI.button(53, y, 8, 1, 0x333333, WHITE, 0x555555, WHITE, "Volno"))
    row.hradloOffBtn = workspace:addChild(GUI.button(62, y, 14, 1, 0x333333, WHITE, 0x555555, WHITE, "Hradlo pryč"))

    row.lockBtn.onTouch = function()
        local routeId = gateCtl:routeIdFor(name)
        if not routeId then
            return
        end
        local ok, err = lock:confirmLock(routeId)
        if ok then
            network.send(map.network.peerAddress, map.network.port, "LOCK_STATE",
                {routeId = routeId, state = lock:state(routeId), group = lock:groupFor(routeId)})
        else
            io.write("Zámek " .. name .. ": " .. tostring(err) .. "\n")
        end
        workspace:draw()
    end

    row.stopBtn.onTouch = function()
        sig:restore(name)
        workspace:draw()
    end

    row.clearBtn.onTouch = function()
        local routeId = gateCtl:routeIdFor(name)
        if not routeId then
            return
        end
        local ok, err = sig:clear(name, routeId)
        if not ok then
            io.write("Návěst " .. name .. ": " .. tostring(err) .. "\n")
        end
        workspace:draw()
    end

    row.hradloOffBtn.onTouch = function()
        local routeId = gateCtl:routeIdFor(name)
        local ok, err = gateCtl:deactivate(name)
        if ok then
            sig:restore(name)
            network.send(map.network.peerAddress, map.network.port, "GATE_STATE", {entrance = name, active = false})
        else
            io.write("Hradlo " .. name .. ": " .. tostring(err) .. "\n")
        end
        workspace:draw()
    end

    rows[name] = row
end

--------------------------------------------------------------------------------
-- Network + detector: composed into one workspace-level handler (grapes forwards every raw
-- signal to it regardless of type -- see common/network.lua's doc comment).

local function onNetworkMessage(msgType, payload, senderAddress)
    if msgType == "HRADLO_REQUEST" then
        local ok, reason = gateCtl:activate(payload.entrance, payload.routeId)
        network.send(senderAddress, map.network.port, "GATE_STATE", {entrance = payload.entrance, active = ok, reason = reason})
    elseif msgType == "LOCK_REQUEST" and payload.action == "release" then
        local route = lock.routesById[payload.routeId]
        local entranceName = route and route.entrance
        local gateInactive = entranceName == nil or not gateCtl:isActive(entranceName)
        local group = lock:groupFor(payload.routeId)
        local ok, reason = lock:release(payload.routeId, gateInactive)
        network.send(senderAddress, map.network.port, "LOCK_STATE",
            {routeId = payload.routeId, state = lock:state(payload.routeId), group = group, ok = ok, reason = reason})
    end
end

local detectorByAddress = {}
for name, entry in pairs(map.gates) do
    if entry.detectorAddress then
        detectorByAddress[entry.detectorAddress] = name
    end
end

local function onDetect(senderAddress)
    local entranceName = detectorByAddress[senderAddress]
    if entranceName then
        gateCtl:onDetect(entranceName)
    end
end

if not component.isAvailable("modem") then
    io.write("Nenalezen žádný modem -- propojení s DK nebude fungovat.\n")
else
    network.open(map.network.port)
end
local netHandler = network.makeHandler(map.network.port, onNetworkMessage)
local detHandler = detector.makeHandler(onDetect)
workspace.eventHandler = function(ws, obj, ...)
    netHandler(...)
    detHandler(...)
end

--------------------------------------------------------------------------------
-- Poll loop: mirrors hardware into the GUI, and applies Control Panel lever movements to the
-- actual switch motors (blocked while the switch is inside a locked/reserved route). Spojené
-- výhybky (map.switches[code].leverOwner set) share one physical lever AND one physical
-- indicator lamp -- both are only ever read/driven once per group, off the owner's entry, while
-- the resulting position is still applied to every member's own motor (each still has its own
-- controller/receiverName).

local lastLever = {}
local reportedLeverErrors = {}

local function pollSwitches()
    for code, entry in pairs(map.switches) do
        if not entry.leverOwner then
            local reading, err = switchio.readLever(entry)
            if reading == nil then
                if not reportedLeverErrors[code] then
                    reportedLeverErrors[code] = true
                    io.write("Výhybka " .. code .. ": nelze přečíst páčku (" .. tostring(err) .. ") -- zkontroluj Redstone I/O/stranu/barvu v setup.lua.\n")
                end
            elseif lastLever[code] == nil or reading ~= lastLever[code] then
                if not lock:isSwitchLocked(code) then
                    for _, memberCode in ipairs(componentmap.leverGroup(map, code)) do
                        local ok, driveErr = switchdrv.setPosition(map.switches[memberCode], reading)
                        if not ok and not reportedLeverErrors["drive:" .. memberCode] then
                            reportedLeverErrors["drive:" .. memberCode] = true
                            io.write("Výhybka " .. memberCode .. ": nelze přestavit motor (" .. tostring(driveErr) .. ") -- zkontroluj digitalUnivController/jméno receiveru.\n")
                        end
                        lastLever[memberCode] = reading
                    end
                    -- One indicator per lever group (one physical lamp for the shared lever),
                    -- never per switch -- see componentmap.resolveIndicatorEntry's doc comment.
                    switchio.setIndicator(componentmap.resolveIndicatorEntry(map, code), reading)
                end
            end
        end
    end
end

-- GUI.label's draw doesn't clear its own background before drawing new text (see
-- grapes/GUI.lua's drawLabel), so setting a SHORTER string than what was there before leaves the
-- old text's tail visible past the end of the new one. Pad to the label's own width instead of
-- setting .text directly wherever it changes repeatedly.
local function setLabelText(label, str)
    local pad = label.width - unicode.len(str)
    label.text = pad > 0 and (str .. string.rep(" ", pad)) or str
end

local function refreshDiagram()
    for code, sw in pairs(switchObjects) do
        local plus = lastLever[code]
        sw.obj.text = plus and sw.cfg[4] or sw.cfg[3]
        sw.obj.color = lock:isSwitchLocked(code) and YELLOW or GRAY
        sw.obj:update()
    end

    for name, entries in pairs(crossingObjects) do
        local entry = map.crossings[name]
        local closed = entry and crossingdrv.isClosed(entry, name)
        for _, e in ipairs(entries) do
            e.obj.color = closed and RED or GRAY
        end
    end

    for _, s in ipairs(mainSignals) do
        local name = s[3]
        local row = rows[name]
        local routeId = gateCtl:routeIdFor(name)
        local state = lock:state(routeId or "")
        local label = "-"
        local color = GRAY
        if routeId then
            label = routeId .. " (" .. state .. ")"
            color = state == "locked" and GREEN or YELLOW
        end
        setLabelText(row.stateLabel, label)
        row.stateLabel.colors.text = color
        signalObjects[name].color = color
    end
end

-- grapes/GUI.lua's own workspace:start() loop calls OpenComputers' real "event" library's
-- event.pull() internally (confirmed: GUI.lua's own top-level require is "event", not
-- "grapes.Event") -- registering a periodic tick through grapes.Event.addHandler instead, as
-- this used to, is a completely separate handler table that GUI's loop never consults, so it
-- silently never fires even though touch/network signals keep working fine (those are raw OC
-- signals GUI's loop does see). event.timer is the built-in library's own equivalent and DOES
-- integrate with that same loop.
local event = require("event")
event.timer(0.5, function()
    pollSwitches()
    refreshDiagram()
    workspace:draw()
end, math.huge)

workspace:draw()
workspace:start()
