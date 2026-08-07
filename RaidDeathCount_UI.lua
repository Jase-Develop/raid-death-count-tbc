-- Raid Death Count (TBC 2.5.6) - the HUD: a movable, resizable Details-style bar list of per-player
-- death counts (class icon > name > count), sorted desc, one row per player with deaths > 0.

local RDC = RaidDeathCount

-- ── Theme (lean subset borrowed from WarlockQol) ──────────────────────────────
local THEME = {
    bg     = { 0.063, 0.063, 0.063, 0.90 },  -- window fill
    panel  = { 0.118, 0.118, 0.118, 1 },     -- header strip
    border = { 0.24,  0.24,  0.24,  1 },     -- 1px borders
    text   = { 0.90,  0.90,  0.90,  1 },     -- body text
    dim    = { 0.55,  0.55,  0.55,  1 },     -- muted text
    accent = { 0.40,  0.73,  1.00,  1 },     -- highlight (blue)
    field  = { 0.16,  0.16,  0.16,  1 },     -- a well: checkbox interiors and the options close button,
                                             -- one step lighter than `panel` so it reads on the title strip
    offRed = { 0.78,  0.25,  0.25,  1 },     -- an "off" toggle, and the HUD title while recording is off
}
local FONT = "Fonts\\ARIALN.TTF"
local FONT_FB = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local HEADER_H = 18
local ROW_H    = 18
local PAD      = 4
local MIN_W, MIN_H = 150, 60
local MAX_W, MAX_H = 500, 700
local DEF_W, DEF_H = 220, 200
local SCROLL_W  = 6    -- scrollbar gutter, only reserved while the bar is shown
local THUMB_MIN = 16   -- keeps the thumb grabbable on a long list

local CLASS_TEX = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

local function ApplyFont(fs, size, flags)
    if not fs:SetFont(FONT, size, flags or "") then fs:SetFont(FONT_FB, size, flags or "") end
    return fs
end

-- Requires the frame to carry the BackdropTemplate mixin, which this client needs for SetBackdrop.
local function ApplyFlat(frame, color, border)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = border and "Interface\\Buttons\\WHITE8X8" or nil,
        edgeSize = 1,
    })
    frame:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
    if border then
        local b = THEME.border
        frame:SetBackdropBorderColor(b[1], b[2], b[3], b[4] or 1)
    end
end

-- ── HUD frame ─────────────────────────────────────────────────────────────────
local hud = CreateFrame("Frame", "RaidDeathCount_HUD", UIParent, "BackdropTemplate")
hud:SetSize(DEF_W, DEF_H)
hud:SetPoint("CENTER")
hud:SetFrameStrata("MEDIUM")
hud:SetClampedToScreen(true)
ApplyFlat(hud, THEME.bg, true)
hud:Hide()

hud:SetResizable(true)
if hud.SetResizeBounds then
    hud:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
else
    if hud.SetMinResize then hud:SetMinResize(MIN_W, MIN_H) end
    if hud.SetMaxResize then hud:SetMaxResize(MAX_W, MAX_H) end
end

local function DB() return RaidDeathCountDB and RaidDeathCountDB.hud end

local function SavePlacement()
    local db = DB(); if not db then return end
    db.width, db.height = hud:GetWidth(), hud:GetHeight()
    local point, _, relPoint, x, y = hud:GetPoint()
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

hud:SetMovable(true)
-- Mouse stays enabled with no drag handler so the body swallows clicks rather than passing them through
-- to the world behind it. Dragging is wired to the header alone, below.
hud:EnableMouse(true)

-- ── Header (title + lock + close) ─────────────────────────────────────────────
local header = CreateFrame("Frame", nil, hud, "BackdropTemplate")
header:SetPoint("TOPLEFT", hud, "TOPLEFT", PAD, -PAD)
header:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -PAD, -PAD)
header:SetHeight(HEADER_H)
ApplyFlat(header, THEME.panel, true)

-- Drag by the title bar only. The header's buttons are child frames and consume their own clicks, so
-- grabbing one of those does not start a move.
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")
header:SetScript("OnDragStart", function()
    local db = DB()
    if db and db.locked then return end
    hud:StartMoving()
end)
header:SetScript("OnDragStop", function() hud:StopMovingOrSizing(); SavePlacement() end)

-- Speaks only while recording is off, so hovering the bar to drag it is unchanged in normal operation. A
-- HUD still showing counts while nothing is being recorded is a lie, and RefreshEnabledState reddening the
-- title says something is wrong without saying what, so the header answers when asked. No width is spent:
-- the header is the frame that already collides with its own title at MIN_W, which is why the report modes
-- moved into a panel, so a disabled marker could not be a badge or a longer title.
header:SetScript("OnEnter", function(self)
    if not RDC.IsEnabled or RDC.IsEnabled() then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Recording is off", THEME.offRed[1], THEME.offRed[2], THEME.offRed[3])
    GameTooltip:AddLine("No deaths are being counted, merged or broadcast.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Turn it back on in /rdc options.", 0.55, 0.55, 0.55, true)
    GameTooltip:Show()
end)
header:SetScript("OnLeave", function() GameTooltip:Hide() end)

local title = header:CreateFontString(nil, "OVERLAY")
ApplyFont(title, 12)
title:SetPoint("LEFT", header, "LEFT", 5, 0)
title:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
title:SetText("Raid Death Count")

local closeBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
closeBtn:SetSize(HEADER_H - 4, HEADER_H - 4)
closeBtn:SetPoint("RIGHT", header, "RIGHT", -3, 0)
ApplyFlat(closeBtn, THEME.bg, true)
local cx = closeBtn:CreateFontString(nil, "OVERLAY")
ApplyFont(cx, 12)
cx:SetPoint("CENTER")
cx:SetText("x")
cx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
closeBtn:SetScript("OnEnter", function() cx:SetTextColor(1, 0.3, 0.3) end)
closeBtn:SetScript("OnLeave", function() cx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3]) end)
closeBtn:SetScript("OnClick", function() RDC.SetHUDShown(false) end)

local lockBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
lockBtn:SetSize(HEADER_H - 4, HEADER_H - 4)
lockBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
ApplyFlat(lockBtn, THEME.bg, true)
local lockIcon = lockBtn:CreateTexture(nil, "OVERLAY")
lockIcon:SetSize(HEADER_H - 8, HEADER_H - 8)
lockIcon:SetPoint("CENTER")

local function RefreshLock()
    local db = DB()
    local locked = db and db.locked
    lockIcon:SetTexture(locked and "Interface\\Buttons\\LockButton-Locked-Up"
                                or  "Interface\\Buttons\\LockButton-Unlocked-Up")
    if locked then
        lockIcon:SetVertexColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    else
        lockIcon:SetVertexColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
    end
end
lockBtn:SetScript("OnClick", function() RDC.ToggleLock() end)
lockBtn:SetScript("OnEnter", function(self)
    local db = DB()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText((db and db.locked) and "Unlock HUD" or "Lock HUD")
    GameTooltip:Show()
end)
lockBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- A flat text button in the addon's own style: dim label, accent on hover, tooltip optional. Shared by the
-- header's report toggle and every button in the report panel so the two cannot drift apart visually.
local function MakeFlatButton(parent, w, h, label, fontSize, tooltip)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h)
    ApplyFlat(b, THEME.bg, true)
    local tx = b:CreateFontString(nil, "OVERLAY")
    ApplyFont(tx, fontSize)
    tx:SetPoint("CENTER")
    tx:SetText(label)
    tx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])

    -- Three distinct states, because a menu needs to show which entry is chosen while still reacting to the
    -- cursor: dim = idle, bright = hovered, bright + a coloured border = the current selection. An optional
    -- tint carries a per-button colour (the channel dropdown gives each entry its own chat colour); nil
    -- keeps the THEME dim/accent pair, so buttons that set neither tint nor MarkActive are unchanged.
    local tint
    local function restColor()
        if tint then
            if b.active then tx:SetTextColor(tint[1], tint[2], tint[3])
            else tx:SetTextColor(tint[1] * 0.55, tint[2] * 0.55, tint[3] * 0.55) end
        else
            local c = b.active and THEME.text or THEME.dim
            tx:SetTextColor(c[1], c[2], c[3])
        end
    end
    function b:MarkActive(on)
        self.active = on or nil
        -- Hover already takes the text to full colour, so a tinted button needs a second channel to say
        -- "chosen" or the two states are indistinguishable under the cursor. The border is that channel.
        if tint and self.SetBackdropBorderColor then
            local c = on and tint or THEME.border
            self:SetBackdropBorderColor(c[1], c[2], c[3], 1)
        end
        restColor()
    end
    function b:SetTint(c) tint = c; self:MarkActive(self.active) end
    function b:SetLabel(s) tx:SetText(s) end

    b:SetScript("OnEnter", function(self)
        local c = tint or THEME.accent
        tx:SetTextColor(c[1], c[2], c[3])
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        restColor()
        if tooltip then GameTooltip:Hide() end   -- only ours to hide; a tooltipless button leaves it alone
    end)
    return b
