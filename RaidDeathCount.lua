-- Raid Death Count (TBC 2.5.6) - core: death detection, RaidID scoping, persistence, comms, reporting.
-- Everything public hangs off the global RaidDeathCount table (alias RDC). The UI file attaches the HUD.

RaidDeathCount = RaidDeathCount or {}
local RDC = RaidDeathCount

local ADDON_NAME    = "raid-death-count"   -- must match the folder / .toc for metadata + ADDON_LOADED
local COMM_PREFIX   = "RDC1"               -- addon-message prefix (format version baked in)
local POLL_INTERVAL = 0.5                  -- seconds between death sweeps
local SYNC_THROTTLE = 5                    -- min seconds between our resync replies
local MSG_MAX       = 230                  -- soft cap on an addon-message body before we flush a chunk
local PEER_STALE    = 90                   -- seconds before a silent peer drops out of the sync count
local HEARTBEAT     = 30                   -- seconds between our presence pings (op H)

-- ── State ─────────────────────────────────────────────────────────────────────
local DB                      -- = RaidDeathCountCharDB, PER CHARACTER (set at ADDON_LOADED): sessions +
                              -- currentRaidID. UI prefs (hud, minimap) stay account-wide in
                              -- RaidDeathCountDB, which the UI file reads directly.
local prevDead   = {}         -- fullName -> last-seen dead state (nil = no baseline yet)
local watched    = {}         -- array of unit tokens to sweep for deaths
local lastSyncReply = 0       -- time() of our last full-state reply (throttle)
local peers      = {}         -- sender -> { t = time() last heard, ver = their addon version }
local playerName              -- our own full name, to exclude ourselves from the peer count
local lastHeartbeat = 0       -- time() of our last presence ping (op H)
local lastSyncCount = 0       -- last live peer count we painted (repaint only when it changes)
local wasInRaid  = false      -- were we inside the raid instance last sweep (re-baseline on re-entry)

local CheckActiveLockout      -- forward declaration: defined down in the lockout section, but the comms
                              -- above it have to be able to re-check before answering a resync

-- ── Small helpers ─────────────────────────────────────────────────────────────

-- Addon version, read from the .toc "## Version" (single source of truth). Modern C_AddOns namespace
-- with a fallback to the older global. Bump ## Version in the .toc before each commit to main.
function RDC.GetVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMeta and getMeta(ADDON_NAME, "Version")) or "?"
end

-- The player key every observer computes identically, which is what lets counts merge across clients.
local function FullName(unit)
    if not UnitExists(unit) then return nil end
    return GetUnitName(unit, true)
end

-- nil when ungrouped, so every comms path goes quiet solo instead of erroring.
local function GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

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
-- The id must be a value every client in the raid computes identically, or the group splits into
-- non-syncing halves. The instance mapID is a client-side constant and satisfies that; the server lockout
-- id was never confirmed to, so it is session metadata only (see CheckLockout). The active id is STICKY:
-- kept while outside (corpse-running, town) so counts survive leaving and re-entering.

-- Returns (lockoutID, secondsUntilReset), or nil when we are not saved to `instanceName`. GetInstanceInfo
-- returns the zone-prefixed name ("Coilfang: Serpentshrine Cavern") while the saved-instance list stores
-- the bare one ("Serpentshrine Cavern"), so an exact compare silently never matches for prefixed raids.
local function FindLockout(instanceName)
    if not instanceName or instanceName == "" then return nil end
    local tail = instanceName:match("^.-:%s*(.+)$")
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    for i = 1, n do
        local name, id, reset, _, locked = GetSavedInstanceInfo(i)
        if locked and name and (name == instanceName or (tail and name == tail)) then
            return id, reset
        end
    end
end

local function ResolveRaidID()
    local iname, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    if itype ~= "raid" then return nil end
    -- A nil/0 mapID is a transient blank read, seen for a tick mid-instance on phase changes. Returning
    -- nil makes UpdateRaidID keep the current id rather than mint a bogus "map:nil" session, which would
    -- both look like a reset and strand the run's counts.
    if not mapID or mapID == 0 then return nil end
    return "map:" .. tostring(mapID), iname, mapID
end

-- Counting gates on this rather than on currentRaidID, which is sticky and would otherwise keep counting
-- deaths out in the open world or in a dungeon.
local function InRaidInstance()
    local _, itype = IsInInstance()
    return itype == "raid"
end

-- ── Sessions / data ───────────────────────────────────────────────────────────

