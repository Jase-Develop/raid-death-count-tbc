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
-- Different RaidIDs are different raids and never merge, so the id has to be a value every client in the
-- raid computes identically. That is the instance mapID, and only the mapID: it is a client-side constant
-- (two clients agreed on map:548 for a whole SSC run, confirmed live). An earlier design preferred the
-- server lockout id and fell back to the mapID, on the assumption that the lockout id is shared between
-- everyone saved to the same reset. That assumption was never confirmed, and if it is wrong the key
-- splits the raid in two and sync stops dead, so the lockout is no longer part of the key at all. What it
-- IS still good for, purely locally, is spotting a new lockout: see CheckLockout below.
--
-- The active id is STICKY: kept while we're outside (corpse-running, town) so counts survive leaving and
-- re-entering; it only switches when we positively resolve a different raid.

-- The server lockout we're saved to for `instanceName`, as (id, secondsUntilReset), or nil when we are
-- not saved to it. Note GetInstanceInfo returns the zone-prefixed name ("Coilfang: Serpentshrine Cavern")
-- while the saved-instance list stores the bare instance ("Serpentshrine Cavern"), so an exact compare
-- silently never matches for prefixed raids (a real bug: it made the whole lockout path dead code for
-- SSC). Match the full name or the tail after the colon.
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

-- Returns a RaidID string + the instance name + mapID, or nil when we're not standing in a raid instance.
local function ResolveRaidID()
    local iname, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    if itype ~= "raid" then return nil end
    -- A nil/0 mapID is a transient read (blank instance info for a tick, seen mid-instance on phase
    -- changes) - return nil so UpdateRaidID keeps the current id rather than minting a bogus "map:nil"
    -- session, which both looks like a reset and strands the run's counts.
    if not mapID or mapID == 0 then return nil end
    return "map:" .. tostring(mapID), iname, mapID
end

-- Are we physically standing in a raid instance right now? Death counting is gated on this so the STICKY
-- currentRaidID (kept for display/sync after we leave, e.g. corpse-running or in town) does not keep
-- counting deaths out in the open world or in a dungeon.
local function InRaidInstance()
    local _, itype = IsInInstance()
    return itype == "raid"
end

-- ── Sessions / data ───────────────────────────────────────────────────────────

local function EnsureSession(rid, iname, mapID)
    DB.sessions[rid] = DB.sessions[rid] or { started = time(), instance = iname, mapID = mapID, players = {} }
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
-- S = full-state chunk (name,class,deaths;...); H = presence ping (payload = sender version), used to
-- count how many addons are in sync. Messages for a different RaidID are ignored. Merge is by max per
-- player, so duplicate/out-of-order/chunked S messages all converge safely.

-- Register our addon-message prefix. Registering ONCE at load is not enough: the client can drop the
-- registration mid-session (seen live in SSC, two bosses in), after which we still SEND fine but receive
-- nothing, every peer ages out and the sync count falls to 1 on every client at once until someone
-- /reloads. The call is idempotent and client-side only (no traffic), so we re-assert it cheaply on
-- zone-in and on the heartbeat cadence, which self-heals within HEARTBEAT + PEER_STALE with no reload.
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

-- Ask peers for their full state for our current raid (on join / zone-in / late arrival).
local function RequestResync()
    if not DB.currentRaidID then return end
    SendComm(DB.currentRaidID .. "|?|")
end

-- ── Peer presence (the "in sync" count) ───────────────────────────────────────
-- Every client running RDC announces itself (op H, payload = version). We keep a table of the senders
-- we have recently heard from and count them (+ ourselves) to show how many addons are in sync. Scoped
-- to our RaidID like everything else, so it counts only peers syncing the SAME raid.

-- Announce our presence + version. Same triggers as RequestResync, plus a periodic heartbeat, so late
-- joiners / reloads are discovered and peers who leave or disconnect age out of the count.
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

-- Note that we just heard from a peer (any op keeps them alive; H also carries their version).
local function TouchPeer(sender, op, payload)
    if IsSelf(sender) then return end
    local ver = (op == "H" and payload and payload ~= "" and payload) or (peers[sender] and peers[sender].ver)
    peers[sender] = { t = time(), ver = ver }
end

-- Count OTHER live peers, pruning any that have gone silent past PEER_STALE.
local function LivePeerCount()
    local now, n = time(), 0
    for name, p in pairs(peers) do
        if now - (p.t or 0) > PEER_STALE then peers[name] = nil else n = n + 1 end
    end
    return n
end

-- How many addons are in sync right now (us + live peers). Always at least 1 (ourselves).
function RDC.GetSyncCount()
    return 1 + LivePeerCount()
end

