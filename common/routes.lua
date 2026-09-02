-- Enumerates every possible train route across one zhlaví (throat) -- from each confirmed
-- "hlavní" (main, entrance/odjezdové) signal to each labelled station/running track.
--
-- Lock grouping: one závěr výměn per traťová kolej (running line, e.g. T1/T2/T4), not a
-- graph-computed "maximum concurrent routes" pool -- confirmed by the user against their real
-- station design: every route sharing a running line (arrival or departure alike) always
-- conflicts with every other route on that same line in this kind of throat, so a single shared
-- lock per line is what a real electromechanical interlocking actually uses. mainSignalGroups
-- (built by the setup wizard) says which running-line label each hlavní signal belongs to.
local layout = require("layout")
local persist = require("persist")

local routes = {}

local function key(x, y)
    return x .. "," .. y
end

-- Labels sit adjacent to their track, not on it (Layout Generator convention: same row, a few
-- cells clear of where the track glyphs start/end). Resolve the nearest graph cell on the same
-- row, searching outward in both directions.
function routes.resolveLabelCell(graph, label, maxRadius)
    local x, y = label[1], label[2]
    maxRadius = maxRadius or 6

    if graph.cells[key(x, y)] then
        return x, y
    end

    for radius = 1, maxRadius do
        if graph.cells[key(x + radius, y)] then
            return x + radius, y
        end
        if graph.cells[key(x - radius, y)] then
            return x - radius, y
        end
    end

    return nil
end

-- mainSignalNames: array of signal names confirmed (by the setup wizard) to be hlavní
-- (entrance/odjezdové) signals -- routes only start from these, never from předvěsti/posunová
-- návěstidla. labels: config.Labels array ({x, y, text}, e.g. {45,27,"T4"} or {71,27,"4"}).
-- Returns an array of route records: {id, entrance, label, cells, switches, crossings,
-- allStraight}.
function routes.enumerate(graph, mainSignalNames, labels)
    local found = {}
    local seenIds = {}

    for _, entranceName in ipairs(mainSignalNames) do
        for _, label in ipairs(labels) do
            local lx, ly = routes.resolveLabelCell(graph, label)
            if lx then
                local result = layout.findPathToPoint(graph, entranceName, lx, ly)
                if result then
                    local id = entranceName .. " -> " .. label[3]
                    if seenIds[id] then
                        id = id .. " #" .. (seenIds[id] + 1)
                    end
                    seenIds[id] = (seenIds[id] or 0) + 1

                    found[#found + 1] = {
                        id = id,
                        entrance = entranceName,
                        label = label[3],
                        cells = result.cells,
                        switches = result.switches,
                        crossings = result.crossings,
                        allStraight = result.allStraight,
                    }
                end
            end
        end
    end

    return found
end

-- [switchName] = {default = iconDefault, toggled = iconToggled} -- lets switchlock.lua translate
-- a route's required glyph (from result.switches) into a required lever position ("-"/"+")
-- without needing the whole graph at runtime.
local function switchIconTable(config)
    local icons = {}
    for _, s in pairs(config.Switches or {}) do
        icons[s[5]] = {default = s[3], toggled = s[4]}
    end
    return icons
end

-- Computes routes + running-line groups for a zhlaví and persists the result so stavedlo/dk can
-- load it at boot without recomputing. mainSignalGroups = {[entranceName] = runningLineLabel}
-- comes from the setup wizard. A route whose entrance isn't in mainSignalGroups (shouldn't
-- happen -- mainSignalGroups is built from exactly the confirmed hlavní signals) is dropped
-- rather than left ungrouped, since an ungrouped route could never be given a lock slot.
function routes.computeAndSave(config, mainSignalGroups, path)
    local graph = layout.buildGraph(config)

    local mainSignalNames = {}
    for name in pairs(mainSignalGroups) do
        mainSignalNames[#mainSignalNames + 1] = name
    end

    local routeList = routes.enumerate(graph, mainSignalNames, config.Labels or {})

    local groupSet, groups = {}, {}
    local saved = {switchIcons = switchIconTable(config), routes = {}}
    for _, r in ipairs(routeList) do
        local group = mainSignalGroups[r.entrance]
        if group then
            if not groupSet[group] then
                groupSet[group] = true
                groups[#groups + 1] = group
            end
            saved.routes[#saved.routes + 1] = {
                id = r.id, entrance = r.entrance, label = r.label, group = group,
                cells = r.cells, switches = r.switches, crossings = r.crossings, allStraight = r.allStraight,
            }
        end
    end
    table.sort(groups)
    saved.groups = groups
    saved.lockCount = #groups

    local ok, err = persist.writeJSON(path, saved)
    if not ok then
        return nil, err
    end
    return saved
end

function routes.load(path)
    return persist.readJSON(path)
end

return routes
