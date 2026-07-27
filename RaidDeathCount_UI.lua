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

-- Each button anchors to the LEFT of the previous one, so they are created right to left and read
-- A, 3, 5 on screen.
local function MakeReportButton(label, anchorTo, tooltip, mode)
    local b = CreateFrame("Button", nil, header, "BackdropTemplate")
    b:SetSize(HEADER_H - 4, HEADER_H - 4)
    b:SetPoint("RIGHT", anchorTo, "LEFT", -2, 0)
    ApplyFlat(b, THEME.bg, true)
    local tx = b:CreateFontString(nil, "OVERLAY")
    ApplyFont(tx, 10)
    tx:SetPoint("CENTER")
    tx:SetText(label)
    tx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
    b:SetScript("OnEnter", function(self)
        tx:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        tx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function() RDC.Report(mode) end)
    return b
end

local report5Btn   = MakeReportButton("5", lockBtn,    "Report top 5",      "top5")
local report3Btn   = MakeReportButton("3", report5Btn,  "Report top 3",      "top3")
local reportAllBtn = MakeReportButton("A", report3Btn,  "Report all deaths", "all")

-- Dot + count of addons in sync (us + live peers). Hidden when ungrouped, where the number is always 1.
local syncTag = CreateFrame("Frame", nil, header)
syncTag:SetSize(26, HEADER_H - 4)
syncTag:SetPoint("RIGHT", reportAllBtn, "LEFT", -5, 0)
syncTag:EnableMouse(true)
local syncDot = syncTag:CreateTexture(nil, "OVERLAY")
syncDot:SetSize(9, 9)
syncDot:SetPoint("LEFT", syncTag, "LEFT", 0, 0)
local syncTx = syncTag:CreateFontString(nil, "OVERLAY")
ApplyFont(syncTx, 10)
syncTx:SetPoint("LEFT", syncDot, "RIGHT", 2, 0)

local function UpdateSyncTag()
    if not (RDC.GetSyncCount and IsInGroup()) then syncTag:Hide(); return end
    local n = RDC.GetSyncCount()
    syncTag:Show()
    syncDot:SetTexture(n > 1 and "Interface\\COMMON\\Indicator-Green" or "Interface\\COMMON\\Indicator-Gray")
    syncTx:SetText(n)
    if n > 1 then
        syncTx:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    else
        syncTx:SetTextColor(THEME.dim[1], THEME.dim[2], THEME.dim[3])
    end
end

syncTag:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    local ver = RDC.GetVersion and RDC.GetVersion() or "?"
    local peers = RDC.GetSyncPeers and RDC.GetSyncPeers() or {}
    GameTooltip:SetText("Addons in sync: " .. (RDC.GetSyncCount and RDC.GetSyncCount() or 1))
    GameTooltip:AddLine("You  |cff888888v" .. ver .. "|r", 0.5, 0.9, 0.5)
    for _, p in ipairs(peers) do
        local short = p.name:match("^[^-]+") or p.name
        if p.ver and p.ver ~= ver then
            GameTooltip:AddLine(short .. "  |cffd9a066v" .. p.ver .. "|r", 0.8, 0.8, 0.8)   -- version mismatch
        else
            GameTooltip:AddLine(short, 0.8, 0.8, 0.8)
        end
    end
    if #peers == 0 then GameTooltip:AddLine("No one else is running the addon.", 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
end)
syncTag:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

-- "Coilfang: Serpentshrine Cavern" becomes "Serpentshrine Cavern"; unprefixed names pass through.
local function ShortInstance(name)
    if not name then return nil end
    local tail = name:match("^.-:%s*(.+)$")
    return tail or name
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

            -- Proportional to the leader's count, floored at a sliver so a 1-death bar is still visible.
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

    local inst = ShortInstance(RDC.GetInstanceName())
    title:SetText(inst and ("RDC: " .. inst) or "Raid Death Count")

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