local function EnsureSession(rid, iname, mapID)
    DB.sessions[rid] = DB.sessions[rid] or { started = time(), instance = iname, mapID = mapID, players = {} }
    return DB.sessions[rid]
end

local function ActiveSession()
    if not DB or not DB.currentRaidID then return nil end
    return DB.sessions[DB.currentRaidID]
end

local function RefreshHUD()
    if RDC.RefreshHUD then RDC.RefreshHUD() end
end

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

-- Merge by MAX. Counts only rise within a raid, so every client converges without dedup, ordering or
-- authority, which is what makes late-join, reconnect and duplicate messages self-heal.
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

-- Sorted by deaths desc, then name asc. Mirrors RDC.demoData instead of the session when demo mode is on.
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
-- Local only: never writes the DB sessions and never broadcasts.
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
-- S = full-state chunk (name,class,deaths;...); H = presence ping (payload = sender version). Messages
-- for a different RaidID are ignored. Merge is by MAX, so duplicate, reordered and chunked messages all
-- converge safely.

-- Registering ONCE at load is not enough: the client can drop the registration mid-session (seen live in
-- SSC, two bosses in), after which we still SEND fine but receive nothing, every peer ages out and the
-- sync count falls to 1 on every client at once until someone /reloads. The call is idempotent and
-- client-side only, so re-asserting on zone-in and on the heartbeat self-heals within
-- HEARTBEAT + PEER_STALE with no reload.
local function EnsurePrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
    end
end

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

local function RequestResync()
    if not DB.currentRaidID then return end
    SendComm(DB.currentRaidID .. "|?|")
end

-- ── Peer presence (the "in sync" count) ───────────────────────────────────────
-- Scoped to our RaidID like every other op, so the count only ever includes peers syncing the SAME raid.
local function AnnouncePresence()
    if not DB.currentRaidID then return end
    SendComm(DB.currentRaidID .. "|H|" .. RDC.GetVersion())
end

local function IsSelf(sender)
    if not sender or sender == "" then return true end
    if playerName and sender == playerName then return true end
    local short = sender:match("^[^-]+")                 -- our own broadcasts loop back to us; drop them
    return short ~= nil and short == UnitName("player")
end

-- ── Update notice ─────────────────────────────────────────────────────────────
-- Peers announce their version in every H ping, so a newer one in the raid is a free update check with
-- no web request and no version file to maintain.

-- Dotted versions compared component by component AS NUMBERS. A plain string compare gets "0.10" < "0.9"
-- backwards, and it fails by staying silent, so the bug would not show up until a 0.10 shipped. gmatch on
-- digits also tolerates a stray "v" prefix.
local function VersionParts(v)
    local parts = {}
    for n in tostring(v or ""):gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
end

local function IsNewer(other, mine)
    local a, b = VersionParts(other), VersionParts(mine)
    if #a == 0 or #b == 0 then return false end   -- unparseable either side (e.g. GetVersion gave "?")
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0         -- "0.3" vs "0.3.2": missing components count as zero
        if x ~= y then return x > y end
    end
    return false
end

local notifiedNewer = false   -- once per session; a reload re-arms it

-- Deliberately does NOT name the version. All we know is that SOMEBODY in this raid is ahead of us, which
-- is not the same as knowing what the latest release is: on a raid running 0.4, 0.4.5 and 0.5 we would
-- name whichever we happened to hear first, and a 0.4 user told "0.4.5 is available" would update to it
-- and still be behind. Reporting a number implies an authority we do not have.
local function CheckPeerVersion(theirVer)
    if notifiedNewer or not IsNewer(theirVer, RDC.GetVersion()) then return end
    notifiedNewer = true
    print("|cff88bbffRaid Death Count|r there is a new version available.")
end

-- Any op keeps a peer alive; only H carries a version, so retain the last one we saw.
local function TouchPeer(sender, op, payload)
    if IsSelf(sender) then return end
    local ver = (op == "H" and payload and payload ~= "" and payload) or (peers[sender] and peers[sender].ver)
    peers[sender] = { t = time(), ver = ver }
    if ver then CheckPeerVersion(ver) end
end

local function LivePeerCount()
    local now, n = time(), 0
    for name, p in pairs(peers) do
        if now - (p.t or 0) > PEER_STALE then peers[name] = nil else n = n + 1 end
    end
    return n
end

function RDC.GetSyncCount()
    return 1 + LivePeerCount()
end