end

-- A flat checkbox: state is one always-shown inset fill, accent when on and red when off, so a row reads at
-- a glance without the eye having to hunt for a tick. The look is borrowed from WarlockQol's StyleCheckbox,
-- but built on a plain Button instead of UICheckButtonTemplate. That template's whole contribution here is
-- art we would immediately strip, and it is an XML template, which this file avoids on the same grounds
-- that got UIDropDownMenu rejected for the channel picker.
--
-- Like the original it deliberately wires NO OnClick of its own, because the caller's SetScript would
-- silently replace it and the state would then never flip. The caller owns the click and calls SetChecked.
local function MakeCheckbox(parent, size)
    local cb = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cb:SetSize(size, size)
    ApplyFlat(cb, THEME.field, true)

    local fill = cb:CreateTexture(nil, "OVERLAY")
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetPoint("TOPLEFT",     cb, "TOPLEFT",      3, -3)
    fill:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -3,  3)

    function cb:GetChecked() return self.checked and true or false end
    function cb:SetChecked(on)
        self.checked = on and true or nil
        local c = self.checked and THEME.accent or THEME.offRed
        fill:SetVertexColor(c[1], c[2], c[3])
    end
    cb:SetChecked(false)
    return cb
end

-- One toggle where the A/3/5 buttons used to sit. The header is width constrained: at MIN_W the fixed
-- furniture already leaves the title barely any room, so report modes past the original three earn their
-- place in the panel below rather than costing another 16px up here.
local reportBtn = MakeFlatButton(header, HEADER_H - 4, HEADER_H - 4, "R", 10, "Reports")
reportBtn:SetPoint("RIGHT", lockBtn, "LEFT", -2, 0)

-- The S pays for its own 16px rather than costing them. It is here, not in the report-hud, because it
-- toggles a persistent display rather than firing an action, and the width it costs is more than covered by
-- the total moving out of the title and into the stats-hud: "Karazhan (Total: 42)" renders ~104px against
-- ~44px for "Karazhan", so the header comes out ahead of where it was.
local statsBtn = MakeFlatButton(header, HEADER_H - 4, HEADER_H - 4, "S", 10, "Stats")
statsBtn:SetPoint("RIGHT", reportBtn, "LEFT", -2, 0)

-- Dot + count of addons in sync (us + live peers). Hidden when ungrouped, where the number is always 1.
local syncTag = CreateFrame("Frame", nil, header)
syncTag:SetSize(26, HEADER_H - 4)
syncTag:SetPoint("RIGHT", statsBtn, "LEFT", -5, 0)
syncTag:EnableMouse(true)
local syncDot = syncTag:CreateTexture(nil, "OVERLAY")
syncDot:SetSize(9, 9)
syncDot:SetPoint("LEFT", syncTag, "LEFT", 0, 0)
local syncTx = syncTag:CreateFontString(nil, "OVERLAY")
ApplyFont(syncTx, 10)
syncTx:SetPoint("LEFT", syncDot, "RIGHT", 2, 0)

-- Three states, not two. Grey alone could not tell a fault from a raid where nobody else runs the addon,
-- which is exactly the ambiguity that made a reported desync impossible to date or confirm: red now means
-- the comms watchdog has lost our own echo, grey means we are simply on our own.
local function UpdateSyncTag()
    if not (RDC.GetSyncCount and IsInGroup()) then syncTag:Hide(); return end
    local n = RDC.GetSyncCount()
    local h = RDC.GetCommsHealth and RDC.GetCommsHealth()
    local down = h and h.ok == false
    syncTag:Show()
    syncDot:SetTexture(down and "Interface\\COMMON\\Indicator-Red"
        or (n > 1 and "Interface\\COMMON\\Indicator-Green")
        or "Interface\\COMMON\\Indicator-Gray")
    syncTx:SetText(n)
    if down then
        syncTx:SetTextColor(0.95, 0.4, 0.4)
    elseif n > 1 then
        syncTx:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    else
        syncTx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
    end
end

-- Summarised by version rather than listing every peer: a full 25-man of addon users would otherwise be
-- 26 lines of names that all say the same thing. Only the peers NOT matching our version are named, since
-- that is the half you can act on, and even that list is capped.
local ODD_CAP = 8

