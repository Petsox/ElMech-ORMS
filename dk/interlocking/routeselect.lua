-- DK-side route selection: click an entrance (hlavní návěstidlo) then a destination Label to
-- pick a route, matching one entry from routes.json (each entrance+label pair maps to exactly
-- one precomputed route, see common/routes.lua). Pending/active selections are tracked by
-- traťová kolej GROUP, not by entrance signal -- a hradlo is shared between every arrival and
-- departure signal on that line (confirmed by the user against the real hradlo count), so
-- what's actually being requested/held is "this group's hradlo", regardless of which specific
-- signal a given click happened to start from. Several groups can be pending/active at once.
-- This module only tracks selection + mirrored network state; it never talks to hardware or the
-- network itself -- dk/init.lua does both after consulting it, keeping this part testable in
-- isolation.
local routeselect = {}
routeselect.__index = routeselect

function routeselect.new(routesData)
    local self = setmetatable({}, routeselect)
    self.routesData = routesData
    self.pendingEntrance = nil               -- entranceName waiting for a destination click
    self.pendingRouteByGroup = {}             -- [group] = routeId, selected but not yet sent
    self.activeRouteByGroup = {}               -- [group] = routeId, sent (HRADLO_REQUEST) and not yet fully released
    self.gateActive = {}                        -- [group] = bool, mirrored via GATE_STATE
    self.lockState = {}                           -- [routeId] = "reserved"|"locked", mirrored via LOCK_STATE
    return self
end

function routeselect:findRoute(entranceName, labelText)
    for _, r in ipairs(self.routesData.routes) do
        if r.entrance == entranceName and r.label == labelText then
            return r
        end
    end
    return nil
end

-- First click of the pair: an entrance (hlavní) signal on the diagram.
function routeselect:clickEntrance(entranceName)
    self.pendingEntrance = entranceName
end

-- Second click: a destination Label. Returns the resolved route (or nil if entrance/label don't
-- connect) and the entranceName the selection was for.
function routeselect:clickLabel(labelText)
    if not self.pendingEntrance then
        return nil
    end
    local entranceName = self.pendingEntrance
    self.pendingEntrance = nil

    local route = self:findRoute(entranceName, labelText)
    if route then
        self.pendingRouteByGroup[route.group] = route.id
    end
    return route, entranceName
end

function routeselect:pendingRouteFor(group)
    return self.pendingRouteByGroup[group]
end

function routeselect:clearPending(group)
    self.pendingRouteByGroup[group] = nil
end

-- Called once the HRADLO_REQUEST for a pending route has actually been sent -- keeps the routeId
-- around under activeRouteByGroup so the later "uvolnit závěr" action still knows which route to
-- reference, even though the selection itself (pendingRouteByGroup) is cleared right after
-- sending (see dk/init.lua).
function routeselect:markSent(group, routeId)
    self.activeRouteByGroup[group] = routeId
end

function routeselect:activeRouteFor(group)
    return self.activeRouteByGroup[group]
end

function routeselect:clearActive(group)
    self.activeRouteByGroup[group] = nil
end

function routeselect:onGateState(group, active)
    self.gateActive[group] = active
end

function routeselect:isGateActive(group)
    return self.gateActive[group] == true
end

function routeselect:onLockState(routeId, state)
    self.lockState[routeId] = state
end

return routeselect
