-- digitalController (signalcraft_controller) wrapper: sets/reads hlavní/předvěst/posunové
-- návěstidla state by name.
local component = require("component")

local signaldrv = {}

-- entry = componentmap.signals[name] = {controller=addr, kind=...}
function signaldrv.setState(entry, signalName, state)
    if not entry or not entry.controller then
        return false, "unmapped"
    end
    local ok, proxy = pcall(component.proxy, entry.controller)
    if not ok then
        return false, proxy
    end
    local callOk, result = pcall(proxy.setState, signalName, state)
    if not callOk then
        return false, result
    end
    return result == true
end

function signaldrv.getState(entry, signalName)
    if not entry or not entry.controller then
        return nil, "unmapped"
    end
    local ok, proxy = pcall(component.proxy, entry.controller)
    if not ok then
        return nil, proxy
    end
    local callOk, result = pcall(proxy.getState, signalName)
    if not callOk then
        return nil, result
    end
    return result
end

-- Applies the most restrictive valid state to every signal on a controller -- used at boot reset.
function signaldrv.resetController(controllerAddress)
    local ok, proxy = pcall(component.proxy, controllerAddress)
    if not ok then
        return false, proxy
    end
    local callOk, result = pcall(proxy.setMostRestrictiveOnAll)
    if not callOk then
        return false, result
    end
    return true
end

return signaldrv
