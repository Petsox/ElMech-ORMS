-- Enumerates every possible train route across one zhlaví (throat) -- from each confirmed
-- "hlavní" (main, entrance/odjezdové) signal to each labelled station/running track -- and
-- computes how many concurrent, mutually non-conflicting routes the layout allows. That count is
-- how many physical závěr výměn (switch-lock) circuits stavedlo/interlocking/switchlock.lua needs
-- to hand out, matching the rule from the design: "based on the number of running lines, how many
-- train routes can be built at once without them crossing".
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

-- Two routes conflict if they use any cell in common (a shared switch, crossing or plain track
-- segment) -- either one being built prevents the other from being locked at the same time.
local function cellSet(result)
    local set = {}
    for _, c in ipairs(result.cells) do
        set[key(c.x, c.y)] = true
    end
    return set
end

local function conflicts(a, b)
    for k in pairs(a) do
        if b[k] then
            return true
        end
    end
    return false
end

-- mainSignalNames: array of signal names confirmed (by the setup wizard) to be hlavní
-- (entrance/odjezdové) signals -- routes only start from these, never from předvěsti/posunová
-- návěstidla. labels: config.Labels array ({x, y, text}, e.g. {45,27,"T4"} or {71,27,"4"}).
-- Returns an array of route records: {id, entrance, label, cells, switches, crossings,
-- allStraight, cellSet}.
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
                        cellSet = cellSet(result),
                    }
                end
            end
        end
    end

    return found
end

-- Maximum set of pairwise non-conflicting routes -- brute-force backtracking with a simple
-- bound-based prune. The number of candidate routes in one zhlaví is small (a few dozen at most),
-- so this stays fast; see common/routes.lua module doc / the design plan for why this is
-- acceptable instead of a polynomial approximation.
function routes.maxConcurrent(routeList)
    local n = #routeList
    if n == 0 then
        return 0, {}
    end

    local conflictRow = {}
    for i = 1, n do
        conflictRow[i] = {}
        for j = 1, n do
            if i ~= j then
                conflictRow[i][j] = conflicts(routeList[i].cellSet, routeList[j].cellSet)
            end
        end
    end

    local best, bestChosen = 0, {}
    local chosen = {}

    local function bt(idx, chosenCount)
        if chosenCount + (n - idx + 1) <= best then
            return
        end
        if idx > n then
            if chosenCount > best then
                best = chosenCount
                bestChosen = {}
                for i = 1, #chosen do
                    bestChosen[i] = chosen[i]
                end
            end
            return
        end

        local canInclude = true
        for i = 1, #chosen do
            if conflictRow[idx][chosen[i]] then
                canInclude = false
                break
            end
        end

        if canInclude then
            chosen[#chosen + 1] = idx
            bt(idx + 1, chosenCount + 1)
            chosen[#chosen] = nil
        end

        bt(idx + 1, chosenCount)
    end

    bt(1, 0)

    local names = {}
    for i = 1, #bestChosen do
        names[i] = routeList[bestChosen[i]].id
    end
    return best, names
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

-- Computes routes + lock-count for a zhlaví and persists the result (stripping cellSet, which is
-- only needed for the in-process conflict computation) so stavedlo/dk can load it at boot without
-- recomputing. mainSignalNames/labels come from the setup wizard's confirmed classification.
function routes.computeAndSave(config, mainSignalNames, path)
    local graph = layout.buildGraph(config)
    local routeList = routes.enumerate(graph, mainSignalNames, config.Labels or {})
    local lockCount, examplePeak = routes.maxConcurrent(routeList)

    local saved = {
        lockCount = lockCount,
        examplePeakRoutes = examplePeak,
        switchIcons = switchIconTable(config),
        routes = {},
    }
    for _, r in ipairs(routeList) do
        saved.routes[#saved.routes + 1] = {
            id = r.id,
            entrance = r.entrance,
            label = r.label,
            cells = r.cells,
            switches = r.switches,
            crossings = r.crossings,
            allStraight = r.allStraight,
        }
    end

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
