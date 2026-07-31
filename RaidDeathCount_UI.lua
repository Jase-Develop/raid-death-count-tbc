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
    b:SetScript("OnEnter", function(self)
        tx:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        tx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
        GameTooltip:Hide()
    end)
    return b
end

-- One toggle where the A/3/5 buttons used to sit. The header is width constrained: at MIN_W the fixed
-- furniture already leaves the title barely any room, so report modes past the original three earn their
-- place in the panel below rather than costing another 16px up here.
local reportBtn = MakeFlatButton(header, HEADER_H - 4, HEADER_H - 4, "R", 10, "Reports")
reportBtn:SetPoint("RIGHT", lockBtn, "LEFT", -2, 0)

-- Dot + count of addons in sync (us + live peers). Hidden when ungrouped, where the number is always 1.
local syncTag = CreateFrame("Frame", nil, header)
syncTag:SetSize(26, HEADER_H - 4)
syncTag:SetPoint("RIGHT", reportBtn, "LEFT", -5, 0)
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

-- ── Report panel ──────────────────────────────────────────────────────────────
-- Every reporting action in one place, so the header does not have to grow a button per mode. A child of
-- the HUD, which buys travelling with it and hiding with it for nothing, and deliberately transient: it
-- keeps no saved position, so unlike the HUD there is no way for it to end up stranded off screen.
local PANEL_BTN_W, PANEL_BTN_H, PANEL_GAP, PANEL_COLS = 56, 18, 3, 3

local REPORTS = {
    { "All",      "all",   "Every player, plus the raid total" },
    { "Top 3",    "top3",  "The three highest death counts" },
    { "Top 5",    "top5",  "The five highest death counts" },
    { "Total",    "total", "Raid total on one line" },
    { "Fewest",   "least", "Lowest count, with the deathless at zero" },
    { "By Class", "class", "Deaths summed per class" },
}

local panelRows = math.ceil(#REPORTS / PANEL_COLS)
local panel = CreateFrame("Frame", "RaidDeathCount_ReportPanel", hud, "BackdropTemplate")
panel:SetSize(PAD * 2 + PANEL_COLS * PANEL_BTN_W + (PANEL_COLS - 1) * PANEL_GAP,
              PAD * 2 + HEADER_H + PANEL_GAP + panelRows * PANEL_BTN_H + (panelRows - 1) * PANEL_GAP)
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

for i, r in ipairs(REPORTS) do
    local label, mode, tip = r[1], r[2], r[3]
    local col, row = (i - 1) % PANEL_COLS, math.floor((i - 1) / PANEL_COLS)
    local b = MakeFlatButton(panel, PANEL_BTN_W, PANEL_BTN_H, label, 10, tip)
    b:SetPoint("TOPLEFT", panelHeader, "BOTTOMLEFT",
               col * (PANEL_BTN_W + PANEL_GAP), -PANEL_GAP - row * (PANEL_BTN_H + PANEL_GAP))
    b:SetScript("OnClick", function()
        GameTooltip:Hide()      -- the panel goes away under the cursor, so OnLeave never fires
        panel:Hide()
        RDC.Report(mode)
    end)
end

-- Prefers to hang below the HUD and flips above when there is not room, so a HUD parked at the bottom of
-- the screen does not open the panel off it. Recomputed on every open rather than cached, since the HUD
-- moves and resizes freely between one open and the next.
local function PositionPanel()
    panel:ClearAllPoints()
    local bottom = hud:GetBottom()
    if bottom and bottom - panel:GetHeight() - 2 < 0 then
        panel:SetPoint("BOTTOMRIGHT", hud, "TOPRIGHT", 0, 2)
    else
        panel:SetPoint("TOPRIGHT", hud, "BOTTOMRIGHT", 0, -2)
    end
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

local function MakeRow(i)
    local row = CreateFrame("Frame", nil, body)
    row:SetHeight(ROW_H - 1)

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

            -- Proportional to the leader's count, floored at a sliver so a 1-death bar is still visible.
            local frac = math.max(0.12, e.deaths / top)
            row.bar:SetWidth(rowW * frac)
            row.bar:SetVertexColor(r, g, b, 0.55)

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

    local inst = ShortInstance(RDC.GetInstanceName(), RDC.GetMapID())
    title:SetText(inst and (inst .. " (Total: " .. deathSum .. ")") or "Raid Death Count")

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
    if db.shown == nil then db.shown = true end   -- visible by default, Details-style
    if db.shown then hud:Show() else hud:Hide() end
    RDC.RefreshHUD()
end

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
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- TexCoord inset crops the icon's baked-in border.
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

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

    btn:SetScript("OnClick", function() RDC.ToggleHUD() end)

    btn:SetScript("OnEnter", function(self)
        if dragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local ver = RDC.GetVersion and RDC.GetVersion() or "?"
        GameTooltip:SetText("Raid Death Count  |cff888888v" .. ver .. "|r", THEME.accent[1], THEME.accent[2], THEME.accent[3])
        GameTooltip:AddLine("Click to toggle the HUD.", 0.8, 0.8, 0.8, true)
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