syncTag:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    local ver = (RDC.GetVersion and RDC.GetVersion()) or "?"
    local peers = (RDC.GetSyncPeers and RDC.GetSyncPeers()) or {}
    GameTooltip:SetText("Addons in sync: " .. ((RDC.GetSyncCount and RDC.GetSyncCount()) or 1))

    -- Comms first: an outage is the explanation for every other line under it, so it does not belong
    -- buried below a peer list that the outage is the reason for.
    local h = RDC.GetCommsHealth and RDC.GetCommsHealth()
    if h and h.ok == false then
        GameTooltip:AddLine(("Comms down since %s, retrying."):format(RDC.Ago(h.brokenSince)), 0.95, 0.4, 0.4, true)
        GameTooltip:AddLine("Your own counts are still being kept.", 0.6, 0.6, 0.6, true)
    end

    if #peers == 0 then
        -- Never claim nobody is running it. We cannot know that, and saying it to someone who has just
        -- silently lost four peers actively hides the fault.
        local lost, lastHeard = 0, nil
        if RDC.GetLostPeers then lost, lastHeard = RDC.GetLostPeers() end
        if lost > 0 then
            GameTooltip:AddLine(("Lost contact with %d peer%s, last heard %s."):format(
                lost, lost == 1 and "" or "s", RDC.Ago(lastHeard)), 0.9, 0.7, 0.4, true)
        else
            GameTooltip:AddLine("No one else has been heard from.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
        return
    end

    local matching, odd = 1, {}   -- starts at 1 for ourselves
    for _, p in ipairs(peers) do
        if p.ver == ver then matching = matching + 1 else odd[#odd + 1] = p end
    end

    if #odd == 0 then
        GameTooltip:AddLine(("All on v%s"):format(ver), 0.5, 0.9, 0.5)
    else
        GameTooltip:AddLine(("%d on v%s (yours)"):format(matching, ver), 0.5, 0.9, 0.5)
        GameTooltip:AddLine(("%d on other versions:"):format(#odd), 0.8, 0.8, 0.8)
        for i = 1, math.min(#odd, ODD_CAP) do
            local p = odd[i]
            -- A peer heard via any op but not yet via H has no version recorded, so show "?" rather than
            -- claiming a version we were never told. The 30s heartbeat resolves it shortly.
            GameTooltip:AddLine(("   %s  |cffd9a066v%s|r"):format(
                p.name:match("^[^-]+") or p.name, p.ver or "?"), 0.8, 0.8, 0.8)
        end
        if #odd > ODD_CAP then
            GameTooltip:AddLine(("   + %d more"):format(#odd - ODD_CAP), 0.6, 0.6, 0.6)
        end
    end
    GameTooltip:Show()
end)
syncTag:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ── Stats HUD ─────────────────────────────────────────────────────────────────
-- A persistent strip under the death-hud, toggled by the header's S. Anchored to both bottom corners, so it
-- is the death-hud's width for free and stays that width through a resize; a child of it, so it travels and
-- hides with it the same way the report-hud does.
--
-- One deliberate difference from the report-hud: a child keeps its own shown flag, and here that is WANTED.
-- The report-hud needs an OnHide hook so closing the death-hud mid-panel does not bring it back uninvited;
-- the stats-hud is a display rather than a transient menu, so coming back exactly as you left it is right,
-- and the saved statsShown pref is what carries that across a reload.
local STATS_H      = PAD * 2 + HEADER_H
local LABEL_MIN_W  = 190   -- below this the labels are dropped and the values kept: see RefreshStats

local statsHUD = CreateFrame("Frame", "RaidDeathCount_StatsHUD", hud, "BackdropTemplate")
statsHUD:SetHeight(STATS_H)
statsHUD:SetPoint("TOPLEFT", hud, "BOTTOMLEFT", 0, -2)
statsHUD:SetPoint("TOPRIGHT", hud, "BOTTOMRIGHT", 0, -2)
ApplyFlat(statsHUD, THEME.bg, true)
-- Same reason the death-hud body enables the mouse with no drag handler: swallow clicks rather than letting
-- them fall through to the world behind. Dragging stays the death-hud title bar's job.
statsHUD:EnableMouse(true)
statsHUD:Hide()

local statsStrip = CreateFrame("Frame", nil, statsHUD, "BackdropTemplate")
statsStrip:SetHeight(HEADER_H)
statsStrip:SetPoint("TOPLEFT", statsHUD, "TOPLEFT", PAD, -PAD)
statsStrip:SetPoint("TOPRIGHT", statsHUD, "TOPRIGHT", -PAD, -PAD)
ApplyFlat(statsStrip, THEME.panel, true)

local deathsLabel = statsStrip:CreateFontString(nil, "OVERLAY")
ApplyFont(deathsLabel, 10)
deathsLabel:SetPoint("LEFT", statsStrip, "LEFT", 5, 0)
deathsLabel:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
deathsLabel:SetText("Deaths")

-- Anchored to the label's right edge, so blanking the label collapses the gap with it. That is why the
-- narrow-width path sets the text to "" rather than hiding the string: a hidden FontString keeps its
-- width, and the value would sit in the same place with nothing in front of it.
local deathsValue = statsStrip:CreateFontString(nil, "OVERLAY")
ApplyFont(deathsValue, 11)
deathsValue:SetPoint("LEFT", deathsLabel, "RIGHT", 4, 0)
deathsValue:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])

-- Centred between the two inputs it is measured against, so the strip reads left to right as deaths, time,
-- then the figure derived from them. DPM in the middle would sit the result between its own operands.
local timerValue = statsStrip:CreateFontString(nil, "OVERLAY")
ApplyFont(timerValue, 11)
timerValue:SetPoint("CENTER", statsStrip, "CENTER", 0, 0)
timerValue:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])

-- Mirror of the deaths cell: the VALUE holds the anchor and the label hangs off its left, so blanking the
-- label at narrow widths collapses inwards and leaves the number against the strip edge where it belongs.
local dpmValue = statsStrip:CreateFontString(nil, "OVERLAY")
ApplyFont(dpmValue, 11)
dpmValue:SetPoint("RIGHT", statsStrip, "RIGHT", -5, 0)
dpmValue:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])

local dpmLabel = statsStrip:CreateFontString(nil, "OVERLAY")
ApplyFont(dpmLabel, 10)
dpmLabel:SetPoint("RIGHT", dpmValue, "LEFT", -4, 0)
dpmLabel:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
dpmLabel:SetText("DPM")

-- Both formatters live in the core, shared with "/rdc report stats" so the chat line and this strip cannot
-- disagree over rounding. Aliased to locals here because they are read on a once-a-second path.
local FormatClock, FormatDPM = RDC.FormatClock, RDC.FormatDPM

-- Full repaint, driven by events (a death, a resize, a merge) rather than by the clock. RefreshHUD already
-- has the summed total, so it passes it in: recomputing it here would rebuild and re-sort a snapshot the
-- caller is holding. The clock is the only value that moves with no event behind it, and it is updated by
-- the tick below instead, which is what keeps this off the once-a-second path.
-- Cached for the tick below, which needs the total to recompute DPM and must not rebuild and re-sort a
-- snapshot to get it. Every path that changes the total goes through RefreshHUD, so this cannot go stale
-- while the strip is up, and showing the strip calls RefreshStats before the tick can read it.
local lastDeathSum = 0

local function RefreshStats(deathSum)
    if not statsHUD:IsShown() then return end
    -- Measured on the death-hud, not the strip: they are equal by construction and the strip's anchors
    -- have not resolved yet while a resize is still in flight.
    local labels = hud:GetWidth() >= LABEL_MIN_W
    lastDeathSum = deathSum or RDC.TotalDeaths()
    deathsLabel:SetText(labels and "Deaths" or "")
    dpmLabel:SetText(labels and "DPM" or "")
    deathsValue:SetText(lastDeathSum)
    timerValue:SetText(FormatClock(RDC.GetCombatSeconds()))
    dpmValue:SetText(FormatDPM(lastDeathSum, RDC.GetCombatSeconds()))
end

-- WoW does not fire OnUpdate on a hidden frame, so hanging the driver on the stats-hud itself makes "only
-- runs while shown" fall out of the frame hierarchy: hiding the strip or the death-hud above it stops the
-- tick with no start/stop bookkeeping to get wrong.
--
-- DPM gets a slower beat than the clock on purpose. Its rate of change is -60*D/t^2, so early in a pull the
-- second decimal moves several units a second, which is noise on a figure nobody reads mid-fight. Out of
-- combat no beat is needed at all: both inputs are frozen, so one tick after the fight ends the number is
-- exact and stays that way for as long as it is being looked at, which is when it is actually read.
local DPM_INTERVAL = 5
local statsAcc, dpmAcc = 0, 0
statsHUD:SetScript("OnUpdate", function(_, elapsed)
    dpmAcc = dpmAcc + elapsed
    if dpmAcc >= DPM_INTERVAL then
        dpmAcc = 0
        dpmValue:SetText(FormatDPM(lastDeathSum, RDC.GetCombatSeconds()))
    end
    statsAcc = statsAcc + elapsed
    if statsAcc < 1 then return end
    statsAcc = 0
    timerValue:SetText(FormatClock(RDC.GetCombatSeconds()))
end)

-- Account-wide alongside the other UI prefs, per the per-character/account split: which panels this client
-- has open is a preference, not data about a raid. Defaults off, so an upgrade does not grow new furniture
-- under everyone's HUD unasked.
function RDC.SetStatsShown(show)
    show = show and true or false
    local db = DB(); if db then db.statsShown = show end
    statsHUD:SetShown(show)
    statsBtn:MarkActive(show or nil)
    if show then RefreshStats() end
end

function RDC.IsStatsShown() return statsHUD:IsShown() end

function RDC.ToggleStats() RDC.SetStatsShown(not statsHUD:IsShown()) end

statsBtn:SetScript("OnClick", function() RDC.ToggleStats() end)

-- ── Report panel ──────────────────────────────────────────────────────────────
-- Every reporting action in one place, so the header does not have to grow a button per mode. A child of
-- the HUD, which buys travelling with it and hiding with it for nothing, and deliberately transient: it
-- keeps no saved position, so unlike the HUD there is no way for it to end up stranded off screen.
-- No button width here on purpose: the report-hud matches the death-hud's width, so the buttons are what
-- flexes to fill it. Only the height is fixed, since the row count is.
local PANEL_BTN_H, PANEL_GAP, PANEL_COLS = 18, 3, 3

-- No tooltips: the labels say what they do, unlike the header's lone R.
local REPORTS = {
    { "All",      "all"   },
    { "Top 3",    "top3"  },
    { "Top 5",    "top5"  },
    { "Stats",    "stats" },
    { "Fewest",   "least" },
    { "By Class", "class" },
}

