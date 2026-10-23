--[[
  Pinger matching rules (pure Lua, no game API), so they can be tested
  outside the client. main.lua passes each chat event through evaluate().
]]
local M = {}

-- ChatType values from developer.runescape.com/rs/game/chat.html
M.GROUPS = {
    { key = "public",  name = "Public",       types = { 1, 2, 17 } },
    { key = "private", name = "Private",      types = { 3, 7, 18 } },
    { key = "friends", name = "Friends chat", types = { 9, 20 } },
    { key = "clan",    name = "Clan",         types = { 41, 42 } },
    { key = "guest",   name = "Guest clan",   types = { 44, 45 } },
    { key = "group",   name = "Group",        types = { 22, 23, 24, 25 } },
    { key = "trade",   name = "Trade/requests", types = { 100, 101, 102, 107, 108, 111, 113, 132 } },
}
M.GROUP_OF = {}
for i, g in ipairs(M.GROUPS) do for _, t in ipairs(g.types) do M.GROUP_OF[t] = i end end
M.SKIP = { [33] = true, [96] = true, [98] = true, [99] = true }   -- plugin messages, console
M.OUTGOING = { [6] = true, [19] = true }                          -- private messages you send
M.FILTERS = { "All", "Players" }
for _, g in ipairs(M.GROUPS) do M.FILTERS[#M.FILTERS + 1] = g.name end

function M.chanName(t)
    local g = M.GROUP_OF[t]
    if g then return M.GROUPS[g].name end
    if t == nil or t < 0 then return "Unknown" end
    return "Game (" .. t .. ")"
end
function M.passesFilter(f, t)
    f = f or 1
    if f == 1 then return true end
    local g = M.GROUP_OF[t]
    if f == 2 then return g ~= nil end
    return g == f - 2
end

--- lower case; <tags> removed; nbsp, '_' and '-' -> space; spaces collapsed.
function M.normText(s)
    local t = tostring(s or "")
    t = t:gsub("<[^>]*>", "")
    t = t:gsub("\194\160", " "):gsub("\160", " "):gsub("[_%-]", " ")
    t = string.lower(t):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return t
end
local function isWordChar(ch) return ch ~= nil and ch ~= "" and ch:match("[%w]") ~= nil end
local function hasWord(hay, needle)
    local i = 1
    while true do
        local s, e = string.find(hay, needle, i, true)
        if not s then return false end
        if not isWordChar(hay:sub(s - 1, s - 1)) and not isWordChar(hay:sub(e + 1, e + 1)) then return true end
        i = s + 1
    end
end
function M.matches(hay, needle, mode)
    if needle == nil or needle == "" then return false end
    if mode == "contains" then return string.find(hay, needle, 1, true) ~= nil end
    return hasWord(hay, needle)
end

--[[
  ev  = { msg, t (number or -1), from, now (seconds) }
  ctx = { name = trigger, trigs = { trigger... }, ignoreOwn, cooldown,
          myNorm, myTight, lastFire = { [trigger] = seconds } }
  Returns hit (trigger or nil), reason (short text for the diagnostics).
  Updates ctx.lastFire when it decides to ping.
]]
function M.evaluate(ev, ctx)
    local t = ev.t or -1
    if M.SKIP[t] then return nil, "skipped: plugin/console message" end
    local fromN = M.normText(ev.from)
    local myNorm, myTight = ctx.myNorm or "", ctx.myTight or ""
    local own = M.OUTGOING[t] or (myNorm ~= "" and fromN ~= "" and (fromN == myNorm or (fromN:gsub(" ", "")) == myTight))
    if own and ctx.ignoreOwn then return nil, "your own message (Ignore own is On)" end
    local hay = M.normText(ev.msg)
    if hay == "" then return nil, "empty message" end
    -- candidate triggers in order: name first, then custom
    local cands = {}
    if myNorm ~= "" then cands[#cands + 1] = { tr = ctx.name, needles = { myNorm, myTight ~= myNorm and myTight or nil }, label = "your name" } end
    for _, tr in ipairs(ctx.trigs or {}) do cands[#cands + 1] = { tr = tr, needles = { M.normText(tr.text) }, label = "\"" .. tostring(tr.text) .. "\"" } end
    local why = nil
    for _, c in ipairs(cands) do
        local found = false
        for _, n in pairs(c.needles) do if M.matches(hay, n, c.tr.match) then found = true end end
        if found then
            if not c.tr.on then why = why or ("matched " .. c.label .. " but it is Off")
            elseif not M.passesFilter(c.tr.chan, t) then why = why or ("matched " .. c.label .. " but channel filter is " .. tostring(M.FILTERS[c.tr.chan]))
            else
                local last = ctx.lastFire and ctx.lastFire[c.tr]
                local cd = ctx.cooldown or 0
                if last ~= nil and cd > 0 and (ev.now or 0) - last < cd then
                    why = why or ("matched " .. c.label .. " but on cooldown")
                else
                    if ctx.lastFire then ctx.lastFire[c.tr] = ev.now or 0 end
                    return c.tr, "PING: " .. c.label
                end
            end
        end
    end
    if why then return nil, why end
    if myNorm == "" and #(ctx.trigs or {}) == 0 then return nil, "no triggers (name not detected yet)" end
    return nil, "no trigger in message"
end

return M