function RDC.GetSyncPeers()
    local now, out = time(), {}
    for name, p in pairs(peers) do
        if now - (p.t or 0) <= PEER_STALE then out[#out + 1] = { name = name, ver = p.ver } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Throttled, and split into <=MSG_MAX chunks since an addon message caps around 255 bytes.
local function SendFullState()
    if not DB.currentRaidID then return end
    if time() - lastSyncReply < SYNC_THROTTLE then return end
    -- The one path that can undo somebody else's correct reset: if the weekly reset lands while we are
    -- both online and the asker has already zeroed, a reply built from our not-yet-checked session heals
    -- last week's counts straight back onto them, since merge is by MAX. Check first so we cannot be the
    -- stale one.
    CheckActiveLockout()
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

-- Anything for a raid other than our current one is dropped.
local function OnComm(msg, sender)
    local rid, op, payload = msg:match("^(.-)|(.-)|(.*)$")
    if not rid or rid ~= DB.currentRaidID then return end
    TouchPeer(sender, op, payload)
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
    elseif op == "H" then
        RefreshHUD()                                     -- a new or returning peer changes the sync count
    end
end

-- ── Death sweep (poll) ────────────────────────────────────────────────────────
-- UnitIsDeadOrGhost is synced for group members regardless of range, so an alive->dead edge is a death and
-- a death across the map is never missed. That is why this polls rather than driving off health events.
-- Any remaining gap is filled by peers' broadcasts.

local function Sweep()
    if not DB.currentRaidID then return end
    if not InRaidInstance() then wasInRaid = false; return end
    if not wasInRaid then
        wasInRaid = true
        wipe(prevDead)   -- re-baseline on entry so already-dead state (including a world death we
                         -- corpse-walked in with) is recorded, not counted as a fresh death this tick
    end
    for _, unit in ipairs(watched) do
        local name = FullName(unit)
        if name then
            local dead = UnitIsDeadOrGhost(unit) and not (UnitIsFeignDeath and UnitIsFeignDeath(unit))
            local was = prevDead[name]
            if was == nil then
                prevDead[name] = dead            -- first sight: baseline only, we did not witness it
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

local function MergeSession(from, to)
    for name, p in pairs(from.players) do
        local q = to.players[name]
        if not q then q = { class = p.class, deaths = 0 }; to.players[name] = q end
        if p.class and p.class ~= "" then q.class = p.class end
        if (p.deaths or 0) > (q.deaths or 0) then q.deaths = p.deaths end
    end
end

-- mapID is the stable identity; the name compare is only a fallback for sessions written before mapID
-- was stored. Used solely by the legacy key migration below.
local function SameInstance(s, iname, mapID)
    if not s then return false end
    if s.mapID and mapID and s.mapID == mapID then return true end
    return s.instance ~= nil and s.instance ~= "" and s.instance == iname
end

-- ── Lockout tracking: the automatic per-reset wipe ────────────────────────────
-- The mapID key does not change when the lockout resets, so the fresh-week wipe has to be detected
-- explicitly. Two signals, both derived from the server's saved-instance data, so every client reaches
-- the same verdict independently with no comms, no ordering and nobody holding authority:
--   1. the lockout the counts were recorded under has passed its reset time (the weekly reset)
--   2. we are saved to a DIFFERENT lockout id than the one they were recorded under (raided again)
-- Neither can misfire on a blank saved-instance read, hence no grace window: (1) reads only stored data,
-- (2) needs a real id in hand.
-- KNOWN GAP: a session that never saw a boss kill was never saved, carries no stamp, and so survives into
-- the following week. Needs a whole night with zero kills to hit; /rdc reset clears it.
local function CheckLockout(s, iname)
    if not s then return end
    local id, resetIn = FindLockout(iname or s.instance)
    local now = time()

    local newLockout = false
    if s.lockResetAt and now >= s.lockResetAt then newLockout = true end   -- (1) our lockout expired
    if id and s.lockID and id ~= s.lockID then newLockout = true end       -- (2) saved to a different one

    if newLockout then
        wipe(s.players)
        s.started = now
        s.lockID, s.lockResetAt = nil, nil
        wipe(prevDead)                    -- counts restart, so the baselines have to as well
        RefreshHUD()
        print(("|cff88bbffRaid Death Count|r new lockout for %s: counts reset."):format(
            tostring(s.instance or iname or "this raid")))
    end

    -- Also re-stamps a session we just wiped, anchoring the fresh counts to the current reset. resetIn is
    -- a countdown, so store it as an absolute time.
    if id then
        s.lockID = id
        if resetIn and resetIn > 0 then s.lockResetAt = now + resetIn end
    end
end

-- Works from anywhere, not just inside the raid: the saved-instance list is global and the session
-- remembers its own instance name. It has to, because a client logging in outside the raid must zero a
-- stale session BEFORE it can answer a peer's resync with last week's counts.
function CheckActiveLockout()   -- assigns the forward-declared local up top, do not make this a new local
    CheckLockout(ActiveSession(), nil)
end

-- Re-resolve the active raid; switch (fresh session + resync) only on a genuinely different raid.
local function UpdateRaidID()
    local rid, iname, mapID = ResolveRaidID()
    if not rid then return end       -- not in a raid: keep current (sticky)

    if rid ~= DB.currentRaidID then
        local oldID = DB.currentRaidID
        local oldS = oldID and DB.sessions[oldID]

        DB.currentRaidID = rid
        local newS = EnsureSession(rid, iname, mapID)

        -- Legacy key migration. Versions up to 0.3.x keyed the session on the lockout ("lock:<id>").
        -- Standing in that same instance under the mapID key is the SAME raid, so carry the counts over by
        -- MAX and adopt the old key's id as the stamp, keeping expiry detection continuous. No lock: key
        -- is minted any more, so this fires at most once per stranded session and can be deleted once
        -- nobody is upgrading from 0.3.x.
        if oldID and oldID:match("^lock:") and SameInstance(oldS, iname, mapID) then
            MergeSession(oldS, newS)
            newS.lockID = newS.lockID or tonumber(oldID:match("^lock:(%d+)"))
            DB.sessions[oldID] = nil
        end

        wipe(prevDead)               -- new raid context: re-baselined on the next sweep
        PruneSessions(10)
        CheckLockout(newS, iname)
        RequestResync()
        RefreshHUD()
    else
        local s = ActiveSession()
        if s then
            if iname and iname ~= "" then
                if not s.instance or s.instance == "" then s.instance = iname end
                if not s.mapID then s.mapID = mapID end   -- backfill for sessions written by older code
            end
            CheckLockout(s, iname)
        end
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
        print("|cff88bbffRaidDeathCount|r " .. text)
    end
end

-- mode = "all" | "top3" | "top5" | a player-name prefix.
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

-- Local only. In a group a peer's next D or S heals the counts back by MAX, so this is a solo convenience,
-- not a group reset. See CLAUDE.md for why there is no group reset.
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
frame:RegisterEvent("UPDATE_INSTANCE_INFO")   -- the saved-instance list arrived: re-check for a new lockout

frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        -- Account-wide: UI preferences only, so the HUD keeps its size and place on every character.
        RaidDeathCountDB = RaidDeathCountDB or {}
        RaidDeathCountDB.hud = RaidDeathCountDB.hud or {}
        RaidDeathCountDB.minimap = RaidDeathCountDB.minimap or {}
        -- Per character: an alt that never set foot in the raid must not inherit the main's counts or its
        -- sticky currentRaidID. Walking that alt into the same raid does refill from peers, which is
        -- intended: counts belong to the raid, storage belongs to the character.
        RaidDeathCountCharDB = RaidDeathCountCharDB or {}
        DB = RaidDeathCountCharDB
        DB.sessions = DB.sessions or {}
        -- Pre-0.3 sessions were account-wide and cannot be attributed to a character, so drop them rather
        -- than hand every alt the main's history. A mid-lockout upgrade re-syncs from peers.
        RaidDeathCountDB.sessions = nil
        RaidDeathCountDB.currentRaidID = nil
        EnsurePrefix()

    elseif event == "PLAYER_LOGIN" then
        playerName = FullName("player")
        RebuildWatched()
        UpdateRaidID()
        -- Before any comms: a session left over from an expired lockout has to be zeroed now, or our
        -- first resync reply would push last week's counts onto peers who had already reset.
        CheckActiveLockout()
        if RequestRaidInfo then RequestRaidInfo() end   -- warms the list, fires UPDATE_INSTANCE_INFO
        if RDC.InitHUD then RDC.InitHUD() end
        if RDC.InitMinimap then RDC.InitMinimap() end
        RequestResync()
        AnnouncePresence()
        print(("|cff88bbffRaid Death Count|r v%s loaded. Enjoy!"):format(RDC.GetVersion()))

    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsurePrefix()        -- before the resync and presence below, or the replies are not heard
        RebuildWatched()
        UpdateRaidID()
        CheckActiveLockout()
        if RequestRaidInfo then RequestRaidInfo() end
        RequestResync()
        AnnouncePresence()

    elseif event == "GROUP_ROSTER_UPDATE" then
        RebuildWatched()
        UpdateRaidID()
        AnnouncePresence()

    elseif event == "UPDATE_INSTANCE_INFO" then
        CheckActiveLockout()   -- the list can be cold at login; this is when it is actually trustworthy

    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == COMM_PREFIX and DB then OnComm(arg2, arg4) end
    end
end)