local panelRows = math.ceil(#REPORTS / PANEL_COLS)
local panel = CreateFrame("Frame", "RaidDeathCount_ReportPanel", hud, "BackdropTemplate")
-- Height only. The width comes from anchoring both sides to the death-hud in PositionPanel, which is what
-- keeps all three huds the same width through a resize.
panel:SetHeight(PAD * 2 + HEADER_H + PANEL_GAP + panelRows * PANEL_BTN_H + (panelRows - 1) * PANEL_GAP)
panel:SetFrameStrata("DIALOG")   -- opens outside the HUD bounds, so it must not sit under other windows
ApplyFlat(panel, THEME.bg, true)
panel:Hide()

local panelHeader = CreateFrame("Frame", nil, panel, "BackdropTemplate")
panelHeader:SetHeight(HEADER_H)
panelHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
panelHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -PAD)
ApplyFlat(panelHeader, THEME.panel, true)

local panelTitle = panelHeader:CreateFontString(nil, "OVERLAY")
ApplyFont(panelTitle, 11)
panelTitle:SetPoint("LEFT", panelHeader, "LEFT", 5, 0)
panelTitle:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
panelTitle:SetText("Reports")

-- ── Report channel dropdown ───────────────────────────────────────────────────
-- Lives in the panel's title bar, not as a fourth row of buttons, so choosing a channel costs the panel no
-- extra height. That rules out UIDropDownMenu on size alone before its taint and styling come into it: it
-- is ~32px tall with a ~115px minimum width and cannot fit an 18px header at all. This is the same widget
-- hand-rolled from the flat button already in the file, at a size that fits.
local CHAN_BTN_W, CHAN_BTN_H = 58, HEADER_H - 4

-- Blizzard's own default chat colours, so an entry reads as the chat it targets rather than as an arbitrary
-- palette the user has to learn. Hardcoded rather than read from ChatTypeInfo: that would track a user's
-- recoloured chat, but it also lets a customised near-black guild colour render the entry unreadable here.
local CHAN_COLOR = {
    RAID  = { 1.00, 0.50, 0.00 },   -- orange
    PARTY = { 0.67, 0.67, 1.00 },   -- blue
    GUILD = { 0.25, 1.00, 0.25 },   -- green
}

local chanBtn = MakeFlatButton(panelHeader, CHAN_BTN_W, CHAN_BTN_H, "Raid", 10, "Report channel")
chanBtn:SetPoint("RIGHT", panelHeader, "RIGHT", -3, 0)
chanBtn:MarkActive(true)   -- the collapsed button is the current channel, so it always shows at full colour

-- A child of the panel, so it travels, hides and gets destroyed with it for free. Frame level rather than
-- strata to sit above the report buttons: they are children of the same panel, so a shared strata already
-- orders correctly and a higher strata would only risk outranking things it has no business covering.
local chanMenu = CreateFrame("Frame", "RaidDeathCount_ChannelMenu", panel, "BackdropTemplate")
chanMenu:SetSize(CHAN_BTN_W + 4, 4 + #RDC.CHANNEL_ORDER * CHAN_BTN_H)
chanMenu:SetPoint("TOPRIGHT", chanBtn, "BOTTOMRIGHT", 0, -2)
chanMenu:SetFrameLevel(panel:GetFrameLevel() + 10)
ApplyFlat(chanMenu, THEME.panel, true)
chanMenu:Hide()

local chanItems = {}
for i, key in ipairs(RDC.CHANNEL_ORDER) do
    local item = MakeFlatButton(chanMenu, CHAN_BTN_W, CHAN_BTN_H, RDC.REPORT_CHANNELS[key], 10)
    item:SetPoint("TOPLEFT", chanMenu, "TOPLEFT", 2, -2 - (i - 1) * CHAN_BTN_H)
    item:SetTint(CHAN_COLOR[key])
    item:SetScript("OnClick", function()
        chanMenu:Hide()
        RDC.SetReportChannel(key)   -- which calls RefreshReportChannel below to repaint this menu
    end)
    chanItems[key] = item
end

-- Named on RDC because the core writes the setting (slash command) and has to be able to repaint the UI.
function RDC.RefreshReportChannel()
    local cur = RDC.GetReportChannel()
    chanBtn:SetLabel(RDC.REPORT_CHANNELS[cur])
    chanBtn:SetTint(CHAN_COLOR[cur])
    for key, item in pairs(chanItems) do item:MarkActive(key == cur) end
end

chanBtn:SetScript("OnClick", function()
    if chanMenu:IsShown() then chanMenu:Hide() else chanMenu:Show() end
end)

local panelButtons = {}
for i, r in ipairs(REPORTS) do
    local label, mode = r[1], r[2]
    -- Width is a placeholder: LayoutPanelButtons owns it, and cannot run yet because the panel has no
    -- width of its own until PositionPanel anchors it to the death-hud.
    local b = MakeFlatButton(panel, 1, PANEL_BTN_H, label, 10)
    b:SetScript("OnClick", function()
        panel:Hide()
        RDC.Report(mode)
    end)
    panelButtons[i] = b
end

-- The buttons divide whatever width the death-hud currently is, rather than the panel sizing itself to fit
-- them. Driven from the panel's OWN OnSizeChanged, which needs no coordination with the death-hud's resize
-- path: the panel is anchored to both of its sides, so dragging the grip resizes the panel, and that fires
-- this. Widths are fractional and left unrounded, so six buttons cannot accumulate a visible drift against
-- the right edge the way six truncated integers would.
local function LayoutPanelButtons()
    local inner = panel:GetWidth() - PAD * 2
    if inner <= 0 then return end   -- anchors not resolved yet; OnSizeChanged calls back once they are
    local w = (inner - (PANEL_COLS - 1) * PANEL_GAP) / PANEL_COLS
    for i, b in ipairs(panelButtons) do
        local col, row = (i - 1) % PANEL_COLS, math.floor((i - 1) / PANEL_COLS)
        b:SetWidth(w)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", panelHeader, "BOTTOMLEFT",
                   col * (w + PANEL_GAP), -PANEL_GAP - row * (PANEL_BTN_H + PANEL_GAP))
    end
end
panel:SetScript("OnSizeChanged", LayoutPanelButtons)

-- Sits above the HUD, dropping below only when there is no room above, so a HUD parked at the top of the
-- screen does not open the panel off it. Recomputed on every open rather than cached, since the HUD moves
-- and resizes freely between one open and the next.
-- Both horizontal anchors, not one: that is what makes the panel the death-hud's width instead of its own,
-- and it has to be re-established on every open because ClearAllPoints drops the pair.
local function PositionPanel()
    panel:ClearAllPoints()
    local top, screenH = hud:GetTop(), UIParent:GetHeight()
    if top and screenH and top + panel:GetHeight() + 2 > screenH then
        -- Clears the stats-hud when that is out, or the report-hud drops straight on top of it. Read at
        -- open time like everything else here, since the strip can be toggled between one open and the next.
        local below = statsHUD:IsShown() and statsHUD or hud
        panel:SetPoint("TOPLEFT",  below, "BOTTOMLEFT",  0, -2)
        panel:SetPoint("TOPRIGHT", below, "BOTTOMRIGHT", 0, -2)
    else
        panel:SetPoint("BOTTOMLEFT",  hud, "TOPLEFT",  0, 2)
        panel:SetPoint("BOTTOMRIGHT", hud, "TOPRIGHT", 0, 2)
    end
    LayoutPanelButtons()   -- harmless if the anchors have not resolved: OnSizeChanged calls back when they do
end

reportBtn:SetScript("OnClick", function()
    if panel:IsShown() then panel:Hide() return end
    PositionPanel()
    panel:Show()
end)

-- Dragging the HUD would carry the panel along on an anchor chosen for where the HUD used to be, which is
-- how it would end up off screen despite PositionPanel. Cheaper to close it than to track the drag.
header:HookScript("OnDragStart", function() panel:Hide() end)

-- Hiding the HUD hides the panel with it as a child, but a child keeps its own shown flag, so without this
-- closing the HUD mid-panel and reopening it would bring the panel back uninvited.
hud:HookScript("OnHide", function() panel:Hide() end)

-- Same trap as the panel/HUD pair above: the menu is a child so it vanishes with the panel, but it keeps
-- its own shown flag, and without this the next open would come back with the menu still hanging open.
-- This is also what makes Escape close the menu, since Escape hides the panel.
panel:HookScript("OnHide", function() chanMenu:Hide() end)

