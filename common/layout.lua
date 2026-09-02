-- Parses a Config table (Layout Generator output, same shape as station.lua) into a cell
-- adjacency graph and provides breadth-first pathfinding over it.
--
-- Graph-building and pathfinding here are a direct adaptation of Open-Rail-Management-System's
-- route.lua (github.com/Petsox/Open-Rail-Management-System, automatic-route-building branch) --
-- that module already correctly interprets the exact glyph/coordinate convention the Layout
-- Generator emits, so it is ported rather than re-derived. Unlike ORMS's route.lua, this module
-- has no built-in route-locking state (lockedCells/tryLock/unlock) -- lock allocation here is a
-- shared pool sized by conflict analysis (see routes.lua), not a simple per-entrance reservation,
-- so that bookkeeping lives in stavedlo/interlocking/switchlock.lua instead.
local unicode = require("unicode")

local layout = {}

-- Grid convention: y increases downward, matching the GUI/screen coordinate system.
local DIRS = {
    U = {dx = 0, dy = -1},
    D = {dx = 0, dy = 1},
    L = {dx = -1, dy = 0},
    R = {dx = 1, dy = 0},
}
local DIR_ORDER = {"L", "R", "U", "D"}
local OPPOSITE = {U = "D", D = "U", L = "R", R = "L"}

-- Glyph -> set of cardinal directions it connects to, as seen from the cell itself.
local GLYPH_DIRS = {
    ["═"] = {L = true, R = true},
    ["║"] = {U = true, D = true},
    ["╔"] = {D = true, R = true},
    ["╗"] = {D = true, L = true},
    ["╚"] = {U = true, R = true},
    ["╝"] = {U = true, L = true},
    ["╞"] = {R = true},
    ["╡"] = {L = true},
    ["╥"] = {D = true},
    ["╨"] = {U = true},
    ["╠"] = {U = true, D = true, R = true},
    ["╣"] = {U = true, D = true, L = true},
    ["╦"] = {L = true, R = true, D = true},
    ["╩"] = {L = true, R = true, U = true},
    ["⦗"] = {L = true, R = true},
    ["⦘"] = {L = true, R = true},
    ["︹"] = {U = true, D = true},
    ["︺"] = {U = true, D = true},
}

local CURVE_GLYPHS = {["╗"] = true, ["╝"] = true, ["╚"] = true, ["╔"] = true}

-- Signal facing icon -> direction of authorized travel through the signal.
local FACING_DIR = {
    ["<"] = "L", ["◀"] = "L", ["◁"] = "L", ["˂"] = "L",
    [">"] = "R", ["▶"] = "R", ["▷"] = "R", ["˃"] = "R",
    ["^"] = "U", ["▲"] = "U", ["△"] = "U", ["˄"] = "U",
    ["V"] = "D", ["▼"] = "D", ["▽"] = "D", ["˅"] = "D",
}

local function key(x, y)
    return x .. "," .. y
end

local function stateKey(x, y, dir)
    return x .. "," .. y .. "," .. dir
end

function layout.isCurveGlyph(glyph)
    return CURVE_GLYPHS[glyph] == true
end

-- Best-effort structural guess only ("hlavní"/"předvěst"/"posunové" naming convention). The
-- setup wizard shows this as a suggestion and lets the user confirm/override per signal, since
-- it directly drives interlocking safety logic and must not be trusted blindly.
function layout.suggestSignalKind(name)
    local prefix = name:sub(1, 2)
    if prefix == "Se" then
        return "shunting"
    elseif prefix == "Pr" then
        return "expect"
    elseif prefix == "VS" or prefix == "VL" then
        return "inserted"
    elseif prefix == "Sc" or prefix == "Lc" then
        return "repeater"
    elseif name:match("^S%d") then
        -- Bare "S" + digit (e.g. "S4", not "Se4") -- odjezdové (departure) signal, a hlavní
        -- signal like any other. Falls into the "main" default below anyway, but made explicit
        -- since it's easy to misread as related to the "Se" shunting prefix.
        return "main"
    end
    return "main"
end

-- Builds the cell adjacency graph from a loaded Config table.
function layout.buildGraph(config)
    local cells = {}
    local signalsByName = {}

    for _, t in pairs(config.Tracks or {}) do
        local x, y, glyphs = t[1], t[2], t[3]
        local length = unicode.len(glyphs)
        for i = 1, length do
            local ch = unicode.sub(glyphs, i, i)
            local dirs = GLYPH_DIRS[ch]
            if dirs then
                cells[key(x + i - 1, y)] = {kind = "track", dirs = dirs}
            end
        end
    end

    for _, s in pairs(config.Switches or {}) do
        local x, y, iconDefault, iconToggled, name = s[1], s[2], s[3], s[4], s[5]
        cells[key(x, y)] = {kind = "switch", name = name, iconDefault = iconDefault, iconToggled = iconToggled}
    end

    for _, c in pairs(config.Crossings or {}) do
        local x, y, _, iconToggled, name = c[1], c[2], c[3], c[4], c[5]
        local dirs = GLYPH_DIRS[iconToggled]
        if dirs then
            cells[key(x, y)] = {kind = "crossing", name = name, dirs = dirs}
        end
    end

    for _, sig in pairs(config.Signals or {}) do
        local x, y, name, facingIcon = sig[1], sig[2], sig[3], sig[4]
        local dir = FACING_DIR[facingIcon]
        signalsByName[name] = {x = x, y = y, dir = dir, kind = layout.suggestSignalKind(name)}

        local k = key(x, y)
        if not cells[k] and dir then
            local axis = (dir == "L" or dir == "R") and {L = true, R = true} or {U = true, D = true}
            cells[k] = {kind = "track", dirs = axis}
        end
    end

    return {cells = cells, signalsByName = signalsByName}
