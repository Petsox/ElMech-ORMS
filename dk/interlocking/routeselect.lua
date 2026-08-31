-- DK-side route selection: click an entrance (hlavní návěstidlo) then a destination Label to
-- pick a route, matching one entry from routes.json (each entrance+label pair maps to exactly
-- one precomputed route, see common/routes.lua). Several selections/hradla can be pending at
-- once, keyed by entranceName, since more than one hradlo can be worked in parallel. This module
-- only tracks selection + mirrored network state; it never talks to hardware or the network
-- itself -- dk/init.lua does both after consulting it, keeping this part testable in isolation.
local routeselect = {}
routeselect.__index = routeselect

function routeselect.new(routesData)
    local self = setmetatable({}, routeselect)
    self.routesData = routesData
    self.pendingEntrance = nil               -- entranceName waiting for a destination click
    self.pendingRouteByEntrance = {}          -- [entranceName] = routeId, selected but not yet sent
    self.activeRouteByEntrance = {}            -- [entranceName] = routeId, sent (HRADLO_REQUEST) and not yet fully released
    self.gateActive = {}                        -- [entranceName] = bool, mirrored via GATE_STATE
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
        self.pendingRouteByEntrance[entranceName] = route.id
    end
    return route, entranceName
end

function routeselect:pendingRouteFor(entranceName)
    return self.pendingRouteByEntrance[entranceName]
end

function routeselect:clearPending(entranceName)
    self.pendingRouteByEntrance[entranceName] = nil
end

-- Called once the HRADLO_REQUEST for a pending route has actually been sent -- keeps the routeId
-- around under activeRouteByEntrance so the later "uvolnit závěr" action still knows which route
-- to reference, even though the selection itself (pendingRouteByEntrance) is cleared right after
-- sending (see dk/init.lua).
function routeselect:markSent(entranceName, routeId)
    self.activeRouteByEntrance[entranceName] = routeId
end

function routeselect:activeRouteFor(entranceName)
    return self.activeRouteByEntrance[entranceName]
end

function routeselect:clearActive(entranceName)
    self.activeRouteByEntrance[entranceName] = nil
end

function routeselect:onGateState(entranceName, active)
    self.gateActive[entranceName] = active
end

function routeselect:isGateActive(entranceName)
    return self.gateActive[entranceName] == true
end

function routeselect:onLockState(routeId, state)
    self.lockState[routeId] = state
end

return routeselect
