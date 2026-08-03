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
local PROBE_TIMEOUT = 10                   -- seconds to wait for our own H to echo back before calling
                                           -- comms broken. Generous on purpose: a false outage would
                                           -- destroy trust in the indicator, and DebugDump reports the
                                           -- worst echo time seen so this can be tuned against real data.
local PROBE_RETRY   = 10                   -- seconds between probes while broken (HEARTBEAT when healthy),
                                           -- so recovery is timestamped sharply enough to be evidence
local DIGEST_COOLDOWN = 60                 -- min seconds between resyncs triggered by a digest mismatch, so
                                           -- a raid that all disagrees at once cannot storm the channel

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
local deathLog   = false      -- diagnostic printing of every death edge and every remote raise, toggled by
                              -- RDC.DebugDeaths(). Exists to separate a genuine death from a
                              -- UnitIsDeadOrGhost flicker: merge by MAX spreads one client's miscount to the
                              -- entire raid, so the only useful question is which client produced the number.

-- Combat timer. Measures seconds the RAID spent fighting, not wall clock, which is what makes it survive a
-- multi-night lockout with no gap rule: the hours between Tuesday and Thursday simply are not counted.
-- Purely local, deliberately: nothing about it crosses the wire, so there is no clock to agree on and no
-- message cost. GetTime() (monotonic, sub-second) for the same reason the watchdog uses it.
local inCombat        = false -- was the raid in combat as of the last sweep
local lastCombatTick          -- GetTime() at the last accumulation (nil = nothing banked yet)

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

-- Death-edge diagnostics. Both read their own API values inside the guard so nothing is evaluated while
-- logging is off, which matters because a wipe hits these 25 times in one tick.
--
-- The decisive reading is the PAIR of lines, not the death on its own: a real death is a single DEATH, while
-- a flicker in UnitIsDeadOrGhost is DEATH / alive / DEATH a tick or two apart. conn and vis separate the two
-- causes of an alive edge, a resurrection from the unit's data merely going unavailable.
local function LogDeathEdge(kind, name, unit, total, own)
    if not deathLog then return end
    print(("|cff88bbffRDC|r |cffaaaaaa%s.%d|r %s %s (%s)%s dead=%s ghost=%s conn=%s vis=%s"):format(
        date("%H:%M:%S"), math.floor(GetTime() * 10) % 10, kind, name, unit,
        -- own alongside the merged total is the readout that verifies the split: our own sightings should
        -- track the real death count even while the total carries a peer's higher number.
        total and (" -> " .. total .. " (own " .. tostring(own) .. ")") or "",
        tostring(UnitIsDead(unit)), tostring(UnitIsGhost(unit)),
        tostring(UnitIsConnected(unit)), tostring(UnitIsVisible(unit))))
end

-- Logged only when the merge actually RAISED our count, since that is the one case that changes what the HUD
-- shows. Names the sender, which is what localises a miscount to a client without instrumenting every install.
local function LogRemoteRaise(op, name, deaths, sender)
    if not deathLog then return end
    print(("|cff88bbffRDC|r |cffaaaaaa%s.%d|r remote %s %s -> %s from %s"):format(
        date("%H:%M:%S"), math.floor(GetTime() * 10) % 10, op, name, tostring(deaths), tostring(sender)))
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
    -- class is the STORED one, which may be from an earlier sighting when this read is nil. own is returned
    -- for the diagnostic log only.
    return p.deaths, p.class, p.own
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

-- Summed from a snapshot rather than kept as a running counter, so it can never drift from the rows the
-- HUD and the report actually show. Pass a snapshot to avoid rebuilding one you already have.
function RDC.TotalDeaths(snap)
    local sum = 0
    for _, e in ipairs(snap or RDC.GetSnapshot()) do sum = sum + e.deaths end
    return sum
end

-- Seconds the raid has spent in combat this lockout. Not wall clock: see the inCombat declaration for why.
function RDC.GetCombatSeconds()
    local s = ActiveSession()
    return (s and s.combatSeconds) or 0
end

function RDC.GetInstanceName()
    if RDC.demoData then return "Demo Preview" end
    local s = ActiveSession()
    return s and s.instance
end

-- Same demo guard as GetInstanceName: without it the HUD would label demo rows with the real raid the
-- session happens to be on.
function RDC.GetMapID()
    if RDC.demoData then return nil end
    local s = ActiveSession()
    return s and s.mapID
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
    -- Counted only while an outage is open, so the recovery report can say how many re-assertions it took.
    -- That is evidence, not proof of cause: recovery on the first one points at a dropped registration,
    -- recovery on the twentieth points at something server-side simply expiring on its own schedule.
    if commsOK == false then reassertCount = reassertCount + 1 end
end

-- Returns true only when a message actually went out. The watchdog needs that: arming an echo probe for a
-- send that never happened (ungrouped) would time out and report a fake outage.
local function SendComm(msg)
    -- Syncing only ever makes sense from inside the raid itself. The RaidID is a mapID and nothing else, so
    -- it says WHERE but never WHICH RUN: two clients sticky on the same instance from different nights are
    -- indistinguishable to it. Comms being group scoped was assumed to cover that, on the reasoning that
    -- any group you are in is your raid, and a 5-man dungeon with mates is the counterexample. Party chat
    -- carried a peer's raid counts straight into a client that had merely walked through that instance
    -- once. Physically standing in the instance is the one condition stickiness cannot fake, so gate on it.
    -- Subsumes the old battleground and arena suppression, neither of which is a raid either.
    if not InRaidInstance() then return false end
    local ch = GroupChannel()
    if not ch then return false end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, ch)
    elseif SendAddonMessage then
        SendAddonMessage(COMM_PREFIX, msg, ch)
    else
        return false
    end
    return true