end

-- Given a cell and the direction of travel used to arrive at it, returns the list of possible
-- continuations: {{dir = "R"[, icon = "═"]}, ...}. For switch cells, both icon states are
-- considered unless a state was already committed earlier on this path.
local function continuationsFor(cell, cameFromDir, switchChoices)
    local entrySide = OPPOSITE[cameFromDir]
    local results = {}

    if cell.kind == "switch" then
        local candidates = {cell.iconDefault, cell.iconToggled}
        if layout.isCurveGlyph(candidates[1]) and not layout.isCurveGlyph(candidates[2]) then
            candidates[1], candidates[2] = candidates[2], candidates[1]
        end
        local forced = switchChoices[cell.name]
        for _, icon in ipairs(candidates) do
            if forced == nil or forced == icon then
                local dirs = GLYPH_DIRS[icon]
                if dirs and dirs[entrySide] then
                    for _, d in ipairs(DIR_ORDER) do
                        if d ~= entrySide and dirs[d] then
                            results[#results + 1] = {dir = d, icon = icon}
                        end
                    end
                end
            end
        end
    else
        local dirs = cell.dirs
        if dirs and dirs[entrySide] then
            if dirs[cameFromDir] then
                results[#results + 1] = {dir = cameFromDir}
            end
            for _, d in ipairs(DIR_ORDER) do
                if d ~= entrySide and d ~= cameFromDir and dirs[d] then
                    results[#results + 1] = {dir = d}
                end
            end
        end
    end

    return results
end

local function cloneTable(t)
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end
    return copy
end

local function crossingsAlong(graph, path)
    local crossings = {}
    for _, c in ipairs(path) do
        local cell = graph.cells[key(c.x, c.y)]
        if cell and cell.kind == "crossing" then
            crossings[cell.name] = true
        end
    end
    return crossings
end

local function allStraightSwitches(switchChoices)
    for _, icon in pairs(switchChoices) do
        if layout.isCurveGlyph(icon) then
            return false
        end
    end
    return true
end

-- Shared BFS core. goal(x, y, dir) is called for every dequeued state and should return true
-- once the search has reached its target; extra is merged into the returned result table.
local function search(graph, entranceName, entranceDirOverride, goal, extra)
    local entrance = graph.signalsByName[entranceName]
    local startFacing = entranceDirOverride or (entrance and entrance.dir)
    if not entrance or not startFacing then
        return nil
    end

    local vec = DIRS[startFacing]
    local startX, startY, startDir = entrance.x + vec.dx, entrance.y + vec.dy, startFacing
    local visited = {[stateKey(startX, startY, startDir)] = true}
    local queue = {
        {x = startX, y = startY, dir = startDir, switchChoices = {}, path = {{x = entrance.x, y = entrance.y}}},
    }
    local head = 1

    while head <= #queue do
        local node = queue[head]
        head = head + 1

        if goal(node.x, node.y, node.dir) then
            local path = cloneTable(node.path)
            path[#path + 1] = {x = node.x, y = node.y}

            local result = {
                switches = node.switchChoices,
                crossings = crossingsAlong(graph, path),
                cells = path,
                allStraight = allStraightSwitches(node.switchChoices),
                arrivalDir = node.dir,
            }
            for k, v in pairs(extra or {}) do
                result[k] = v
            end
            return result
        end

        local cell = graph.cells[key(node.x, node.y)]
        if cell then
            local path = cloneTable(node.path)
            path[#path + 1] = {x = node.x, y = node.y}

            for _, opt in ipairs(continuationsFor(cell, node.dir, node.switchChoices)) do
                local optVec = DIRS[opt.dir]
                local nx, ny = node.x + optVec.dx, node.y + optVec.dy
                if not (nx == entrance.x and ny == entrance.y) then
                    local sk = stateKey(nx, ny, opt.dir)
                    if not visited[sk] then
                        visited[sk] = true
                        local switchChoices = node.switchChoices
                        if opt.icon then
                            switchChoices = cloneTable(node.switchChoices)
                            switchChoices[cell.name] = opt.icon
                        end
                        queue[#queue + 1] = {x = nx, y = ny, dir = opt.dir, switchChoices = switchChoices, path = path}
                    end
                end
            end
        end
    end

    return nil
end

-- Finds a route from entranceName to exitName (another named signal). entranceName forces the
-- route's first step in its own facing direction unless entranceDirOverride is given. exitName is
-- a pure location marker (any arrival direction counts). Returns nil if none exists, otherwise
-- {switches = {[switchName] = requiredIconGlyph, ...}, crossings = {[crossingName] = true, ...},
-- cells = {{x,y}, ...}, allStraight = bool}.
function layout.findPath(graph, entranceName, exitName, entranceDirOverride)
    local exit = graph.signalsByName[exitName]
    if not exit then
        return nil
    end
    return search(graph, entranceName, entranceDirOverride, function(x, y)
        return x == exit.x and y == exit.y
    end)
end

-- Same search, but the goal is an arbitrary point (targetX, targetY) in any arrival direction --
-- used to resolve a route ending at a Label cell (station/running track) rather than a named
-- signal. Returned result additionally carries arrivalDir, needed by callers that stitch a
-- further leg onward from the point.
function layout.findPathToPoint(graph, entranceName, targetX, targetY, entranceDirOverride)
    return search(graph, entranceName, entranceDirOverride, function(x, y)
        return x == targetX and y == targetY
    end)
end

return layout