-- Escape closes it like any other transient window. This is why the frame is globally named.
if UISpecialFrames then table.insert(UISpecialFrames, "RaidDeathCount_ReportPanel") end

-- ── Resize grip (bottom-right) ────────────────────────────────────────────────
local grip = CreateFrame("Button", nil, hud)
grip:SetSize(14, 14)
grip:SetPoint("BOTTOMRIGHT", hud, "BOTTOMRIGHT", -2, 2)
local gtx = grip:CreateTexture(nil, "OVERLAY")
gtx:SetAllPoints()
gtx:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetScript("OnMouseDown", function()
    local db = DB()
    if db and db.locked then return end
    hud:StartSizing("BOTTOMRIGHT")
end)
grip:SetScript("OnMouseUp", function() hud:StopMovingOrSizing(); SavePlacement(); RDC.RefreshHUD() end)

-- Bar widths and the visible row count both derive from the body size, so reflow live during the drag
-- rather than letting the rows snap into place only on release.
hud:SetScript("OnSizeChanged", function() if RDC.RefreshHUD then RDC.RefreshHUD() end end)

-- ── Body / rows ───────────────────────────────────────────────────────────────
local body = CreateFrame("Frame", nil, hud)
body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -PAD)
body:SetPoint("BOTTOMRIGHT", hud, "BOTTOMRIGHT", -PAD, PAD)

local emptyText = body:CreateFontString(nil, "OVERLAY")
ApplyFont(emptyText, 11)
emptyText:SetPoint("TOP", body, "TOP", 0, -6)
emptyText:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
emptyText:SetText("No deaths recorded")

-- ── Scrolling ─────────────────────────────────────────────────────────────────
-- The row pool renders a WINDOW into the snapshot: slot n shows snap[n + scrollOffset]. Only the offset
-- moves, so the pool stays bounded by what fits the body rather than by raid size. Offset is view state
-- and deliberately not persisted.
local scrollOffset = 0

local scrollTrack = CreateFrame("Frame", nil, body, "BackdropTemplate")
scrollTrack:SetWidth(SCROLL_W)
scrollTrack:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
scrollTrack:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
ApplyFlat(scrollTrack, THEME.panel, false)
scrollTrack:Hide()

local scrollThumb = CreateFrame("Frame", nil, scrollTrack, "BackdropTemplate")
scrollThumb:SetWidth(SCROLL_W)
scrollThumb:SetHeight(THUMB_MIN)
scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, 0)
ApplyFlat(scrollThumb, THEME.dim, false)
scrollThumb:EnableMouse(true)

local function ThumbColor(c)
    if scrollThumb.SetBackdropColor then scrollThumb:SetBackdropColor(c[1], c[2], c[3], c[4] or 1) end
end

local function VisibleRows()
    return math.max(0, math.floor(body:GetHeight() / ROW_H))
end

local function MaxScrollOffset(total)
    return math.max(0, total - VisibleRows())
end

-- Sizes and places the thumb for the current offset. Returns whether the bar is showing, so the caller
-- can inset the rows and keep the count text clear of it.
local function UpdateScrollBar(total, visible)
    if visible <= 0 or total <= visible then
        scrollTrack:Hide()
        return false
    end
    scrollTrack:Show()
    local trackH = scrollTrack:GetHeight()
    local thumbH = math.min(trackH, math.max(THUMB_MIN, trackH * (visible / total)))
    scrollThumb:SetHeight(thumbH)
    local maxOff = total - visible
    local progress = (maxOff > 0) and (scrollOffset / maxOff) or 0
    scrollThumb:ClearAllPoints()
    scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, -progress * (trackH - thumbH))
    return true
end

local function ScrollTo(offset)
    local want = math.max(0, math.min(MaxScrollOffset(#RDC.GetSnapshot()), offset))
    if want == scrollOffset then return end
    scrollOffset = want
    RDC.RefreshHUD()
end

hud:EnableMouseWheel(true)
hud:SetScript("OnMouseWheel", function(_, delta) ScrollTo(scrollOffset - delta) end)

-- Cursor-to-thumb-top distance captured on mouse down, so grabbing mid-thumb does not snap it.
local dragGrab = nil

local function ThumbDragUpdate(self)
    -- OnMouseUp only arrives if the release happens over the thumb, so poll the button instead: a drag
    -- that ends off-frame has to let go too.
    if not IsMouseButtonDown("LeftButton") then
        dragGrab = nil
        self:SetScript("OnUpdate", nil)
        if not self:IsMouseOver() then ThumbColor(THEME.dim) end
        return
    end
    local span = scrollTrack:GetHeight() - self:GetHeight()
    if span <= 0 then return end
    local _, cursorY = GetCursorPosition()
    cursorY = cursorY / scrollTrack:GetEffectiveScale()
    local progress = math.max(0, math.min(1, ((scrollTrack:GetTop() - cursorY) - dragGrab) / span))
    ScrollTo(math.floor(progress * MaxScrollOffset(#RDC.GetSnapshot()) + 0.5))
end

scrollThumb:SetScript("OnMouseDown", function(self)
    local _, cursorY = GetCursorPosition()
    dragGrab = self:GetTop() - (cursorY / self:GetEffectiveScale())
    ThumbColor(THEME.accent)
    self:SetScript("OnUpdate", ThumbDragUpdate)
end)
scrollThumb:SetScript("OnEnter", function() ThumbColor(THEME.accent) end)
scrollThumb:SetScript("OnLeave", function() if not dragGrab then ThumbColor(THEME.dim) end end)

-- ── Rows ──────────────────────────────────────────────────────────────────────
local ROW_POOL = 40
local rows = {}
local BAR_ALPHA, BAR_ALPHA_HOVER = 0.55, 0.85

local function RowBarAlpha(row) return row:IsMouseOver() and BAR_ALPHA_HOVER or BAR_ALPHA end

local function MakeRow(i)
    local row = CreateFrame("Frame", nil, body)
    row:SetHeight(ROW_H - 1)

    -- Ctrl-click reports the row's player. Ctrl rather than a plain click because a bare left click on a
    -- dense list posts to raid chat on a misclick, and mouse-up rather than down so it can be aborted by
    -- dragging off. Enabling mouse does NOT enable the wheel, so the scroll handler on hud still gets it.
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", function(self, button)
        -- Read at click time, never captured: rows are recycled by slot, so a row that held Bob before
        -- you scrolled holds someone else now.
        if button == "LeftButton" and IsControlKeyDown() and self.entry then
            RDC.ReportPlayer(self.entry)
        end
    end)
    row:SetScript("OnEnter", function(self)
        self.bar:SetVertexColor(self.cr or 0.4, self.cg or 0.4, self.cb or 0.4, BAR_ALPHA_HOVER)
    end)
    row:SetScript("OnLeave", function(self)
        self.bar:SetVertexColor(self.cr or 0.4, self.cg or 0.4, self.cb or 0.4, BAR_ALPHA)
    end)

    row.bar = row:CreateTexture(nil, "BACKGROUND")
    row.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)

    row.rank = row:CreateFontString(nil, "OVERLAY")
    ApplyFont(row.rank, 10)
    row.rank:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.rank:SetWidth(16)
    row.rank:SetJustifyH("LEFT")
    row.rank:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])

    row.icon = row:CreateTexture(nil, "OVERLAY")
    row.icon:SetSize(ROW_H - 4, ROW_H - 4)
    row.icon:SetPoint("LEFT", row.rank, "RIGHT", 1, 0)

    row.name = row:CreateFontString(nil, "OVERLAY")
    ApplyFont(row.name, 11)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 3, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.count = row:CreateFontString(nil, "OVERLAY")
    ApplyFont(row.count, 11)
    row.count:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.count:SetJustifyH("RIGHT")
    row.count:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])

    -- Second anchor on name, set after count exists, so it stretches to fill the gap and truncates
    -- instead of overrunning the count.
    row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
    return row
end

