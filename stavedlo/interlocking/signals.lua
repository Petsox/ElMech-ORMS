-- Vjezdové/odjezdové návěstidlo: the entrance/exit signal only clears once its route's závěr
-- výměn is actually locked AND every crossing the route uses reports its arm physically down
-- (not just "commanded closed") -- step 3 of the design's sequence.
--
-- State NAMES are never asked from the user (setup.lua has no prompt for them at all) -- checked
-- against ORMS (github.com/Petsox/Open-Rail-Management-System, automatic-route-building branch),
-- which hardcodes exactly the same fixed SignalCraft vocabulary ("Stuj", "Volno", "R40Volno", ...)
-- throughout its own code rather than configuring it per station. "Stuj" is the universal stop
-- state; a cleared main signal shows "Volno" for a straight route, or "R40Volno" for a diverging
-- one if that signal actually supports it (matching ORMS's defaultCurveState/chooseProceedState:
-- not every signal has an R40 variant, so this is confirmed live via getValidStatesForSignal and
-- falls back to plain "Volno" when it isn't offered).
local signaldrv = require("hw.signaldrv")
local crossingdrv = require("hw.crossingdrv")
local component = require("component")

local signals = {}
signals.__index = signals

signals.STUJ = "Stuj"
signals.VOLNO = "Volno"

function signals.new(map, switchlockObj)
    local self = setmetatable({}, signals)
    self.map = map
    self.switchlock = switchlockObj
    return self
end

local function hasValidState(entry, signalName, wantedState)
    if not entry or not entry.controller then
        return false
    end
    local ok, proxy = pcall(component.proxy, entry.controller)
    if not ok then
        return false
    end
    local okStates, states = pcall(proxy.getValidStatesForSignal, signalName)
    if not okStates or type(states) ~= "table" then
        return false
    end
    for _, s in pairs(states) do
        if tostring(s):lower() == wantedState:lower() then
            return true
        end
    end
    return false
end

-- Signalista's entrance/exit signal lever.
function signals:clear(entranceName, routeId)
    if self.switchlock:state(routeId) ~= "locked" then
        return false, "not_locked"
    end

    local route = self.switchlock.routesById[routeId]
    for crossingName in pairs(route.crossings) do
        local closed, err = crossingdrv.isClosed(self.map.crossings[crossingName], crossingName)
        if not closed then
            return false, "crossing_not_closed:" .. crossingName .. (err and (" (" .. tostring(err) .. ")") or "")
        end
    end

    local entry = self.map.signals[entranceName]
    local state = signals.VOLNO
    if not route.allStraight and hasValidState(entry, entranceName, "R40Volno") then
        state = "R40Volno"
    end

    return signaldrv.setState(entry, entranceName, state)
end

function signals:restore(entranceName)
    return signaldrv.setState(self.map.signals[entranceName], entranceName, signals.STUJ)
end

function signals:reset()
    local seenControllers = {}
    for _, entry in pairs(self.map.signals) do
        if entry.controller and not seenControllers[entry.controller] then
            seenControllers[entry.controller] = true
            signaldrv.resetController(entry.controller)
        end
    end
end

return signals
