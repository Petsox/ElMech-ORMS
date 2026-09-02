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

-- Shows a summary of what's about to be saved for one entity and lets the user confirm it,
-- redo it (typo/wrong pick just now, without restarting the whole wizard), or skip it. Wrap the
-- per-entity collection code in a `while true do ... end` loop and act on the returned choice --
-- "save" commits and breaks, "retry" loops back to collect again, "skip" breaks without saving.
-- summaryLines: array of already-formatted display strings (no numbering needed).
function cli.reviewChoice(summaryLines)
    io.write("\nSouhrn:\n")
    for _, line in ipairs(summaryLines) do
        io.write("  " .. line .. "\n")
    end
    while true do
        io.write("Uložit? (a)no / (z)novu vyplnit / (p)řeskočit: ")
        local answer = (io.read("l") or ""):lower()
        if answer == "a" or answer == "" then
            return "save"
        elseif answer == "z" then
            return "retry"
        elseif answer == "p" then
            return "skip"
        end
        io.write("Neplatná volba.\n")
    end
end

return cli
