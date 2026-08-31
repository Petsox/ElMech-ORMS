-- Thin wrapper around component.modem for the Stavědlo <-> DK link. Messages are typed
-- (HRADLO_REQUEST/STATE, LOCK_REQUEST/STATE, GATE_STATE, HEARTBEAT -- see the design plan's
-- "Doménová logika" sequence) and JSON-encoded via common/json.lua.
--
-- Every OpenComputers signal (touch, key, modem_message, ...) is already forwarded verbatim to
-- any GUI object's eventHandler by grapes' workspace:start() loop (confirmed by reading
-- grapes/GUI.lua's workspaceStart/handleContainer), so no polling thread or change to grapes is
-- needed -- network.install just becomes the workspace's top-level eventHandler and filters for
-- "modem_message" itself, the same pattern grapes/GUI.lua's own doc comment demonstrates.
local component = require("component")
local json = require("json")

local network = {}

network.DEFAULT_PORT = 4210

function network.open(port)
    local modem = component.modem
    modem.open(port or network.DEFAULT_PORT)
    return modem
end

-- Sends {type = msgType, payload = payload} to targetAddress. Silently no-ops if there is no
-- modem or no configured peer yet -- callers treat "peer unreachable" the same as "peer hasn't
-- acknowledged", the interlocking must never assume a message arrived.
function network.send(targetAddress, port, msgType, payload)
    if not targetAddress or not component.isAvailable("modem") then
        return false
    end
    component.modem.send(targetAddress, port or network.DEFAULT_PORT, msgType, json.encode(payload or {}))
    return true
end

function network.broadcast(port, msgType, payload)
    if not component.isAvailable("modem") then
        return false
    end
    component.modem.broadcast(port or network.DEFAULT_PORT, msgType, json.encode(payload or {}))
    return true
end

-- Returns a raw (e1, e2, ...) event handler function that filters for modem_message on `port`
-- and calls onMessage(msgType, payload, senderAddress). A single grapes workspace only has one
-- workspace.eventHandler slot, so when more than one top-level listener is needed (e.g. also
-- hw/detector.lua's push signal), compose the handlers returned by each module's makeHandler
-- instead of calling network.install more than once.
function network.makeHandler(port, onMessage)
    port = port or network.DEFAULT_PORT
    return function(e1, e2, e3, e4, e5, e6, e7)
        if e1 == "modem_message" and e4 == port then
            local msgType, rawPayload, senderAddress = e6, e7, e3
            local ok, payload = pcall(json.decode, rawPayload or "{}")
            onMessage(msgType, ok and payload or {}, senderAddress)
        end
    end
end

-- Convenience for the common case where the modem listener is the workspace's only top-level
-- handler.
function network.install(workspace, port, onMessage)
    local handler = network.makeHandler(port, onMessage)
    workspace.eventHandler = function(ws, obj, ...)
        handler(...)
    end
end

return network
