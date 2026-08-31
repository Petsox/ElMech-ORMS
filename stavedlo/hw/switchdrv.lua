-- digitalUnivController (signalcraft_universal_controller) wrapper: drives the actual
-- SignalCraft switch motor (Universal Receiver) paired to a switch's receiverName.
local component = require("component")

local switchdrv = {}

-- ASSUMPTION: plus=true (active) energises the receiver into the "+" (diverging) position,
-- plus=false (inactive) is "-" (normal/straight) -- matches how a real switch motor rests
-- de-energised in normal position. Verify against the actual SignalCraft receiver in-game.
-- entry = componentmap.switches[code] = {controller=addr, receiverName=str, ...}
function switchdrv.setPosition(entry, plus)
    if not entry or not entry.controller or not entry.receiverName then
        return false, "unmapped"
    end
    local ok, proxy = pcall(component.proxy, entry.controller)
    if not ok then
        return false, proxy
    end
    local callOk, result = pcall(proxy.setActive, entry.receiverName, plus)
    if not callOk then
        return false, result
    end
    return result == true
end

return switchdrv
