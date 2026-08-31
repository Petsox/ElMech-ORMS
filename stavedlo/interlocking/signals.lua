-- Vjezdové/odjezdové návěstidlo: the entrance/exit signal only clears once its route's závěr
-- výměn is actually locked AND every crossing the route uses reports its arm physically down
-- (not just "commanded closed") -- step 3 of the design's sequence. restore() sets the signal
-- back to its wizard-confirmed stop state; there's no per-signal "most restrictive" call in the
-- digitalController API (setMostRestrictiveOnAll only applies to a whole controller at once), so
-- the stop state name is recorded per-signal by the setup wizard instead.
local signaldrv = require("hw.signaldrv")
local crossingdrv = require("hw.crossingdrv")

local signals = {}
signals.__index = signals

function signals.new(map, switchlockObj)
    local self = setmetatable({}, signals)
    self.map = map
    self.switchlock = switchlockObj
    return self
end

-- Signalista's entrance/exit signal lever.
function signals:clear(entranceName, routeId, state)
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

    return signaldrv.setState(self.map.signals[entranceName], entranceName, state)
end

function signals:restore(entranceName)
    local entry = self.map.signals[entranceName]
    if not entry or not entry.stopState then
        return false, "unmapped"
    end
    return signaldrv.setState(entry, entranceName, entry.stopState)
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
