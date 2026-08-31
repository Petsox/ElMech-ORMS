-- Závěr výměn: a shared pool of routesData.lockCount lock "slots", sized at setup time (see
-- common/routes.lua) as the largest set of routes that can ever be simultaneously non-conflicting
-- across this zhlaví. Two-phase per route, matching the design's sequence:
--   1. reserve(routeId)     -- návěstní hradlo activation (gate.lua): claims a slot if the route
--                               doesn't conflict with any other currently reserved/locked route.
--                               This is the actual "kolik vlakových cest najednou" conflict check.
--   2. confirmLock(routeId) -- signalista's "uzamčení závěru výměn" button: verifies the physical
--                               switch positions match the route and turns the clonka green /
--                               closes crossings.
--   3. release(routeId)     -- DK's unlock action, itself only permitted once gate.lua reports
--                               the hradlo already inactive: frees the slot, clonka back to
--                               white, opens crossings.
-- A slot stays held from reserve() through confirmLock() until release() -- hradlo turning off
-- (step 4/5 of the design) does NOT free it by itself, only the explicit DK unlock does; that is
-- what keeps a conflicting route locked out for the whole time a signalman could still need to
-- re-open the crossing/relock, exactly matching the real electromechanical behaviour.
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
    self.slotCount = routesData.lockCount
    self.slots = {}          -- [routeId] = {state = "reserved"|"locked", slotIndex = n}
    self.occupied = {}         -- [slotIndex] = routeId
    return self
end

function switchlock:state(routeId)
    local s = self.slots[routeId]
    return s and s.state or "free"
end

function switchlock:slotIndexFor(routeId)
    local s = self.slots[routeId]
    return s and s.slotIndex or nil
end

-- Whether switchCode is used by any currently reserved/locked route -- the kolejový závěrník
-- blocking manual relever while true. init.lua's switch-poll loop consults this before ever
-- applying a lever movement to the physical switch motor. Also true when a spojená výhybka
-- sharing this switch's lever is itself locked (see componentmap.leverGroup) -- the lever can't
-- move independently of that group-mate, so it must be blocked here too even if this exact
-- switch code isn't named by any active route.
function switchlock:isSwitchLocked(switchCode)
    for _, code in ipairs(componentmap.leverGroup(self.map, switchCode)) do
        for routeId in pairs(self.slots) do
            local route = self.routesById[routeId]
            if route.switches[code] then
                return true
            end
        end
    end
    return false
end

local function firstFreeSlot(self)
    for i = 1, self.slotCount do
        if not self.occupied[i] then
            return i
        end
    end
    return nil
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

    local mySet = self.cellSets[routeId]
    for otherId in pairs(self.slots) do
        if cellSetsConflict(mySet, self.cellSets[otherId]) then
            return false, "conflict"
        end
    end

    local slot = firstFreeSlot(self)
    if not slot then
        return false, "no_free_lock"
    end

    self.slots[routeId] = {state = "reserved", slotIndex = slot}
    self.occupied[slot] = routeId
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

-- Signalista's "uzamčení závěru výměn" button. Requires the route to already be reserved
-- (hradlo active) and every switch it uses to physically sit in the position the route needs.
function switchlock:confirmLock(routeId)
    local slot = self.slots[routeId]
    if not slot or slot.state ~= "reserved" then
        return false, "not_reserved"
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

    local lockEntry = self.map.switchlock[tostring(slot.slotIndex)]
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

    local lockEntry = self.map.switchlock[tostring(slot.slotIndex)]
    if lockEntry then
        lockboxdrv.setAspect(lockEntry.controller, lockEntry.clonkaName, lockEntry.aspects.normal)
    end

    self.occupied[slot.slotIndex] = nil
    self.slots[routeId] = nil
    return true
end

-- Boot reset: releases every slot unconditionally and drives every configured clonka + crossing
-- back to its idle state, regardless of in-memory state (which starts empty anyway on a fresh
-- boot, but the physical world may not).
function switchlock:reset()
    for slotIndex = 1, self.slotCount do
        local lockEntry = self.map.switchlock[tostring(slotIndex)]
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
