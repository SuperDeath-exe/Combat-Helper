-- Reads chat lines from the chatbox interface (137:86, found with the
-- recorder's UI scan). Works without the chatAccess permission.

local ChatReader = {}

local function lookup(tbl, key)
    local ok, value = pcall(function() return tbl[key] end)
    if ok then return value end
    return nil
end

local CHAT_INTERFACE, CHAT_COMPONENT = 137, 86
local CHAT_OVERLAP = 5          -- lines that must match to line up two reads
local MAX_NEW_CHAT_LINES = 10   -- most new lines expected between two ticks

function ChatReader.Read()
    local ok, comp = pcall(function() return ui.Interfaces:GetComponent(CHAT_INTERFACE, CHAT_COMPONENT) end)
    if not ok or comp == nil then return nil end
    local entries = {}
    pcall(function()
        comp:IterateDynamicComponents(function(child)
            local text, dyn = lookup(child, "content"), lookup(child, "dynamicID")
            if type(text) == "string" and text ~= "" and dyn ~= nil then
                table.insert(entries, { dyn = dyn, text = text })
            end
            return false
        end)
    end)
    table.sort(entries, function(a, b) return a.dyn < b.dyn end)
    local lines = {}
    for i, entry in ipairs(entries) do lines[i] = entry.text end
    return lines
end

local function rangeEqual(a, aStart, b, bStart, count)
    for j = 0, count - 1 do
        if a[aStart + j] ~= b[bStart + j] then return false end
    end
    return true
end

-- Lines added since the last read, oldest first. Handles the list growing at
-- either end (newest-first or oldest-first ordering), with old lines dropping
-- off the other end once the chat history is full.
function ChatReader.NewLines(old, new)
    if old == nil or #old == 0 then return {} end
    local overlap = math.min(CHAT_OVERLAP, #old)
    -- Grew at the front: new[k+1 ..] lines up with the start of old
    for k = 0, MAX_NEW_CHAT_LINES do
        if #new >= k + overlap and rangeEqual(new, k + 1, old, 1, overlap) then
            if k == 0 then break end -- nothing new at the front
            local added = {}
            for i = k, 1, -1 do table.insert(added, new[i]) end
            return added
        end
    end
    -- Grew at the back: new[.. #new-k] lines up with the end of old
    for k = 0, MAX_NEW_CHAT_LINES do
        local tailStart = #new - k - overlap + 1
        if tailStart >= 1 and rangeEqual(new, tailStart, old, #old - overlap + 1, overlap) then
            local added = {}
            for i = #new - k + 1, #new do table.insert(added, new[i]) end
            return added
        end
    end
    return {} -- chat tab switched or cleared: resync silently
end


-- Returns a poll function: each call gives the lines added since the previous call
function ChatReader.Watcher()
    local snapshot = nil
    return function()
        local lines = ChatReader.Read()
        if lines == nil then return {} end
        local added = ChatReader.NewLines(snapshot, lines)
        snapshot = lines
        return added
    end
end

return ChatReader
