-- Závěr výměn: one lock per traťová kolej (running-line group, e.g. "T1"/"T2"/"T4" -- see
-- common/routes.lua's grouping), not a generically-sized pool. Two-phase per route, matching the
-- design's sequence:
--   1. reserve(routeId)     -- návěstní hradlo activation (gate.lua): claims that route's group's
--                               lock if it isn't already held by a different route. A defense-in-
--                               depth cellSet check also runs here in case two groups were ever
--                               misconfigured to overlap physically.
--   2. confirmLock(routeId) -- signalista's "uzamčení závěru výměn" button: requires the
--                               kolejový závěrník lever for this specific route to be engaged
--                               (the mechanical route-lock the user described -- a signalman
--                               throws it after setting the switches, and only then may the
--                               závěr výměn itself be locked), then verifies the physical switch
--                               positions match the route, and turns the clonka green / closes
--                               crossings.
--   3. release(routeId)     -- DK's unlock action, itself only permitted once gate.lua reports
--                               the hradlo already inactive: frees the group's lock, clonka back
--                               to white, opens crossings.
-- The lock stays held from reserve() through confirmLock() until release() -- hradlo turning off
-- (step 4/5 of the design) does NOT free it by itself, only the explicit DK unlock does; that is
-- what keeps a conflicting route on the same line locked out for the whole time a signalman
-- could still need to re-open the crossing/relock, exactly matching the real electromechanical
-- behaviour.
local switchdrv = require("hw.switchdrv")
local switchio = require("hw.switchio")
local crossingdrv = require("hw.crossingdrv")
local lockboxdrv = require("hw.lockboxdrv")
local componentmap = require("componentmap")

local switchlock = {}
switchlock.__index = switchlock

local function cellKey(x, y)
    return x .. "," .. y
end

local function cellSetOf(route)
    local set = {}
    for _, c in ipairs(route.cells) do
        set[cellKey(c.x, c.y)] = true
    end
    return set
end

local function cellSetsConflict(a, b)
    for k in pairs(a) do
        if b[k] then
            return true
        end
    end
    return false
end

-- routesData: loaded common/routes.json (routes.load). map: componentmap.load result.
function switchlock.new(routesData, map)
    local self = setmetatable({}, switchlock)
    self.routesData = routesData
    self.map = map
    self.routesById = {}
    self.cellSets = {}
    for _, r in ipairs(routesData.routes) do
        self.routesById[r.id] = r
        self.cellSets[r.id] = cellSetOf(r)
    end
    self.slots = {}       -- [routeId] = {state = "reserved"|"locked", group = runningLineLabel}
    self.occupied = {}      -- [runningLineLabel] = routeId
    return self
end

function switchlock:state(routeId)
    local s = self.slots[routeId]
    return s and s.state or "free"
end

function switchlock:groupFor(routeId)
    local s = self.slots[routeId]
    if s then
        return s.group
    end
    local route = self.routesById[routeId]
    return route and route.group or nil
end

-- Whether switchCode is used by a route whose závěr výměn is already LOCKED (state=="locked",
-- i.e. confirmLock has run) -- this, not mere reservation, is the kolejový závěrník that blocks
-- manual relever. A route that's only "reserved" (hradlo active) must still let the signalista
-- physically set its switches -- that's the whole point of that phase -- so this deliberately
-- does not block on "reserved". init.lua's switch-poll loop consults this before ever applying a
-- lever movement to the physical switch motor. Also true when a spojená výhybka sharing this
-- switch's lever is itself locked (see componentmap.leverGroup) -- the lever can't move
-- independently of that group-mate, so it must be blocked here too even if this exact switch
-- code isn't named by any locked route.
function switchlock:isSwitchLocked(switchCode)
    for _, code in ipairs(componentmap.leverGroup(self.map, switchCode)) do
        for routeId, slot in pairs(self.slots) do
            if slot.state == "locked" then
                local route = self.routesById[routeId]
                if route.switches[code] then
                    return true
                end
            end
        end
    end
    return false
end

-- Called by gate.lua when a návěstní hradlo activates. Returns ok, reason.
function switchlock:reserve(routeId)
    local route = self.routesById[routeId]
    if not route then
        return false, "unknown_route"
    end
    if self.slots[routeId] then
        return false, "already_reserved"
    end
    if not route.group then
        return false, "no_group"
    end
    if self.occupied[route.group] then
        return false, "group_busy"
    end

    local mySet = self.cellSets[routeId]
    for otherId in pairs(self.slots) do
        if cellSetsConflict(mySet, self.cellSets[otherId]) then
            return false, "conflict"
        end
    end

    self.slots[routeId] = {state = "reserved", group = route.group}
    self.occupied[route.group] = routeId
    return true
end

local function leverMatchesRoute(self, route)
    for switchName, requiredIcon in pairs(route.switches) do
        local icons = self.routesData.switchIcons[switchName]
        local entry = componentmap.resolveLeverEntry(self.map, switchName)
        if not icons or not entry then
            return false, switchName
        end
        local wantPlus = requiredIcon == icons.toggled
        local actual, err = switchio.readLever(entry)
        if actual == nil then
            return false, switchName .. " (" .. tostring(err) .. ")"
        end
        if actual ~= wantPlus then
            return false, switchName
        end
    end
    return true
end

-- Signalista's "uzamčení závěru výměn" button. Requires: the route to already be reserved
-- (hradlo active), its kolejový závěrník lever to be engaged (mechanically confirms this
-- specific route, not just "some route on this line"), and every switch it uses to physically
-- sit in the position the route needs.
function switchlock:confirmLock(routeId)
    local slot = self.slots[routeId]
    if not slot or slot.state ~= "reserved" then
        return false, "not_reserved"
    end

    local routeLockEntry = self.map.routeLocks[routeId]
    local engaged = routeLockEntry and switchio.readLever(routeLockEntry)
    if not engaged then
        return false, "route_lock_not_engaged"
    end

    local route = self.routesById[routeId]
    local ok, badSwitch = leverMatchesRoute(self, route)
    if not ok then
        return false, "switch_mismatch:" .. tostring(badSwitch)
    end

    -- Drive the physical switch motors to match (idempotent -- they should already be there).
    for switchName, requiredIcon in pairs(route.switches) do
        local icons = self.routesData.switchIcons[switchName]
        switchdrv.setPosition(self.map.switches[switchName], requiredIcon == icons.toggled)
    end

    for crossingName in pairs(route.crossings) do
        crossingdrv.activate(self.map.crossings[crossingName], crossingName, true)
    end

    slot.state = "locked"

    local lockEntry = self.map.switchlock[slot.group]
    if lockEntry then
        lockboxdrv.setAspect(lockEntry.controller, lockEntry.clonkaName, lockEntry.aspects.locked)
    end

    return true
end

-- DK's deactivation of závěr výměn. gateIsInactive must be computed by the caller (checking
-- gate.lua's state for this route's entrance) so this module never has to know about hradlo
-- state directly.
function switchlock:release(routeId, gateIsInactive)
    local slot = self.slots[routeId]
    if not slot then
        return false, "not_locked"
    end
    if not gateIsInactive then
        return false, "gate_still_active"
    end

    local route = self.routesById[routeId]
    for crossingName in pairs(route.crossings) do
        crossingdrv.activate(self.map.crossings[crossingName], crossingName, false)
    end

    local lockEntry = self.map.switchlock[slot.group]
    if lockEntry then
        lockboxdrv.setAspect(lockEntry.controller, lockEntry.clonkaName, lockEntry.aspects.normal)
    end

    self.occupied[slot.group] = nil
    self.slots[routeId] = nil
    return true
end

-- Boot reset: releases every lock unconditionally and drives every configured clonka + crossing
-- back to its idle state, regardless of in-memory state (which starts empty anyway on a fresh
-- boot, but the physical world may not).
function switchlock:reset()
    for _, group in ipairs(self.routesData.groups or {}) do
        local lockEntry = self.map.switchlock[group]
        if lockEntry then
            lockboxdrv.setAspect(lockEntry.controller, lockEntry.clonkaName, lockEntry.aspects.normal)
        end
    end
    for _, entry in pairs(self.map.crossings) do
        crossingdrv.resetController(entry.controller)
    end
    self.slots = {}
    self.occupied = {}
end

return switchlock
