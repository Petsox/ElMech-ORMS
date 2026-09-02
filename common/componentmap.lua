-- Load/save the hardware mapping produced by setup.lua: which OpenComputers component address
-- (Redstone I/O, digitalUnivController/digitalController/digitalCrossController,
-- TileDigitalControllerBox) and which manually-entered SignalCraft receiver name/side/color
-- backs each entity discovered in the layout. Deliberately not auto-discovered by
-- getControllerName() the way ORMS's controllers.lua does -- the user wants explicit manual
-- entry so more than 16 switches can be spread across several Redstone I/O blocks.
local component = require("component")
local persist = require("persist")

local componentmap = {}

function componentmap.empty()
    return {
        switches = {},   -- [switchCode] = {redstoneIO=addr, side=str, color=str, controller=addr, receiverName=str,
                         --   leverOwner=otherSwitchCode}  -- "spojené výhybky": when set, this switch has no lever
                         --   of its own (redstoneIO/side/color are nil) and shares the named switch's physical
                         --   lever/indicator; it still has its own controller/receiverName (own motor). leverOwner
                         --   always points at a switch that owns its lever directly (setup.lua flattens chains),
                         --   so resolveLeverEntry below never has to recurse.
        signals = {},     -- [signalName] = {controller=addr, kind="main"|"expect"|"shunting"|"repeater"|"inserted",
                          --   runningLine=str}  -- runningLine only set for kind=="main": which traťová kolej
                          --   (T-label) this entrance/odjezdové signal belongs to -- see common/routes.lua's
                          --   grouping. State NAMES are never stored here -- see interlocking/signals.lua's doc
                          --   comment for why (ORMS hardcodes the same fixed vocabulary instead of configuring it).
        crossings = {},    -- [crossingName] = {controller=addr}
        switchlock = {},    -- [runningLineLabel] = {controller=addr, clonkaName=str, aspects={normal=n, locked=n}}
                            --   one entry per routes.json group (e.g. "T1"/"T2"/"T4"), not per route.
        routeLocks = {},      -- [routeId] = {redstoneIO=addr, side=str, color=str}  -- kolejový závěrník: a
                              --   Control Panel lever (input only, no motor/indicator) that must be engaged before
                              --   switchlock:confirmLock will lock that specific route's závěr výměn.
        gates = {},          -- [entranceSignalName] = {
                             --   hradloController=addr, hradloClonkaName=str, hradloAspects={normal=n, active=n},
                             --   zarazkaController=addr, zarazkaClonkaName=str, zarazkaAspects={normal=n, active=n},
                             --   detectorAddress=addr,
                             -- }
        network = {},          -- {peerAddress=addr, port=n}
    }
end

function componentmap.load(path)
    local data = persist.readJSON(path)
    if not data then
        return componentmap.empty()
    end

    local base = componentmap.empty()
    for section in pairs(base) do
        data[section] = data[section] or base[section]
    end
    return data
end

function componentmap.save(path, data)
    return persist.writeJSON(path, data)
end

-- List available components of a given type (exact match; pass nil for every component on the
-- network, used as a fallback when the caller isn't sure of the exact type string) as
-- {address, type, label} entries, for the setup wizard to build a picker from. `label` is
-- component.proxy(address).getControllerName() when available (every SignalCraft-Integrations /
-- Computronics controller in this project exposes it), else nil.
function componentmap.discover(componentType)
    local found = {}
    for address, cType in component.list(componentType, true) do
        local ok, proxy = pcall(component.proxy, address)
        local label = nil
        if ok and proxy.getControllerName then
            local okName, name = pcall(proxy.getControllerName)
            if okName then
                label = name
            end
        end
        found[#found + 1] = {address = address, type = cType, label = label}
    end
    return found
end

-- Resolves the switch entry that actually owns the physical lever/indicator for `code`'s
-- redstoneIO reads/writes -- either its own entry, or (for a spojená výhybka) the entry named
-- by its leverOwner. Every hw/switchio.lua call for a switch's Control Panel lever/light should
-- go through this instead of indexing map.switches[code] directly.
function componentmap.resolveLeverEntry(map, code)
    local entry = map.switches[code]
    if not entry then
        return nil
    end
    if entry.leverOwner then
        return map.switches[entry.leverOwner]
    end
    return entry
end

-- Every switch code that shares a physical lever with `code` (code itself and, transitively via
-- resolveLeverEntry's owner, every other switch pointing at the same owner) -- used to keep
-- kolejový závěrník locking in sync across a spojená výhybka: locking one member must lock all of
-- them, since moving the shared lever would move every motor on it at once. (Different concept
-- from map.routeLocks -- this is about switches sharing one Control Panel lever, that's a
-- separate per-route mechanical lock lever.)
function componentmap.leverGroup(map, code)
    local ownerEntry = componentmap.resolveLeverEntry(map, code)
    if not ownerEntry then
        return {code}
    end
    local ownerCode = map.switches[code].leverOwner or code

    local group = {ownerCode}
    for otherCode, entry in pairs(map.switches) do
        if otherCode ~= ownerCode and entry.leverOwner == ownerCode then
            group[#group + 1] = otherCode
        end
    end
    return group
end

-- Auto-detection (requested after the user found manual re-entry tedious in practice): searches
-- every component of componentType for one whose `listMethod` callback (e.g. "getReceiverNames",
-- "getSignalNames") already reports wantedName among its paired names, and returns that
-- component's address -- or nil if wantedName isn't paired anywhere yet, in which case the
-- caller should fall back to the manual picker. Relies on the user's in-game naming already
-- matching the layout's own identifiers (switch code, signal name, crossing name, or a
-- wizard-chosen clonka name) -- exactly the convention the setup wizard now assumes first and
-- only asks about manually when nothing matches.
function componentmap.findByPairedName(componentType, listMethod, wantedName)
    for address in component.list(componentType, true) do
        local ok, proxy = pcall(component.proxy, address)
        if ok and proxy[listMethod] then
            local okList, names = pcall(proxy[listMethod])
            if okList and type(names) == "table" then
                for _, n in pairs(names) do
                    if n == wantedName then
                        return address
                    end
                end
            end
        end
    end
    return nil
end

componentmap.TYPES = {
    redstone = "redstone",
    universalController = "signalcraft_universal_controller",
    signalController = "signalcraft_controller",
    crossingController = "signalcraft_crossing_controller",
    controllerBox = "digital_controller_box",
    detector = "digital_detector",
    modem = "modem",
}

return componentmap