-- Keyed by instance mapID, not by name: the mapID is the same client-side constant the RaidID is built
-- from, so this needs no locale handling and cannot be broken by a "Coilfang: " style prefix changing.
local RAID_ABBR = {
    [532] = "Karazhan",
    [565] = "Gruul",
    [544] = "Maggy",
    [548] = "SSC",
    [550] = "TK",
    [534] = "Hyjal",
    [564] = "BT",
    [568] = "ZA",
    [580] = "Sunwell",
}

-- A known raid becomes its abbreviation; anything else falls back to trimming the cluster prefix, so
-- "Coilfang: Serpentshrine Cavern" becomes "Serpentshrine Cavern" and unprefixed names pass through.
local function ShortInstance(name, mapID)
    if mapID and RAID_ABBR[mapID] then return RAID_ABBR[mapID] end
    if not name then return nil end
    local tail = name:match("^.-:%s*(.+)$")
    return tail or name
end

-- ── Refresh ───────────────────────────────────────────────────────────────────
function RDC.RefreshHUD()
    if not hud:IsShown() then return end
    local snap = RDC.GetSnapshot()
    local total = #snap
    local deathSum = RDC.TotalDeaths(snap)
    -- The divisor stays the overall leader, not the top VISIBLE row, or bar widths would rescale as you
    -- scroll and stop being comparable between screenfuls.
    local top = (snap[1] and snap[1].deaths) or 1
    local maxRows = VisibleRows()

    -- Clamp before rendering: a shrinking list, or a resize that reveals more rows, must not leave the
    -- view stranded past the end.
    if scrollOffset > math.max(0, total - maxRows) then scrollOffset = math.max(0, total - maxRows) end

    emptyText:SetShown(total == 0)

    local scrolling = UpdateScrollBar(total, maxRows)
    local rowInset = scrolling and -(SCROLL_W + 2) or 0
    local rowW = math.max(1, body:GetWidth() + rowInset)

    for slot = 1, ROW_POOL do
        local index = slot + scrollOffset
        local e = (slot <= maxRows) and snap[index] or nil
        if e then
            local row = rows[slot]
            if not row then row = MakeRow(slot); rows[slot] = row end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(slot - 1) * ROW_H)
            row:SetPoint("RIGHT", body, "RIGHT", rowInset, 0)

            local c = RAID_CLASS_COLORS and e.class and RAID_CLASS_COLORS[e.class]
            local r, g, b = 0.4, 0.4, 0.4
            if c then r, g, b = c.r, c.g, c.b end

            -- What ctrl-click reports, refreshed every pass because the pool recycles slots as you scroll.
            row.entry = e
            row.cr, row.cg, row.cb = r, g, b

            -- Proportional to the leader's count, floored at a sliver so a 1-death bar is still visible.
            local frac = math.max(0.12, e.deaths / top)
            row.bar:SetWidth(rowW * frac)
            -- Honours the hover state: a refresh mid-hover (a death lands, the frame resizes) must not
            -- flick the highlighted row back to its resting colour under the cursor.
            row.bar:SetVertexColor(r, g, b, RowBarAlpha(row))

            if e.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.class] then
                row.icon:SetTexture(CLASS_TEX)
                row.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[e.class]))
                row.icon:Show()
            else
                row.icon:Hide()
            end

            row.rank:SetText(index)   -- absolute placing in the snapshot, not the row slot
            local shortName = e.name:match("^[^-]+") or e.name
            row.name:SetText(shortName)
            row.name:SetTextColor(r, g, b)
            row.count:SetText(e.deaths)
            row:Show()
        elseif rows[slot] then
            rows[slot]:Hide()
        end
    end

    -- The total lives in the stats-hud now, not here. Duplicating it cost the header ~60px it does not have
    -- at MIN_W, where the title already collides with the buttons.
    local inst = ShortInstance(RDC.GetInstanceName(), RDC.GetMapID())
    title:SetText(inst or "Raid Death Count")

    RefreshStats(deathSum)
    UpdateSyncTag()
end

-- ── Show / lock API ───────────────────────────────────────────────────────────
function RDC.SetHUDShown(show)
    local db = DB(); if db then db.shown = show and true or false end
    if show then hud:Show(); RDC.RefreshHUD() else hud:Hide() end
end

function RDC.IsHUDShown() return hud:IsShown() end

function RDC.ToggleHUD() RDC.SetHUDShown(not hud:IsShown()) end

function RDC.ToggleLock()
    local db = DB(); if not db then return end
    db.locked = not db.locked
    RefreshLock()
    print("|cff88bbffRaidDeathCount|r HUD " .. (db.locked and "locked." or "unlocked."))
end

-- ── Init (restore geometry + state at login) ──────────────────────────────────
function RDC.InitHUD()
    local db = DB(); if not db then return end
    if db.width and db.height then hud:SetSize(db.width, db.height) end
    if db.point then
        hud:ClearAllPoints()
        hud:SetPoint(db.point, UIParent, db.relPoint, db.x or 0, db.y or 0)
    end
    RefreshLock()
    RDC.RefreshReportChannel()   -- the saved channel exists only now, so the dropdown is built showing "Raid"
    RDC.SetStatsShown(db.statsShown)   -- nil on first run reads as off, which is the intended default
    if db.shown == nil then db.shown = true end   -- visible by default, Details-style
    if db.shown then hud:Show() else hud:Hide() end
    RDC.RefreshHUD()
end

-- ── Options frame ─────────────────────────────────────────────────────────────
-- Top-level on UIParent, NOT a child of the HUD the way the report panel is. The panel wants to travel and
-- hide with the HUD; this one is opened from the minimap button, and the case where it is most wanted is
-- exactly when the HUD is closed.
--
-- Saves its SIZE but not its position, which is a deliberate split rather than an oversight. Size is a
-- lasting preference the user sets once; position is where the window happened to be dragged, and a
-- remembered one can be stranded off screen the way the report panel's never can. It opens centred every
-- time, at whatever size was last chosen. Also rejected: anchoring it to the minimap button, which reads as
-- the natural home for a right-click menu and then hangs off the screen edge, the button orbiting a minimap
-- that sits in a corner.
--
-- The size is stored PER CHARACTER, unlike the HUD's account-wide geometry, because that is what was asked
-- for; it rides in RaidDeathCountCharDB.options alongside the master switch, which is per character for its
-- own reasons (see the core).
-- Default and MINIMUM are the same, so the window only ever grows, and that is what keeps the title bar
-- safe to crowd: brand left, toggle group centred, close button right, none of them able to collide the way
-- the HUD's header does at ITS minimum. The binding gap is the LEFT one, between the end of the brand and
-- the start of the centred group, and at 640 it is comfortable but no longer generous. Two things eat it: a
-- longer brand string, and a third toggle, since the group grows from its centre outwards in both
-- directions. Check that gap before adding either, and never let the minimum drop below the default.
local OPT_DEF_W, OPT_DEF_H = 640, 480
local OPT_MIN_W, OPT_MIN_H = 640, 480
local OPT_MAX_W, OPT_MAX_H = 940, 780   -- WarlockQol's grow limit

-- Title-bar metrics lifted from WarlockQol so the two addons' windows read as a pair: a 30px strip, an 18px
-- logo, the brand at 14pt and a 22px close button, with secondary labels at its caption size of 11.
local OPT_TITLE_H  = 30
local OPT_LOGO     = 18
local OPT_BRAND_FS = 14
local OPT_LABEL_FS = 11
local OPT_CLOSE    = 22
local OPT_BOX      = 20   -- WarlockQol's title-bar checkbox size (its in-page ones are 22)
local OPT_LABEL_GAP = 6   -- label to its own box
local OPT_GROUP_GAP = 28  -- one toggle to the next

-- Per character, so it cannot use DB() above, which is the account-wide UI table. Resolved lazily rather
-- than captured: the saved variables do not exist when this file loads.
local function OptDB()
    if not RaidDeathCountCharDB then return nil end
    RaidDeathCountCharDB.options = RaidDeathCountCharDB.options or {}
    return RaidDeathCountCharDB.options
end

