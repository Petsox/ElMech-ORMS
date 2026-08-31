-- Návěstní hradlo + hradlová zarážka, one pair of clonky per hlavní (entrance/odjezdové) signal.
-- Pure interlocking state -- no network I/O here; stavedlo/init.lua calls into this after a
-- lever/button press or an incoming HRADLO_REQUEST, then broadcasts GATE_STATE itself so this
-- module stays testable independent of the network layer.
--
-- activate() is also where the route-conflict check actually happens (via switchlock:reserve),
-- matching step 1 of the design's domain-logic sequence: "Pokud je cestu možné postavit [does
-- not cross another currently active route], hradlo se aktivuje". deactivate() deliberately
-- requires the hradlová zarážka to already be active (i.e. the train has actually crossed the
-- mapped TileDigitalDetector) -- the design only ever describes deactivating hradlo AFTER the
-- zarážka fired, so this is enforced rather than left to operator discipline; there is
-- deliberately no cancel-before-the-train-arrives path in this first iteration (see the plan's
-- "Odloženo" section -- route cancellation belongs with posun/multi-throat work later).
local lockboxdrv = require("hw.lockboxdrv")

local gate = {}
gate.__index = gate

function gate.new(map, switchlockObj)
    local self = setmetatable({}, gate)
    self.map = map
    self.switchlock = switchlockObj
    self.active = {}   -- [entranceName] = {routeId = str, zarazka = bool}
    return self
end

function gate:isActive(entranceName)
    return self.active[entranceName] ~= nil
end

function gate:zarazkaActive(entranceName)
    local st = self.active[entranceName]
    return st ~= nil and st.zarazka
end

function gate:routeIdFor(entranceName)
    local st = self.active[entranceName]
    return st and st.routeId or nil
end

local function driveClonka(entry, aspectKey)
    if not entry then
        return
    end
    lockboxdrv.setAspect(entry.hradloController, entry.hradloClonkaName, entry.hradloAspects[aspectKey])
end

local function driveZarazka(entry, aspectKey)
    if not entry then
        return
    end
    lockboxdrv.setAspect(entry.zarazkaController, entry.zarazkaClonkaName, entry.zarazkaAspects[aspectKey])
end

-- DK's hradlo lever press.
function gate:activate(entranceName, routeId)
    if self.active[entranceName] then
        return false, "already_active"
    end

    local ok, reason = self.switchlock:reserve(routeId)
    if not ok then
        return false, reason
    end

    self.active[entranceName] = {routeId = routeId, zarazka = false}
    driveClonka(self.map.gates[entranceName], "active")
    return true
end

-- Called from hw/detector.lua's handler once the sender address is matched to an entranceName.
function gate:onDetect(entranceName)
    local st = self.active[entranceName]
    if not st or st.zarazka then
        return false
    end
    st.zarazka = true
    driveZarazka(self.map.gates[entranceName], "active")
    return true
end

-- Signalista's hradlo lever release.
function gate:deactivate(entranceName)
    local st = self.active[entranceName]
    if not st then
        return false, "not_active"
    end
    if not st.zarazka then
        return false, "zarazka_not_triggered"
    end

    self.active[entranceName] = nil
    driveClonka(self.map.gates[entranceName], "normal")
    driveZarazka(self.map.gates[entranceName], "normal")
    return true
end

function gate:reset()
    for entranceName, entry in pairs(self.map.gates) do
        driveClonka(entry, "normal")
        driveZarazka(entry, "normal")
    end
    self.active = {}
end

return gate
