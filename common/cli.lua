-- Small terminal-prompt helpers shared by stavedlo/setup.lua and dk/setup.lua. The setup wizard
-- is deliberately a plain term-based interactive script rather than a grapes GUI: it's one-time
-- guided data entry (pick a component address, type a receiver name) which a numbered
-- text-menu handles at a fraction of the code and risk of a custom widget flow, while still
-- meeting the design's "wizard" requirement (guided manual entry, saved to a mapping file).
local cli = {}

function cli.prompt(question, default)
    if default then
        io.write(question .. " [" .. tostring(default) .. "]: ")
    else
        io.write(question .. ": ")
    end
    local answer = io.read("l")
    if answer == nil or answer == "" then
        return default
    end
    return answer
end

function cli.confirm(question, default)
    local suffix = default and " (Y/n): " or " (y/N): "
    io.write(question .. suffix)
    local answer = io.read("l")
    if answer == nil or answer == "" then
        return default or false
    end
    answer = answer:lower()
    return answer == "y" or answer == "yes" or answer == "a" or answer == "ano"
end

-- items: array of arbitrary values. formatFn(item) -> display string. Returns the chosen item,
-- or nil if the list was empty and allowSkip was requested.
function cli.pick(items, formatFn, allowSkip)
    if #items == 0 then
        io.write("  (nic nenalezeno)\n")
        return nil
    end

    for i, item in ipairs(items) do
        io.write("  " .. i .. ") " .. formatFn(item) .. "\n")
    end
    if allowSkip then
        io.write("  0) přeskočit\n")
    end

    while true do
        io.write("Výběr: ")
        local answer = io.read("l")
        local n = tonumber(answer)
        if n == 0 and allowSkip then
            return nil
        end
        if n and items[n] then
            return items[n]
        end
        io.write("Neplatná volba.\n")
    end
end

function cli.header(text)
    io.write("\n== " .. text .. " ==\n")
end

return cli
