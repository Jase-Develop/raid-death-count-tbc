-- Raid Death Count (TBC 2.5.6) - core: death detection, RaidID scoping, persistence, comms, reporting.
-- Everything public hangs off the global RaidDeathCount table (alias RDC). The UI file attaches the HUD.

RaidDeathCount = RaidDeathCount or {}
local RDC = RaidDeathCount

local ADDON_NAME    = "raid-death-count"   -- must match the folder / .toc for metadata + ADDON_LOADED
local COMM_PREFIX   = "RDC1"               -- addon-message prefix (format version baked in)
local POLL_INTERVAL = 0.5                  -- seconds between death sweeps
local SYNC_THROTTLE = 5                    -- min seconds between our resync replies
local MSG_MAX       = 230                  -- soft cap on an addon-message body before we flush a chunk

-- ── State ─────────────────────────────────────────────────────────────────────
local DB                      -- = RaidDeathCountDB (set at ADDON_LOADED)
local prevDead   = {}         -- fullName -> last-seen dead state (nil = no baseline yet)
local watched    = {}         -- array of unit tokens to sweep for deaths
local lastSyncReply = 0       -- time() of our last full-state reply (throttle)

-- ── Small helpers ─────────────────────────────────────────────────────────────

-- Addon version, read from the .toc "## Version" (single source of truth). Modern C_AddOns namespace
-- with a fallback to the older global. Bump ## Version in the .toc before each commit to main.
function RDC.GetVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMeta and getMeta(ADDON_NAME, "Version")) or "?"
end

-- "Name-Realm" (or plain "Name" same-realm) for a unit; the shared key every observer agrees on.
local function FullName(unit)
    if not UnitExists(unit) then return nil end
    return GetUnitName(unit, true)
end

