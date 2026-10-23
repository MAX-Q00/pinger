--[[
  Pinger
  ------
  Plays an alert sound when a chat message contains your name or one of your
  own trigger words. Each trigger has its own sound (picked from the game's
  built-in sound list), on/off switch, channel filter and match mode.

  Guideline notes for moderators:
    * Read-only. Reads Event.ChatMessage payloads (needs the optional
      chatAccess permission) and never modifies them, never calls
      Chat.AddMessage, never sends chat, input, menu actions or packets.
    * Plays built-in client sounds locally through audio.Play.
    * Reads the local player's display name (Player.GetEntity().displayName)
      only to match it against chat text. Nothing leaves the plugin.
    * Lists are virtualised (fixed row components rebound on paging).
]]

local PLUGIN_NAME = "Pinger"
local helpers = require("ui_helpers")
helpers.VERSION = "0.1.1"
local H = helpers

-------------------------------------------------------------------------------
-- Channels (ChatType values from developer.runescape.com/rs/game/chat.html)
-------------------------------------------------------------------------------
local GROUPS = {
    { key = "public",  name = "Public",       types = { 1, 2, 17 } },
    { key = "private", name = "Private",      types = { 3, 7, 18 } },
    { key = "friends", name = "Friends chat", types = { 9, 20 } },
    { key = "clan",    name = "Clan",         types = { 41, 42 } },
    { key = "guest",   name = "Guest clan",   types = { 44, 45 } },
    { key = "group",   name = "Group",        types = { 22, 23, 24, 25 } },
    { key = "trade",   name = "Trade/requests", types = { 100, 101, 102, 107, 108, 111, 113, 132 } },
}
local GROUP_OF = {}
for i, g in ipairs(GROUPS) do for _, t in ipairs(g.types) do GROUP_OF[t] = i end end
-- never ping on our own plugin messages or the dev console
local SKIP = { [33] = true, [96] = true, [98] = true, [99] = true }
-- outgoing private messages are always yours
local OUTGOING = { [6] = true, [19] = true }
-- Filter options: 1 = All (incl. game messages), 2 = All player chat, 3.. = one group
local FILTERS = { "All", "Players" }
for _, g in ipairs(GROUPS) do FILTERS[#FILTERS + 1] = g.name end
local function chanName(t)
    local g = GROUP_OF[t]
    return g and GROUPS[g].name or "Game"
end
local function passesFilter(f, t)
    f = f or 1
    if f == 1 then return true end
    local g = GROUP_OF[t]
    if f == 2 then return g ~= nil end
    return g == f - 2
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
local KEY = "pinger"
local state = {}
pcall(function() state = PersistentDB:GetStructuredData(KEY) or {} end)
if type(state) ~= "table" then state = {} end
local function fixTrig(t, isName)
    if type(t) ~= "table" then t = {} end
    t.on = t.on ~= false
    t.match = (t.match == "contains") and "contains" or "word"
    t.chan = math.tointeger(t.chan) or 1
    if t.chan < 1 or t.chan > #FILTERS then t.chan = 1 end
    t.sid = math.tointeger(t.sid)
    t.sname = type(t.sname) == "string" and t.sname or nil
    if not isName then t.text = helpers.cleanText(t.text, 40) end
    return t
end
state.name = fixTrig(state.name, true)
state.trigs = type(state.trigs) == "table" and state.trigs or {}
do
    local ok = {}
    for _, t in ipairs(state.trigs) do t = fixTrig(t); if t.text ~= "" then ok[#ok + 1] = t end end
    state.trigs = ok
end
state.ignoreOwn = state.ignoreOwn ~= false
state.cooldown = math.tointeger(state.cooldown) or 3
state.bus = type(state.bus) == "string" and state.bus or "MASTER"
local function save() pcall(function() PersistentDB:SetStructuredData(KEY, state) end) end
local MAX_TRIGS = 40

local function busList()
    local L = {}
    pcall(function() for k, v in pairs(audio.AudioBus) do if type(k) == "string" and type(v) == "number" then L[#L + 1] = { k = k, v = v } end end end)
    table.sort(L, function(a, b) return a.v < b.v end)
    local out = {}
    for _, b in ipairs(L) do out[#out + 1] = b.k end
    return out
end

-------------------------------------------------------------------------------
-- Text matching
-------------------------------------------------------------------------------
-- lower case; tags removed; nbsp, '_' and '-' -> space; spaces collapsed
local function normText(s)
    local t = tostring(s or "")
    t = t:gsub("<[^>]*>", "")
    t = t:gsub("\194\160", " "):gsub("\160", " "):gsub("[_%-]", " ")
    t = string.lower(t):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return t
end
local function isWordChar(ch) return ch ~= nil and ch ~= "" and ch:match("[%w]") ~= nil end
local function hasWord(hay, needle)
    if needle == "" then return false end
    local i = 1
    while true do
        local s, e = string.find(hay, needle, i, true)
        if not s then return false end
        if not isWordChar(hay:sub(s - 1, s - 1)) and not isWordChar(hay:sub(e + 1, e + 1)) then return true end
        i = s + 1
    end
end
local function matches(hay, needle, mode)
    if needle == "" then return false end
    if mode == "contains" then return string.find(hay, needle, 1, true) ~= nil end
    return hasWord(hay, needle)
end

-------------------------------------------------------------------------------
-- Local player name
-------------------------------------------------------------------------------
local myName, myNorm, myTight = nil, "", ""
local function readName()
    local n = nil
    pcall(function()
        if Player.IsAvailable() then
            local e = Player.GetEntity()
            if e ~= nil then n = e.displayName end
        end
    end)
    if type(n) == "string" and n ~= "" then
        myName = n:gsub("<[^>]*>", ""):gsub("\194\160", " "):gsub("\160", " ")
        myNorm = normText(n)
        myTight = myNorm:gsub(" ", "")
    end
end
readName()

local function hasChat()
    local ok, v = pcall(function() return Plugin.HasPermission(PluginPermissions.chatAccess) end)
    if not ok then return nil end
    return v == true
end

-------------------------------------------------------------------------------
-- Sound list (same runtime read as Sound Browser)
-------------------------------------------------------------------------------
local MAX_ID = 62000
local function spaced(n) return (tostring(n or ""):gsub("_", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end
local function nice(n) local t = string.lower(spaced(n)); return (t:gsub("^%l", string.upper)) end
local function norm(q) return string.lower(spaced(q)) end
local sounds, byId = {}, {}
local scanNext = nil
local function addSound(id, raw)
    if byId[id] then return end
    local s = { id = id, raw = raw, name = nice(raw), lower = norm(raw) }
    sounds[#sounds + 1] = s; byId[id] = s
end
local function sortSounds() table.sort(sounds, function(a, b) return a.id < b.id end) end
local function readTable()
    pcall(function()
        for k, v in pairs(id.Sound) do
            if type(k) == "string" and type(v) == "number" then addSound(v, k) end
        end
    end)
    if #sounds > 0 then sortSounds(); return true end
    return false
end
local function scanStep()
    local stop = math.min(MAX_ID, scanNext + 1500)
    for i = scanNext, stop do
        local name = nil
        pcall(function() name = id.Sound.FromID(i) end)
        if type(name) == "string" and name ~= "" then addSound(i, name) end
    end
    scanNext = stop + 1
    if scanNext > MAX_ID then scanNext = nil; sortSounds(); return true end
    return false
end
if not readTable() then scanNext = 1 end

local function defaultSound()
    for _, w in ipairs({ "notification", "alert", "ping", "bell", "chime", "ding" }) do
        for _, s in ipairs(sounds) do if string.find(s.lower, w, 1, true) then return s end end
    end
    return sounds[1]
end
local function soundOf(t)
    if t.sid ~= nil then return t.sid, (byId[t.sid] and byId[t.sid].name) or t.sname or ("Sound " .. t.sid) end
    local d = defaultSound()
    if d then return d.id, d.name .. " (default)" end
    return nil, "none"
end

-------------------------------------------------------------------------------
-- Playback (volume is always 1.0: the client mutes anything lower)
-------------------------------------------------------------------------------
local insts = {}
local function play(sid)
    if sid == nil then return false end
    local ok = false
    pcall(function()
        local p = audio.SoundPlaybackParams.new()
        p.type = audio.SoundType.SCRIPT
        p.audioBus = audio.AudioBus[state.bus] or audio.AudioBus.MASTER
        p.volume = 1.0
        p.numLoops = 0
        p.delayTick = 0
        p.emitterShape = audio.EmitterShape.NONE
        local inst = audio.Play(sid, p)
        if inst ~= nil then insts[#insts + 1] = inst; ok = true end
    end)
    if #insts > 16 then table.remove(insts, 1) end
    return ok
end
local function stopAll()
    for _, inst in ipairs(insts) do pcall(function() inst:Stop() end) end
    insts = {}
end

-------------------------------------------------------------------------------
-- Chat handling (read-only)
-------------------------------------------------------------------------------
local recent = {}          -- newest first: { ts, chan, from, trig }
local lastFire = {}        -- trigger table -> timestamp
local seen = { count = 0, types = {} }
local refreshRecent, bindRows
local window = nil

local function fmtClock(ts)
    ts = math.tointeger(ts) or 0
    local d = ts % 86400
    return string.format("%02d:%02d:%02d", d // 3600, (d % 3600) // 60, d % 60)
end

local function onChat(e)
    -- copy fields; the payload is never written to
    local msg, t, from, ts = "", -1, "", 0
    pcall(function()
        msg = tostring(e.chatMessage or "")
        t = math.tointeger(e.chatType) or -1
        from = tostring(e.senderNameUnfiltered or "")
        ts = math.tointeger(e.timestamp) or 0
    end)
    seen.count = seen.count + 1
    seen.types[t] = true
    if SKIP[t] then return end
    if myNorm == "" then readName() end
    local fromN = normText(from)
    local own = OUTGOING[t] or (myNorm ~= "" and fromN ~= "" and (fromN == myNorm or fromN:gsub(" ", "") == myTight))
    if own and state.ignoreOwn then return end
    local hay = normText(msg)
    if hay == "" then return end
    local hit = nil
    local nt = state.name
    if nt.on and myNorm ~= "" and passesFilter(nt.chan, t) then
        if matches(hay, myNorm, nt.match) or (myTight ~= myNorm and matches(hay, myTight, nt.match)) then hit = nt end
    end
    if hit == nil then
        for _, tr in ipairs(state.trigs) do
            if tr.on and passesFilter(tr.chan, t) and matches(hay, normText(tr.text), tr.match) then hit = tr; break end
        end
    end
    if hit == nil then return end
    local now = ts > 0 and ts or (lastFire[hit] or 0) + 1000
    if lastFire[hit] ~= nil and state.cooldown > 0 and now - lastFire[hit] < state.cooldown then return end
    lastFire[hit] = now
    local sid = soundOf(hit)
    play(sid)
    table.insert(recent, 1, { ts = ts, chan = chanName(t), from = from:gsub("<[^>]*>", ""), trig = hit == nt and ("Name: " .. tostring(myName or "?")) or hit.text })
    while #recent > 3 do table.remove(recent) end
    if window and refreshRecent then pcall(refreshRecent) end
end
helpers.subscribe(PLUGIN_NAME, "ChatMessage", "pingerChat", onChat)

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------
local PANEL_W = 600
local COL_PAD, GAP = 8, 6
local ROWS = 8
local ON_W, MATCH_W, CHAN_W, SOUND_W, TEST_W, DEL_W = 40, 70, 104, 150, 40, 24
local DEL_X   = -(COL_PAD + DEL_W)
local TEST_X  = DEL_X - GAP - TEST_W
local SOUND_X = TEST_X - GAP - SOUND_W
local CHAN_X  = SOUND_X - GAP - CHAN_W
local MATCH_X = CHAN_X - GAP - MATCH_W
local TRIG_X  = COL_PAD + ON_W + GAP
local TRIG_W  = MATCH_X - GAP - TRIG_X     -- negative: fill minus this
local BG = { { 0x24/255, 0x21/255, 0x1E/255 }, { 0x2E/255, 0x2A/255, 0x26/255 } }
local SEL = { 0x5A/255, 0x4A/255, 0x2A/255 }
local function tw(s) return helpers.textWidthOf(H.FONT, s) or (#s * 7) end

local view = "list"         -- "list" or "pick"
local pickFor = nil         -- trigger being edited in the picker
local page, ppage = 1, 1
local settingsUI = nil
local refresh

local function newText(root, w, align)
    local t = nil
    pcall(function()
        t = ui.Text.new(root)
        t:SetSize(w, H.ROW_HEIGHT, w < 0 and 1.0 or 0.0, 0.0)
        t.font = H.FONT
        t.content = ""
        t:AlignTo(align or ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        helpers.shadow(t)
    end)
    return t
end
local function newRect(root, k, a)
    local r = nil
    pcall(function()
        r = ui.Rectangle.new(root)
        r.fill = true
        r.colour = Vector4.new(k[1], k[2], k[3], a or 0.92)
    end)
    return r
end

-- all triggers: index 1 = name, then custom
local function trigAt(i) if i == 1 then return state.name end return state.trigs[i - 1] end
local function trigCount() return 1 + #state.trigs end
local function pages() return math.max(1, math.ceil(trigCount() / ROWS)) end

-- components -----------------------------------------------------------------
local C = { list = {}, pick = {} }   -- per-view component lists for hiding
local statusText, permText, addField, addBtn, addMsg
local head, headDiv, listBg, rowBgs, rows = {}, nil, nil, {}, {}
local prevB, nextB, pageLbl, pageBox, pageOf
local ownBtn, cdLbl, cdStep, busBtn, stopBtn
local recentHead, recentRows, recentDiv = nil, {}, nil
-- picker
local pSearch, pBack, pStatus, pHead, pDiv, pBg, pBgs, pRows = nil, nil, nil, {}, nil, nil, {}, {}
local pPrev, pNext, pPageLbl, pPageBox, pPageOf
local pFilter, pFiltered, pLastSeen = "", {}, nil
local PROWS = 12
local P_USE_W, P_ID_W = 44, 48
local P_USE_X = -(COL_PAD + P_USE_W)
local P_ID_X = P_USE_X - GAP - P_ID_W

local function ownLabel() return state.ignoreOwn and "Ignore own: On" or "Ignore own: Off" end
local function busLabel() return "Bus: " .. state.bus end

local function permLine()
    local p = hasChat()
    if p == true then
        return H.lbl("Chat access: ") .. H.col(H.C_GOOD, "granted") .. H.lbl("  messages seen: ") .. H.val(seen.count)
    elseif p == false then
        return H.col(H.C_WARN, "Chat access is off, so Pinger can't see chat. Allow chatAccess for Pinger (dev: ppe pinger chatAccess, then prl pinger).")
    end
    return H.col(H.C_WARN, "Chat access unknown (Plugin.HasPermission failed). Messages seen: " .. seen.count)
end

local function rebuildPick()
    pFiltered = {}
    local q = norm(helpers.cleanText(pFilter, 64))
    for i, s in ipairs(sounds) do
        if q == "" or string.find(s.lower, q, 1, true) or tostring(s.id) == q then pFiltered[#pFiltered + 1] = i end
    end
end
local function ppages() return math.max(1, math.ceil(#pFiltered / PROWS)) end

bindRows = function()
    helpers.setText(statusText, H.lbl("Your name: ") .. (myName and H.gold(myName) or H.col(H.C_WARN, "not detected yet (log in)"))
        .. H.lbl("   Triggers: ") .. H.val(trigCount()))
    helpers.setText(permText, permLine())
    for r = 1, ROWS do
        local c = rows[r]
        local i = (page - 1) * ROWS + r
        local t = trigAt(i)
        c.i = t and i or nil
        local show = t ~= nil and view == "list"
        helpers.setHidden({ c.on, c.text, c.match, c.chan, c.sound, c.test }, not show)
        helpers.setHidden({ c.del }, not show or i == 1)
        helpers.safe(function() rowBgs[r].hidden = not show end)
        if show then
            local isName = i == 1
            helpers.setText(c.on, t.on and "On" or "Off", "label")
            local label = isName and ("Your name" .. (myName and (" (" .. myName .. ")") or "")) or t.text
            helpers.setText(c.text, isName and H.gold(label) or (t.on and H.val(label) or H.lbl(label)))
            helpers.setText(c.match, t.match == "contains" and "Contains" or "Word", "label")
            helpers.setText(c.chan, FILTERS[t.chan] or "All", "label")
            local _, sn = soundOf(t)
            helpers.setText(c.sound, sn, "label")
            helpers.safe(function()
                local k = (pickFor == t) and SEL or BG[(r % 2) + 1]
                rowBgs[r].colour = Vector4.new(k[1], k[2], k[3], 0.92)
            end)
        end
    end
    helpers.setText(pageOf, H.lbl("of " .. pages()))
    helpers.safe(function() pageBox.content = tostring(page) end)
end

refreshRecent = function()
    for r = 1, 3 do
        local e = recent[r]
        local c = recentRows[r]
        if e then
            helpers.setText(c, H.lbl(fmtClock(e.ts) .. "  ") .. H.val(e.chan) .. H.lbl("  " .. (e.from ~= "" and e.from or "(game)") .. "  ") .. H.gold(e.trig))
        else
            helpers.setText(c, r == 1 and H.lbl("No pings yet.") or "")
        end
    end
end

local function bindPick()
    local n = #pFiltered
    for r = 1, PROWS do
        local c = pRows[r]
        local idx = pFiltered[(ppage - 1) * PROWS + r]
        local s = idx and sounds[idx]
        c.sid = s and s.id or nil; c.raw = s and s.raw or nil
        local show = s ~= nil and view == "pick"
        helpers.setHidden({ c.name, c.idt, c.use }, not show)
        helpers.safe(function() pBgs[r].hidden = not show end)
        if show then
            local cur = pickFor and pickFor.sid == s.id
            helpers.setText(c.name, cur and H.gold(s.name) or H.val(s.name))
            helpers.setText(c.idt, H.lbl(tostring(s.id)))
            helpers.safe(function()
                local k = cur and SEL or BG[(r % 2) + 1]
                pBgs[r].colour = Vector4.new(k[1], k[2], k[3], 0.92)
            end)
        end
    end
    local who = pickFor and (pickFor == state.name and "your name" or ("\"" .. tostring(pickFor.text) .. "\"")) or "?"
    local st = scanNext and ("Reading sound list... " .. #sounds)
        or (n .. " sounds. Click a name to hear it, Use to set it for " .. who .. ".")
    helpers.setText(pStatus, H.lbl(st))
    helpers.setText(pPageOf, H.lbl("of " .. ppages()))
    helpers.safe(function() pPageBox.content = tostring(ppage) end)
end

local function placePager(prev, lbl, box, ofT, nxt, y)
    local ow = math.floor(tw("of 99999")) + 4
    local total = 40 + 6 + 40 + 48 + 6 + ow + 6 + 40
    local x = -(total // 2)
    helpers.safe(function()
        prev:SetPos(x, y, 0.5, 0.0); x = x + 46
        lbl:SetSize(40, H.BTN_H); lbl:SetPos(x, y, 0.5, 0.0); x = x + 40
        box:SetPos(x, y, 0.5, 0.0); x = x + 48 + 6
        ofT:SetSize(ow, H.BTN_H); ofT:SetPos(x, y, 0.5, 0.0); x = x + ow + 6
        nxt:SetPos(x, y, 0.5, 0.0)
    end)
end

local function layout()
    local y = H.PAD + helpers.TITLE_HEIGHT + 4
    local isList = view == "list"
    helpers.setHidden(C.list, not isList)
    helpers.setHidden(C.pick, isList)
    if isList then
        helpers.safe(function() statusText:SetPos(COL_PAD, y) end); y = y + H.ROW_HEIGHT
        helpers.safe(function() permText:SetPos(COL_PAD, y) end); y = y + H.ROW_HEIGHT + 4
        helpers.safe(function() addField:SetPos(COL_PAD, y); addBtn:SetPos(-(COL_PAD + 90), y, 1.0, 0.0) end)
        y = y + H.BTN_H + 2
        helpers.safe(function() addMsg:SetPos(COL_PAD, y) end); y = y + H.ROW_HEIGHT
        -- header
        helpers.safe(function()
            head.on:SetPos(COL_PAD, y); head.text:SetPos(TRIG_X, y)
            head.match:SetPos(MATCH_X, y, 1.0, 0.0); head.chan:SetPos(CHAN_X, y, 1.0, 0.0)
            head.sound:SetPos(SOUND_X, y, 1.0, 0.0); head.test:SetPos(TEST_X, y, 1.0, 0.0)
            head.del:SetPos(DEL_X, y, 1.0, 0.0)
        end)
        y = y + H.ROW_HEIGHT
        helpers.safe(function() headDiv:SetPos(COL_PAD, y) end); y = y + 2
        helpers.safe(function() listBg:SetPos(4, y); listBg:SetSize(-8, ROWS * H.ROW_HEIGHT, 1.0, 0.0) end)
        for r = 1, ROWS do
            local c = rows[r]
            local by = y + 1
            helpers.safe(function()
                rowBgs[r]:SetPos(4, y)
                c.on:SetPos(COL_PAD, by)
                c.text:SetPos(TRIG_X, y)
                c.match:SetPos(MATCH_X, by, 1.0, 0.0)
                c.chan:SetPos(CHAN_X, by, 1.0, 0.0)
                c.sound:SetPos(SOUND_X, by, 1.0, 0.0)
                c.test:SetPos(TEST_X, by, 1.0, 0.0)
                c.del:SetPos(DEL_X, by, 1.0, 0.0)
            end)
            y = y + H.ROW_HEIGHT
        end
        y = y + 6
        placePager(prevB, pageLbl, pageBox, pageOf, nextB, y); y = y + H.BTN_H + 8
        -- options row
        local x = COL_PAD
        helpers.safe(function() ownBtn:SetPos(x, y) end); x = x + 120 + GAP * 2
        helpers.safe(function() cdLbl:SetSize(110, H.BTN_H); cdLbl:SetPos(x, y) end); x = x + 110
        cdStep.setPos(x, y); x = x + cdStep.w + GAP * 2
        helpers.safe(function() busBtn:SetPos(x, y) end)
        helpers.safe(function() stopBtn:SetPos(-(COL_PAD + 64), y, 1.0, 0.0) end)
        y = y + H.BTN_H + 8
        helpers.safe(function() recentHead:SetPos(COL_PAD, y) end); y = y + H.ROW_HEIGHT
        helpers.safe(function() recentDiv:SetPos(COL_PAD, y) end); y = y + 2
        for r = 1, 3 do helpers.safe(function() recentRows[r]:SetPos(COL_PAD, y) end); y = y + H.ROW_HEIGHT end
        bindRows(); refreshRecent()
    else
        helpers.safe(function() pBack:SetPos(COL_PAD, y); pSearch:SetPos(COL_PAD + 64 + GAP, y) end)
        y = y + H.BTN_H + 4
        helpers.safe(function() pStatus:SetPos(COL_PAD, y) end); y = y + H.ROW_HEIGHT
        helpers.safe(function()
            pHead.name:SetPos(COL_PAD, y); pHead.idt:SetPos(P_ID_X, y, 1.0, 0.0); pHead.use:SetPos(P_USE_X, y, 1.0, 0.0)
        end)
        y = y + H.ROW_HEIGHT
        helpers.safe(function() pDiv:SetPos(COL_PAD, y) end); y = y + 2
        helpers.safe(function() pBg:SetPos(4, y); pBg:SetSize(-8, PROWS * H.ROW_HEIGHT, 1.0, 0.0) end)
        for r = 1, PROWS do
            local c = pRows[r]
            helpers.safe(function()
                pBgs[r]:SetPos(4, y)
                c.name:SetPos(COL_PAD, y); c.idt:SetPos(P_ID_X, y, 1.0, 0.0)
                c.use:SetPos(P_USE_X, y + 1, 1.0, 0.0)
            end)
            y = y + H.ROW_HEIGHT
        end
        y = y + 6
        placePager(pPrev, pPageLbl, pPageBox, pPageOf, pNext, y); y = y + H.BTN_H + 8
        bindPick()
    end
    y = y + 4
    if settingsUI ~= nil then
        settingsUI.open = state.editOpen == true
        y = settingsUI:place(y)
    end
    helpers.fitHeight(y + H.PAD)
end

refresh = function() layout(); helpers.refit() end

local function goPage(p) page = math.max(1, math.min(pages(), p)); bindRows() end
local function goPPage(p) ppage = math.max(1, math.min(ppages(), p)); bindPick() end
local function openPicker(t)
    pickFor = t; view = "pick"
    rebuildPick()
    ppage = 1
    if t.sid then for k, idx in ipairs(pFiltered) do if sounds[idx].id == t.sid then ppage = (k - 1) // PROWS + 1; break end end end
    refresh()
end
local function closePicker() view = "list"; pickFor = nil; stopAll(); refresh() end
-- X in the title bar closes only the sound picker while it is open.
helpers.onCloseSub = function()
    if view == "pick" then closePicker(); return true end
    return false
end

local function L(c) C.list[#C.list + 1] = c; return c end
local function P(c) C.pick[#C.pick + 1] = c; return c end

local function pageInput(root, getMax, go, name)
    local b = helpers.input(root, 0, 0, 48, H.BTN_H, "1")
    helpers.setTip(b, "Current page. Click, type a page number and press Enter.")
    pcall(function()
        b:Subscribe(ui.Hook.ONCONTENTCHANGED, name, function(_, cause)
            if cause == ui.InputFieldActionResult.SUBMIT or cause == ui.InputFieldActionResult.SUBMIT_ON_FOCUS_LOSS then
                local t = ""; pcall(function() t = tostring(b.content or "") end)
                local n = helpers.cleanInt(helpers.cleanText(t, 8), 1, getMax())
                if n then go(n) else go(nil) end
            end
        end)
    end)
    return b
end

local function addTrigger()
    local t = ""
    pcall(function() t = tostring(addField.content or "") end)
    t = helpers.cleanText(t, 40)
    local msg
    if t == "" then msg = H.col(H.C_WARN, "Type a word or phrase first.")
    elseif #state.trigs >= MAX_TRIGS then msg = H.col(H.C_WARN, "Limit is " .. MAX_TRIGS .. " triggers.")
    else
        local dup = false
        for _, x in ipairs(state.trigs) do if normText(x.text) == normText(t) then dup = true end end
        if dup then msg = H.col(H.C_WARN, "\"" .. t .. "\" is already a trigger.")
        else
            state.trigs[#state.trigs + 1] = fixTrig({ text = t, on = true, match = "word", chan = 1 })
            save()
            helpers.safe(function() addField.content = "" end)
            msg = H.col(H.C_GOOD, "Added \"" .. t .. "\". Click its Sound to choose an alert.")
            page = pages()
        end
    end
    helpers.setText(addMsg, msg)
    bindRows()
end

local function buildPanel(root)
    -- list view ---------------------------------------------------------------
    statusText = L(newText(root, -2 * COL_PAD))
    permText = L(newText(root, -2 * COL_PAD)); helpers.track(permText, "content", 2)
    helpers.setTip(permText, "Pinger reads chat through the chatAccess permission. Without it the game sends no chat events to the plugin. Read-only: it never changes or sends chat.")
    addField = L(helpers.input(root, 0, 0, 200, H.BTN_H, "Add a word or phrase that should ping you"))
    helpers.safe(function() addField:SetSize(-(2 * COL_PAD + 90 + GAP), H.BTN_H, 1.0, 0.0) end)
    helpers.setTip(addField, "Type a word or phrase (up to 40 characters), then press Add trigger. Case doesn't matter; spaces, _ and - count as the same.")
    addBtn = L(helpers.button(root, 0, 0, 90, H.BTN_H, "Add trigger", addTrigger))
    helpers.setTip(addBtn, "Add the typed word or phrase as a new trigger.")
    addMsg = L(newText(root, -2 * COL_PAD))
    helpers.setText(addMsg, H.lbl("Your name is detected automatically. Add other words below it."))

    listBg = L(newRect(root, { 0x1C/255, 0x1A/255, 0x17/255 }, 0.94))
    for r = 1, ROWS do
        local bg = L(newRect(root, BG[(r % 2) + 1]))
        helpers.safe(function() bg:SetSize(-8, H.ROW_HEIGHT, 1.0, 0.0); bg.hidden = true end)
        rowBgs[r] = bg
    end
    local function hd(w, s, tip)
        local t = L(newText(root, w)); helpers.setText(t, H.gold(s)); helpers.setTip(t, tip); return t
    end
    head.on = hd(ON_W, "On", "Turn a trigger on or off.")
    head.text = hd(TRIG_W, "Trigger", "What Pinger listens for. The first row is your own name, read from the game.")
    head.match = hd(MATCH_W, "Match", "Word: only whole words (\"bob\" won't match \"bobby\"). Contains: anywhere in the message.")
    head.chan = hd(CHAN_W, "Channels", "Which chat this trigger listens to. All includes game messages; Players is every player chat channel.")
    head.sound = hd(SOUND_W, "Sound", "The alert for this trigger. Click a row's sound to pick another.")
    head.test = hd(TEST_W, "Test", "Play this trigger's sound now.")
    head.del = hd(DEL_W, "Del", "Remove the trigger. Your name can't be removed, only turned off.")
    headDiv = L(newRect(root, { 0.78, 0.70, 0.52 }, 0.9))
    helpers.safe(function() headDiv:SetSize(-2 * COL_PAD, 1, 1.0, 0.0) end)

    for r = 1, ROWS do
        local c = {}
        local function cur() return c.i and trigAt(c.i) end
        c.on = L(helpers.button(root, 0, 0, ON_W, 18, "On", function()
            local t = cur(); if not t then return end
            t.on = not t.on; save(); bindRows()
        end))
        helpers.setTip(c.on, "Click to turn this trigger on or off.")
        c.text = L(newText(root, TRIG_W)); helpers.track(c.text, "content", 2)
        helpers.setTip(c.text, function()
            local t = cur(); if not t then return nil end
            if c.i == 1 then return "Your display name" .. (myName and (" (" .. myName .. ")") or "") .. ", matched without case. Spaces, underscores and the game's non-breaking space all match, and so does the name written without spaces." end
            return "Trigger \"" .. t.text .. "\"."
        end)
        c.match = L(helpers.button(root, 0, 0, MATCH_W, 18, "Word", function()
            local t = cur(); if not t then return end
            t.match = t.match == "word" and "contains" or "word"; save(); bindRows()
        end))
        helpers.setTip(c.match, "Click to switch between Word (whole words only) and Contains (anywhere, even inside other words).")
        c.chan = L(helpers.button(root, 0, 0, CHAN_W, 18, "All", function()
            local t = cur(); if not t then return end
            t.chan = t.chan % #FILTERS + 1; save(); bindRows()
        end))
        helpers.setTip(c.chan, function()
            return "Click to cycle: " .. table.concat(FILTERS, ", ") .. ". All also includes game and broadcast messages."
        end)
        c.sound = L(helpers.button(root, 0, 0, SOUND_W, 18, "-", function()
            local t = cur(); if t then openPicker(t) end
        end))
        helpers.setTip(c.sound, function()
            local t = cur(); if not t then return nil end
            local sid, sn = soundOf(t)
            return "Alert: " .. sn .. (sid and (" (id " .. sid .. ")") or "") .. ". Click to choose a different sound from the game's sound list."
        end)
        c.test = L(helpers.button(root, 0, 0, TEST_W, 18, "Play", function()
            local t = cur(); if t then play((soundOf(t))) end
        end))
        helpers.setTip(c.test, "Play this trigger's alert at full volume on the selected bus.")
        c.del = L(helpers.button(root, 0, 0, DEL_W, 18, "x", function()
            if not c.i or c.i == 1 then return end
            table.remove(state.trigs, c.i - 1); save()
            if page > pages() then page = pages() end
            bindRows()
        end))
        helpers.setTip(c.del, "Remove this trigger.")
        rows[r] = c
    end
    prevB = L(helpers.button(root, 0, 0, 40, H.BTN_H, "Prev", function() goPage(page - 1) end))
    pageLbl = L(newText(root, 40)); helpers.setText(pageLbl, H.lbl("Page"))
    pageBox = L(pageInput(root, pages, function(n) goPage(n or page) end, "pgPage"))
    pageOf = L(newText(root, 60))
    nextB = L(helpers.button(root, 0, 0, 40, H.BTN_H, "Next", function() goPage(page + 1) end))

    ownBtn = L(helpers.button(root, 0, 0, 120, H.BTN_H, ownLabel(), function()
        state.ignoreOwn = not state.ignoreOwn; save(); helpers.setText(ownBtn, ownLabel(), "label")
    end))
    helpers.setTip(ownBtn, "On: messages you send (including private messages you send) never ping you. Off: they can, which is handy for testing.")
    cdLbl = L(newText(root, 110)); helpers.setText(cdLbl, H.lbl("Cooldown (sec)"))
    helpers.setTip(cdLbl, "After a trigger pings, it stays quiet for this many seconds (0-60) so a busy chat doesn't spam you. Each trigger has its own cooldown timer.")
    cdStep = helpers.stepper(root, 0, 0, { name = "pgCd", min = 0, max = 60, step = 1,
        get = function() return state.cooldown end,
        set = function(v) state.cooldown = v; save() end,
        tip = "Seconds between pings from the same trigger (0-60). Type a value and press Enter, or use - and +." })
    L(cdStep.minus); L(cdStep.box); L(cdStep.plus)
    do
        local ok = false
        for _, b in ipairs(busList()) do if b == state.bus then ok = true end end
        if not ok then state.bus = "MASTER" end
    end
    busBtn = L(helpers.button(root, 0, 0, 120, H.BTN_H, busLabel(), function()
        local Lb = busList(); if #Lb == 0 then return end
        local k = 1
        for i, b in ipairs(Lb) do if b == state.bus then k = i end end
        state.bus = Lb[k % #Lb + 1]; save(); helpers.setText(busBtn, busLabel(), "label")
    end))
    helpers.setTip(busBtn, function()
        return "Audio bus for alerts: " .. state.bus .. ". MASTER follows only the master volume; SFX, MUSIC, AMBIENT and VOICEOVER follow their own sliders; the *_SUB buses may be silent. Alerts always play at full volume, because the game mutes anything lower. Click to cycle."
    end)
    stopBtn = L(helpers.button(root, 0, 0, 64, H.BTN_H, "Stop", function() stopAll() end))
    helpers.setTip(stopBtn, "Stop any alert that is still playing.")
    recentHead = L(newText(root, -2 * COL_PAD)); helpers.setText(recentHead, H.gold("Recent pings") .. H.lbl("  (game time, UTC)"))
    recentDiv = L(newRect(root, { 0.78, 0.70, 0.52 }, 0.9))
    helpers.safe(function() recentDiv:SetSize(-2 * COL_PAD, 1, 1.0, 0.0) end)
    for r = 1, 3 do recentRows[r] = L(newText(root, -2 * COL_PAD)); helpers.track(recentRows[r], "content", 2) end

    -- picker view -------------------------------------------------------------
    pBack = P(helpers.button(root, 0, 0, 64, H.BTN_H, "Back", closePicker))
    helpers.setTip(pBack, "Back to the trigger list (the X button does the same while the picker is open).")
    pSearch = P(helpers.input(root, 0, 0, 200, H.BTN_H, "Search sound name or id"))
    helpers.safe(function() pSearch:SetSize(-(2 * COL_PAD + 64 + GAP), H.BTN_H, 1.0, 0.0) end)
    helpers.setTip(pSearch, "Filter the game's sounds by name or exact id.")
    pStatus = P(newText(root, -2 * COL_PAD)); helpers.track(pStatus, "content", 2)
    pBg = P(newRect(root, { 0x1C/255, 0x1A/255, 0x17/255 }, 0.94))
    for r = 1, PROWS do
        local bg = P(newRect(root, BG[(r % 2) + 1]))
        helpers.safe(function() bg:SetSize(-8, H.ROW_HEIGHT, 1.0, 0.0); bg.hidden = true end)
        pBgs[r] = bg
    end
    pHead.name = P(newText(root, P_ID_X - GAP - COL_PAD)); helpers.setText(pHead.name, H.gold("Sound"))
    helpers.setTip(pHead.name, "Click a name to hear it. The current sound is gold.")
    pHead.idt = P(newText(root, P_ID_W)); helpers.setText(pHead.idt, H.gold("ID"))
    pHead.use = P(newText(root, P_USE_W)); helpers.setText(pHead.use, H.gold("Use"))
    helpers.setTip(pHead.use, "Set this sound as the trigger's alert and go back.")
    pDiv = P(newRect(root, { 0.78, 0.70, 0.52 }, 0.9))
    helpers.safe(function() pDiv:SetSize(-2 * COL_PAD, 1, 1.0, 0.0) end)
    for r = 1, PROWS do
        local c = {}
        c.name = P(newText(root, P_ID_X - GAP - COL_PAD)); helpers.track(c.name, "content", 2)
        helpers.blockClicks(c.name)
        helpers.setTip(c.name, function() return c.sid and (tostring(c.raw) .. " (id " .. c.sid .. "). Click to hear it.") or nil end)
        pcall(function()
            c.name:Subscribe(ui.Hook.ONCLICK, "pgPrev", function()
                pcall(helpers.raiseWindow)
                if c.sid then stopAll(); play(c.sid) end
            end)
        end)
        c.idt = P(newText(root, P_ID_W))
        c.use = P(helpers.button(root, 0, 0, P_USE_W, 18, "Use", function()
            if c.sid and pickFor then
                pickFor.sid = c.sid; pickFor.sname = byId[c.sid] and byId[c.sid].name or nil
                save(); closePicker()
            end
        end))
        helpers.setTip(c.use, "Use this sound for the trigger.")
        pRows[r] = c
    end
    pPrev = P(helpers.button(root, 0, 0, 40, H.BTN_H, "Prev", function() goPPage(ppage - 1) end))
    pPageLbl = P(newText(root, 40)); helpers.setText(pPageLbl, H.lbl("Page"))
    pPageBox = P(pageInput(root, ppages, function(n) goPPage(n or ppage) end, "pgPPage"))
    pPageOf = P(newText(root, 60))
    pNext = P(helpers.button(root, 0, 0, 40, H.BTN_H, "Next", function() goPPage(ppage + 1) end))

    local items = helpers.commonItems(function() refresh() end)
    table.insert(items, 1, { labelFn = function() return "Custom triggers: " .. #state.trigs end, options = { "Clear" },
        get = function() return 1 end, set = function() state.trigs = {}; save(); page = 1; bindRows() end })
    settingsUI = helpers.newSettings(root, items, 6)
    settingsUI.onChange = function() refresh() end
    helpers.editToggle(root, function() return state.editOpen == true end, function(v)
        state.editOpen = v; save(); refresh()
    end)
    refresh()
end

-------------------------------------------------------------------------------
-- Ticks
-------------------------------------------------------------------------------
local tick = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "pgLogic", function()
    helpers.tickToast()
    tick = tick + 1
    if scanNext ~= nil then
        if scanStep() then if window and view == "pick" then rebuildPick(); bindPick() end end
    end
    if tick % 250 == 0 then
        local before = myName
        readName()
        if window and view == "list" then pcall(bindRows) end
        if before ~= myName then helpers.diag("name", { detected = myName ~= nil }) end
    end
    if window and view == "pick" and pSearch and tick % 10 == 0 then
        local t = ""
        pcall(function() t = tostring(pSearch.content or "") end)
        if t ~= pLastSeen then pLastSeen = t; pFilter = t; rebuildPick(); goPPage(1) end
    end
    if tick % 50 == 0 then
        local keep = {}
        for _, inst in ipairs(insts) do
            local p = false; pcall(function() p = inst.isPlaying == true end)
            if p then keep[#keep + 1] = inst end
        end
        insts = keep
    end
end)
table.insert(helpers.onLogin, function() readName(); if window and view == "list" then pcall(bindRows) end end)

local function tryCreateWindow()
    if window ~= nil then return end
    window = helpers.createWindow(PLUGIN_NAME, PANEL_W, 200, 0.35, 0.20)
    if window ~= nil then
        if not state.w010 then helpers.growWidth(PANEL_W); state.w010 = true; save() end
        local ok, err = pcall(buildPanel, window)
        helpers.raiseGrip()
        helpers.diag("pinger", { chat = hasChat(), sounds = #sounds })
        if not ok then helpers.log("[" .. PLUGIN_NAME .. "] ERROR building panel: " .. tostring(err)) end
    end
end
tryCreateWindow()

local retryTicks = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "windowRetry", function()
    if window == nil then
        retryTicks = retryTicks + 1
        if retryTicks >= 50 then retryTicks = 0; tryCreateWindow() end
    end
end)

helpers.installRibbon(PLUGIN_NAME)
helpers.log("[" .. PLUGIN_NAME .. "] loaded")

function PluginShutdown()
    pcall(function() Event.ChatMessage.Unsubscribe("pingerChat") end)
    stopAll()
    save()
    helpers.destroyToast()
    helpers.destroyWindow()
end
