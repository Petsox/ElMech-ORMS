-- TileDigitalControllerBox (Computronics_Ctyrk4_Edition) wrapper: drives a Railcraft Distant
-- Signal used as a clonka (indicator flap) -- for závěr výměn, návěstní hradlo and hradlová
-- zarážka indicators alike. Aspect ordinal -> colour meaning is resolved by the caller from
-- componentmap (the setup wizard records, per clonka, which numbered aspect the in-game
-- controller reports for each meaningful colour -- see lockboxdrv.listAspects), since Railcraft's
-- aspect set/ordinals aren't safe to hardcode here.
local component = require("component")

local lockboxdrv = {}

-- Confirmed by the user in-game across their Distant Signal boxes: these ordinals are stable
-- regardless of which specific clonka/controller they belong to. Used as the setup wizard's
-- default so it no longer has to ask for a number blind; still overridable per clonka in case a
-- particular box turns out to differ.
lockboxdrv.DEFAULT_ASPECT = {
    green = 1,
    red = 5,
    black = 6,
    white = 7,
}

function lockboxdrv.setAspect(controllerAddress, clonkaName, aspect)
    if not controllerAddress or not clonkaName or aspect == nil then
        return false, "unmapped"
    end
    local ok, proxy = pcall(component.proxy, controllerAddress)
    if not ok then
        return false, proxy
    end
    local callOk, result = pcall(proxy.setAspect, clonkaName, aspect)
    if not callOk then
        return false, result
    end
    return result == true
end

-- Used by the setup wizard to let the user pick aspect ordinals per colour meaning.
function lockboxdrv.listAspects(controllerAddress)
    local ok, proxy = pcall(component.proxy, controllerAddress)
    if not ok then
        return nil, proxy
    end
    local callOk, result = pcall(function() return proxy.aspects end)
    if not callOk then
        return nil, result
    end
    return result
end

return lockboxdrv
