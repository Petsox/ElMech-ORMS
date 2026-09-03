-- Návěstní hradlo + hradlová zarážka, one pair of clonky per traťová kolej GROUP (T1/T2/T4) --
-- shared between the arrival signal AND every departure signal that can reach that line,
-- confirmed by the user against the real hradlo count: it matches switchlock's own per-group
-- granularity (one lock/one hradlo per line, not per signal), since a departure signal can reach
-- more than one line depending on the route (see common/routes.lua's module doc comment) and a
-- real station only has as many physical hradlo relays as running lines, not one per signal.
--
-- Each main signal still has its OWN physical hradlová-zarážka detector (map.detectors[name] --
-- a train detector can only sense a train passing its own location) even though the clonka it
-- feeds into is shared; onDetect resolves a firing detector's signal name back to whichever
-- group currently has that signal as its active route's entrance.
--
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
    self.active = {}   -- [group] = {routeId = str, entrance = str, zarazka = bool}
    return self
end

function gate:isActive(group)
    return self.active[group] ~= nil
end

function gate:zarazkaActive(group)
    local st = self.active[group]
    return st ~= nil and st.zarazka
end

function gate:routeIdFor(group)
    local st = self.active[group]
    return st and st.routeId or nil
end

-- Which signal is currently "using" this group's hradlo -- needed to know which návěstidlo the
-- Stůj/Volno buttons should actually command.
function gate:entranceFor(group)
    local st = self.active[group]
    return st and st.entrance or nil
end

-- Which group (if any) currently has entranceName as its active route's entrance -- resolves a
-- firing detector (keyed by signal name, see map.detectors) back to a group.
function gate:groupForEntrance(entranceName)
    for group, st in pairs(self.active) do
        if st.entrance == entranceName then
            return group
        end
    end
    return nil
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

-- DK's hradlo lever press for routeId -- its group (which physical hradlo it needs) comes from
-- the route data itself.
function gate:activate(routeId)
    local route = self.switchlock.routesById[routeId]
    if not route then
        return false, "unknown_route"
    end
    local group = route.group
    if self.active[group] then
        return false, "already_active"
    end

    local ok, reason = self.switchlock:reserve(routeId)
    if not ok then
        return false, reason
    end

    self.active[group] = {routeId = routeId, entrance = route.entrance, zarazka = false}
    driveClonka(self.map.gates[group], "active")
    return true
end

-- Called from hw/detector.lua's handler once the sender address is matched (via map.detectors)
-- to a signal name.
function gate:onDetect(entranceName)
    local group = self:groupForEntrance(entranceName)
    if not group then
        return false
    end
    local st = self.active[group]
    if st.zarazka then
        return false
    end
    st.zarazka = true
    driveZarazka(self.map.gates[group], "active")
    return true
end

-- Signalista's hradlo lever release for a group.
function gate:deactivate(group)
    local st = self.active[group]
    if not st then
        return false, "not_active"
    end
    if not st.zarazka then
        return false, "zarazka_not_triggered"
    end

    self.active[group] = nil
    driveClonka(self.map.gates[group], "normal")
    driveZarazka(self.map.gates[group], "normal")
    return true
end

function gate:reset()
    for _, entry in pairs(self.map.gates) do
        driveClonka(entry, "normal")
        driveZarazka(entry, "normal")
    end
    self.active = {}
end

return gate