end

local function Entry(name, class, deaths)
    return name .. "," .. (class or "") .. "," .. deaths .. ";"
end

-- Sends a list of "name,class,deaths;" entries as op S, split into <=MSG_MAX chunks since an addon message
-- caps around 255 bytes. Shared by the full-state reply and the sweep batch, which put the same rows on the
-- wire and must chunk them the same way.
local function SendEntries(entries)
    local prefix = DB.currentRaidID .. "|S|"
    local buf, sent = "", false
    for i = 1, #entries do
        local e = entries[i]
        -- The buf check matters for a single oversize entry: without it we would flush an empty payload
        -- first and waste a message.
        if buf ~= "" and #prefix + #buf + #e > MSG_MAX then
            SendComm(prefix .. buf); buf = ""; sent = true
        end
        buf = buf .. e
    end
    if buf ~= "" then SendComm(prefix .. buf); sent = true end
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
    -- Doubles as the watchdog's echo probe. Only arm when nothing is already in flight, so the timeout is
    -- measured from the OLDEST unanswered send rather than being pushed forward by every later one.
    if SendComm(DB.currentRaidID .. "|H|" .. body) and not commsProbeSent then
        commsProbeSent = GetTime()
    end
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
    return SendEntries(entries)
end

-- Anything for a raid other than our current one is dropped.
local function OnComm(msg, sender)
    local rid, op, payload = msg:match("^(.-)|(.-)|(.*)$")
    if not rid then return end
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
            LogRemoteRaise("D", name, deaths, sender)
            RefreshHUD()
        end
    elseif op == "S" then
        local changed = false
        for name, class, deaths in payload:gmatch("([^,;]+),([^,;]*),(%d+);?") do
            if ApplyRemote(name, class, tonumber(deaths)) then
                LogRemoteRaise("S", name, deaths, sender)
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
                local total, cls, own = RecordDeath(name, select(2, UnitClass(unit)))
                if total then batch[#batch + 1] = Entry(name, cls, total) end
                LogDeathEdge("DEATH", name, unit, total, own)
            elseif not dead then
                if was then LogDeathEdge("alive", name, unit, nil) end
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
-- (2) needs a real id in hand.
-- KNOWN GAP: a session that never saw a boss kill was never saved, carries no stamp, and so survives into
-- the following week. Needs a whole night with zero kills to hit, and since /rdc reset was removed there is
-- no manual clear: it resolves itself once a boss kill stamps the session, or on entering a different raid.
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
        s.combatSeconds = 0   -- or last week's fighting stays in the denominator for the whole new week
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

-- An idle queue sends immediately, so a one-line report (a ctrl-clicked row, "report total") is never
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
    all = true, top3 = true, top5 = true, total = true,
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

-- mode = "all" | "top3" | "top5" | "total" | "least" (alias "lowest") | "class" (alias "classes")
--        | a player-name prefix.
function RDC.Report(mode)
    local snap = RDC.GetSnapshot()
    if #snap == 0 then ReportLine("No deaths recorded yet.") return end

    -- Keywords match case insensitively; mode itself stays as typed so a miss can echo the name back.
    local key = mode and mode:lower() or "all"

    if key == "total" then
        local total = RDC.TotalDeaths(snap)
        ReportLine(("Raid Death Count: %d total death%s"):format(total, total == 1 and "" or "s"))
        return
    end

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
        CheckActiveLockout()
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
        CheckActiveLockout()   -- the list can be cold at login; this is when it is actually trustworthy

    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == COMM_PREFIX and DB then OnComm(arg2, arg4) end
    end
end)

local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    DrainChat()   -- ahead of the gate on purpose: behind it the queue drains no faster than POLL_INTERVAL
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
        print(("  <%s> instance=%s mapID=%s lock=%s players=%d totalDeaths=%d%s"):format(
            tostring(id), tostring(sess.instance), tostring(sess.mapID), tostring(sess.lockID), np, total,
            id == DB.currentRaidID and "  <== ACTIVE" or ""))
    end
end

-- inRaidInstance is on this line because it gates accumulation: a timer that is not moving during a fight
-- is explained by that reading before anything else.
function RDC.DebugTimer()
    local cs = RDC.GetCombatSeconds()
    print(("|cff88bbffRDC|r combat timer: %.1fs (%dm %02ds)  inCombat=%s  inRaidInstance=%s"):format(
        cs, math.floor(cs / 60), math.floor(cs % 60), tostring(inCombat), tostring(InRaidInstance())))
end

-- In memory only, so it is off again after a /reload. Deliberate: this prints on every death of every fight,
-- which is not something to leave running by accident for a whole raid night.
function RDC.DebugDeaths()
    deathLog = not deathLog
    print("|cff88bbffRDC|r death edge logging " .. (deathLog and "|cff44ff44ON|r" or "|cffff4444OFF|r")
        .. " (off again after /reload)")
    return deathLog
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
    print(("|cff88bbffRDC|r comms: %s   echo %s (worst %.1fs)   peers %s   live=%d lost=%d"):format(
        state, RDC.Ago(h.lastLoopback), h.maxEcho, RDC.Ago(h.lastPeerRx),
        LivePeerCount(), (RDC.GetLostPeers())))
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
        print("  /rdc report [<name>|top3|top5|least|total|class|all]   report to chat")
        print("  /rdc channel [raid|party|guild]   where reports are sent")
        print("  /rdc lock           lock/unlock HUD move + resize")
        print("  /rdc minimap        show/hide the minimap button")
        print("  /rdc demo           toggle sample data for a UI preview")
        print("  /rdc version        print the addon version")
    end
end
