-- Raid Death Count (TBC 2.5.6) - core: death detection, RaidID scoping, persistence, comms, reporting.
-- Everything public hangs off the global RaidDeathCount table (alias RDC). The UI file attaches the HUD.

RaidDeathCount = RaidDeathCount or {}
local RDC = RaidDeathCount

local ADDON_NAME    = "raid-death-count"   -- must match the folder / .toc for metadata + ADDON_LOADED
local COMM_PREFIX   = "RDC1"               -- addon-message prefix (format version baked in)
local POLL_INTERVAL = 0.5                  -- seconds between death sweeps
local SYNC_THROTTLE = 5                    -- min seconds between our resync replies
local MSG_MAX       = 230                  -- soft cap on an addon-message body before we flush a chunk
local COMM_INTERVAL = 0.2                  -- min seconds between our own outbound addon messages. Batching
                                           -- already killed the per-death fan-out, but a chunked S still
                                           -- leaves the client in one frame; this paces what is left.
local REPLY_JITTER  = 2                    -- max seconds a full-state reply is held back. "?" is a
                                           -- BROADCAST and every client answers it, so the burst that
                                           -- actually threatens the channel is N clients replying on the
                                           -- same frame, which no per-client queue can pace. See ReplyDelay.
local PEER_STALE    = 90                   -- seconds before a silent peer drops out of the sync count
local HEARTBEAT     = 30                   -- seconds between our presence pings (op H)
local PROBE_TIMEOUT = 10                   -- seconds to wait for our own H to echo back before calling
                                           -- comms broken. Generous on purpose: a false outage would
                                           -- destroy trust in the indicator, and DebugDump reports the
                                           -- worst echo time seen so this can be tuned against real data.
local PROBE_RETRY   = 10                   -- seconds between probes while broken (HEARTBEAT when healthy),
                                           -- so recovery is timestamped sharply enough to be evidence
local DIGEST_COOLDOWN = 60                 -- min seconds between resyncs triggered by a digest mismatch, so
                                           -- a raid that all disagrees at once cannot storm the channel
local STALE_SESSION = 6 * 60 * 60          -- seconds of inactivity after which an UNSTAMPED session (a night
                                           -- that never killed a boss, so it was never saved) is wiped on
                                           -- next contact. See CheckLockout: only sessions with no lockout
                                           -- stamp decay, since those are the only ones with no reset of
                                           -- their own. Comfortably longer than any within-night break and
                                           -- shorter than a return the next evening.
local DEMO_COMBAT_SECONDS = 4354           -- 01:12:34, the clock demo mode substitutes for the real one. A
                                           -- fixed number rather than a running one, so a screenshot of the
                                           -- preview is reproducible. Over an hour on purpose: it is a
                                           -- realistic figure for a lockout's combat time and it is the only
                                           -- way the hours field of FormatClock appears in a preview at all.

-- ── State ─────────────────────────────────────────────────────────────────────
local DB                      -- = RaidDeathCountCharDB, PER CHARACTER (set at ADDON_LOADED): sessions +
                              -- currentRaidID. UI prefs (hud, minimap) stay account-wide in
                              -- RaidDeathCountDB, which the UI file reads directly.
local prevDead   = {}         -- fullName -> last-seen dead state (nil = no baseline yet)
local watched    = {}         -- array of unit tokens to sweep for deaths
local lastSyncReply = 0       -- time() of our last full-state reply (throttle)
local peers      = {}         -- sender -> { t = time() last heard, ver = their addon version, dig = their
                              -- last state digest, mismatched = did that digest disagree with ours }.
                              -- Entries are retained once stale, not deleted, so "lost contact" stays
                              -- distinguishable from "never heard anyone"; cleared when we leave the group.
local playerName              -- our own full name, to exclude ourselves from the peer count
local lastHeartbeat = 0       -- time() of our last presence ping (op H)
local lastSyncCount = 0       -- last live peer count we painted (repaint only when it changes)
local lastResyncAsk = 0       -- time() of the last resync request we KNOW ABOUT, ours or a peer's. A peer's
                              -- counts because "?" is a broadcast: their replies heal us too, so a second
                              -- request adds traffic and nothing else (see DIGEST_COOLDOWN).
local wasInRaid  = false      -- were we inside the raid instance last sweep (re-baseline on re-entry)

-- Combat timer. Measures seconds the RAID spent fighting, not wall clock, which is what makes it survive a
-- multi-night lockout with no gap rule: the hours between Tuesday and Thursday simply are not counted.
-- Purely local, deliberately: nothing about it crosses the wire, so there is no clock to agree on and no
-- message cost. GetTime() (monotonic, sub-second) for the same reason the watchdog uses it.
local inCombat        = false -- was the raid in combat as of the last sweep
local lastCombatTick          -- GetTime() at the last accumulation (nil = nothing banked yet)

-- Outbound comm queue. Declared up here rather than beside its functions (where chatQueue sits) because
-- SetEnabled has to be able to discard it, and that runs well above the comms block.
local commQueue = {}          -- pending outbound messages, each { msg, probe, after }
local commNextAt = 0          -- GetTime() before which the next message must not go out

-- Comms watchdog. Durations use GetTime() (monotonic, sub-second); anything shown to a human uses time().
local commsProbeSent          -- GetTime() of the H we are waiting to hear echo back (nil = not waiting)
local commsOK                 -- nil = not yet established, true = echo seen, false = outage in progress
local everLooped = false      -- has the echo EVER worked on this client (gates outage reporting)
local commsBrokenSince        -- time() the current outage started
local lastLoopback            -- time() our own message last echoed back
local lastPeerRx              -- time() we last heard any OTHER client
local reassertCount = 0       -- prefix re-asserts attempted during the current outage
local maxEchoTime = 0         -- worst echo round trip seen, in seconds (calibrates PROBE_TIMEOUT)
local lastOutage              -- { from, to, reasserts } for the most recent recovered outage

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

-- A battleground or arena replaces the group with a raid of strangers while our RaidID stays sticky from
-- the last real raid, so there is nobody in there we have anything to say to. Worse, a BG group's addon
-- traffic rides INSTANCE_CHAT, so a send to RAID never leaves the client: the heartbeat's echo cannot come
-- back, the watchdog times out and reports a false outage on a loop for the whole match. Comms are
-- suppressed outright rather than switched to INSTANCE_CHAT, because reaching that group is not wanted.
-- SendComm no longer consults this, since gating comms on being IN a raid instance already excludes a BG,
-- but the watchdog still needs to tell "we chose not to send" apart from "the channel is broken".
local function InPvPInstance()
    local _, itype = IsInInstance()
    return itype == "pvp" or itype == "arena"
end

-- ── Sessions / data ───────────────────────────────────────────────────────────

local function EnsureSession(rid, iname, mapID)
    DB.sessions[rid] = DB.sessions[rid] or
        { started = time(), instance = iname, mapID = mapID, players = {}, combatSeconds = 0 }
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

-- Records locally and returns the new count. Broadcasting and repainting are deliberately the CALLER's
-- job: Sweep finds every death of a raid wipe in one 0.5s tick, and a message each would be 20-25 sends
-- from one client in a single frame, from every client at once. That is far over the server's
-- addon-message rate limit, so the excess is dropped exactly when the counts matter most. The caller
-- flushes the whole tick as one message instead.
--
-- `own` counts only what THIS client witnessed and is what gets incremented; `deaths` is the merged value
-- shown and sent. Keeping them apart is not tidiness, it is the whole correctness argument. Incrementing
-- `deaths` directly stacks our own sighting on top of the number a peer just sent for the SAME death, so
-- one death inflates once per addon user in the raid: A broadcasts 1, B merges to 1 then its own sweep
-- makes it 2, C merges to 2 then makes it 3. Ordering-dependent, invisible solo, and MAX then spreads the
-- highest result to everyone. Confirmed live 2026-08-02 from a `remote D -> 4` immediately followed by a
-- local edge producing 5 for a single death.
local function RecordDeath(name, class)
    local s = ActiveSession()
    if not s then return end
    local p = s.players[name]
    if not p then p = { class = class, deaths = 0, own = 0 }; s.players[name] = p end
    if class then p.class = class end
    -- Absent `own` means a row written before this field existed. Defaulting to `deaths` is exactly right
    -- for the single-client case (where every count WAS our own) and is the conservative choice for a row
    -- already inflated by the old bug: starting from 0 instead would park us below the merged value and
    -- silently swallow real deaths until we climbed back past it.
    p.own = (p.own or p.deaths) + 1
    if p.own > p.deaths then p.deaths = p.own end
    -- class is the STORED one, which may be from an earlier sighting when this read is nil.
    return p.deaths, p.class
end

-- Merge by MAX. Counts only rise within a raid, so every client converges without dedup, ordering or
-- authority, which is what makes late-join, reconnect and duplicate messages self-heal.
--
-- Deliberately does NOT touch `own`: a peer's number is not something we witnessed, and letting it raise our
-- own counter is precisely the compounding this split exists to stop.
local function ApplyRemote(name, class, deaths)
    local s = ActiveSession()
    if not s or not name or not deaths then return false end
    local p = s.players[name]
    if not p then p = { class = class, deaths = 0, own = 0 }; s.players[name] = p end
    if class and class ~= "" then p.class = class end
    if deaths > p.deaths then
        p.deaths = deaths
        return true
    end
    return false
end

-- ── Snapshot (for HUD + reports) ──────────────────────────────────────────────

-- Deaths desc, then name asc. The name tiebreak's real job is STABILITY: a player moves only when their own
-- count changes, never because somebody else's did, which neither insertion nor pairs() order would give.
local function SortRows(out)
    table.sort(out, function(a, b)
        if a.deaths ~= b.deaths then return a.deaths > b.deaths end
        return a.name < b.name
    end)
    return out
end