local options = CreateFrame("Frame", "RaidDeathCount_Options", UIParent, "BackdropTemplate")
options:SetSize(OPT_DEF_W, OPT_DEF_H)
options:SetPoint("CENTER")
options:SetFrameStrata("DIALOG")
options:SetClampedToScreen(true)
options:SetMovable(true)
options:EnableMouse(true)   -- swallow clicks rather than passing them through to the world behind
ApplyFlat(options, THEME.bg, true)
options:Hide()

-- SetResizeBounds is the modern call; the older pair is kept for the same reason the HUD keeps it.
options:SetResizable(true)
if options.SetResizeBounds then
    options:SetResizeBounds(OPT_MIN_W, OPT_MIN_H, OPT_MAX_W, OPT_MAX_H)
else
    if options.SetMinResize then options:SetMinResize(OPT_MIN_W, OPT_MIN_H) end
    if options.SetMaxResize then options:SetMaxResize(OPT_MAX_W, OPT_MAX_H) end
end

local optHeader = CreateFrame("Frame", nil, options, "BackdropTemplate")
optHeader:SetHeight(OPT_TITLE_H)
optHeader:SetPoint("TOPLEFT",  options, "TOPLEFT",   PAD, -PAD)
optHeader:SetPoint("TOPRIGHT", options, "TOPRIGHT", -PAD, -PAD)
ApplyFlat(optHeader, THEME.panel, true)

-- Dragged by the title bar alone, like the HUD. Unlike the HUD it ignores the lock (that setting is about
-- not disturbing a HUD placed for a fight) and saves nothing on drop.
optHeader:EnableMouse(true)
optHeader:RegisterForDrag("LeftButton")
optHeader:SetScript("OnDragStart", function() options:StartMoving() end)
optHeader:SetScript("OnDragStop",  function() options:StopMovingOrSizing() end)

-- The same skull the minimap button wears, on the same TexCoord crop that trims the icon's baked-in border.
-- Deliberately the same art rather than a second icon: it is what the user right-clicked to get here.
local optLogo = optHeader:CreateTexture(nil, "OVERLAY")
optLogo:SetSize(OPT_LOGO, OPT_LOGO)
optLogo:SetPoint("LEFT", optHeader, "LEFT", 8, 0)
optLogo:SetTexture("Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")
optLogo:SetTexCoord(0.08, 0.92, 0.08, 0.92)

-- Accent blue for the name, with the version in grey via an inline colour code, which is why the base
-- colour is set here and not baked into the string: SetTextColor only reaches the uncoded run.
local optTitle = optHeader:CreateFontString(nil, "OVERLAY")
ApplyFont(optTitle, OPT_BRAND_FS)
optTitle:SetPoint("LEFT", optLogo, "RIGHT", 6, 0)
optTitle:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
optTitle:SetText("Raid Death Count")   -- version appended on open, see RefreshOptions

-- WarlockQol's close button rather than this file's MakeFlatButton: at 22px on a 30px strip it is the piece
-- that most carries the "same window" impression, and its accent X plus accent-border hover is the thing
-- being matched. MakeFlatButton is built for a dim 14px header and looks undersized here.
local optClose = CreateFrame("Button", nil, optHeader, "BackdropTemplate")
optClose:SetSize(OPT_CLOSE, OPT_CLOSE)
optClose:SetPoint("RIGHT", optHeader, "RIGHT", -4, 0)
ApplyFlat(optClose, THEME.field, true)

local optCloseX = optClose:CreateFontString(nil, "OVERLAY")
ApplyFont(optCloseX, OPT_BRAND_FS)
optCloseX:SetPoint("CENTER")
optCloseX:SetText("X")
optCloseX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])

optClose:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    optCloseX:SetTextColor(0.78, 0.88, 1.0)
end)
optClose:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
    optCloseX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
end)
optClose:SetScript("OnClick", function() options:Hide() end)

-- Same grip as the HUD's, minus the lock check: the lock exists to stop a HUD placed for a fight being
-- nudged mid-pull, which is not a hazard a settings window has.
local optGrip = CreateFrame("Button", nil, options)
optGrip:SetSize(14, 14)
optGrip:SetPoint("BOTTOMRIGHT", options, "BOTTOMRIGHT", -2, 2)
local optGripTx = optGrip:CreateTexture(nil, "OVERLAY")
optGripTx:SetAllPoints()
optGripTx:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
optGrip:SetScript("OnMouseDown", function() options:StartSizing("BOTTOMRIGHT") end)
optGrip:SetScript("OnMouseUp", function()
    options:StopMovingOrSizing()
    local db = OptDB()
    if db then db.width, db.height = options:GetWidth(), options:GetHeight() end
end)

-- ── Title-bar toggles ─────────────────────────────────────────────────────────
-- The global switches live in the title bar, centred as one group, the way WarlockQol carries its master
-- and minimap pair. They belong there rather than in the body because they are the two that apply to the
-- whole addon and are wanted from anywhere; the body below is for settings that will scope to a feature.
--
-- The frame is NOT sized to its toggles, which an earlier version was: it is user-resizable now, so growing
-- it per setting would fight the height the user chose and saved. The empty body is deliberate room.
local optToggles = {}

-- Re-laid out after every add rather than positioned at creation, because each new toggle moves the centre
-- of the group and every earlier one has to shift left to keep it centred. The box hangs off its own
-- label's right, so placing the label places the pair.
local function LayoutToggles()
    local total = 0
    for i, t in ipairs(optToggles) do
        total = total + t.label:GetStringWidth() + OPT_LABEL_GAP + OPT_BOX
        if i > 1 then total = total + OPT_GROUP_GAP end
    end
    local x = -total / 2
    for i, t in ipairs(optToggles) do
        t.label:ClearAllPoints()
        t.label:SetPoint("LEFT", optHeader, "CENTER", x, 0)
        x = x + t.label:GetStringWidth() + OPT_LABEL_GAP + OPT_BOX
        if i < #optToggles then x = x + OPT_GROUP_GAP end
    end
end