local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < POLL_INTERVAL then return end
    acc = 0
    if DB and DB.currentRaidID then
        UpdateRaidID()   -- steady cadence picks up a zone change and runs CheckLockout even when
                         -- GROUP_ROSTER_UPDATE is quiet; cheap when nothing has changed
        Sweep()
        local now = time()
        if now - lastHeartbeat >= HEARTBEAT then
            lastHeartbeat = now
            EnsurePrefix()   -- re-assert: a silently dropped registration otherwise needs a /reload
            -- Safety net for a client parked in town across the weekly reset, which would otherwise keep
            -- last week's counts until it zoned or relogged. Converges everyone within HEARTBEAT.
            CheckActiveLockout()
            AnnouncePresence()
            -- Grouped but hearing nobody means either we are the only user here or we just went deaf and
            -- missed their broadcasts. Merge is by MAX, so a redundant resync costs one message.
            if IsInGroup() and LivePeerCount() == 0 then RequestResync() end
        end
        local c = LivePeerCount()
        if c ~= lastSyncCount then lastSyncCount = c; RefreshHUD() end
    end
end)

-- ── Debug ─────────────────────────────────────────────────────────────────────
-- /run RaidDeathCount.DebugDump()
function RDC.DebugDump()
    local iname, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    print("|cff88bbffRDC|r instance:", iname, "type:", itype, "mapID:", mapID)
    local rid = ResolveRaidID()
    print("|cff88bbffRDC|r ResolveRaidID:", tostring(rid), "  active:", tostring(DB and DB.currentRaidID))
    local s = ActiveSession()
    -- Outside an instance iname is just the zone name, so fall back to the session's own instance: that is
    -- what CheckLockout uses from town, and the dump should show what it acts on.
    local lid, lreset = FindLockout((itype == "raid" and iname) or (s and s.instance))
    print(("|cff88bbffRDC|r lockout now: id=%s resetIn=%s   session: id=%s resetAt=%s (%s)"):format(
        tostring(lid), tostring(lreset), tostring(s and s.lockID), tostring(s and s.lockResetAt),
        (s and s.lockResetAt) and (s.lockResetAt > time() and "current" or "EXPIRED") or "unstamped"))
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    print("|cff88bbffRDC|r saved instances:", n)
    for i = 1, n do
        local name, id, reset, diff, locked = GetSavedInstanceInfo(i)
        print(("  [%d] %s id=%s reset=%s diff=%s locked=%s"):format(i, tostring(name), tostring(id), tostring(reset), tostring(diff), tostring(locked)))
    end
    for _, e in ipairs(RDC.GetSnapshot()) do
        print(("  %s (%s): %d"):format(e.name, tostring(e.class), e.deaths))
    end
    -- All sessions, so a stranded raidID's counts are visible and not just the active one's.
    print("|cff88bbffRDC|r sessions in DB:")
    for id, sess in pairs(DB and DB.sessions or {}) do
        local total, np = 0, 0
        for _, p in pairs(sess.players or {}) do total = total + (p.deaths or 0); np = np + 1 end
        print(("  <%s> instance=%s mapID=%s lock=%s players=%d totalDeaths=%d%s"):format(
            tostring(id), tostring(sess.instance), tostring(sess.mapID), tostring(sess.lockID), np, total,
            id == DB.currentRaidID and "  <== ACTIVE" or ""))
    end
end

-- Manual recovery for counts orphaned by an old RaidID bug:
-- /run RaidDeathCount.DebugRecover("map:550")
function RDC.DebugRecover(fromID)
    if not DB or not DB.currentRaidID then print("|cff88bbffRDC|r no active raid"); return end
    local from = DB.sessions[fromID]
    local to = DB.sessions[DB.currentRaidID]
    if not from then print("|cff88bbffRDC|r no session " .. tostring(fromID)); return end
    if not to or from == to then print("|cff88bbffRDC|r nothing to merge"); return end
    MergeSession(from, to)
    DB.sessions[fromID] = nil
    RefreshHUD()
    print(("|cff88bbffRDC|r merged %s into active %s"):format(tostring(fromID), tostring(DB.currentRaidID)))
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
