-- TileDigitalDetector (Computronics_Ctyrk4_Edition) listener: this component has NO callbacks --
-- it pushes a signal via node():sendToReachable("computer.signal", {"minecart", ...}) when a
-- minecart passes. OpenComputers' network layer prepends the sending node's component address
-- right after the signal name, so the shape actually received is:
--   "computer.signal", senderAddress, "minecart", cartType, entityName, [locomotive fields...]
-- This is the one push-based source in the system (everything else is polled via callbacks), so
-- it needs its own top-level workspace handler alongside common/network.lua's -- see
-- network.makeHandler's doc comment on composing more than one.
local detector = {}

-- onDetect(senderAddress, cartType, entityName) is called whenever any mapped detector fires.
-- Callers filter by senderAddress against componentmap.gates[entranceName].detectorAddress to
-- know which hradlová zarážka the event belongs to.
function detector.makeHandler(onDetect)
    return function(e1, e2, e3, e4, e5)
        if e1 == "computer.signal" and e3 == "minecart" then
            local senderAddress, cartType, entityName = e2, e4, e5
            onDetect(senderAddress, cartType, entityName)
        end
    end
end

return detector