-- get and set are passed as functions rather than values because the state lives elsewhere and can change
-- behind a closed frame (a slash command, or the other toggle), and because the minimap accessors do not
-- exist yet at this point in the file.
local function AddToggle(label, tooltip, get, set)
    local tx = optHeader:CreateFontString(nil, "OVERLAY")
    ApplyFont(tx, OPT_LABEL_FS)
    tx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
    tx:SetText(label)   -- set before LayoutToggles, which measures the rendered string

    local cb = MakeCheckbox(optHeader, OPT_BOX)
    cb:SetPoint("LEFT", tx, "RIGHT", OPT_LABEL_GAP, 0)

    -- The click lives here because MakeCheckbox deliberately wires none. Read the state back from get()
    -- afterwards rather than assuming the flip took: a setter is free to refuse, and a checkbox showing a
    -- state the addon is not in is worse than one that appears not to have responded.
    cb:SetScript("OnClick", function(self)
        set(not self:GetChecked())
        self:SetChecked(get())
    end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")   -- downwards: the bar is at the top of the window
        GameTooltip:SetText(label, THEME.text[1], THEME.text[2], THEME.text[3])
        if tooltip then GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true) end
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    optToggles[#optToggles + 1] = { label = tx, cb = cb, get = get }
    LayoutToggles()
    return cb
end

-- Read on every open rather than tracked as the frame's own state: every one of these can be changed while
-- the frame is shut, by a slash command or by the HUD, and a stale checkbox is a lie about the addon.
--
-- The saved size is restored here too rather than from an init call at login, which is the whole reason
-- this frame needs no PLAYER_LOGIN hook: it cannot be seen before it is shown, so first open is early
-- enough. The version rides the title the same way, and is read here because it is one string per open.
local function RefreshOptions()
    local db = OptDB()
    if db and db.width and db.height then options:SetSize(db.width, db.height) end
    optTitle:SetText(("Raid Death Count  |cff888888v%s|r")
        :format(RDC.GetVersion and RDC.GetVersion() or "?"))
    for _, t in ipairs(optToggles) do t.cb:SetChecked(t.get()) end
end
options:SetScript("OnShow", RefreshOptions)

-- Labels are bare nouns because the title bar has no room for sentences and the tooltip carries the
-- meaning. That is the whole reason the tooltips stay: "Enabled" alone does not say that it stops inbound
-- merges too, and that is exactly the part a user would be surprised by.
AddToggle("Enabled",
    "Off means nothing is recorded, merged from other players, or broadcast. Counts already stored are kept.",
    function() return RDC.IsEnabled and RDC.IsEnabled() end,
    function(on) if RDC.SetEnabled then RDC.SetEnabled(on) end end)

-- Checked means SHOWN while the flag stored is `hidden`, so this pair is inverted and is easy to wire up
-- backwards. The tooltip names the slash command on purpose: hiding the button removes the only other way
-- back into this frame, so the escape hatch has to be visible at the moment it is being closed off.
AddToggle("Minimap Icon",
    "Show the Raid Death Count button on the minimap. Reachable again with /rdc options if you hide it.",
    function() return not (RDC.IsMinimapHidden and RDC.IsMinimapHidden()) end,
    function(on) if RDC.SetMinimapHidden then RDC.SetMinimapHidden(not on) end end)

function RDC.ToggleOptions()
    if options:IsShown() then options:Hide() else options:Show() end
end

-- The one repaint for the master switch, called by the core whenever it flips and once at login. Recolours
-- the HUD title and re-syncs the open frame, so the checkbox, the slash command and the HUD cannot end up
-- telling three different stories.
function RDC.RefreshEnabledState()
    local on = (not RDC.IsEnabled) or RDC.IsEnabled()
    local c = on and THEME.text or THEME.offRed
    title:SetTextColor(c[1], c[2], c[3])
    if options:IsShown() then RefreshOptions() end
    -- Late-bound through the RDC table because the minimap button is built further down this file, and
    -- routed through here rather than called from each toggle site so the switch keeps ONE repaint.
    if RDC.RefreshMinimapTint then RDC.RefreshMinimapTint() end
end

-- Escape closes it like any other transient window. This is why the frame is globally named.
if UISpecialFrames then table.insert(UISpecialFrames, "RaidDeathCount_Options") end

-- ── Minimap button ──────────────────────────────────────────────────────────────
-- Hand-rolled rather than LibDBIcon, since the addon carries no libraries. Created at load but positioned
-- and shown from RDC.InitMinimap on PLAYER_LOGIN, once the saved variables exist.
do
    local DEFAULT_ANGLE = 200   -- degrees; lower-left, clear of the zoom +/- buttons

    -- Skinning addons expose GetMinimapShape(). Each entry flags whether that QUADRANT is rounded (true)
    -- or squared (false), ordered {BR, BL, TR, TL}. Absent means ROUND. Same public contract LibDBIcon uses.
    local MINIMAP_SHAPES = {
        ["ROUND"]                 = { true,  true,  true,  true  },
        ["SQUARE"]                = { false, false, false, false },
        ["CORNER-TOPLEFT"]        = { false, false, false, true  },
        ["CORNER-TOPRIGHT"]       = { false, false, true,  false },
        ["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
        ["CORNER-BOTTOMRIGHT"]    = { true,  false, false, false },
        ["SIDE-LEFT"]             = { false, true,  false, true  },
        ["SIDE-RIGHT"]            = { true,  false, true,  false },
        ["SIDE-TOP"]              = { false, false, true,  true  },
        ["SIDE-BOTTOM"]           = { true,  true,  false, false },
        ["TRICORNER-TOPLEFT"]     = { false, true,  true,  true  },
        ["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true  },
        ["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true  },
        ["TRICORNER-BOTTOMRIGHT"] = { true,  true,  true,  false },
    }

    local function MMDB() return RaidDeathCountDB and RaidDeathCountDB.minimap end

    local btn = CreateFrame("Button", "RaidDeathCount_MinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    -- Right-click opens the options. Drag stays left-only, so a right-click can never be swallowed by a
    -- move that the cursor started but did not travel far enough to register.
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- TexCoord inset crops the icon's baked-in border.
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Tinted red while the master switch is off, so the state reads from the minimap at a glance with
    -- nothing opened. Desaturated FIRST, and that ordering is the point: SetVertexColor multiplies rather
    -- than replaces, so tinting the skull's own bone browns directly gives an uneven muddy red, whereas
    -- tinting a flat grey gives a clean one. Guarded because the call is not on every client's texture.
    --
    -- THEME.offRed rather than a colour picked for the minimap, so the switch says "off" in one colour
    -- everywhere: this icon, the checkbox fill and the HUD title.
    function RDC.RefreshMinimapTint()
        local off = RDC.IsEnabled and not RDC.IsEnabled()
        if icon.SetDesaturated then icon:SetDesaturated(off and true or false) end
        if off then
            icon:SetVertexColor(THEME.offRed[1], THEME.offRed[2], THEME.offRed[3])
        else
            icon:SetVertexColor(1, 1, 1)   -- back to the texture's own colours, not to a "normal" tint
        end
    end

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Half-extents come from the live minimap size rather than a constant, so the button tracks a skin
    -- that resizes the minimap after login.
    local angle = DEFAULT_ANGLE
    local function UpdatePosition()
        local a = math.rad(angle)
        local x, y = math.cos(a), math.sin(a)
        local q = 1
        if x < 0 then q = q + 1 end
        if y > 0 then q = q + 2 end
        local shape = (GetMinimapShape and GetMinimapShape()) or "ROUND"
        local quad  = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES["ROUND"]
        local w = (Minimap:GetWidth()  / 2) + 5
        local h = (Minimap:GetHeight() / 2) + 5
        if quad[q] then
            x, y = x * w, y * h                       -- rounded quadrant: sit on the ellipse
        else
            local dw = math.sqrt(2 * w * w) - 10      -- squared quadrant: clamp the ray to the edge
            local dh = math.sqrt(2 * h * h) - 10
            x = math.max(-w, math.min(x * dw, w))
            y = math.max(-h, math.min(y * dh, h))
        end
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    Minimap:HookScript("OnSizeChanged", function() UpdatePosition() end)

    -- Converts the cursor's offset from the minimap centre back into the stored angle.
    local dragging = false
    local function OnDragUpdate()
        local mx, my = Minimap:GetCenter()
        local scale  = Minimap:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale
        angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
        UpdatePosition()
    end
    btn:SetScript("OnDragStart", function(self)
        dragging = true
        GameTooltip:Hide()
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    btn:SetScript("OnDragStop", function(self)
        dragging = false
        self:SetScript("OnUpdate", nil)
        local db = MMDB()
        if db then db.angle = angle end
    end)

    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then RDC.ToggleOptions() else RDC.ToggleHUD() end
    end)

    btn:SetScript("OnEnter", function(self)
        if dragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local ver = RDC.GetVersion and RDC.GetVersion() or "?"
        GameTooltip:SetText("Raid Death Count  |cff888888v" .. ver .. "|r", THEME.accent[1], THEME.accent[2], THEME.accent[3])
        GameTooltip:AddLine("Click to toggle the HUD.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Right-click for options.", 0.8, 0.8, 0.8, true)
        if RDC.IsEnabled and not RDC.IsEnabled() then
            GameTooltip:AddLine("Recording is off.", THEME.offRed[1], THEME.offRed[2], THEME.offRed[3], true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:Hide()   -- InitMinimap shows it once the saved hidden flag is readable

    function RDC.IsMinimapHidden()
        local db = MMDB()
        return (db and db.hidden) and true or false
    end
    function RDC.SetMinimapHidden(hide)
        hide = hide and true or false
        local db = MMDB()
        if db then db.hidden = hide end
        if hide then btn:Hide() else btn:Show() end
    end
    function RDC.ToggleMinimap()
        RDC.SetMinimapHidden(not RDC.IsMinimapHidden())
        print("|cff88bbffRaidDeathCount|r minimap button " .. (RDC.IsMinimapHidden() and "hidden." or "shown."))
    end
    -- Called from the core's PLAYER_LOGIN, once RaidDeathCountDB is resolved.
    function RDC.InitMinimap()
        local db = MMDB()
        if db and db.angle then angle = db.angle end
        UpdatePosition()
        if db and db.hidden then btn:Hide() else btn:Show() end
    end
end
