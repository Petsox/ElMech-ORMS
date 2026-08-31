-- digitalCrossController (signalcraft_crossing_controller) wrapper: lowers/raises přejezd
-- barriers by name.
local component = require("component")

local crossingdrv = {}

-- entry = componentmap.crossings[name] = {controller=addr}
function crossingdrv.activate(entry, crossingName, closed)
    if not entry or not entry.controller then
        return false, "unmapped"
    end
    local ok, proxy = pcall(component.proxy, entry.controller)
    if not ok then
        return false, proxy
    end
    local callOk, result = pcall(proxy.activate, crossingName, closed)
    if not callOk then
        return false, result
    end
    return result == true
end

function crossingdrv.isClosed(entry, crossingName)
    if not entry or not entry.controller then
        return nil, "unmapped"
    end
    local ok, proxy = pcall(component.proxy, entry.controller)
    if not ok then
        return nil, proxy
    end
    local callOk, result = pcall(proxy.isArmDownFor, crossingName)
    if not callOk then
        return nil, result
    end
    return result
end

function crossingdrv.resetController(controllerAddress)
    local ok, proxy = pcall(component.proxy, controllerAddress)
    if not ok then
        return false, proxy
    end
    local callOk, result = pcall(proxy.activateAll, false)
    if not callOk then
        return false, result
    end
    return true
end

return crossingdrv