-- The addon channel for the current group (nil when ungrouped, so comms simply go quiet solo).
local function GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- Rebuild the list of unit tokens whose death we track (self always included so solo runs still count).
local function RebuildWatched()
    wipe(watched)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do watched[#watched + 1] = "raid" .. i end
    elseif IsInGroup() then
        watched[#watched + 1] = "player"
        for i = 1, GetNumGroupMembers() - 1 do watched[#watched + 1] = "party" .. i end
    else
        watched[#watched + 1] = "player"
    end
end

-- ── RaidID (sync scope) ───────────────────────────────────────────────────────
-- Different RaidIDs are different raids and never merge. Preference: the server lockout id (identical
-- for everyone saved to the same reset, changes on reset); before the first boss (not yet saved) we fall
-- back to the instance map id. The active id is STICKY: kept while we're outside (corpse-running, town)
-- so counts survive leaving and re-entering; it only switches when we positively resolve a different raid.

local function FindLockoutID(instanceName)
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    for i = 1, n do
        local name, id, _, _, locked = GetSavedInstanceInfo(i)
        if locked and name == instanceName then return id end
    end
end

-- Returns a RaidID string + the instance name, or nil when we're not standing in a raid instance.
local function ResolveRaidID()
    local iname, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    if itype ~= "raid" then return nil end
    local lockoutID = FindLockoutID(iname)
    if lockoutID and lockoutID ~= 0 then return "lock:" .. lockoutID, iname end
    return "map:" .. tostring(mapID), iname   -- fresh raid, not yet saved
end

-- ── Sessions / data ───────────────────────────────────────────────────────────

local function EnsureSession(rid, iname)
    DB.sessions[rid] = DB.sessions[rid] or { started = time(), instance = iname, players = {} }
    return DB.sessions[rid]
end

-- The session for the active RaidID, or nil if we have no raid context yet.
local function ActiveSession()
    if not DB or not DB.currentRaidID then return nil end
    return DB.sessions[DB.currentRaidID]
end

local function RefreshHUD()
    if RDC.RefreshHUD then RDC.RefreshHUD() end
end

-- Keep only the N most recent sessions so the DB never grows without bound.
local function PruneSessions(keep)
    local ids = {}
    for id in pairs(DB.sessions) do ids[#ids + 1] = id end
    if #ids <= keep then return end
    table.sort(ids, function(a, b) return (DB.sessions[a].started or 0) > (DB.sessions[b].started or 0) end)
    for i = keep + 1, #ids do
        if ids[i] ~= DB.currentRaidID then DB.sessions[ids[i]] = nil end
    end
end

-- ── Death recording + merge ───────────────────────────────────────────────────

-- Record a locally-witnessed death: increment, persist, broadcast, refresh. Returns the new count.
local function RecordDeath(name, class)
    local s = ActiveSession()
    if not s then return end
    local p = s.players[name]
    if not p then p = { class = class, deaths = 0 }; s.players[name] = p end
    if class then p.class = class end
    p.deaths = p.deaths + 1
    RefreshHUD()
    RDC.BroadcastDeath(name, p.class, p.deaths)
    return p.deaths
end

-- Merge a remote count by MAX (counts only rise within a raid, so max always converges). Returns true
-- if anything changed.
local function ApplyRemote(name, class, deaths)
    local s = ActiveSession()
    if not s or not name or not deaths then return false end
    local p = s.players[name]
    if not p then p = { class = class, deaths = 0 }; s.players[name] = p end
    if class and class ~= "" then p.class = class end
    if deaths > p.deaths then
        p.deaths = deaths
        return true
    end
    return false
end

-- ── Snapshot (for HUD + reports) ──────────────────────────────────────────────

-- Array of { name, class, deaths } with deaths > 0, sorted by deaths desc then name asc.
-- When demo mode is on (RDC.demoData set), the snapshot mirrors that fake data instead of the session,
-- so a UI pass can be done anywhere without a raid or real deaths.
function RDC.GetSnapshot()
    local out = {}
    if RDC.demoData then
        for _, e in ipairs(RDC.demoData) do
            out[#out + 1] = { name = e.name, class = e.class, deaths = e.deaths }
        end
    else
        local s = ActiveSession()
        if s then
            for name, p in pairs(s.players) do
                if (p.deaths or 0) > 0 then
                    out[#out + 1] = { name = name, class = p.class, deaths = p.deaths }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.deaths ~= b.deaths then return a.deaths > b.deaths end
        return a.name < b.name
    end)
    return out
end

function RDC.GetInstanceName()
    if RDC.demoData then return "Demo Preview" end
    local s = ActiveSession()
    return s and s.instance
end

-- ── Demo / UI-preview mode ─────────────────────────────────────────────────────
-- Toggles fake data (5 rows, varied classes/counts) so the HUD can be styled outside a raid. Purely
-- local: never touches the DB sessions and never broadcasts. Also force-shows the HUD so it's visible.
function RDC.ToggleDemo()
    if RDC.demoData then
        RDC.demoData = nil
        print("|cff88bbffRaidDeathCount|r demo data off.")
    else
        RDC.demoData = {
            { name = "Grimtusk",   class = "WARRIOR", deaths = 12 },
            { name = "Salandra",   class = "PRIEST",  deaths = 8  },
            { name = "Backstabby", class = "ROGUE",   deaths = 5  },
            { name = "Pewpewz",    class = "MAGE",     deaths = 3  },
            { name = "Huntardo",   class = "HUNTER",   deaths = 1  },
        }
        print("|cff88bbffRaidDeathCount|r demo data on (5 sample rows).")
    end
    if RDC.SetHUDShown then RDC.SetHUDShown(true) elseif RDC.RefreshHUD then RDC.RefreshHUD() end
end

-- ── Comms ─────────────────────────────────────────────────────────────────────
-- Wire format: "<raidID>|<op>|<payload>". Ops: D = one death (name,class,deaths); ? = resync request;
-- S = full-state chunk (name,class,deaths;...). Messages for a different RaidID are ignored. Merge is
-- by max per player, so duplicate/out-of-order/chunked S messages all converge safely.

local function SendComm(msg)
    local ch = GroupChannel()
    if not ch then return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, ch)
    elseif SendAddonMessage then
        SendAddonMessage(COMM_PREFIX, msg, ch)
    end
end

function RDC.BroadcastDeath(name, class, deaths)
    if not DB.currentRaidID then return end
    SendComm(DB.currentRaidID .. "|D|" .. name .. "," .. (class or "") .. "," .. deaths)
end

-- Ask peers for their full state for our current raid (on join / zone-in / late arrival).
local function RequestResync()
    if not DB.currentRaidID then return end
    SendComm(DB.currentRaidID .. "|?|")
end

-- Reply to a resync request with our full state, packed into <=MSG_MAX chunks (throttled).
local function SendFullState()
    if not DB.currentRaidID then return end
    if time() - lastSyncReply < SYNC_THROTTLE then return end
    local s = ActiveSession()
    if not s then return end
    lastSyncReply = time()
    local prefix = DB.currentRaidID .. "|S|"
    local buf = ""
    local flushed = false
    for name, p in pairs(s.players) do
        if (p.deaths or 0) > 0 then
            local entry = name .. "," .. (p.class or "") .. "," .. p.deaths .. ";"
            if #prefix + #buf + #entry > MSG_MAX then
                SendComm(prefix .. buf); buf = ""; flushed = true
            end
            buf = buf .. entry
        end
    end
    if buf ~= "" then SendComm(prefix .. buf); flushed = true end
    return flushed
end

-- Parse and apply an inbound message. Ignores anything for a raid other than our current one.
local function OnComm(msg, sender)
    local rid, op, payload = msg:match("^(.-)|(.-)|(.*)$")
    if not rid or rid ~= DB.currentRaidID then return end
    if op == "D" then
        local name, class, deaths = payload:match("^(.-),(.-),(%d+)$")
        if name and ApplyRemote(name, class, tonumber(deaths)) then RefreshHUD() end
    elseif op == "S" then
        local changed = false
        for name, class, deaths in payload:gmatch("([^,;]+),([^,;]*),(%d+);?") do
            if ApplyRemote(name, class, tonumber(deaths)) then changed = true end
        end
        if changed then RefreshHUD() end
    elseif op == "?" then
        SendFullState()
    end
end

-- ── Death sweep (poll) ────────────────────────────────────────────────────────
-- UnitIsDeadOrGhost is synced for group members regardless of range, so an alive->dead edge is a death.
-- A poll (vs health events) is used so a death across the map is never missed for units we can see; any
-- remaining gap is filled by peers' broadcasts. Feign Death is guarded out.

local function Sweep()
    if not DB.currentRaidID then return end
    for _, unit in ipairs(watched) do
        local name = FullName(unit)
        if name then
            local dead = UnitIsDeadOrGhost(unit) and not (UnitIsFeignDeath and UnitIsFeignDeath(unit))
            local was = prevDead[name]
            if was == nil then
                prevDead[name] = dead            -- baseline only, never counts (we didn't witness it)
            elseif dead and not was then
                prevDead[name] = true
                RecordDeath(name, select(2, UnitClass(unit)))
            elseif not dead then
                prevDead[name] = false
            end
        end
    end
end

-- ── RaidID transitions ────────────────────────────────────────────────────────

-- Copy one session's counts into another, merging by MAX per player (same rule sync uses).
local function MergeSession(from, to)
    for name, p in pairs(from.players) do
        local q = to.players[name]
        if not q then q = { class = p.class, deaths = 0 }; to.players[name] = q end
        if p.class and p.class ~= "" then q.class = p.class end
        if (p.deaths or 0) > (q.deaths or 0) then q.deaths = p.deaths end
    end
end

-- Re-resolve the active raid; switch (fresh session + resync) only on a genuinely different raid.
local function UpdateRaidID()
    local rid, iname = ResolveRaidID()
    if rid and rid ~= DB.currentRaidID then
        local oldID = DB.currentRaidID
        DB.currentRaidID = rid
        local newS = EnsureSession(rid, iname)
        -- Map->lock upgrade for the raid we're standing in: the temporary "map:<id>" fallback becomes the
        -- real server lockout key the moment we get saved (first boss). That is the SAME raid, not a new
        -- one, so carry its counts forward and drop the stale map session instead of resetting to zero.
        if oldID and oldID:match("^map:") and rid:match("^lock:") then
            local oldS = DB.sessions[oldID]
            if oldS and oldS.instance == iname then
                MergeSession(oldS, newS)
                DB.sessions[oldID] = nil
            end
        end
        wipe(prevDead)               -- new raid context: drop stale baselines (re-baselined next sweep)
        PruneSessions(10)
        RequestResync()
        RefreshHUD()
    elseif rid and iname then
        local s = ActiveSession()
        if s and not s.instance then s.instance = iname end
    end
end

-- ── Reporting ─────────────────────────────────────────────────────────────────

local function ClassLabel(class)
    if not class then return "?" end
    return class:sub(1, 1) .. class:sub(2):lower()
end

local function ReportLine(text)
    local ch = GroupChannel()
    if ch then
        SendChatMessage(text, ch)
    else
        print("|cff88bbffRaidDeathCount|r " .. text)   -- solo: print locally
    end
end

-- mode = "all" | "top3" | "top5" | a player name. Posts to raid/party (or prints solo).
function RDC.Report(mode)
    local snap = RDC.GetSnapshot()
    if #snap == 0 then ReportLine("No deaths recorded yet.") return end

    if mode and mode ~= "all" and mode ~= "top3" and mode ~= "top5" then
        local want = mode:lower()
        for _, e in ipairs(snap) do
            if e.name:lower():match("^" .. want) then
                ReportLine(("%s (%s): %d death%s"):format(e.name, ClassLabel(e.class), e.deaths, e.deaths == 1 and "" or "s"))
                return
            end
        end
        ReportLine("No deaths recorded for " .. mode .. ".")
        return
    end

    local limit = (mode == "top3" and 3) or (mode == "top5" and 5) or #snap
    local title = (mode == "top3" and "Top 3") or (mode == "top5" and "Top 5") or "All"
    ReportLine("Raid Death Count (" .. title .. "):")
    for i = 1, math.min(limit, #snap) do
        local e = snap[i]
        ReportLine(("%d. %s (%s): %d"):format(i, e.name, ClassLabel(e.class), e.deaths))
    end
end

-- Clear the current raid's counts.
function RDC.ResetCurrent()
    if not DB or not DB.currentRaidID then return end
    local s = DB.sessions[DB.currentRaidID]
    if s then wipe(s.players) end
    wipe(prevDead)
    RefreshHUD()
    print("|cff88bbffRaidDeathCount|r current raid counts cleared.")
end

-- ── Events / driver ───────────────────────────────────────────────────────────

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")

frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        RaidDeathCountDB = RaidDeathCountDB or {}
        DB = RaidDeathCountDB
        DB.sessions = DB.sessions or {}
        DB.hud = DB.hud or {}
        DB.minimap = DB.minimap or {}
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
        end

    elseif event == "PLAYER_LOGIN" then
        RebuildWatched()
        UpdateRaidID()
        if RDC.InitHUD then RDC.InitHUD() end
        if RDC.InitMinimap then RDC.InitMinimap() end
        RequestResync()
        print(("|cff88bbffRaid Death Count|r v%s loaded. Enjoy!"):format(RDC.GetVersion()))

    elseif event == "PLAYER_ENTERING_WORLD" then
        RebuildWatched()
        UpdateRaidID()
        RequestResync()

    elseif event == "GROUP_ROSTER_UPDATE" then
        RebuildWatched()
        UpdateRaidID()

    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == COMM_PREFIX and DB then OnComm(arg2, arg4) end
    end
end)

-- Death poll: only sweeps while we have an active raid context.
local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < POLL_INTERVAL then return end
    acc = 0
    if DB and DB.currentRaidID then Sweep() end
end)

-- ── Debug ─────────────────────────────────────────────────────────────────────
-- /run RaidDeathCount.DebugDump() prints RaidID resolution + the current snapshot (for in-game tuning).
function RDC.DebugDump()
    local iname, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    print("|cff88bbffRDC|r instance:", iname, "type:", itype, "mapID:", mapID)
    local rid = ResolveRaidID()
    print("|cff88bbffRDC|r ResolveRaidID:", tostring(rid), "  active:", tostring(DB and DB.currentRaidID))
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    print("|cff88bbffRDC|r saved instances:", n)
    for i = 1, n do
        local name, id, reset, diff, locked = GetSavedInstanceInfo(i)
        print(("  [%d] %s id=%s reset=%s diff=%s locked=%s"):format(i, tostring(name), tostring(id), tostring(reset), tostring(diff), tostring(locked)))
    end
    for _, e in ipairs(RDC.GetSnapshot()) do
        print(("  %s (%s): %d"):format(e.name, tostring(e.class), e.deaths))
    end
end

-- ── Slash command ─────────────────────────────────────────────────────────────
SLASH_RAIDDEATHCOUNT1 = "/rdc"
SlashCmdList["RAIDDEATHCOUNT"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S+)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "report" then
        RDC.Report(rest ~= "" and rest or "all")
    elseif cmd == "reset" then
        RDC.ResetCurrent()
    elseif cmd == "lock" then
        if RDC.ToggleLock then RDC.ToggleLock() end
    elseif cmd == "minimap" then
        if RDC.ToggleMinimap then RDC.ToggleMinimap() end
    elseif cmd == "demo" then
        if RDC.ToggleDemo then RDC.ToggleDemo() end
    elseif cmd == "version" then
        print("|cff88bbffRaidDeathCount|r v" .. RDC.GetVersion())
    elseif cmd == "" or cmd == "toggle" then
        if RDC.ToggleHUD then RDC.ToggleHUD() end
    else
        print("|cff88bbffRaidDeathCount|r v" .. RDC.GetVersion() .. " commands:")
        print("  /rdc                toggle the HUD")
        print("  /rdc report [player|top3|top5|all]   report to party/raid")
        print("  /rdc lock           lock/unlock HUD move + resize")
        print("  /rdc minimap        show/hide the minimap button")
        print("  /rdc demo           toggle sample data for a UI preview")
        print("  /rdc version        print the addon version")
        print("  /rdc reset          clear this raid's counts")
    end
end