-- The one row builder over a session's players, shared by the HUD's active session and by the Lockouts
-- page's stored ones, so a browsed raid cannot render by different rules than the raid you are standing in.
-- Zero-count rows are dropped here rather than by the caller: we may hold one for a player nobody has seen
-- die, and StateDigest skips them for the same reason.
local function SnapshotOf(players)
    local out = {}
    for name, p in pairs(players or {}) do
        if (p.deaths or 0) > 0 then
            out[#out + 1] = { name = name, class = p.class, deaths = p.deaths }
        end
    end
    return SortRows(out)
end

-- Sorted by deaths desc, then name asc. Mirrors RDC.demoData instead of the session when demo mode is on.
function RDC.GetSnapshot()
    if RDC.demoData then
        local out = {}
        for _, e in ipairs(RDC.demoData) do
            out[#out + 1] = { name = e.name, class = e.class, deaths = e.deaths }
        end
        return SortRows(out)   -- demo rows are authored, so they skip the zero filter and only need sorting
    end
    local s = ActiveSession()
    return SnapshotOf(s and s.players)
end

-- Summed from a snapshot rather than kept as a running counter, so it can never drift from the rows the
-- HUD and the report actually show. Pass a snapshot to avoid rebuilding one you already have.
function RDC.TotalDeaths(snap)
    local sum = 0
    for _, e in ipairs(snap or RDC.GetSnapshot()) do sum = sum + e.deaths end
    return sum
end

-- Seconds the raid has spent in combat this lockout. Not wall clock: see the inCombat declaration for why.
--
-- Demo-guarded like GetInstanceName, and for a stronger reason: demo mode fakes the
-- rows but a real session's clock is whatever the character happens to hold, which in town is zero, so the
-- preview showed 29 deaths against 00:00:00 and 0.00 DPM. That is not a plausible-looking preview, it is a
-- stats strip that reads as broken. Every consumer of the clock goes through here (the strip, the DPM cell
-- and "/rdc report stats"), so this is the one place it needs faking.
function RDC.GetCombatSeconds()
    if RDC.demoData then return DEMO_COMBAT_SECONDS end
    local s = ActiveSession()
    return (s and s.combatSeconds) or 0
end

-- Both formatters live here rather than in the UI because the stats-hud and "/rdc report stats" render the
-- same two figures, and a raider comparing the chat line against the bar on screen must not find them
-- disagreeing over rounding or precision. The core loads first, so the UI can call these freely.

-- Fixed width so the strip does not reflow every time the clock crosses ten minutes. Hours are not wrapped:
-- combat time accumulates across a whole lockout, so a week of raiding can legitimately pass 24.
function RDC.FormatClock(sec)
    sec = math.floor(sec or 0)
    return ("%02d:%02d:%02d"):format(math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

-- Deaths per minute OF COMBAT, not of wall clock, since that is what the denominator measures. A zero
-- denominator reads 0.00 rather than blank or a dash: the figure is always populated, and the alternative
-- for deaths-with-no-combat-time is an infinity there is no sensible way to print. Reachable whenever rows
-- exist with no clock behind them, which is a resync from peers before this client has fought anything.
function RDC.FormatDPM(deaths, sec)
    if not sec or sec <= 0 then return "0.00" end
    return ("%.2f"):format((deaths or 0) * 60 / sec)
end

-- A coarse two-part span: "2d 4h", "4h 12m", "12m". Beside the other two formatters and for the same
-- reason, so nothing the addon prints can disagree about rounding. RDC.Ago cannot serve this: it stops at
-- minutes, and a lockout runs to days.
function RDC.FormatDuration(sec)
    sec = math.max(0, math.floor(sec or 0))
    local d = math.floor(sec / 86400)
    local h = math.floor(sec / 3600) % 24
    local m = math.floor(sec / 60) % 60
    if d > 0 then return ("%dd %dh"):format(d, h) end
    if h > 0 then return ("%dh %dm"):format(h, m) end
    return ("%dm"):format(m)
end

-- An absolute wall-clock stamp, DD/MM/YYYY HH:MM. Beside the other formatters and for the same reason,
-- even though the Lockouts page is its only caller today: a second surface that wants to print a date must
-- not be free to pick its own field order. `date` is the client's os.date, so this is the LOCAL machine's
-- clock, which is the only clock the addon has and deliberately so (see the raid timer decision: nothing
-- here is agreed with peers, so a wrong clock misreads one player's page and cannot poison anyone else's).
function RDC.FormatStamp(t)
    if not t or t <= 0 then return "" end
    return date("%d/%m/%Y %H:%M", t)
end

function RDC.GetInstanceName()
    if RDC.demoData then return "Demo Preview" end
    local s = ActiveSession()
    return s and s.instance
end

-- RDC.GetMapID lived here and was deleted on 2026-08-11. Its only caller was the HUD title's abbreviation
-- table, which keyed short raid names off the mapID; the title shows full names now, so nothing asks.

-- ── Stored lockouts (the options window's Lockouts page) ──────────────────────
-- A read-only view over EVERY stored session rather than just the active one. The HUD only ever shows
-- DB.sessions[currentRaidID], so the four or five other raids a character holds have until now been
-- reachable only through DebugRaid.

-- What a stored raid's counts are actually worth, phrased for a reader. It lives here and not in the UI for
-- the same reason FormatClock does: it is CheckLockout's own three signals restated, and a page that
-- re-derived them could drift from the rules that actually fire.
--
-- Since SweepLockouts this is a window onto a state that does not last. Every stored session is now checked
-- against its OWN stamp at login, on zoning and on the heartbeat, so an expired raid is cleared and deleted
-- within HEARTBEAT rather than sitting condemned until you happen to walk back into it. The expired wordings
-- survive for the one case the sweep cannot reach: a client with the master switch off, which is doing no
-- housekeeping at all. They say "clear automatically" and NOT "when you next enter", which stopped being
-- true the moment clearing stopped requiring you to go anywhere.
local function LockoutState(s)
    local now = time()
    if s.lockResetAt then
        if s.lockResetAt > now then
            return "Resets in " .. RDC.FormatDuration(s.lockResetAt - now)
        end
        return "Expired - counts clear automatically"
    end
    -- Saved, but the server gave no reset countdown when we stamped it. Stamped is still stamped: signal
    -- (2) can wipe this on a different lockout id, so it is not the decay case.
    if s.lockID then return "Saved to this lockout" end
    -- Unstamped: no boss was killed, so there is no lockout to hang the counts on and the staleness decay
    -- is the only thing that will ever clear them. Measured off lastSeen exactly as CheckLockout measures it.
    local left = STALE_SESSION - (now - (s.lastSeen or s.started or now))
    if left <= 0 then return "Not saved (no boss killed) - clears automatically" end
    return ("Not saved (no boss killed) - clears in %s if left idle")
        :format(RDC.FormatDuration(left))
end

-- ── The raid roster ───────────────────────────────────────────────────────────
-- The one place the addon holds hardcoded instance knowledge, and it exists so the Active Lockouts page
-- lists a STABLE set of raids rather than a set that changes shape every lockout. A raid you have not run
-- shows as an inert button, so the page reads as "what is available" instead of "what happens to be
-- stored". Note this is not a return of the mapID abbreviation table deleted on 2026-08-11: that one
-- existed to SHORTEN names for a header with no room, where this one exists to list raids no session
-- covers. Labels here are full and match what the HUD title shows.
--
-- Three fields, and the split between them is the load-bearing part.
--   label   what the user reads, and the sort key. Chosen for the reader, so it need not be the client's
--           own name for the instance: "Mount Hyjal" over Blizzard's "Hyjal Summit".
--   mapID   the PRIMARY match against a stored session, since sessions are keyed "map:<id>" and a mapID is
--           locale independent where a name is not.
--   aliases normalised names, the FALLBACK match, and the reason a wrong mapID is survivable. Name matching
--           is already proven here: FindLockout has matched saved-instance names against session names in
--           production since v0.1.
--
-- **These are INSTANCE ids, not uiMap ids, and the two are easy to confuse because published tables list
-- both side by side.** Karazhan is instance 532 / map 799, Gruul's Lair 565 / 776, and so on. What belongs
-- here is the first of each pair, because it is the 8th return of GetInstanceInfo and therefore what
-- ResolveRaidID builds the "map:<n>" session key from. Confirmed live: a client standing in Gruul's Lair
-- reports `active: map:565`. Swapping in the uiMap column would break every match at once, and silently,
-- since the aliases would still carry the page.
--
-- All nine were cross-checked against a reference table on 2026-08-21. GetLockouts below is nevertheless a
-- UNION rather than a lookup, which is not redundancy: it means a session the roster fails to claim for ANY
-- reason still gets its own button, so the failure is a DUPLICATE and never a hidden raid. DebugRaid prints
-- roster= per session so a miss is visible rather than silent.
--
-- Unreleased content is listed ahead of time on purpose, so the page needs no change on the day it lands:
-- Mount Hyjal, Black Temple and Zul'Aman for phase 3, and Sunwell Plateau further out. An un-run raid
-- already renders as an inert label, so a raid that does not exist yet costs one dimmed button and nothing
-- else.
--
-- Zul'Aman's shorter lockout needs NOTHING here or anywhere else: every reset is derived from the resetIn
-- the server returns and stored as an absolute lockResetAt, and FormatDuration renders any span. Nothing in
-- the addon assumes seven days. That is the whole payoff of judging each session against its own stamp.
local RAID_ROSTER = {
    { label = "Black Temple",         mapID = 564, aliases = { "black temple" } },
    { label = "Gruul's Lair",         mapID = 565, aliases = { "gruul's lair" } },
    { label = "Karazhan",             mapID = 532, aliases = { "karazhan" } },
    { label = "Magtheridon's Lair",   mapID = 544, aliases = { "magtheridon's lair" } },
    { label = "Mount Hyjal",          mapID = 534, aliases = { "hyjal summit", "mount hyjal",
                                                               "the battle for mount hyjal" } },
    { label = "Serpentshrine Cavern", mapID = 548, aliases = { "serpentshrine cavern" } },
    { label = "Sunwell Plateau",      mapID = 580, aliases = { "sunwell plateau", "the sunwell" } },
    { label = "Tempest Keep",         mapID = 550, aliases = { "tempest keep", "the eye" } },
    { label = "Zul'Aman",             mapID = 568, aliases = { "zul'aman", "zulaman" } },
}

-- Strips a cluster prefix and nothing else, mirroring the UI's InstanceLabel so a roster miss still reads
-- the way the rest of the addon names a raid. The same shape FindLockout already uses for its tail match.
local function TrimCluster(s)
    if not s or s == "" then return nil end
    return s:match("^.-:%s*(.+)$") or s
end

local function NormalName(s)
    local t = TrimCluster(s)
    return t and t:lower() or nil
end

-- Which roster entry a stored session belongs to, or nil. mapID first, falling back to the aliases, and
-- reading the id out of the "map:<n>" key when the session predates the mapID field. Shared by GetLockouts
-- and DebugRaid so the debug line can never disagree with what the page draws.
local function RosterFor(s, rid)
    local mid = (s and s.mapID) or tonumber(tostring(rid or ""):match("^map:(%d+)$") or "")
    local nn  = NormalName(s and s.instance)
    for _, r in ipairs(RAID_ROSTER) do
        if mid and r.mapID == mid then return r end
        if nn then
            for _, a in ipairs(r.aliases) do
                if a == nn then return r end
            end
        end
    end
    return nil
end

-- One entry per ROSTER raid, plus any stored raid the roster did not claim, in alphabetical order.
--
-- `run` is what the page dims a button on, and it means PLAYED rather than merely stored: deaths recorded
-- or combat time accumulated. That deliberately admits a deathless night, which is a real result (the same
-- reasoning that puts `report stats` above the empty guard), and it excludes the empty shell a lockout wipe
-- leaves on the ACTIVE session, which SweepLockouts cannot delete because Sweep and the OnUpdate driver
-- both reach the active raid through DB.currentRaidID.
--
-- `key` and not `rid` is what the page tracks a button by, because a roster raid with no session has no
-- rid at all. For a run raid the two are the same string, which is what keeps GetLockoutRows(selected)
-- working unchanged.
--
-- `started` is carried for the page's start time, and the wipe is what gives it its meaning: it reads as
-- "when this lockout's counting began" and NOT "when the pull started". It is written when the session
-- row is minted, which is the zone-in that first resolved this RaidID, and rewritten to now by every
-- CheckLockout wipe, so a raid reset last Tuesday dates from the Tuesday you walked back in.
--
-- Ordered ALPHABETICALLY, replacing the old lastSeen ordering. The whole point of the roster is that the
-- page does not rearrange itself between lockouts, so a raid has to sit in the same place whether it was
-- run tonight, run last week or never run at all.
function RDC.GetLockouts()
    local out = {}
    local sessions = (DB and DB.sessions) or {}

    local function Summarise(rid, s)
        local deaths = 0
        for _, p in pairs(s.players or {}) do deaths = deaths + (p.deaths or 0) end
        return {
            rid           = rid,
            key           = rid,
            instance      = s.instance,
            deaths        = deaths,
            combatSeconds = s.combatSeconds or 0,
            started       = s.started or 0,
            seen          = s.lastSeen or s.started or 0,
            state         = LockoutState(s),
            run           = deaths > 0 or (s.combatSeconds or 0) > 0,
        }
    end

    -- One session per roster entry. A legacy "lock:" key and a "map:" key can both resolve to the same
    -- raid, so the one holding more deaths wins rather than whichever pairs() reached first.
    local claim = {}
    for rid, s in pairs(sessions) do
        local r = RosterFor(s, rid)
        if r then
            local cur = claim[r.label]
            if not cur then
                claim[r.label] = rid
            else
                local a, b = 0, 0
                for _, p in pairs(sessions[cur].players or {}) do a = a + (p.deaths or 0) end
                for _, p in pairs(s.players or {})            do b = b + (p.deaths or 0) end
                if b > a then claim[r.label] = rid end
            end
        end
    end

    local used = {}
    for _, r in ipairs(RAID_ROSTER) do
        local rid = claim[r.label]
        local e
        if rid and sessions[rid] then
            e = Summarise(rid, sessions[rid])
            used[rid] = true
        else
            e = { deaths = 0, combatSeconds = 0, started = 0, seen = 0, run = false }
            e.key = "roster:" .. r.label
        end
        e.label = r.label
        -- The BUTTON and the detail header both read the roster label, which is what keeps "a button and
        -- the raid it opens read identically" true now that a label can differ from the client's own name:
        -- "Mount Hyjal" must not become "Hyjal Summit" the instant a session exists behind it. It also
        -- drops the cluster prefix from the header for free, so the raid reads the same in both places.
        e.instance = r.label
        out[#out + 1] = e
    end

    -- Anything stored that the roster did not claim still gets a button, which is what makes a wrong mapID
    -- cosmetic instead of destructive. Filtered on `run` for the same reason the old zero-death filter
    -- existed: an empty shell has nothing to show.
    for rid, s in pairs(sessions) do
        if not used[rid] then
            local e = Summarise(rid, s)
            if e.run then
                e.label = TrimCluster(s.instance) or rid
                out[#out + 1] = e
            end
        end
    end

    table.sort(out, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        return tostring(a.key) < tostring(b.key)
    end)
    return out
end

-- Rows for one stored raid, built by the same rules the HUD's own rows are. Deliberately NOT demo-guarded
-- the way GetSnapshot is: this browses what is actually saved, and there is nothing about stored history to
-- preview.
function RDC.GetLockoutRows(rid)
    local s = DB and DB.sessions and DB.sessions[rid]
    return SnapshotOf(s and s.players)
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

-- ── Master switch ─────────────────────────────────────────────────────────────
-- Per character, stored beside the sessions rather than with the account-wide UI prefs. It is not a
-- preference about this client's furniture, it gates what gets WRITTEN to this character's death data, so
-- it belongs with that data: the existing split is "counts belong to the raid, storage belongs to the
-- character", and this is storage. An alt parked in a raid as a bank mule sits the night out while the main
-- keeps counting.
--
-- Applied at four choke points and nowhere else, each one chosen because everything of its kind passes
-- through it: SendComm (all outbound), OnComm (all inbound), CheckLockout (all housekeeping, including the
-- two calls UpdateRaidID makes from outside the poll) and the OnUpdate driver (the sweep and the combat
-- timer). Gating only the sweep would leave a "disabled" client silently merging peers' rows into its saved
-- variables with the HUD climbing, which is not off by any reading of the word.
--
-- Deliberately NOT gated: UpdateRaidID itself, which only tracks WHERE the character is and mints an empty
-- session, and the report paths, because reading counts already stored is not recording and a report button
-- that silently did nothing is the exact failure that got "/rdc reset" deleted.
local function Enabled() return not DB or DB.enabled ~= false end
RDC.IsEnabled = Enabled

function RDC.SetEnabled(on)
    on = on and true or false
    if not DB or DB.enabled == on then return end
    DB.enabled = on

    -- Both halves mirror what Sweep already does on finding itself outside the raid, because "was switched
    -- off" and "was not in the raid yet" have to mean the same thing to the poll.
    --
    -- Drop the combat clock's anchor, or the entire disabled window is banked as combat time on the first
    -- tick back, exactly as zoning out mid-fight would (see Sweep's early return).
    inCombat, lastCombatTick = false, nil
    -- Force a re-baseline. prevDead still holds the latch state from the instant we switched off, so a
    -- player who died during the blackout reads as a fresh alive->dead edge and is counted minutes late.
    -- Worse, whether that phantom appears depends on nothing but whether they happened to still be a corpse
    -- when the switch flipped. Wiping on both transitions rather than only on enable: it costs nothing while
    -- Sweep is not running, and it means no path can reach the poll with a stale latch.
    wipe(prevDead)
    wasInRaid = false
    -- Discard anything still waiting to go out. The opposite of what the chat queue wants: a queued REPORT
    -- is something the user asked for and must still be delivered, whereas a queued sync message from a
    -- client the user has just switched off is exactly what the switch exists to stop. Without this the
    -- drain sits below the switch and the messages would either strand forever or leave on re-enable,
    -- carrying a digest and counts from whenever they were built.
    wipe(commQueue)

    print("|cff88bbffRaidDeathCount|r " .. (on
        and "|cff44ff44on|r: recording and syncing."
        or  "|cffff4444off|r: nothing recorded, merged or broadcast. Stored counts are kept."))
    if RDC.RefreshEnabledState then RDC.RefreshEnabledState() end
    if RDC.RefreshHUD then RDC.RefreshHUD() end
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
    -- Counted only while an outage is open, so the recovery report can say how many re-assertions it took.
    -- That is evidence, not proof of cause: recovery on the first one points at a dropped registration,
    -- recovery on the twentieth points at something server-side simply expiring on its own schedule.
    if commsOK == false then reassertCount = reassertCount + 1 end
end

-- The three gates every outbound message passes. Returns the channel to send on, or false.
--
-- Called at QUEUE time and again at DRAIN time, which is not belt and braces: the queue opened a gap
-- between deciding to send and sending, and a message that was legitimate when queued must not go out
-- after we have zoned out of the instance or the user has switched the addon off. Re-checking here is what
-- makes the queue unable to widen any of the three.
local function CanSend()
    -- The master switch is applied to comms here rather than only in the OnUpdate poll because
    -- AnnouncePresence and RequestResync are driven by events (login, zoning, roster changes), so a
    -- poll-only gate would leave a disabled client still introducing itself and asking peers for state.
    if not Enabled() then return false end
    -- Syncing only ever makes sense from inside the raid itself. The RaidID is a mapID and nothing else, so
    -- it says WHERE but never WHICH RUN: two clients sticky on the same instance from different nights are
    -- indistinguishable to it. Comms being group scoped was assumed to cover that, on the reasoning that
    -- any group you are in is your raid, and a 5-man dungeon with mates is the counterexample. Party chat
    -- carried a peer's raid counts straight into a client that had merely walked through that instance
    -- once. Physically standing in the instance is the one condition stickiness cannot fake, so gate on it.
    -- Subsumes the old battleground and arena suppression, neither of which is a raid either.
    if not InRaidInstance() then return false end
    return GroupChannel()
end

-- isProbe arms the watchdog HERE and not at the call site, and that move is required by the queue rather
-- than being tidier: arming when we DECIDE to send starts the PROBE_TIMEOUT clock before the message
-- exists on the wire, and a heartbeat the drain then refuses (we zoned out while it waited) could never
-- echo and would time out into a FALSE outage. A false outage is the one thing the indicator must never
-- produce, which is why PROBE_TIMEOUT is already generous.
local function PushComm(msg, isProbe)
    local ch = CanSend()
    if not ch then return false end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, ch)
    elseif SendAddonMessage then
        SendAddonMessage(COMM_PREFIX, msg, ch)
    else
        return false
    end
    -- Only when nothing is already in flight, so the timeout is measured from the OLDEST unanswered send
    -- rather than being pushed forward by every later one.
    if isProbe and not commsProbeSent then commsProbeSent = GetTime() end
    return true
end

-- Paces our own outbound messages. Same shape as QueueChat below and for the same reason, one layer down:
-- an idle queue sends immediately, so the overwhelmingly common case (a lone death, a heartbeat) puts
-- exactly the same bytes on the wire at exactly the same moment it always has, and only a burst is spread.
--
-- THE MESSAGE IS QUEUED FULLY FORMED, with the RaidID already baked into the string by the caller. Queueing
-- the parts and building the string at drain time is the one way this file could corrupt counts: zoning
-- between queue and drain would stamp one raid's rows with another raid's id, peers there would see a
-- matching rid, and merge by MAX would make it permanent. QueueChat captures its channel at queue time
-- against the same class of mistake.
--
-- Returns whether the message was ACCEPTED, not whether it was sent, which is the one semantic the split
-- above changes. Nothing consults it any more except SendEntries, which only reports whether there was
-- anything to send at all.
--
-- The queue is strictly FIFO, so a delayed message at the head holds up everything behind it: a death found
-- while a jittered full-state reply is still waiting can be up to REPLY_JITTER late. Accepted rather than
-- worked around with a priority queue, because merge is by MAX and a late death converges identically to a
-- prompt one. Reordering to let deaths overtake would buy nothing and cost the FIFO property that makes
-- this easy to reason about.
local function SendComm(msg, delay, isProbe)
    if not CanSend() then return false end
    local now = GetTime()
    if #commQueue == 0 and not delay and now >= commNextAt then
        commNextAt = now + COMM_INTERVAL
        return PushComm(msg, isProbe)
    end
    commQueue[#commQueue + 1] = { msg = msg, probe = isProbe, after = delay and (now + delay) or 0 }
    return true
end

-- Driven from the OnUpdate below, which must call this ahead of its POLL_INTERVAL gate: behind it the
-- queue could only drain every 0.5s and COMM_INTERVAL would mean nothing.
local function DrainComm()
    local m = commQueue[1]
    if not m then return end
    local now = GetTime()
    if now < commNextAt or now < m.after then return end
    -- Measured from the actual send, not the scheduled one, so a frame hitch stretches the gap rather than
    -- banking credit and firing a burst to catch up, which is the thing being prevented.
    commNextAt = now + COMM_INTERVAL
    table.remove(commQueue, 1)
    -- Return deliberately ignored: a message CanSend now refuses is dropped rather than retried. Merge is
    -- by MAX and the heartbeat digest catches a peer up within ~60s, so a dropped send costs latency and
    -- never a count.
    PushComm(m.msg, m.probe)
end

-- How long to hold back our reply to a "?", so twenty clients answering one broadcast do not land on the
-- same frame. Derived from our own NAME rather than from math.random, and that is not paranoia: Lua 5.1
-- starts from a FIXED seed unless something calls math.randomseed, so every client could draw the identical
-- "random" delay and stack up exactly as before, with the spread silently doing nothing. A name hash is
-- different per client by construction and needs no seeding, no shared clock and no agreement.
local function ReplyDelay()
    local n = playerName or UnitName("player") or ""
    local h = 0
    for i = 1, #n do h = (h + n:byte(i) * i) % 97 end
    return (h / 97) * REPLY_JITTER
end

local function Entry(name, class, deaths)
    return name .. "," .. (class or "") .. "," .. deaths .. ";"
end

-- Sends a list of "name,class,deaths;" entries as op S, split into <=MSG_MAX chunks since an addon message
-- caps around 255 bytes. Shared by the full-state reply and the sweep batch, which put the same rows on the
-- wire and must chunk them the same way.
-- delay holds every chunk back by the same amount, passed only by the full-state reply. A sweep batch
-- passes nothing: those are deaths as they happen and there is no fan-in to spread, since the sweep that
-- produced them ran on one client.
local function SendEntries(entries, delay)
    local prefix = DB.currentRaidID .. "|S|"
    local buf, sent = "", false
    for i = 1, #entries do
        local e = entries[i]
        -- The buf check matters for a single oversize entry: without it we would flush an empty payload
        -- first and waste a message.
        if buf ~= "" and #prefix + #buf + #e > MSG_MAX then
            SendComm(prefix .. buf, delay); buf = ""; sent = true
        end
        buf = buf .. e
    end
    if buf ~= "" then SendComm(prefix .. buf, delay); sent = true end
    return sent
end

-- One message for everything a single sweep found, instead of one per death.
--
-- Multiple deaths go out as S, NOT as a multi-entry D. Op D is specified as exactly one death and 0.5
-- clients parse it with an anchored "^(.-),(.-),(%d+)$": handed two entries that pattern still MATCHES,
-- and quietly records one player whose class is the middle of the string. Corrupting a peer mid-upgrade
-- is far worse than the op being named slightly wrong. S already carries a multi-entry payload that every
-- shipped version merges correctly, so a batch is wire-compatible with 0.5 in both directions.
--
-- A lone death still goes as D, so the overwhelmingly common case puts exactly the same bytes on the wire
-- as it always has.
function RDC.BroadcastDeaths(entries)
    if not DB.currentRaidID or #entries == 0 then return end
    if #entries == 1 then
        SendComm(DB.currentRaidID .. "|D|" .. entries[1]:sub(1, -2))   -- strip the entry's trailing ";"
    else
        SendEntries(entries)
    end
end

local function RequestResync()
    if not DB.currentRaidID then return end
    SendComm(DB.currentRaidID .. "|?|")
end

-- ── State digest ──────────────────────────────────────────────────────────────
-- A number every client computes from its own counts, ridden along on the heartbeat so two clients can
-- notice they disagree without exchanging any state. Merge by MAX only heals a player when that player
-- dies AGAIN, so without this a death lost to a dropped message stays lost for the rest of the night and
-- each client converges on "the max I happened to hear" rather than on the truth.
--
-- A sum of deaths was the obvious digest and is not enough: the failure it has to catch is a wipe where I
-- miss Bob's death and you miss Carl's, which leaves us on an identical total and permanently different
-- rows. So the name is folded in per player, which makes the digest sensitive to WHICH deaths are missing
-- and not just how many.
--
-- Two properties this must keep, or clients disagree over identical data and resync forever:
--   * order independence, since pairs() order differs per client. Hence a sum, which commutes.
--   * only rows a peer could also have. Zero-count rows are skipped (we may hold one for a player nobody
--     has seen die) and class is excluded (it is legitimately "" until someone sees the unit).
-- Reads the session directly rather than a snapshot, so demo mode can never reach the wire.
local function StateDigest()
    local s = ActiveSession()
    if not s then return 0 end
    local sum = 0
    for name, p in pairs(s.players) do
        local d = p.deaths or 0
        if d > 0 then
            local h = 0
            for i = 1, #name do h = (h * 31 + name:byte(i)) % 65536 end
            sum = (sum + h * d) % 1000000
        end
    end
    return sum
end

-- ── Peer presence (the "in sync" count) ───────────────────────────────────────
-- Scoped to our RaidID like every other op, so the count only ever includes peers syncing the SAME raid.
local function AnnouncePresence()
    if not DB.currentRaidID then return end
    -- Payload gained the digest after 0.5, which read the whole payload as a version string. A 0.5 client
    -- hearing "0.6,12345" therefore parses the digits as version 0.6.12345 and prints "a new version is
    -- available", which is CORRECT: only a client newer than 0.5 sends a digest at all. The one cost is
    -- that its peer tooltip shows the raw field, cosmetic and only until it updates.
    local body = RDC.GetVersion() .. "," .. StateDigest()
    -- Doubles as the watchdog's echo probe, which PushComm arms at the moment this actually reaches the
    -- server rather than here. Not jittered: heartbeats are already spread, each client's running off its
    -- own login time rather than off a shared trigger the way a "?" reply is.
    SendComm(DB.currentRaidID .. "|H|" .. body, nil, true)
end

local function IsSelf(sender)
    if not sender or sender == "" then return true end
    if playerName and sender == playerName then return true end
    local short = sender:match("^[^-]+")                 -- our own broadcasts loop back to us; drop them
    return short ~= nil and short == UnitName("player")
end

-- ── Comms watchdog (echo probe) ───────────────────────────────────────────────
-- Our own addon messages come back to us, which is the entire reason IsSelf exists. That makes every H
-- ping a probe of the whole send-and-receive path requiring NO other addon user present, and it answers the
-- one question the sync count cannot: a count of 1 reads identically whether we have gone deaf or we are
-- simply the only user in the raid.
--
-- What the two signals together distinguish, which is the point of the exercise:
--   echo back + peers heard    healthy
--   echo back + peers silent   genuinely nobody else running it
--   echo lost  + peers heard   our SEND is being dropped (server-side throttle or mute)
--   echo lost  + peers silent  our RECEIVE is dead (the case EnsurePrefix was written for)
-- Whether re-asserting the prefix is what ends an outage is recorded rather than assumed, since that is
-- exactly the unverified claim behind the existing self-heal.
--
-- An outage is only ever declared after the echo has worked at least once, so a client where it does not
-- work at all reports "never observed" instead of sitting in a permanent false alarm.

local function MarkCommsUp()
    if commsProbeSent then
        local rtt = GetTime() - commsProbeSent
        if rtt > maxEchoTime then maxEchoTime = rtt end
    end
    lastLoopback, everLooped, commsProbeSent = time(), true, nil
    local recovered = (commsOK == false)
    commsOK = true                       -- set BEFORE the repaint below, or the tag paints red one last
                                         -- time and nothing ever repaints it green
    if recovered then
        local since = commsBrokenSince or time()
        lastOutage = { from = since, to = time(), reasserts = reassertCount }
        print(("|cff88bbffRaid Death Count|r comms recovered after %ds (%d prefix re-assert%s)."):format(
            time() - since, reassertCount, reassertCount == 1 and "" or "s"))
        commsBrokenSince, reassertCount = nil, 0
        RefreshHUD()
    end
end

local function MarkCommsDown()
    if not everLooped then return end        -- never proved the echo works here, so this proves nothing
    if commsOK == false then return end      -- already reported, do not repeat every retry
    commsOK, commsBrokenSince, reassertCount = false, time(), 0
    print("|cff88bbffRaid Death Count|r addon comms have gone silent, retrying in the background.")
    RefreshHUD()
end

-- Any inbound message at all, before the RaidID filter: a message from the wrong raid still proves we can
-- hear, and our own echo always carries our own id anyway.
local function NoteInbound(sender)
    if IsSelf(sender) then MarkCommsUp() else lastPeerRx = time() end
end

-- Called every tick. Cheap when idle: one comparison unless a probe is outstanding.
local function CheckCommsProbe()
    if not commsProbeSent then return end
    if GetTime() - commsProbeSent < PROBE_TIMEOUT then return end
    commsProbeSent = nil
    if not IsInGroup() then return end       -- left the group mid-probe: no echo expected, not a fault
    if InPvPInstance() then return end       -- ditto: we stopped sending on the way in, so silence is us
    MarkCommsDown()
    EnsurePrefix()   -- the only client-side repair available, and it counts itself (see EnsurePrefix)
end

function RDC.GetCommsHealth()
    return {
        ok = commsOK, everLooped = everLooped, brokenSince = commsBrokenSince,
        lastLoopback = lastLoopback, lastPeerRx = lastPeerRx,
        reasserts = reassertCount, maxEcho = maxEchoTime, lastOutage = lastOutage,
    }
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

-- H payload is "<version>" from 0.5 and "<version>,<digest>" after it. The digest capture is optional and
-- anchored, so an old payload yields the version and no digest rather than a half-parse.
local function ParseHeartbeat(payload)
    local ver, dig = tostring(payload or ""):match("^([^,]*),?(%d*)$")
    if ver == "" then ver = nil end
    return ver, tonumber(dig)
end

-- A settled disagreement, meaning the peer has repeated the SAME digest across two heartbeats and it
-- differed from ours both times. Requiring it to repeat is what keeps a wipe quiet: during one, counts
-- legitimately differ for a few seconds while the broadcasts land, and a digest that is still moving is
-- not evidence of anything. Only a stuck disagreement is.
--
-- Both sides of a mismatch see it, so a raid that disagrees would all ask at once. Two things stop that
-- storm, which matters because the whole reason a desync happened is that the channel was overloaded:
-- the ask is a broadcast "?" whose replies heal everyone hearing it, so hearing a peer's request counts as
-- ours (see lastResyncAsk), and DIGEST_COOLDOWN bounds the rest. One request per raid per minute.
local function NoteDigest(p, dig)
    if not dig then return end
    local mine = StateDigest()
    local settled = (p.dig == dig) and p.mismatched and (dig ~= mine)
    p.dig, p.mismatched = dig, (dig ~= mine)
    if settled and time() - lastResyncAsk >= DIGEST_COOLDOWN then
        lastResyncAsk = time()
        RequestResync()
    end
end

-- Any op keeps a peer alive; only H carries a version and a digest, so retain the last ones we saw. The
-- entry is updated in place rather than replaced: it now holds digest history that a wholesale rebuild on
-- every inbound message would silently reset, which would stop a mismatch ever repeating.
local function TouchPeer(sender, op, payload)
    if IsSelf(sender) then return end
    local p = peers[sender]
    if not p then p = {}; peers[sender] = p end
    p.t = time()
    if op == "H" then
        local ver, dig = ParseHeartbeat(payload)
        if ver then p.ver = ver; CheckPeerVersion(ver) end
        NoteDigest(p, dig)
    end
end

-- Stale peers are kept rather than deleted, because "we lost four people" and "nobody else is running the
-- addon" are the same sync count of 1 and very different situations. Retention is bounded by the number of
-- distinct addon users heard in one session, so raid-sized, and the table is local (a reload clears it).
local function LivePeerCount()
    local now, n = time(), 0
    for _, p in pairs(peers) do
        if now - (p.t or 0) <= PEER_STALE then n = n + 1 end
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

-- Peers heard from at some point but not within PEER_STALE. Returns (count, time() we last heard any of
-- them), so the HUD can say "lost contact with 4, last heard 6m ago" instead of asserting that nobody else
-- is running the addon, which is something we have no way to know.
function RDC.GetLostPeers()
    local now, n, recent = time(), 0, nil
    for _, p in pairs(peers) do
        if now - (p.t or 0) > PEER_STALE then
            n = n + 1
            if not recent or (p.t or 0) > recent then recent = p.t end
        end
    end
    return n, recent
end

-- Shared by the HUD tooltip and DebugDump so both phrase elapsed time identically.
function RDC.Ago(t)
    if not t then return "never" end
    local d = time() - t
    if d < 60 then return d .. "s ago" end
    return math.floor(d / 60) .. "m ago"
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
    local entries = {}
    for name, p in pairs(s.players) do
        if (p.deaths or 0) > 0 then entries[#entries + 1] = Entry(name, p.class, p.deaths) end
    end
    -- Held back by our own offset. SYNC_THROTTLE bounds how often ONE client replies and does nothing about
    -- all of them replying at once, which is the shape of the burst that actually matters here: every
    -- client's timer starts from the same inbound "?". Costs a latecomer up to REPLY_JITTER before their
    -- counts fill in, which merge by MAX makes free.
    return SendEntries(entries, ReplyDelay())
end

-- Anything for a raid other than our current one is dropped.
local function OnComm(msg, sender)
    local rid, op, payload = msg:match("^(.-)|(.-)|(.*)$")
    if not rid then return end
    -- Merging an inbound row IS recording, so the master switch has to be enforced on the way in and not
    -- just on the way out: a send-only gate would leave a client the user believes is off quietly absorbing
    -- the whole raid's counts into its saved variables, with the HUD climbing to prove it. Ahead of
    -- NoteInbound for the same reason the raid-instance gate below is: traffic we refuse to process is not
    -- evidence our channel works.
    if not Enabled() then return end
    -- The mirror of the send gate, and it has to exist independently rather than trusting peers to stay
    -- quiet: through any staged rollout a peer still on <= 0.7.2 keeps broadcasting from a dungeon, and our
    -- own gate is the only thing that can refuse it. Ahead of NoteInbound deliberately, since traffic from
    -- a group that is not a raid is not ours to count as evidence the channel works.
    if not InRaidInstance() then return end
    NoteInbound(sender)                      -- before the RaidID filter: hearing anything proves the path
    if rid ~= DB.currentRaidID then return end
    TouchPeer(sender, op, payload)
    if op == "D" then
        local name, class, deaths = payload:match("^(.-),(.-),(%d+)$")
        if name and ApplyRemote(name, class, tonumber(deaths)) then
            RefreshHUD()
        end
    elseif op == "S" then
        local changed = false
        for name, class, deaths in payload:gmatch("([^,;]+),([^,;]*),(%d+);?") do
            if ApplyRemote(name, class, tonumber(deaths)) then
                changed = true
            end
        end
        if changed then RefreshHUD() end
    elseif op == "?" then
        lastResyncAsk = time()   -- somebody has already asked; ours would only duplicate the replies
        SendFullState()
    elseif op == "H" then
        RefreshHUD()                                     -- a new or returning peer changes the sync count
    end
end

-- ── Death sweep (poll) ────────────────────────────────────────────────────────
-- UnitIsDeadOrGhost is synced for group members regardless of range, so an alive->dead edge is a death and
-- a death across the map is never missed. That is why this polls rather than driving off health events.
-- Any remaining gap is filled by peers' broadcasts.

local batch = {}   -- deaths found this tick, flushed as ONE message. Reused rather than reallocated: this
                   -- runs twice a second for a whole raid night.

local function Sweep()
    if not DB.currentRaidID then return end
    -- Clearing inCombat on the way out matters: without it, zoning out mid-fight and returning hours later
    -- would bank the entire absence as combat time on the first tick back.
    if not InRaidInstance() then wasInRaid = false; inCombat = false; return end
    if not wasInRaid then
        wasInRaid = true
        wipe(prevDead)   -- re-baseline on entry so already-dead state (including a world death we
                         -- corpse-walked in with) is recorded, not counted as a fresh death this tick
    end
    wipe(batch)
    local anyCombat = false
    for _, unit in ipairs(watched) do
        local name = FullName(unit)
        if name then
            -- Raid-level rather than our own flag alone. A dead player is out of combat, so gating on
            -- "player" would stop the clock exactly when a fight is going worst.
            if not anyCombat and UnitAffectingCombat(unit) then anyCombat = true end
            local dead = UnitIsDeadOrGhost(unit) and not (UnitIsFeignDeath and UnitIsFeignDeath(unit))
            local was = prevDead[name]
            if was == nil then
                prevDead[name] = dead            -- first sight: baseline only, we did not witness it
            elseif dead and not was then
                prevDead[name] = true
                local total, cls = RecordDeath(name, select(2, UnitClass(unit)))
                if total then batch[#batch + 1] = Entry(name, cls, total) end
            elseif not dead then
                prevDead[name] = false
            end
        end
    end
    -- Banked against the PREVIOUS tick's state, so a segment is only counted once both of its ends are
    -- known. The first tick of a fight therefore adds nothing, which is where the stated +/-0.5s per
    -- combat segment comes from. Incremental rather than banked at combat end, so a disconnect mid-pull
    -- costs one tick instead of the whole fight.
    local now = GetTime()
    local sess = ActiveSession()
    -- Marks the session as still being played, for the unstamped-session decay in CheckLockout. Wall clock,
    -- not GetTime(), because it has to survive a logout. Stamped per tick rather than per death, so a long
    -- deathless attempt still reads as activity; Sweep has already returned unless we are physically inside
    -- the raid, which is exactly the condition that should count as playing it.
    if sess then sess.lastSeen = time() end
    if sess and inCombat and lastCombatTick then
        sess.combatSeconds = (sess.combatSeconds or 0) + (now - lastCombatTick)
    end
    inCombat, lastCombatTick = anyCombat, now

    -- One flush for the whole tick, so a 25-man wipe is one message rather than 25, and one repaint
    -- rather than 25.
    if #batch > 0 then
        RefreshHUD()
        RDC.BroadcastDeaths(batch)
    end
end

-- ── RaidID transitions ────────────────────────────────────────────────────────

local function MergeSession(from, to)
    for name, p in pairs(from.players) do
        local q = to.players[name]
        if not q then q = { class = p.class, deaths = 0, own = 0 }; to.players[name] = q end
        if p.class and p.class ~= "" then q.class = p.class end
        if (p.deaths or 0) > (q.deaths or 0) then q.deaths = p.deaths end
        -- Carried by MAX like the count itself. Both sides are the same client's own sightings, so the
        -- larger is the better record; dropping it would let the row default `own` back to `deaths` and
        -- re-inherit a peer's number as if we had seen it ourselves.
        if (p.own or 0) > (q.own or 0) then q.own = p.own end
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
-- (2) needs a real id in hand. A third signal covers the sessions the first two cannot see at all:
--   3. the session carries NO stamp and has not been played in STALE_SESSION seconds
-- A night that killed no boss was never saved, so it has no lockout of its own and neither (1) nor (2) can
-- ever fire for it: the counts are not merely stranded for the week, they are carried into the NEXT real
-- lockout, because stamping an unstamped session does not wipe it. Reported live 2026-08-05 from a pug that
-- wiped without a kill and was still showing those deaths days later to a completely different group.
-- Decay is gated on the session being unstamped, and that gate is the whole design rather than a
-- heuristic: no lockout means there is no continuity to protect, whereas a STAMPED session legitimately
-- spans a week (clear on Tuesday, continue on Thursday) and must never decay, for the same reason
-- combatSeconds concatenates across nights. Derived locally like the other two, so every client reaches
-- the same verdict with nothing crossing the wire and nobody holding authority.
--
-- All three run against EVERY stored session, not just the active one: see SweepLockouts below.

-- The half of the wipe that belongs to the raid we are standing in and to no other. This is the sharp edge
-- of sweeping every session rather than only the active one, and it is invisible in a diff: prevDead is the
-- death-edge baseline for the ACTIVE raid, and first sight re-baselines a unit WITHOUT counting it, so
-- wiping it because some other raid's lockout rolled over would silently drop every player already on the
-- floor here. A stranded Karazhan session decaying mid-wipe in Serpentshrine would cost Serpentshrine those
-- deaths, with nothing printed anywhere. RefreshHUD is the same story one layer up and merely wasteful
-- rather than harmful, the HUD only ever rendering the active session.
local function IsActiveSession(s)
    return s ~= nil and DB ~= nil and DB.currentRaidID ~= nil and DB.sessions[DB.currentRaidID] == s
end

-- One line per stale decay, one line for however many lockouts rolled over together. The split is the one
-- that already shipped: a reset announces WHAT, a decay announces WHY as well, because no boss was killed
-- and without the reason the clear reads as data loss rather than as maintenance. The BATCHING is new, and
-- exists because a Tuesday login can now clear five raids in one pass where only the active one was ever
-- checked before. A single rolled-over raid still prints exactly the wording it always printed.
local function AnnounceResets(events)
    local names = {}
    for _, e in ipairs(events) do
        if e.stale then
            print(("|cff88bbffRaid Death Count|r %s was left unfinished (no boss killed) and idle over "
                .. "%d hours: %d deaths cleared."):format(e.label, STALE_SESSION / 3600, e.cleared))
        else
            names[#names + 1] = e.label
        end
    end
    if #names == 1 then
        print(("|cff88bbffRaid Death Count|r new lockout for %s: counts reset."):format(names[1]))
    elseif #names > 1 then
        print(("|cff88bbffRaid Death Count|r new lockout: counts reset for %s.")
            :format(table.concat(names, ", ")))
    end
end

-- `events`, when given, collects what would have been printed instead of printing it, so a sweep can batch
-- the whole pass into one line. Omitted, this announces immediately exactly as it always has, which is what
-- keeps CheckActiveLockout and UpdateRaidID's two calls unchanged.
local function CheckLockout(s, iname, events)
    if not s then return end
    -- A switched-off addon does no housekeeping either, and the gate belongs HERE rather than on
    -- CheckActiveLockout, which is only one of several callers: UpdateRaidID reaches this directly from both
    -- of its branches and runs off PLAYER_ENTERING_WORLD and GROUP_ROSTER_UPDATE, neither of which is
    -- behind the OnUpdate gate, and SweepLockouts reaches it once per stored session. The decay in
    -- particular announces itself in chat, and "N deaths cleared" arriving from something the user
    -- believes is off reads as a bug rather than as maintenance. Nothing is
    -- lost by deferring: re-enabling picks it up within a heartbeat, and a disabled client answers no
    -- resyncs, so it cannot serve the counts it skipped clearing to anybody else.
    if not Enabled() then return end
    local id, resetIn = FindLockout(iname or s.instance)
    local now = time()

    local newLockout = false
    if s.lockResetAt and now >= s.lockResetAt then newLockout = true end   -- (1) our lockout expired
    if id and s.lockID and id ~= s.lockID then newLockout = true end       -- (2) saved to a different one

    -- lastSeen is absent on sessions written before it existed, so fall back to `started`: for a night
    -- that has already gone stale those are the same evening, which is why old bad data clears itself on
    -- the next visit. Cannot fire on a session being played, since Sweep re-stamps it every 0.5s.
    --
    -- The empty check is not an optimisation, it stops the message repeating forever. Unlike (1) and (2),
    -- which re-stamp themselves silent immediately below, a decay leaves the session unstamped, so its own
    -- fresh `started` goes stale again 6 hours later and it announces another reset of nothing. Parked in
    -- town that recurs for as long as the character exists. An empty session has nothing to reset, so it
    -- has no business claiming it did.
    local unstamped = not s.lockID and not s.lockResetAt
    local hasData = next(s.players or {}) ~= nil or (s.combatSeconds or 0) > 0
    local stale = unstamped and hasData
                  and (now - (s.lastSeen or s.started or now)) >= STALE_SESSION   -- (3)

    if newLockout or stale then
        -- Counted before the wipe: a decay is the one reset the player has no way to anticipate, since it
        -- can fire at login or on the heartbeat in town with no zoning to explain it. Naming the number
        -- discarded is what separates "the addon did a thing" from "the addon lost my raid".
        local cleared = 0
        for _, p in pairs(s.players) do cleared = cleared + (p.deaths or 0) end
        wipe(s.players)
        s.started = now
        s.combatSeconds = 0   -- or last week's fighting stays in the denominator for the whole new week
        s.lockID, s.lockResetAt = nil, nil
        s.lastSeen = nil
        -- Active-only, and see IsActiveSession for why: wiping the latch on behalf of a raid we are not in
        -- would drop the deaths of anyone lying on the floor in the raid we ARE in.
        if IsActiveSession(s) then
            wipe(prevDead)                -- counts restart, so the baselines have to as well
            RefreshHUD()
        end
        -- Silent when there was nothing to clear. The wipe above still runs, since the stamps and the
        -- combat clock have to be re-anchored either way, but "counts reset" having reset no counts is
        -- noise: harmless when only the active session was ever checked, and five lines of it on a Tuesday
        -- login now that every stored raid is.
        if cleared > 0 then
            local ev = { label = tostring(s.instance or iname or "this raid"),
                         cleared = cleared, stale = stale }
            if events then events[#events + 1] = ev else AnnounceResets({ ev }) end
        end
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
--
-- Deliberately still ACTIVE-only, and deliberately not switched to SweepLockouts: its one remaining caller
-- is SendFullState, which can only ever reply with the active raid's rows, so the guarantee it needs is
-- about that session and no other. Sweeping there would be work on a latency-sensitive path for a promise
-- the reply cannot break, and it would put a session-deleting loop inside the outbound comms path.
function CheckActiveLockout()   -- assigns the forward-declared local up top, do not make this a new local
    CheckLockout(ActiveSession(), nil)   -- which is where the master-switch gate lives, covering all callers
end

-- Every stored session against its OWN stamp, which is the difference between "the raid I am standing in
-- has reset" and "a new lockout has begun". It has to be per session rather than one verdict applied to
-- all, because TBC reset periods are not uniform across raids: keying a blanket wipe off the active raid
-- would clear a shorter-cycle raid's live counts and then miss that raid's own reset when it came. Every
-- session already carries the server's lockID and lockResetAt, so each one answers for itself and the addon
-- never has to know which raid resets how often.
--
-- Emptied non-active sessions are DELETED rather than left as shells. The Lockouts page is a within-lockout
-- review surface and keeps no history by design, so once a raid's lockout has rolled the counts are worth
-- nothing to anybody and a row holding no players and no combat seconds has nothing left to read. This also
-- retires the legacy pre-0.4 "lock:" orphan for free, which could never be migrated and never decayed.
--
-- Three things must survive a refactor. The ACTIVE session is never deleted, because Sweep and the OnUpdate
-- driver both reach it through DB.currentRaidID and a live raid losing its row stops counting dead with no
-- error printed. A session with combat seconds but no deaths is NOT empty and survives, since a deathless
-- night is a real result until its own lockout expires and the wipe zeroes the clock. And the master switch
-- is checked here as well as inside CheckLockout, because the deletion below is housekeeping that
-- CheckLockout's own gate does not cover.
local function SweepLockouts()
    if not DB or not DB.sessions then return end
    if not Enabled() then return end
    local events, emptied = {}, {}
    for rid, s in pairs(DB.sessions) do
        CheckLockout(s, nil, events)
        if rid ~= DB.currentRaidID
           and next(s.players or {}) == nil and (s.combatSeconds or 0) <= 0 then
            emptied[#emptied + 1] = rid
        end
    end
    -- Collected first, deleted after. Assigning nil to the key `next` is currently sitting on is legal in
    -- Lua 5.1, but nothing here needs to lean on that to be read correctly.
    for _, rid in ipairs(emptied) do DB.sessions[rid] = nil end
    if #events > 0 then AnnounceResets(events) end
    -- Guarded like every other UI call from the core, which loads first. Only on a pass that changed
    -- something: the Lockouts page repaints on show and on resize and has no tick of its own, so a window
    -- left open in town across a reset would otherwise keep drawing a raid this sweep just deleted.
    if (#events > 0 or #emptied > 0) and RDC.RefreshLockouts then RDC.RefreshLockouts() end
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
        -- EnsureSession, not ActiveSession. The two are identical in normal operation, since the branch
        -- above mints the session at the moment it sets the id. Nothing defends that invariant from the
        -- outside though, and losing the session while the id still points at it is unrecoverable without
        -- this: the id never changes, so the branch that would rebuild it is never reached again, and every
        -- sweep from then on has nowhere to record. Counting stops dead with no error printed anywhere,
        -- which is the worst shape a fault can have. Confirmed 2026-08-04 from a hand-cleared session that
        -- left a live raid silently uncounted. Rebuilding here is free when the session is present.
        local missing = not DB.sessions[rid]
        local s = EnsureSession(rid, iname, mapID)
        if iname and iname ~= "" then
            if not s.instance or s.instance == "" then s.instance = iname end
            if not s.mapID then s.mapID = mapID end   -- backfill for sessions written by older code
        end
        CheckLockout(s, iname)

        -- A session minted here needs the same footing the switch branch gives a new one, or the heal is
        -- only half done: re-baseline the death latch so nobody already on the floor is counted for a death
        -- that predates the session, ask peers for what they hold, and repaint. Fires once, because the
        -- next tick finds the session present.
        if missing then
            wipe(prevDead)
            RequestResync()
            RefreshHUD()
        end
    end
end

-- ── Reporting ─────────────────────────────────────────────────────────────────

local function ClassLabel(class)
    if not class then return "?" end
    return class:sub(1, 1) .. class:sub(2):lower()
end

-- Where reports go. Account-wide with the other UI prefs, because it is a preference about this client's
-- chat rather than data about a raid, so it has no business in the per-character session store.
-- "RAID" resolves through GroupChannel rather than sending to RAID literally, which keeps the default
-- byte-identical to what shipped before there was a choice. "PARTY" means the raid subgroup.
local REPORT_CHANNELS = { RAID = "Raid", PARTY = "Party", GUILD = "Guild" }
RDC.REPORT_CHANNELS = REPORT_CHANNELS
RDC.CHANNEL_ORDER   = { "RAID", "PARTY", "GUILD" }   -- display order; the table above has no order of its own

function RDC.GetReportChannel()
    local c = RaidDeathCountDB and RaidDeathCountDB.reportChannel
    return REPORT_CHANNELS[c] and c or "RAID"
end

function RDC.SetReportChannel(c)
    c = c and c:upper() or ""
    if not REPORT_CHANNELS[c] then return false end
    if RaidDeathCountDB then RaidDeathCountDB.reportChannel = c end
    if RDC.RefreshReportChannel then RDC.RefreshReportChannel() end   -- core loads first, so guard it
    return true
end

-- A choice we cannot honour prints locally instead of falling back to another channel: quietly
-- redirecting a guild-intended report into raid chat, or the reverse, is a far worse failure than only
-- the sender seeing it.
local function ResolveReportChannel(want)
    if want == "GUILD" then return IsInGuild() and "GUILD" or nil end
    if want == "PARTY" then return IsInGroup() and "PARTY" or nil end
    return GroupChannel()
end

local lastChannelWarn = 0

-- Report lines are paced, never sent as a burst of SendChatMessage inside one frame. A Top 5 is six lines,
-- and sent together the server delivered them as header,2,3,4,5,1: every rank number correct, the order
-- wrong, all six stamped the same second. Chat sent that fast has no delivery-order guarantee, and
-- "report all" in a full raid is 27 lines rather than six, so this gets worse exactly where it is most
-- public. The channel is resolved when the line is QUEUED and carried with it, not re-resolved at send
-- time: a report is issued as a unit, and leaving the group midway through one should not send its tail
-- somewhere else.
local CHAT_INTERVAL = 0.25
local chatQueue, chatNextAt = {}, 0

-- An idle queue sends immediately, so a one-line report (a ctrl-clicked row, "report stats") is never
-- delayed by pacing it is the only occupant of, and a multi-line one still puts its header on screen at
-- once. That instant first line is also what stops an impatient re-click turning a slow report into three
-- interleaved ones.
local function QueueChat(text, ch)
    local now = GetTime()
    if #chatQueue == 0 and now >= chatNextAt then
        chatNextAt = now + CHAT_INTERVAL
        SendChatMessage(text, ch)
        return
    end
    chatQueue[#chatQueue + 1] = { text = text, ch = ch }
end

-- Driven from the OnUpdate below, which must call this ahead of its POLL_INTERVAL gate: behind it the
-- queue could only drain every 0.5s and CHAT_INTERVAL would mean nothing.
local function DrainChat()
    if #chatQueue == 0 then return end
    local now = GetTime()
    if now < chatNextAt then return end
    -- Measured from the actual send, not the scheduled one, so a frame hitch stretches the gap rather
    -- than banking credit and firing a burst to catch up, which is the thing being prevented.
    chatNextAt = now + CHAT_INTERVAL
    local m = table.remove(chatQueue, 1)
    SendChatMessage(m.text, m.ch)
end

local function ReportLine(text)
    local want = RDC.GetReportChannel()
    local ch = ResolveReportChannel(want)
    if ch then
        QueueChat(text, ch)
        return
    end
    -- Throttled, or "report all" repeats the warning on all 25 lines. Deliberately silent on RAID: falling
    -- back to a local print when ungrouped is what this always did, and it is obvious on screen.
    if want ~= "RAID" and GetTime() - lastChannelWarn > 5 then
        lastChannelWarn = GetTime()
        print(("|cff88bbffRaidDeathCount|r Not in %s chat, printing locally."):format(REPORT_CHANNELS[want]:lower()))
    end
    print("|cff88bbffRaidDeathCount|r " .. text)
end

-- Reports one player straight from a snapshot row. The HUD calls this for a ctrl-clicked row rather than
-- routing the name back through RDC.Report: that path is a prefix search that interpolates the name into a
-- Lua pattern, so a cross-realm "Bob-Frostmourne" would be read as a quantifier and match nothing, failing
-- on exactly the name it was handed. Searching for a row we are already holding is also pointless work.
-- Prints the short name to match what the HUD row shows and what was clicked.
function RDC.ReportPlayer(e)
    if not e or not e.name then return end
    local short = e.name:match("^[^-]+") or e.name
    ReportLine(("%s (%s): %d death%s"):format(short, ClassLabel(e.class), e.deaths, e.deaths == 1 and "" or "s"))
end

-- Anything NOT in here is treated as a player-name prefix, so a new keyword must be added or
-- "/rdc report <keyword>" silently searches for a player of that name instead.
local REPORT_MODES = {
    all = true, top3 = true, top5 = true, stats = true, total = true,   -- total: retired alias for stats
    least = true, lowest = true, class = true, classes = true,
}

-- Candidates for "fewest deaths". A snapshot cannot answer this on its own: GetSnapshot drops zero-count
-- rows, so the players who actually went deathless, the ones the question is really about, have no row in
-- it at all. The live roster has them, and a roster unit also carries a class we can trust, unlike a
-- session row for someone we have only ever heard about over comms. Returns nil when there is no roster
-- worth reading, meaning demo mode, where the sample rows are the whole point, or ungrouped, where the
-- roster is just us; the caller falls back to the snapshot rows in that case.
local function FewestCandidates(snap)
    if RDC.demoData or not IsInGroup() then return nil end

    local deaths = {}
    for _, e in ipairs(snap) do deaths[e.name] = e.deaths end

    local out = {}
    for _, unit in ipairs(watched) do
        local name = FullName(unit)     -- same key the counts are stored under, so the lookup lines up
        if name then
            out[#out + 1] = { name = name, class = select(2, UnitClass(unit)), deaths = deaths[name] or 0 }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- mode = "all" | "top3" | "top5" | "stats" (alias "total") | "least" (alias "lowest")
--        | "class" (alias "classes") | a player-name prefix.
function RDC.Report(mode)
    local snap = RDC.GetSnapshot()

    -- Keywords match case insensitively; mode itself stays as typed so a miss can echo the name back.
    local key = mode and mode:lower() or "all"

    -- Deliberately AHEAD of the empty guard below, unlike every other mode. A night with no deaths is a
    -- result worth posting here, and the combat time next to it is what makes it one: "0 deaths in 00:42:10"
    -- is the report a clean run wants, where the other modes genuinely have nothing to list.
    --
    -- "total" is kept as an alias rather than removed. It shipped as a documented command and may sit in
    -- someone's macro, and this output is a superset of what it printed, so the rename costs its callers
    -- nothing. A keyword that silently became a player-name search would be the same kind of quietly broken
    -- command that got "/rdc reset" deleted.
    if key == "stats" or key == "total" then
        local total = RDC.TotalDeaths(snap)
        local sec   = RDC.GetCombatSeconds()
        ReportLine(("Raid Death Count: %d death%s in %s of combat (%s deaths per min)"):format(
            total, total == 1 and "" or "s", RDC.FormatClock(sec), RDC.FormatDPM(total, sec)))
        return
    end

    if #snap == 0 then ReportLine("No deaths recorded yet.") return end

    -- Deaths summed per class instead of per player. Snapshot-based, unlike "least" below: a class with
    -- nobody dead has nothing to say, whereas a player with no deaths is the whole point of that command.
    if key == "class" or key == "classes" then
        local byClass, order = {}, {}
        for _, e in ipairs(snap) do
            -- A row can legitimately carry no class (a player we have only ever heard about over comms and
            -- never seen), and ClassLabel maps "" to "", which would print a bucket with no name at all.
            local label = (e.class and e.class ~= "") and ClassLabel(e.class) or "Unknown"
            if not byClass[label] then
                byClass[label] = 0
                order[#order + 1] = label
            end
            byClass[label] = byClass[label] + e.deaths
        end
        table.sort(order, function(a, b)
            if byClass[a] ~= byClass[b] then return byClass[a] > byClass[b] end
            return a < b
        end)

        ReportLine("Raid Death Count (by class):")
        -- Safe to total here, unlike top3/top5: every death lands in some bucket, so the figure really is
        -- the sum of the rows shown.
        ReportLine(("Total Deaths (%d)"):format(RDC.TotalDeaths(snap)))
        for i, label in ipairs(order) do
            ReportLine(("%d. %s: %d"):format(i, label, byClass[label]))
        end
        return
    end

    -- Fewest deaths across the raid, counting the deathless at zero. A lone winner reads better on one
    -- line, but a tie is listed row by row in the same shape as the top3/top5/all reports: against a
    -- roster a tie is routinely most of the raid, which no single line could hold anyway.
    if key == "least" or key == "lowest" then
        local rows, fewest = FewestCandidates(snap)
        if rows and #rows > 0 then
            fewest = rows[1].deaths
            for _, e in ipairs(rows) do if e.deaths < fewest then fewest = e.deaths end end
        else
            rows, fewest = snap, snap[#snap].deaths   -- sorted deaths desc, so the tail is the minimum
        end

        local tied = {}
        for _, e in ipairs(rows) do
            if e.deaths == fewest then tied[#tied + 1] = e end
        end

        local header = ("Raid Death Count (fewest, %d death%s)"):format(fewest, fewest == 1 and "" or "s")
        if #tied == 1 then
            ReportLine(("%s: %s (%s)"):format(header, tied[1].name, ClassLabel(tied[1].class)))
        else
            ReportLine(header .. ":")
            for i, e in ipairs(tied) do
                ReportLine(("%d. %s (%s): %d"):format(i, e.name, ClassLabel(e.class), e.deaths))
            end
        end
        return
    end

    if not REPORT_MODES[key] then
        for _, e in ipairs(snap) do
            if e.name:lower():match("^" .. key) then
                ReportLine(("%s (%s): %d death%s"):format(e.name, ClassLabel(e.class), e.deaths, e.deaths == 1 and "" or "s"))
                return
            end
        end
        ReportLine("No deaths recorded for " .. mode .. ".")
        return
    end

    local limit = (key == "top3" and 3) or (key == "top5" and 5) or #snap
    local title = (key == "top3" and "Top 3") or (key == "top5" and "Top 5") or "All"
    ReportLine("Raid Death Count (" .. title .. "):")
    -- Full report only: against a truncated top3/top5 list a raid-wide total reads as the sum of the rows
    -- shown, which it is not.
    if title == "All" then
        ReportLine(("Total Deaths (%d)"):format(RDC.TotalDeaths(snap)))
    end
    for i = 1, math.min(limit, #snap) do
        local e = snap[i]
        ReportLine(("%d. %s (%s): %d"):format(i, e.name, ClassLabel(e.class), e.deaths))
    end
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
        -- Absent reads as on, so an upgrade never silently stops counting for someone who has never opened
        -- the options. Written out explicitly rather than left nil, because the saved-variables file is
        -- read by hand when something goes wrong and "enabled = false" is the first thing to check.
        if DB.enabled == nil then DB.enabled = true end
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
        -- first resync reply would push last week's counts onto peers who had already reset. The full
        -- sweep rather than the active one, because a login is where a week's worth of rolled-over raids
        -- is most likely to be noticed all at once.
        SweepLockouts()
        if RequestRaidInfo then RequestRaidInfo() end   -- warms the list, fires UPDATE_INSTANCE_INFO
        if RDC.InitHUD then RDC.InitHUD() end
        if RDC.InitMinimap then RDC.InitMinimap() end
        -- After InitHUD, which shows the frame: a character logging in switched off has to say so on the
        -- HUD from the first frame, or it looks like an addon that has simply stopped working.
        if RDC.RefreshEnabledState then RDC.RefreshEnabledState() end
        RequestResync()
        AnnouncePresence()
        print(("|cff88bbffRaid Death Count|r v%s loaded. Enjoy!"):format(RDC.GetVersion()))

    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsurePrefix()        -- before the resync and presence below, or the replies are not heard
        -- A probe armed before the loading screen can never be answered, and GetTime keeps running across
        -- it, so it would time out instantly on the far side and report an outage that never happened.
        -- AnnouncePresence below arms a fresh one.
        commsProbeSent = nil
        -- Zoning into a BG or arena suspends comms outright (see InPvPInstance), so an outage still open
        -- from the raid would hold the dot red for the whole match with no probe able to clear it. Drop
        -- back to the unproven state; returning to the raid re-establishes the truth within PROBE_TIMEOUT.
        if InPvPInstance() then commsOK, commsBrokenSince, reassertCount = nil, nil, 0 end
        RebuildWatched()
        UpdateRaidID()
        SweepLockouts()
        if RequestRaidInfo then RequestRaidInfo() end
        RequestResync()
        AnnouncePresence()

    elseif event == "GROUP_ROSTER_UPDATE" then
        RebuildWatched()
        UpdateRaidID()
        -- Left the group entirely: drop the peer history and the watchdog verdict, or the next group we
        -- join opens reporting lost contact with people from the last one and possibly a stale outage.
        -- everLooped and the worst echo time survive, being facts about this client rather than this group.
        if not IsInGroup() then
            wipe(peers)
            commsOK, commsBrokenSince, commsProbeSent, reassertCount = nil, nil, nil, 0
        end
        AnnouncePresence()

    elseif event == "UPDATE_INSTANCE_INFO" then
        SweepLockouts()   -- the list can be cold at login; this is when it is actually trustworthy

    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == COMM_PREFIX and DB then OnComm(arg2, arg4) end
    end
end)

local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    DrainChat()   -- ahead of the gate on purpose: behind it the queue drains no faster than POLL_INTERVAL
    -- Below DrainChat and above everything else. Switching off mid-report must not strand the lines already
    -- queued, since they are a report the user asked for and the queue has no other drain; past this point
    -- nothing that records, syncs or times the raid may run.
    if not Enabled() then return end
    -- Below the switch where DrainChat is above it, which is the whole difference between the two queues:
    -- a report is owed to the user and must survive being switched off, a sync message must not outlive it.
    -- SetEnabled empties the queue on the way out, so nothing strands here. Above the POLL_INTERVAL gate
    -- for the same reason DrainChat is: behind it COMM_INTERVAL could never be shorter than 0.5s.
    DrainComm()
    acc = acc + elapsed
    if acc < POLL_INTERVAL then return end
    acc = 0
    if DB and DB.currentRaidID then
        UpdateRaidID()   -- steady cadence picks up a zone change and runs CheckLockout even when
                         -- GROUP_ROSTER_UPDATE is quiet; cheap when nothing has changed
        Sweep()
        CheckCommsProbe()
        local now = time()
        -- Probe harder while broken: the timestamp of recovery is the evidence for whether the prefix
        -- re-assert is what fixes it, and at the 30s cadence that timestamp is too blurry to tell.
        if now - lastHeartbeat >= ((commsOK == false) and PROBE_RETRY or HEARTBEAT) then
            lastHeartbeat = now
            EnsurePrefix()   -- re-assert: a silently dropped registration otherwise needs a /reload
            -- Safety net for a client parked in town across the weekly reset, which would otherwise keep
            -- last week's counts until it zoned or relogged. Converges everyone within HEARTBEAT, and
            -- since the sweep reaches every stored session this is also what clears the raids the
            -- character is not standing in, with no zoning needed to reach them.
            SweepLockouts()
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
-- Split into sections because the combined dump outgrew a readable chat window. Each is callable on its
-- own for a targeted check; DebugDump still prints all four, which is what to paste when reporting a
-- problem. All /run only, deliberately: none of this belongs on the slash command surface.
--   /run RaidDeathCount.DebugRaid()     instance, RaidID, lockouts, stored sessions
--   /run RaidDeathCount.DebugTimer()    combat timer
--   /run RaidDeathCount.DebugComms()    comms health, digests, last outage
--   /run RaidDeathCount.DebugMemory()   addon memory
--   /run RaidDeathCount.DebugDump()     all of the above
function RDC.DebugRaid()
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
        -- Positions 11 and 12 are numEncounters/encounterProgress, confirmed populated on 2.5.6 (a cleared
        -- SSC reads 6/6). Informational only: a "raid complete" flag was considered for stopping the combat
        -- timer and dropped, because a timer that only runs in combat already freezes when the raid ends,
        -- making the flag a label rather than a mechanism.
        local name, id, reset, diff, locked, _, _, _, _, _, encounters, progress = GetSavedInstanceInfo(i)
        print(("  [%d] %s id=%s reset=%s diff=%s locked=%s progress=%s/%s"):format(
            i, tostring(name), tostring(id), tostring(reset), tostring(diff), tostring(locked),
            tostring(progress), tostring(encounters)))
    end
    -- All sessions, so a stranded raidID's counts are visible and not just the active one's.
    print("|cff88bbffRDC|r sessions in DB:")
    for id, sess in pairs(DB and DB.sessions or {}) do
        local total, np = 0, 0
        for _, p in pairs(sess.players or {}) do total = total + (p.deaths or 0); np = np + 1 end
        -- Idle time explains a decay before anything else does, and it is the only visible difference
        -- between a session that is about to be wiped on entry and one that will survive. A stranded
        -- session is never checked while it is inactive, so a high idle here is expected, not a fault:
        -- it decays at the moment re-entering that raid makes it active.
        local seen = sess.lastSeen or sess.started
        -- roster= is how a wrong mapID surfaces. A session reading "roster=NONE" for a raid that plainly IS
        -- on the roster means neither its mapID nor its aliases matched, so the page is drawing it as a
        -- duplicate button beside the inert roster one instead of filling that one in.
        local r = RosterFor(sess, id)
        print(("  <%s> instance=%s mapID=%s lock=%s idle=%s players=%d totalDeaths=%d roster=%s%s"):format(
            tostring(id), tostring(sess.instance), tostring(sess.mapID), tostring(sess.lockID),
            seen and ("%.1fh"):format((time() - seen) / 3600) or "?", np, total,
            r and r.label or "NONE",
            id == DB.currentRaidID and "  <== ACTIVE" or ""))
    end
end

-- inRaidInstance is on this line because it gates accumulation: a timer that is not moving during a fight
-- is explained by that reading before anything else.
-- Reads the session directly rather than through RDC.GetCombatSeconds(), which substitutes a fixed clock
-- under demo mode. This is the tool for a timer that looks wrong, so it must report the real accumulation
-- and never the faked one; demo is called out on the line instead, since it explains what the HUD is showing.
function RDC.DebugTimer()
    local s = ActiveSession()
    local cs = (s and s.combatSeconds) or 0
    print(("|cff88bbffRDC|r combat timer: %.1fs (%dm %02ds)  inCombat=%s  inRaidInstance=%s%s"):format(
        cs, math.floor(cs / 60), math.floor(cs % 60), tostring(inCombat), tostring(InRaidInstance()),
        RDC.demoData and "  (DEMO: hud shows " .. RDC.FormatClock(DEMO_COMBAT_SECONDS) .. ")" or ""))
end

function RDC.DebugComms()
    -- Comms health. The echo column is the one that matters: it is the only reading that separates "we
    -- went deaf" from "nobody else here", which the sync count alone cannot do.
    local h = RDC.GetCommsHealth()
    local state
    -- First, because it explains every other figure on the line: nothing is sent or expected in here.
    if InPvPInstance() then
        state = "SUSPENDED (battleground/arena)"
    elseif not InRaidInstance() then
        -- The usual reason for silence now, and the one most likely to be read as a fault: outside the
        -- instance nothing is sent and nothing inbound is accepted, by design.
        state = "SUSPENDED (not in a raid instance)"
    elseif h.ok == false then
        state = ("DOWN since %s, %d re-asserts"):format(RDC.Ago(h.brokenSince), h.reasserts)
    elseif h.ok then
        state = "ok"
    elseif not h.everLooped then
        state = "echo NEVER observed"   -- either we have not probed yet or the echo does not work here
    else
        state = "idle (no probe answered since the last group)"
    end
    -- Parenthesised: GetLostPeers returns two values and this is the last argument, so without them the
    -- second would spill into the format call.
    -- queued is the only window onto the send queue, which is otherwise invisible: a figure that is anything
    -- but 0 outside the instant of a burst means the drain has stalled, and the drain is what every outbound
    -- message now depends on.
    print(("|cff88bbffRDC|r comms: %s   echo %s (worst %.1fs)   peers %s   live=%d lost=%d queued=%d"):format(
        state, RDC.Ago(h.lastLoopback), h.maxEcho, RDC.Ago(h.lastPeerRx),
        LivePeerCount(), (RDC.GetLostPeers()), #commQueue))
    -- Our digest against every peer's. Same number everywhere means the raid genuinely agrees; a peer stuck
    -- on a different one is the desync, visible here without waiting for the automatic resync to fire.
    local mine, agree, differ = StateDigest(), {}, {}
    for name, p in pairs(peers) do
        local short = name:match("^[^-]+") or name
        if p.dig == nil then differ[#differ + 1] = short .. "=?"
        elseif p.dig == mine then agree[#agree + 1] = short
        else differ[#differ + 1] = short .. "=" .. p.dig end
    end
    print(("|cff88bbffRDC|r digest: %d   agreeing=%d   differing: %s"):format(
        mine, #agree, #differ > 0 and table.concat(differ, " ") or "none"))
    if h.lastOutage then
        print(("|cff88bbffRDC|r last outage: %ds, ended %s, %d prefix re-assert%s"):format(
            (h.lastOutage.to or 0) - (h.lastOutage.from or 0), RDC.Ago(h.lastOutage.to),
            h.lastOutage.reasserts or 0, (h.lastOutage.reasserts == 1) and "" or "s"))
    end
end

-- GetAddOnMemoryUsage reads a cached figure that only refreshes on demand, so without the update call it
-- reports whatever the last consumer of the API happened to leave behind.
function RDC.DebugMemory()
    local update = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
    local usage  = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
    if update and usage then
        update()
        print(("|cff88bbffRDC|r memory: %.1f KB"):format(usage(ADDON_NAME) or 0))
    end
end

-- Everything, in the order that reads best in chat. Memory stays last because chat scrolls the oldest
-- print out of view first, so the shortest line is the one worth keeping on screen.
function RDC.DebugDump()
    RDC.DebugRaid()
    RDC.DebugTimer()
    RDC.DebugComms()
    RDC.DebugMemory()
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
    elseif cmd == "channel" then
        if rest ~= "" and not RDC.SetReportChannel(rest) then
            print("|cff88bbffRaidDeathCount|r channel must be raid, party or guild.")
        else
            print(("|cff88bbffRaidDeathCount|r reporting to %s chat.")
                :format(RDC.REPORT_CHANNELS[RDC.GetReportChannel()]:lower()))
        end
    elseif cmd == "lock" then
        if RDC.ToggleLock then RDC.ToggleLock() end
    -- No "stats" here any more: the strip it toggled is part of the HUD and is always shown, so there is
    -- nothing left to switch. Removed rather than kept as a no-op, unlike the "total" report alias, which
    -- still had a real command to point at. This one falls through to the help print.
    elseif cmd == "options" or cmd == "config" then
        if RDC.ToggleOptions then RDC.ToggleOptions() end
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
        print("  /rdc report [<name>|top3|top5|least|stats|class|all]   report to chat")
        print("  /rdc channel [raid|party|guild]   where reports are sent")
        print("  /rdc options        settings (or right-click the minimap button)")
        print("  /rdc lock           lock/unlock HUD move + resize")
        print("  /rdc minimap        show/hide the minimap button")
        print("  /rdc demo           toggle sample data for a UI preview")
        print("  /rdc version        print the addon version")
    end
end
