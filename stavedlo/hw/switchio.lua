-- Redstone I/O <-> Control Panel wrapper for výhybky (switches): reads lever positions and
-- drives indicator lamps, both addressed as a bundled-cable colour on a fixed side of a
-- redstone_io block (ocdoc.cil.li/block:redstone_io confirms redstone_io always uses absolute
-- sides.* directions, never orientation-relative ones -- unlike a plain redstone card). The
-- Control Panel itself (ProjectBlue) maps each of its up to 16 lever/lamp slots to one bundled
-- wire colour per block, which is exactly why componentmap stores a side+colour pair per switch
-- instead of a single redstone side (>16 switches need several redstone_io/panel pairs).
--
-- ASSUMPTION FLAGGED FOR IN-GAME VERIFICATION: getBundledInput/setBundledOutput are the standard
-- OC redstone-component bundled-cable calls, and colour indices follow the common
-- ProjectRed/ProjectBlue wire-colour ordering (white=0, orange=1, magenta=2, lightBlue=3,
-- yellow=4, lime=5, pink=6, gray=7, lightGray=8, cyan=9, purple=10, blue=11, brown=12, green=13,
-- red=14, black=15). Confirm both against the actual panel's colour chart before relying on this
-- in a real build -- the docs page for redstone_io didn't spell out bundled method names, and the
-- Control Panel docs didn't spell out the colour->index chart itself.
local component = require("component")
local sides = require("sides")

local switchio = {}

switchio.COLOR_NAMES = {
    "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
    "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black",
}

switchio.COLOR_INDEX = {}
for i, name in ipairs(switchio.COLOR_NAMES) do
    switchio.COLOR_INDEX[name] = i - 1
end

switchio.SIDE_NAMES = {"down", "up", "north", "south", "west", "east"}

function switchio.sideValue(name)
    return sides[name]
end

-- entry = {redstoneIO = address, side = "north", color = "white"} -- same shape for both the
-- switch's own lever fields (componentmap.switches[code], passed to readLever) and its
-- `.indicator` sub-table (passed to setIndicator) -- these must be TWO DIFFERENT entries on two
-- different (redstoneIO, side, color) triples. Confirmed in practice: reusing one entry for both
-- readLever and setIndicator lets the indicator's own output feed back into the lever's input
-- reading and permanently stick it (the switch could be thrown once, then never again, even
-- across a restart, since the redstone output itself is persisted in the world) -- see
-- componentmap.lua's schema comment.
local function proxyAndArgs(entry)
    if not entry or not entry.redstoneIO or not entry.side or not entry.color then
        return nil
    end
    local ok, proxy = pcall(component.proxy, entry.redstoneIO)
    if not ok then
        return nil
    end
    local side = switchio.sideValue(entry.side)
    local color = switchio.COLOR_INDEX[entry.color]
    if not side or not color then
        return nil
    end
    return proxy, side, color
end

-- Reads the lever: true = "+" (plus), false = "-" (minus/normal position).
function switchio.readLever(entry)
    local proxy, side, color = proxyAndArgs(entry)
    if not proxy then
        return nil, "unmapped"
    end
    local ok, value = pcall(proxy.getBundledInput, side, color)
    if not ok then
        return nil, value
    end
    return value > 0
end

-- Drives the indication lamp: on (lit) = "+", off = "-", matching the design's
-- "Svítí = +, Nesvítí = -" convention for the second Control Panel.
function switchio.setIndicator(entry, plus)
    local proxy, side, color = proxyAndArgs(entry)
    if not proxy then
        return false, "unmapped"
    end
    local ok, err = pcall(proxy.setBundledOutput, side, color, plus and 255 or 0)
    if not ok then
        return false, err
    end
    return true
end

return switchio