-- Live peers as a sorted list of { name, ver } for the HUD tooltip (excludes ourselves).
function RDC.GetSyncPeers()
    local now, out = time(), {}
    for name, p in pairs(peers) do
        if now - (p.t or 0) <= PEER_STALE then out[#out + 1] = { name = name, ver = p.ver } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Reply to a resync request with our full state, packed into <=MSG_MAX chunks (throttled).
local function SendFullState()
    if not DB.currentRaidID then return end
    if time() - lastSyncReply < SYNC_THROTTLE then return end
    -- Validate our lockout before answering. This is the one path that can undo somebody else's correct
    -- reset: if the weekly reset lands while we are both online and the asker has already zeroed, a reply
    -- built from our not-yet-checked session would heal last week's counts straight back onto them (merge
    -- is by MAX, so the higher number always wins). Checking here means we cannot be the stale one.
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

-- Parse and apply an inbound message. Ignores anything for a raid other than our current one.
local function OnComm(msg, sender)
    local rid, op, payload = msg:match("^(.-)|(.-)|(.*)$")
    if not rid or rid ~= DB.currentRaidID then return end
    TouchPeer(sender, op, payload)                       -- any op from a peer keeps them in the sync count
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
        RefreshHUD()                                     -- a new/refreshed peer may change the sync count
    end
end

-- ── Death sweep (poll) ────────────────────────────────────────────────────────
-- UnitIsDeadOrGhost is synced for group members regardless of range, so an alive->dead edge is a death.
-- A poll (vs health events) is used so a death across the map is never missed for units we can see; any
-- remaining gap is filled by peers' broadcasts. Feign Death is guarded out.

local function Sweep()
    if not DB.currentRaidID then return end
    if not InRaidInstance() then wasInRaid = false; return end   -- only count while inside the raid instance
    if not wasInRaid then
        wasInRaid = true
        wipe(prevDead)   -- just entered: re-baseline so any already-dead state (incl. a world death we
                         -- corpse-walked in with) is recorded, not counted as a fresh death this tick
    end
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

-- Is `s` the SAME physical raid we are standing in right now? Match on the stable instance mapID first
-- (sessions written by newer code carry it), falling back to the instance name for older sessions.
local function SameInstance(s, iname, mapID)
    if not s then return false end
    if s.mapID and mapID and s.mapID == mapID then return true end
    return s.instance ~= nil and s.instance ~= "" and s.instance == iname
end

-- ── Lockout tracking: the automatic per-reset wipe ────────────────────────────
-- The RaidID is the instance mapID, which every client agrees on but which does NOT change when the
-- lockout resets, so the fresh-week wipe that used to fall out of a changing key now has to be detected
-- explicitly. The lockout is therefore kept as session METADATA rather than as part of the key. Two
-- signals, both read from the server's own saved-instance data, so every client reaches the same verdict
-- independently with no comms, no message ordering and nobody holding authority:
--   1. the lockout the counts were recorded under has passed its reset time (the weekly reset)
--   2. we are saved to a DIFFERENT lockout id than the one they were recorded under (we raided again
--      after a reset and got saved anew)
-- Neither can misfire on a blank saved-instance read, which is what made the old lock:/map: demotion so
-- delicate: (1) reads only stored data, and (2) requires a real id in hand. Hence no grace window here.
-- KNOWN GAP: a session that never saw a boss kill was never saved, so it carries no lockout stamp and
-- neither signal can fire; its counts survive into the following week. That needs a whole raid night with
-- zero kills to hit, and /rdc reset clears it.
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
        wipe(prevDead)                    -- counts restart, so the death baselines have to as well
        RefreshHUD()
        print(("|cff88bbffRaid Death Count|r new lockout for %s: counts reset."):format(
            tostring(s.instance or iname or "this raid")))
    end

    -- Stamp the lockout we are saved to now. This also re-stamps a session we just wiped, so the fresh
    -- counts are anchored to the current reset. resetIn is a countdown, so store it as an absolute time.
    if id then
        s.lockID = id
        if resetIn and resetIn > 0 then s.lockResetAt = now + resetIn end
    end
end

-- Run the lockout check on the active session from wherever we happen to be standing. The saved-instance
-- list is global and the session remembers its own instance name, so this works from town, and it has to:
-- a client that logs in outside the raid must zero a stale session BEFORE it can answer a peer's resync
-- with last week's counts, since merge is by MAX and one stale reply would heal those numbers straight
-- back onto everyone who had correctly reset.
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

        -- Legacy key migration. Versions up to 0.3.x keyed the session on the server lockout ("lock:<id>")
        -- whenever they could resolve one. Standing in that same instance under the mapID key is the SAME
        -- raid, not a new one, so carry the counts over (by MAX) and adopt the old key's lockout id as the
        -- session's stamp so expiry detection stays continuous. No lock: key is ever minted again, so this
        -- fires at most once per stranded session and can be deleted once nobody is upgrading from 0.3.x.
        if oldID and oldID:match("^lock:") and SameInstance(oldS, iname, mapID) then
            MergeSession(oldS, newS)
            newS.lockID = newS.lockID or tonumber(oldID:match("^lock:(%d+)"))
            DB.sessions[oldID] = nil
        end

        wipe(prevDead)               -- new raid context: drop stale baselines (re-baselined next sweep)
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
frame:RegisterEvent("UPDATE_INSTANCE_INFO")   -- the saved-instance list arrived: re-check for a new lockout

frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        -- Account-wide: UI preferences only, so the HUD keeps its size/place on every character.
        RaidDeathCountDB = RaidDeathCountDB or {}
        RaidDeathCountDB.hud = RaidDeathCountDB.hud or {}
        RaidDeathCountDB.minimap = RaidDeathCountDB.minimap or {}
        -- Death data is PER CHARACTER: an alt that never set foot in the raid must not inherit the
        -- main's counts or its sticky currentRaidID. Walking that alt into the same raid still fills
        -- the counts back in from peers (comms are scoped by RaidID, merged by MAX), which is correct:
        -- the counts belong to the raid, the storage belongs to the character.
        RaidDeathCountCharDB = RaidDeathCountCharDB or {}
        DB = RaidDeathCountCharDB
        DB.sessions = DB.sessions or {}
        -- Pre-0.3 sessions were account-wide. They cannot be attributed to a character now, so rather
        -- than handing every alt the main's history we drop them; the active run re-syncs from peers.
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
        if RequestRaidInfo then RequestRaidInfo() end   -- warm the saved-instance list (UPDATE_INSTANCE_INFO)
        if RDC.InitHUD then RDC.InitHUD() end
        if RDC.InitMinimap then RDC.InitMinimap() end
        RequestResync()
        AnnouncePresence()
        print(("|cff88bbffRaid Death Count|r v%s loaded. Enjoy!"):format(RDC.GetVersion()))

    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsurePrefix()        -- before the resync/presence below, so the replies are actually heard
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

-- Death poll: only sweeps while we have an active raid context.
local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < POLL_INTERVAL then return end
    acc = 0
    if DB and DB.currentRaidID then
        UpdateRaidID()   -- re-resolve on a steady cadence so the demotion grace window elapses even when
                         -- GROUP_ROSTER_UPDATE is quiet (e.g. single-client testing); cheap on no change
        Sweep()
        -- Presence heartbeat + age-out: ping every HEARTBEAT secs, and if the live peer count changed
        -- (someone joined, reloaded, or went silent) repaint so the HUD's sync number stays current.
        local now = time()
        if now - lastHeartbeat >= HEARTBEAT then
            lastHeartbeat = now
            EnsurePrefix()   -- re-assert: a silently dropped registration otherwise needs a /reload
            -- Lockout safety net. UpdateRaidID only checks while we are standing in the raid, so a client
            -- parked in town across the weekly reset would otherwise keep last week's counts until it
            -- zoned or relogged. This runs anywhere, so everyone converges within HEARTBEAT of the reset.
            CheckActiveLockout()
            AnnouncePresence()
            -- Grouped but hearing nobody: either we are the only user here (a harmless extra ping) or we
            -- just went deaf and missed their broadcasts, so pull full state back in. Merge is by MAX, so
            -- a redundant resync costs one message and changes nothing.
            if IsInGroup() and LivePeerCount() == 0 then RequestResync() end
        end
        local c = LivePeerCount()
        if c ~= lastSyncCount then lastSyncCount = c; RefreshHUD() end
    end
end)

-- ── Debug ─────────────────────────────────────────────────────────────────────
-- /run RaidDeathCount.DebugDump() prints RaidID resolution + the current snapshot (for in-game tuning).
function RDC.DebugDump()
    local iname, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    print("|cff88bbffRDC|r instance:", iname, "type:", itype, "mapID:", mapID)
    local rid = ResolveRaidID()
    print("|cff88bbffRDC|r ResolveRaidID:", tostring(rid), "  active:", tostring(DB and DB.currentRaidID))
    -- Lockout is metadata now, not part of the key, but it drives the automatic per-reset wipe, so show
    -- both what we resolve right now and what the active session was stamped with.
    local s = ActiveSession()
    -- Outside an instance iname is just the zone name, so fall back to the session's own instance: that
    -- is what CheckLockout uses from town, and the dump should show the same thing it acts on.
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
    -- Every stored session, so a stranded/orphaned raidID's counts are visible (not just the active one).
    print("|cff88bbffRDC|r sessions in DB:")
    for id, sess in pairs(DB and DB.sessions or {}) do
        local total, np = 0, 0
        for _, p in pairs(sess.players or {}) do total = total + (p.deaths or 0); np = np + 1 end
        print(("  <%s> instance=%s mapID=%s lock=%s players=%d totalDeaths=%d%s"):format(
            tostring(id), tostring(sess.instance), tostring(sess.mapID), tostring(sess.lockID), np, total,
            id == DB.currentRaidID and "  <== ACTIVE" or ""))
    end
end

-- Recovery: MAX-merge a stranded session's counts into the active one, then drop the source. Manual, for
-- reclaiming counts orphaned by an old bug: /run RaidDeathCount.DebugRecover("map:550")
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
