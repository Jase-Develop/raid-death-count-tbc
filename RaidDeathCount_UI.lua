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

-- Layout constants.
local HEADER_H = 18
local ROW_H    = 18
local PAD      = 4
local MIN_W, MIN_H = 150, 60
local MAX_W, MAX_H = 500, 700
local DEF_W, DEF_H = 220, 200

local CLASS_TEX = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

local function ApplyFont(fs, size, flags)
    if not fs:SetFont(FONT, size, flags or "") then fs:SetFont(FONT_FB, size, flags or "") end
    return fs
end

-- Flat fill + optional 1px border (requires the BackdropTemplate mixin).
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

-- Whole-frame drag (guarded by the lock).
hud:SetMovable(true)
hud:EnableMouse(true)
hud:RegisterForDrag("LeftButton")
hud:SetScript("OnDragStart", function(self)
    local db = DB()
    if db and db.locked then return end
    self:StartMoving()
end)
hud:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePlacement() end)

-- ── Header (title + lock + close) ─────────────────────────────────────────────
local header = CreateFrame("Frame", nil, hud, "BackdropTemplate")
header:SetPoint("TOPLEFT", hud, "TOPLEFT", PAD, -PAD)
header:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -PAD, -PAD)
header:SetHeight(HEADER_H)
ApplyFlat(header, THEME.panel, true)

local title = header:CreateFontString(nil, "OVERLAY")
ApplyFont(title, 12)
title:SetPoint("LEFT", header, "LEFT", 5, 0)
title:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
title:SetText("Raid Death Count")

-- Close button: hides the HUD (same as /rdc).
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

-- Lock button: toggles move/resize; tinted accent when locked.
local lockBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
lockBtn:SetSize(HEADER_H - 4, HEADER_H - 4)
lockBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
ApplyFlat(lockBtn, THEME.bg, true)
local lockTx = lockBtn:CreateFontString(nil, "OVERLAY")
ApplyFont(lockTx, 11)
lockTx:SetPoint("CENTER")
lockTx:SetText("L")

local function RefreshLock()
    local db = DB()
    local locked = db and db.locked
    if locked then
        lockTx:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    else
        lockTx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
    end
end
lockBtn:SetScript("OnClick", function() RDC.ToggleLock() end)

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

-- ── Body / rows ───────────────────────────────────────────────────────────────
local body = CreateFrame("Frame", nil, hud)
body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -PAD)
body:SetPoint("BOTTOMRIGHT", hud, "BOTTOMRIGHT", -PAD, PAD)

local emptyText = body:CreateFontString(nil, "OVERLAY")
ApplyFont(emptyText, 11)
emptyText:SetPoint("TOP", body, "TOP", 0, -6)
emptyText:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
emptyText:SetText("No deaths recorded")

local ROW_POOL = 40
local rows = {}

-- Build one bar row (class-colour bar sized to the leader, rank + icon + name + count).
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

    -- Count occupies the right end; name fills the gap between the icon and the count.
    row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
    return row
end

-- ── Refresh ───────────────────────────────────────────────────────────────────
function RDC.RefreshHUD()
    if not hud:IsShown() then return end
    local snap = RDC.GetSnapshot()
    local top = (snap[1] and snap[1].deaths) or 1
    local bodyW = math.max(1, body:GetWidth())
    local maxRows = math.max(0, math.floor(body:GetHeight() / ROW_H))

    emptyText:SetShown(#snap == 0)

    for i = 1, ROW_POOL do
        local e = snap[i]
        if e and i <= maxRows then
            local row = rows[i]
            if not row then row = MakeRow(i); rows[i] = row end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(i - 1) * ROW_H)
            row:SetPoint("RIGHT", body, "RIGHT", 0, 0)

            local c = RAID_CLASS_COLORS and e.class and RAID_CLASS_COLORS[e.class]
            local r, g, b = 0.4, 0.4, 0.4
            if c then r, g, b = c.r, c.g, c.b end

            -- Bar width proportional to the leader's count (min sliver so a 1-death bar reads).
            local frac = math.max(0.12, e.deaths / top)
            row.bar:SetWidth(bodyW * frac)
            row.bar:SetVertexColor(r, g, b, 0.55)

            if e.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.class] then
                row.icon:SetTexture(CLASS_TEX)
                row.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[e.class]))
                row.icon:Show()
            else
                row.icon:Hide()
            end

            row.rank:SetText(i)
            local shortName = e.name:match("^[^-]+") or e.name
            row.name:SetText(shortName)
            row.name:SetTextColor(r, g, b)
            row.count:SetText(e.deaths)
            row:Show()
        elseif rows[i] then
            rows[i]:Hide()
        end
    end

    -- Reflect instance name in the title when we have one.
    local inst = RDC.GetInstanceName()
    title:SetText(inst and ("Deaths - " .. inst) or "Raid Death Count")
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
    if db.shown == nil then db.shown = true end   -- visible by default (Details-style)
    if db.shown then hud:Show() else hud:Hide() end
    RDC.RefreshHUD()
end
