--[[
    NEXUS - World of Warcraft Community Addon
    Midnight API v12 (Interface 120000)

    Modul: Nexus_UI – Theme "CLASSIC"
    v0.9.5: 1:1 Rekonstruktion nach echtem Blizzard_AchievementUI.xml

    Bestätigte Textur-Pfade (aus Blizzard XML):
    Hauptframe:
      Backdrop: BACKDROP_ACHIEVEMENTS_0_64 (BackdropTemplate)
      Haupt-BG: UI-Achievement-AchievementBackground TexCoords 0,1,0,0.5
      Black Cover: a=0.75 (macht BG dunkel)
      Kategorie-BG: UI-Achievement-Parchment TexCoords 0,0.5,0,1
      Metallband: UI-Achievement-MetalBorder-Left/Top/Joint
      Holzecken: UI-Achievement-WoodBorder-Corner (4x gespiegelt)

    Kategorie-Button (AchievementCategoryTemplate):
      BG: UI-Achievement-Category-Background TexCoords 0,0.6640625,0,1
      Highlight: UI-Achievement-Category-Highlight ADD TexCoords 0,0.6640625,0,1

    Tabs (AchievementFrameTabButtonTemplate):
      Aktiv 59px: UI-Achievement-Header TexCoords L:0.4727,0.5137 M:0.5137,0.6855 R:0.6855,0.7207 (top:0.7695 bot:1.0)
      Inaktiv 49px: gleich + SetVertexColor(0.6,0.6,0.6)

    Content-BG: UI-Achievement-AchievementBackground TexCoords 0,1,0,0.5 + BlackCover 0.75
    Parchment-Horizontal: NUR für einzelne Eintragszeilen (AchievementTemplate)!

    ProgressBar-Rand 3-teilig:
      Links  TexCoords 0,0.0625,0,0.75
      Mitte  TexCoords 0.0625,0.812,0,0.75
      Rechts TexCoords 0.812,0.8745,0,0.75
]]

local UI_VERSION = "0.9.7"
NexusTheme = "CLASSIC"

-- ============================================================
-- DIMENSIONEN
-- ============================================================
local MAIN_W   = 860
local MAIN_H   = 640
local CAT_W    = 196
local HEADER_H = 49   -- Blizzard: Header BOTTOMLEFT y=-49 (skaliert von -38)
local TAB_H    = 32
local PAD      = 8

-- ============================================================
-- TAB-CONTROLLER STATE
-- ============================================================
local VALID_TABS = { FEED=true, PROFILE=true, SETTINGS=true }
NexusTabState = { activeTab="FEED", activeCategory="FEED" }
local tabCBs = {}
NexusTabs = {}

function NexusTabs.SetActive(id)
    if not VALID_TABS[id] then return end
    if NexusTabState.activeTab == id then return end
    local prev = NexusTabState.activeTab
    NexusTabState.activeTab = id
    NexusTabs.RefreshPanelVisibility()
    NexusTabs.RefreshTabButtons()
    for _,cb in ipairs(tabCBs) do cb(id, prev) end
end
function NexusTabs.GetActive()      return NexusTabState.activeTab end
function NexusTabs.IsActive(id)     return NexusTabState.activeTab == id end
function NexusTabs.OnTabChanged(cb) if type(cb)=="function" then table.insert(tabCBs,cb) end end

-- ============================================================
-- FRAME-REFERENZEN
-- ============================================================
local F = {
    main=nil, titleFS=nil, badgeFS=nil, badgePctFS=nil, badgeBar=nil,
    safeModeFS=nil, catPanel=nil, catBtns={},
    content=nil, feed=nil, profile=nil, settings=nil,
    tabBtns={}, contentLabelFS=nil,
}

-- ============================================================
-- PANEL-SICHTBARKEIT
-- ============================================================
function NexusTabs.RefreshPanelVisibility()
    local a = NexusTabState.activeTab
    for _,p in ipairs({{F.feed,"FEED"},{F.profile,"PROFILE"},{F.settings,"SETTINGS"}}) do
        if p[1] then
            if a==p[2] then p[1]:Show() else p[1]:Hide() end
        end
    end
    if F.catPanel then
        if a=="FEED" then F.catPanel:Show() else F.catPanel:Hide() end
    end
    if F.content then
        F.content:ClearAllPoints()
        if a=="FEED" then
            F.content:SetPoint("TOPLEFT", F.main, "TOPLEFT",
                CAT_W + PAD + 9, -(HEADER_H + PAD))
        else
            F.content:SetPoint("TOPLEFT", F.main, "TOPLEFT",
                PAD + 9, -(HEADER_H + PAD))
        end
        F.content:SetPoint("BOTTOMRIGHT", F.main, "BOTTOMRIGHT", -9, TAB_H + PAD + 2)
    end
    if F.contentLabelFS then
        local labels = {
            FEED={FEED="Feed",GUILD="Gilde",FRIENDS="Freunde",PUBLIC="Oeffentlich"},
            PROFILE="Profil", SETTINGS="Einstellungen",
        }
        if a=="FEED" then
            F.contentLabelFS:SetText(L and L["CATEGORY_"..NexusTabState.activeCategory]
                or labels.FEED[NexusTabState.activeCategory] or "Feed")
        elseif a=="PROFILE" then
            F.contentLabelFS:SetText(L and L["TAB_PROFILE"] or "Profil")
        else
            F.contentLabelFS:SetText(L and L["TAB_SETTINGS"] or "Einstellungen")
        end
    end
end

-- ============================================================
-- TAB-BUTTON REFRESH (Aktiv/Inaktiv-Layer umschalten)
-- ============================================================
function NexusTabs.RefreshTabButtons()
    for _,btn in ipairs(F.tabBtns) do
        local active = btn.tabID == NexusTabState.activeTab
        if btn.tLeftA  then btn.tLeftA:SetShown(active)   end
        if btn.tMidA   then btn.tMidA:SetShown(active)    end
        if btn.tRightA then btn.tRightA:SetShown(active)  end
        if btn.tLeft   then btn.tLeft:SetShown(not active) end
        if btn.tMid    then btn.tMid:SetShown(not active)  end
        if btn.tRight  then btn.tRight:SetShown(not active) end
        if btn.labelFS then
            if active then
                btn.labelFS:SetTextColor(1.00, 0.82, 0.00)
                btn.labelFS:SetFontObject("GameFontNormal")
            else
                btn.labelFS:SetTextColor(0.60, 0.50, 0.35)
                btn.labelFS:SetFontObject("GameFontNormalSmall")
            end
        end
    end
end

-- ============================================================
-- HILFSFUNKTION: solide Textur
-- ============================================================
local function SolidTex(parent, layer, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub or 0)
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetVertexColor(r, g, b, a or 1)
    return t
end

-- ============================================================
-- HAUPTFRAME
-- ============================================================
local function BuildMainFrame()
    local f = CreateFrame("Frame", "NexusMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(MAIN_W, MAIN_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(10)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)

    -- Haupt-BG: AchievementBackground, nur obere Hälfte (TexCoord 0,1,0,0.5)
    local mainBG = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    mainBG:SetTexture("Interface\\AchievementFrame\\UI-Achievement-AchievementBackground")
    -- mainBG: BOTTOMRIGHT fest, TOPLEFT wird nach BuildHeader gesetzt
    mainBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    f._mainBG = mainBG
    mainBG:SetTexCoord(0, 1, 0, 0.5)

    -- Black Cover a=0.75 (macht BG sehr dunkel wie Original)
    local blackCover = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    blackCover:SetTexture("Interface\\Buttons\\WHITE8X8")
    blackCover:SetPoint("TOPLEFT",     mainBG, "TOPLEFT")
    blackCover:SetPoint("BOTTOMRIGHT", mainBG, "BOTTOMRIGHT")
    blackCover:SetVertexColor(0, 0, 0, 0.75)

    -- Metallband Links (16x auto)
    local mL = f:CreateTexture(nil, "ARTWORK", nil, 0)
    mL:SetTexture("Interface\\AchievementFrame\\UI-Achievement-MetalBorder-Left")
    mL:SetSize(16, 436); mL:SetPoint("LEFT", f, "LEFT", 14, 0)
    mL:SetTexCoord(0, 1, 0, 0.87)

    -- Metallband Rechts (gespiegelt)
    local mR = f:CreateTexture(nil, "ARTWORK", nil, 0)
    mR:SetTexture("Interface\\AchievementFrame\\UI-Achievement-MetalBorder-Left")
    mR:SetSize(16, 436); mR:SetPoint("RIGHT", f, "RIGHT", -13, 0)
    mR:SetTexCoord(1, 0, 0.87, 0)

    -- Metallband Oben
    local mT = f:CreateTexture(nil, "ARTWORK", nil, 0)
    mT:SetTexture("Interface\\AchievementFrame\\UI-Achievement-MetalBorder-Top")
    mT:SetSize(450, 16)
    mT:SetPoint("TOPLEFT",  f, "TOPLEFT",  28, -12)
    mT:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -12)
    mT:SetTexCoord(0.87, 0, 0, 1)

    -- Metallband Unten
    local mB = f:CreateTexture(nil, "ARTWORK", nil, 0)
    mB:SetTexture("Interface\\AchievementFrame\\UI-Achievement-MetalBorder-Top")
    mB:SetSize(450, 16)
    mB:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  28, 13)
    mB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 13)
    mB:SetTexCoord(0, 0.87, 1.0, 0)

    -- Metallecken (Joint 32x32)
    local function MakeJoint(pt, tx, ty, l, r, t, b)
        local j = f:CreateTexture(nil, "OVERLAY", nil, 1)
        j:SetTexture("Interface\\AchievementFrame\\UI-Achievement-MetalBorder-Joint")
        j:SetSize(32, 32); j:SetPoint(pt, f, pt, tx, ty)
        j:SetTexCoord(l, r, t, b)
    end
    MakeJoint("TOPLEFT",      9,  -7,  1, 0, 1, 0)
    MakeJoint("TOPRIGHT",    -8,  -7,  0, 1, 1, 0)
    MakeJoint("BOTTOMLEFT",   9,   8,  1, 0, 0, 1)
    MakeJoint("BOTTOMRIGHT", -8,   8,  0, 1, 0, 1)

    -- Holzecken (WoodBorder-Corner 64x64, gespiegelt nach Blizzard-XML)
    local function MakeCorner(pt, tx, ty, l, r, t, b)
        local c = f:CreateTexture(nil, "OVERLAY", nil, 2)
        c:SetTexture("Interface\\AchievementFrame\\UI-Achievement-WoodBorder-Corner")
        c:SetSize(64, 64); c:SetPoint(pt, f, pt, tx, ty)
        c:SetTexCoord(l, r, t, b)
    end
    MakeCorner("TOPLEFT",      4,  -2,  0, 1, 0, 1)
    MakeCorner("TOPRIGHT",    -4,  -2,  1, 0, 0, 1)
    MakeCorner("BOTTOMLEFT",   4,   3,  0, 1, 1, 0)
    MakeCorner("BOTTOMRIGHT", -4,   3,  1, 0, 1, 0)

    -- Close-Button
    local cb = CreateFrame("Button", "NexusCloseBtn", f, "UIPanelCloseButton")
    cb:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    cb:SetScript("OnClick", function() f:Hide() end)

    -- Escape
    f:SetPropagateKeyboardInput(true)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false); self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    f:Hide()
    F.main = f
    return f
end

-- ============================================================
-- HEADER
-- Blizzard-Struktur (aus XML):
--   Header-Frame: 726x106 (skaliert: 812x135)
--   Anker: BOTTOMLEFT → Frame.TOPLEFT  x=+29  y=-49
--   → Header ragt 87px ÜBER den Frame hinaus
--   Textur Links:  512x106, BOTTOMLEFT, TexCoords 0,1,0,0.4140625
--   Textur Rechts: 215x100, BOTTOMLEFT von Links+BOTTOMRIGHT, y=-6
--                  TexCoords 0,0.419921875,0.4140625,0.8046875
-- ============================================================
local function BuildHeader(parent)
    -- ── HEADER-FRAME (sitzt physisch ÜBER dem Hauptframe!) ──
    -- Blizzard: BOTTOMLEFT→TOPLEFT  x=26 y=-38  (skaliert: x=29 y=-49)
    local header = CreateFrame("Frame", "NexusHeaderFrame", parent)
    header:SetSize(812, 135)
    header:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", 29, -49)
    header:SetFrameLevel(parent:GetFrameLevel() + 4)

    -- ── TEXTUR LINKS (512x106 → 573x135) ──
    -- TexCoords: 0,1,0,0.4140625
    local hLeft = header:CreateTexture(nil, "BACKGROUND", nil, 0)
    hLeft:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
    hLeft:SetSize(573, 135)
    hLeft:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    hLeft:SetTexCoord(0, 1, 0, 0.4140625)
    F.headerBG = hLeft   -- Referenz für mainBG-Anker

    -- ── TEXTUR RECHTS (215x100 → 240x128) ──
    -- TexCoords: 0,0.419921875,0.4140625,0.8046875
    -- Anchor: BOTTOMLEFT von hLeft.BOTTOMRIGHT, y=-6 (skaliert: -8)
    local hRight = header:CreateTexture(nil, "BACKGROUND", nil, 0)
    hRight:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
    hRight:SetSize(240, 128)
    hRight:SetPoint("BOTTOMLEFT", hLeft, "BOTTOMRIGHT", 0, -8)
    hRight:SetTexCoord(0, 0.419921875, 0.4140625, 0.8046875)

    -- ── PUNKTERAHMEN (PointBorder, 133x39 → 148x49) ──
    -- Anchor: BOTTOM +22,+20 (skaliert: +25,+26)
    local pBorder = header:CreateTexture(nil, "BORDER", nil, 0)
    pBorder:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
    pBorder:SetSize(148, 49)
    pBorder:SetPoint("BOTTOM", header, "BOTTOM", 25, 26)
    pBorder:SetTexCoord(0.419921875, 0.6796875, 0.4140625, 0.56640625)

    -- ── TITEL: Spielername + Klasse ──
    -- Anchor: TOP des PointBorder + (0, +12) → ÜBER dem Schild
    local titleFS = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFS:SetPoint("TOP", pBorder, "TOP", 0, 12)
    titleFS:SetText((UnitName("player") or "?") ..
        "  –  " ..
        (L and L["HEADER_CHARACTER_LEVEL_CLASS"] or "Stufe %s %s"):format(
            tostring(UnitLevel("player") or "?"), UnitClass("player") or "?"))
    titleFS:SetTextColor(1.00, 0.82, 0.00)
    F.titleFS = titleFS

    -- ── BADGE-ZEILE: Speicher-Zähler (unter Schild) ──
    -- Anchor: TOP des PointBorder - 13px (Blizzard: Points FontString)
    local badgeFS = header:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    badgeFS:SetPoint("TOP", pBorder, "TOP", 0, -13)
    badgeFS:SetText("0 / 2000")
    badgeFS:SetTextColor(1.00, 0.82, 0.00)
    F.badgeFS = badgeFS

    local badgePctFS = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    badgePctFS:SetPoint("LEFT", badgeFS, "RIGHT", 5, 0)
    badgePctFS:SetText("0%")
    badgePctFS:SetTextColor(0.70, 0.65, 0.45)
    F.badgePctFS = badgePctFS

    -- ── PROGRESS BAR (3-teilig, exakt wie AchievementProgressBarTemplate) ──
    local barHolder = CreateFrame("Frame", nil, header)
    barHolder:SetSize(220, 16)
    barHolder:SetPoint("LEFT", badgeFS, "RIGHT", 65, 0)

    local barBG = barHolder:CreateTexture(nil, "BACKGROUND", nil, 0)
    barBG:SetTexture("Interface\\Buttons\\WHITE8X8")
    barBG:SetAllPoints(barHolder)
    barBG:SetVertexColor(0, 0, 0, 0.5)

    -- Links: TexCoords 0,0.0625,0,0.75
    local bBL = barHolder:CreateTexture(nil, "ARTWORK", nil, 1)
    bBL:SetTexture("Interface\\AchievementFrame\\UI-Achievement-ProgressBar-Border")
    bBL:SetSize(16, 0)
    bBL:SetPoint("TOPLEFT",    barHolder, "TOPLEFT",    -6, 5)
    bBL:SetPoint("BOTTOMLEFT", barHolder, "BOTTOMLEFT", -6, -5)
    bBL:SetTexCoord(0, 0.0625, 0, 0.75)

    -- Rechts: TexCoords 0.812,0.8745,0,0.75
    local bBR = barHolder:CreateTexture(nil, "ARTWORK", nil, 1)
    bBR:SetTexture("Interface\\AchievementFrame\\UI-Achievement-ProgressBar-Border")
    bBR:SetSize(16, 0)
    bBR:SetPoint("TOPRIGHT",    barHolder, "TOPRIGHT",    6, 5)
    bBR:SetPoint("BOTTOMRIGHT", barHolder, "BOTTOMRIGHT", 6, -5)
    bBR:SetTexCoord(0.812, 0.8745, 0, 0.75)

    -- Mitte: TexCoords 0.0625,0.812,0,0.75
    local bBC = barHolder:CreateTexture(nil, "ARTWORK", nil, 1)
    bBC:SetTexture("Interface\\AchievementFrame\\UI-Achievement-ProgressBar-Border")
    bBC:SetPoint("TOPLEFT",     bBL, "TOPRIGHT")
    bBC:SetPoint("BOTTOMRIGHT", bBR, "BOTTOMLEFT")
    bBC:SetTexCoord(0.0625, 0.812, 0, 0.75)

    local bar = CreateFrame("StatusBar", "NexusStorageBar", barHolder)
    bar:SetPoint("TOPLEFT",     barHolder, "TOPLEFT",     2, -2)
    bar:SetPoint("BOTTOMRIGHT", barHolder, "BOTTOMRIGHT", -2, 2)
    bar:SetMinMaxValues(0, 1); bar:SetValue(0)
    bar:SetStatusBarTexture("Interface\\AchievementFrame\\UI-Achievement-ProgressBar-Bar")
    bar:SetStatusBarColor(0, 0.6, 0, 1)
    F.badgeBar = bar

    -- ── TRENNLINIE (Divider) zwischen Header und Content ──
    -- Sitzt im Parent (Hauptframe), nicht im Header-Frame
    local hDiv = parent:CreateTexture(nil, "ARTWORK", nil, 1)
    hDiv:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Divider")
    hDiv:SetPoint("TOPLEFT",  parent, "TOPLEFT",  30, -(HEADER_H + 2))
    hDiv:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -30, -(HEADER_H + 2))
    hDiv:SetHeight(8); hDiv:SetHorizTile(true)

    -- ── ONLINE-STATUS (links unten) ──
    local safeFS = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    safeFS:SetPoint("LEFT", parent, "LEFT", 32, -(HEADER_H - 20))
    safeFS:SetText("")
    F.safeModeFS = safeFS

    F.headerFrame = header
    return header
end

-- ============================================================
-- KATEGORIE-PANEL
-- ============================================================
local function GetCategories()
    return {
        {id="FEED",    label=L and L["CATEGORY_FEED"]    or "Feed"},
        {id="GUILD",   label=L and L["CATEGORY_GUILD"]   or "Gilde"},
        {id="FRIENDS", label=L and L["CATEGORY_FRIENDS"] or "Freunde"},
        {id="PUBLIC",  label=L and L["CATEGORY_PUBLIC"]  or "Oeffentlich"},
    }
end

local function BuildCategoryPanel(parent)
    local cp = CreateFrame("Frame", "NexusCategoryPanel", parent, "BackdropTemplate")
    cp:SetPoint("TOPLEFT",    parent, "TOPLEFT",    9, -(HEADER_H + PAD + 2))
    cp:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 9,  TAB_H + PAD + 2)
    cp:SetWidth(CAT_W)

    -- Backdrop: TooltipBackdropTemplate mit ACHIEVEMENT_GOLD_BORDER_COLOR
    cp:SetBackdrop({
        bgFile   = nil,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true, tileEdge = true, edgeSize = 16,
        insets   = {left=4, right=4, top=4, bottom=4},
    })
    cp:SetBackdropBorderColor(0.90, 0.75, 0.30, 1)

    -- BG: UI-Achievement-Parchment, TexCoords 0,0.5,0,1 (linke Hälfte!)
    local cpBG = cp:CreateTexture(nil, "BACKGROUND", nil, -1)
    cpBG:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Parchment")
    cpBG:SetPoint("TOPLEFT",     cp, "TOPLEFT",     5, -5)
    cpBG:SetPoint("BOTTOMRIGHT", cp, "BOTTOMRIGHT", -5, 5)
    cpBG:SetTexCoord(0, 0.5, 0, 1)
    cpBG:SetVertTile(true)

    -- ScrollFrame
    local sf = CreateFrame("ScrollFrame", "NexusCatScroll", cp, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     cp, "TOPLEFT",      5,  -8)
    sf:SetPoint("BOTTOMRIGHT", cp, "BOTTOMRIGHT", -22,  6)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(CAT_W - 30); sc:SetHeight(1)
    sf:SetScrollChild(sc)

    local cats = GetCategories()
    local totalH = 0

    for i, cat in ipairs(cats) do
        -- AchievementCategoryTemplate: Button 158x24
        local btn = CreateFrame("Button", "NexusCategoryBtn_" .. cat.id, sc)
        btn:SetSize(CAT_W - 30, 24)
        btn:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i-1)*26)
        totalH = totalH + 26

        -- BG: UI-Achievement-Category-Background 170x32
        -- Blizzard XML: TexCoords 0,0.6640625,0,1
        local catBG = btn:CreateTexture(nil, "BACKGROUND", nil, 0)
        catBG:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Category-Background")
        catBG:SetPoint("TOPLEFT",  btn, "TOPLEFT")
        catBG:SetPoint("TOPRIGHT", btn, "TOPRIGHT")
        catBG:SetHeight(32)
        catBG:SetTexCoord(0, 0.6640625, 0, 1)

        -- Aktiv-BG: Category-Highlight in ARTWORK (immer sichtbar wenn aktiv)
        -- Blizzard: HighlightTexture alphaMode ADD | Anker TOPLEFT 0,0 | BOTTOMRIGHT -1,-7
        local activeBG = btn:CreateTexture(nil, "ARTWORK", nil, 0)
        activeBG:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Category-Highlight")
        activeBG:SetPoint("TOPLEFT",     btn, "TOPLEFT",     0, 0)
        activeBG:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, -7)
        activeBG:SetTexCoord(0, 0.6640625, 0, 1)
        activeBG:SetBlendMode("ADD")
        activeBG:SetAlpha(0)
        btn.activeBG = activeBG

        -- Hover-Highlight (HIGHLIGHT-Layer, automatisch bei Maus)
        local hlTex = btn:CreateTexture(nil, "HIGHLIGHT", nil, 0)
        hlTex:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Category-Highlight")
        hlTex:SetPoint("TOPLEFT",     btn, "TOPLEFT",     0, 0)
        hlTex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, -7)
        hlTex:SetTexCoord(0, 0.6640625, 0, 1)
        hlTex:SetBlendMode("ADD")

        -- Linker Akzent (gold, nur aktiv)
        local accent = btn:CreateTexture(nil, "ARTWORK", nil, 1)
        accent:SetTexture("Interface\\Buttons\\WHITE8X8")
        accent:SetPoint("TOPLEFT",    btn, "TOPLEFT",    0, -1)
        accent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0,  1)
        accent:SetWidth(3)
        accent:SetVertexColor(1.00, 0.82, 0.00, 0)
        btn.accent = accent

        -- Label: GameFontNormalLeftBottom (Blizzard XML)
        -- BOTTOMLEFT +16,+4 | TOPRIGHT -8,-4
        local lbl = btn:CreateFontString(nil, "ARTWORK", "GameFontNormalLeftBottom")
        lbl:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 16, 4)
        lbl:SetPoint("TOPRIGHT",   btn, "TOPRIGHT",   -8, -4)
        lbl:SetText(cat.label)
        lbl:SetWordWrap(false)
        btn.lbl = lbl
        btn.catID = cat.id

        local function Refresh()
            local active = NexusTabState.activeCategory == btn.catID
            if active then
                btn.activeBG:SetAlpha(1.0)
                btn.accent:SetVertexColor(1.00, 0.82, 0.00, 1)
                btn.lbl:SetTextColor(1.00, 1.00, 1.00)
                btn.lbl:SetFontObject("GameFontNormal")
            else
                btn.activeBG:SetAlpha(0)
                btn.accent:SetVertexColor(1.00, 0.82, 0.00, 0)
                btn.lbl:SetTextColor(0.85, 0.78, 0.60)
                btn.lbl:SetFontObject("GameFontNormalSmall")
            end
        end
        btn.Refresh = Refresh

        btn:SetScript("OnEnter", function(self)
            if NexusTooltip_Show then
                NexusTooltip_Show(self, nil, "TOOLTIP_CATEGORY_" .. self.catID .. "_BODY")
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if NexusTooltip_Hide then NexusTooltip_Hide() end
        end)
        btn:SetScript("OnClick", function(self)
            NexusTabState.activeCategory = self.catID
            for _,b in ipairs(F.catBtns) do b.Refresh() end
            NexusTabs.RefreshPanelVisibility()
            local fpr = _G["NexusFeedPanel_Real"]
            if fpr and fpr.OnCategoryChange then fpr:OnCategoryChange(self.catID) end
        end)

        table.insert(F.catBtns, btn)
    end

    sc:SetHeight(math.max(totalH, 1))
    if F.catBtns[1] then F.catBtns[1].Refresh() end

    F.catPanel = cp
    return cp
end

-- ============================================================
-- CONTENT-PANEL
-- ============================================================
local function BuildContentPanel(parent)
    local cp = CreateFrame("Frame", "NexusContentPanel", parent)
    F.content = cp

    -- BG: AchievementBackground TexCoords 0,1,0,0.5 (wie Blizzard XML)
    local cpBG = cp:CreateTexture(nil, "BACKGROUND", nil, 0)
    cpBG:SetTexture("Interface\\AchievementFrame\\UI-Achievement-AchievementBackground")
    cpBG:SetPoint("TOPLEFT",     cp, "TOPLEFT",     3, -3)
    cpBG:SetPoint("BOTTOMRIGHT", cp, "BOTTOMRIGHT", -3, 3)
    cpBG:SetTexCoord(0, 1, 0, 0.5)

    -- Black Cover a=0.75 (Blizzard macht Content ebenfalls dunkel)
    local blackCover = cp:CreateTexture(nil, "BACKGROUND", nil, 1)
    blackCover:SetTexture("Interface\\Buttons\\WHITE8X8")
    blackCover:SetPoint("TOPLEFT",     cpBG, "TOPLEFT")
    blackCover:SetPoint("BOTTOMRIGHT", cpBG, "BOTTOMRIGHT")
    blackCover:SetVertexColor(0, 0, 0, 0.75)

    -- Content-Label
    local clFS = cp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    clFS:SetPoint("TOP", cp, "TOP", 0, -10)
    clFS:SetText("Feed")
    clFS:SetTextColor(1.00, 0.82, 0.00)
    F.contentLabelFS = clFS

    -- Divider
    local clDiv = cp:CreateTexture(nil, "ARTWORK", nil, 1)
    clDiv:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Divider")
    clDiv:SetPoint("TOPLEFT",  cp, "TOPLEFT",  4, -30)
    clDiv:SetPoint("TOPRIGHT", cp, "TOPRIGHT", -4, -30)
    clDiv:SetHeight(8); clDiv:SetHorizTile(true)

    -- Panel-Slots
    local function MakePanel(name)
        local p = CreateFrame("Frame", name, cp)
        p:SetPoint("TOPLEFT",     cp, "TOPLEFT",     0, -42)
        p:SetPoint("BOTTOMRIGHT", cp, "BOTTOMRIGHT",  0,  0)
        p:Hide()
        return p
    end
    F.feed     = MakePanel("NexusFeedPanel")
    F.profile  = MakePanel("NexusProfilePanel")
    F.settings = MakePanel("NexusSettingsPanel")
    return cp
end

-- ============================================================
-- BOTTOM TABS (exakt nach AchievementFrameTabButtonTemplate)
-- ============================================================
local function GetTabs()
    return {
        {id="FEED",     label=L and L["TAB_FEED"]     or "Feed"},
        {id="PROFILE",  label=L and L["TAB_PROFILE"]  or "Profil"},
        {id="SETTINGS", label=L and L["TAB_SETTINGS"] or "Einstellungen"},
    }
end

local function BuildBottomTabs(parent)
    local tabs = GetTabs()
    local tabW = 140

    for i, tab in ipairs(tabs) do
        local btn = CreateFrame("Button", "NexusTabBtn_" .. tab.id, parent)
        btn:SetSize(tabW, TAB_H)
        btn:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", (i-1)*(tabW-12)+8, 0)
        btn.tabID = tab.id

        -- AKTIV-TEXTUREN (59px hoch) – Blizzard: LeftActive/RightActive/MiddleActive
        local tLeftA = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
        tLeftA:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
        tLeftA:SetSize(21, 59); tLeftA:SetPoint("TOPLEFT", btn, "TOPLEFT", -4, 0)
        tLeftA:SetTexCoord(0.47265625, 0.513671875, 0.76953125, 1.0); tLeftA:Hide()
        btn.tLeftA = tLeftA

        local tRightA = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
        tRightA:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
        tRightA:SetSize(18, 59); tRightA:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 4, 0)
        tRightA:SetTexCoord(0.685546875, 0.720703125, 0.76953125, 1.0); tRightA:Hide()
        btn.tRightA = tRightA

        local tMidA = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
        tMidA:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
        tMidA:SetPoint("TOPLEFT", tLeftA, "TOPRIGHT", 0, 0)
        tMidA:SetPoint("TOPRIGHT", tRightA, "TOPLEFT", 0, 0)
        tMidA:SetHeight(59)
        tMidA:SetTexCoord(0.513671875, 0.685546875, 0.76953125, 1.0); tMidA:Hide()
        btn.tMidA = tMidA

        -- INAKTIV-TEXTUREN (49px, dimmed 0.6,0.6,0.6) – Blizzard: Left/Right/Middle
        local tLeft = btn:CreateTexture(nil, "BACKGROUND", nil, 0)
        tLeft:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
        tLeft:SetSize(21, 49); tLeft:SetPoint("TOPLEFT", btn, "TOPLEFT", -4, 0)
        tLeft:SetTexCoord(0.47265625, 0.513671875, 0.76953125, 1.0)
        tLeft:SetVertexColor(0.6, 0.6, 0.6); btn.tLeft = tLeft

        local tRight = btn:CreateTexture(nil, "BACKGROUND", nil, 0)
        tRight:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
        tRight:SetSize(18, 49); tRight:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 4, 0)
        tRight:SetTexCoord(0.685546875, 0.720703125, 0.76953125, 1.0)
        tRight:SetVertexColor(0.6, 0.6, 0.6); btn.tRight = tRight

        local tMid = btn:CreateTexture(nil, "BACKGROUND", nil, 0)
        tMid:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
        tMid:SetPoint("TOPLEFT", tLeft, "TOPRIGHT", 0, 0)
        tMid:SetPoint("TOPRIGHT", tRight, "TOPLEFT", 0, 0)
        tMid:SetHeight(49)
        tMid:SetTexCoord(0.513671875, 0.685546875, 0.76953125, 1.0)
        tMid:SetVertexColor(0.6, 0.6, 0.6); btn.tMid = tMid

        -- HIGHLIGHT (ADD, Hover) – Blizzard TexCoords 0.7207,0.9238,0.7695,1.0
        local tHL = btn:CreateTexture(nil, "HIGHLIGHT", nil, 0)
        tHL:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Header")
        tHL:SetPoint("TOPLEFT",  tLeft,  "TOPLEFT",  -3, 0)
        tHL:SetPoint("TOPRIGHT", tRight, "TOPRIGHT",  0, 0)
        tHL:SetHeight(49)
        tHL:SetTexCoord(0.720703125, 0.923828125, 0.76953125, 1.0)
        tHL:SetBlendMode("ADD")

        -- Label (CENTER x=0 y=-3 wie Blizzard ButtonText)
        local labelFS = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        labelFS:SetPoint("CENTER", btn, "CENTER", 0, -3)
        labelFS:SetText(tab.label)
        labelFS:SetTextColor(0.60, 0.50, 0.35)
        btn.labelFS = labelFS

        btn:SetScript("OnEnter", function(self)
            if NexusTooltip_Show then
                NexusTooltip_Show(self, "TOOLTIP_TAB_"..self.tabID.."_TITLE",
                    "TOOLTIP_TAB_"..self.tabID.."_BODY")
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if NexusTooltip_Hide then NexusTooltip_Hide() end
        end)
        btn:SetScript("OnClick", function(self)
            NexusTabs.SetActive(self.tabID)
        end)

        table.insert(F.tabBtns, btn)
    end
    NexusTabs.RefreshTabButtons()
end

-- ============================================================
-- SAFE MODE / STATUS / BADGE
-- ============================================================
local function UpdateSafeMode()
    if not F.safeModeFS then return end
    local ok = NexusState and NexusState.commAllowed
    if ok then
        F.safeModeFS:SetText("|cff00cc44" .. (L and L["NEXUS_ONLINE"] or "[Nexus Online]") .. "|r")
    elseif NexusState and NexusState.inCombat then
        F.safeModeFS:SetText("|cffff4400" .. (L and L["SAFE_MODE_REASON_COMBAT"] or "[Kampf]") .. "|r")
    else
        F.safeModeFS:SetText("|cffff8800" .. (L and L["SAFE_MODE_ACTIVE"] or "[Offline]") .. "|r")
    end
end

local function UpdateBadge()
    if not F.badgeFS then return end
    local count, cap = 0, 2000
    if NexusDB and NexusDB.posts then
        for _,p in pairs(NexusDB.posts) do
            if p.state ~= "locally_deleted" then count = count + 1 end
        end
    end
    if NexusConfig and NexusConfig.maxPosts then cap = NexusConfig.maxPosts end
    F.badgeFS:SetText(count .. " / " .. cap)
    local pct = math.floor((count/cap)*100)
    if F.badgePctFS then
        F.badgePctFS:SetText(pct .. "%")
        if pct < 70 then F.badgePctFS:SetTextColor(0.65,0.58,0.40)
        elseif pct < 90 then F.badgePctFS:SetTextColor(1,0.70,0)
        else F.badgePctFS:SetTextColor(1,0.20,0.20) end
    end
    if F.badgeBar then
        local ratio = math.min(1, count/cap)
        F.badgeBar:SetValue(ratio)
        if ratio < 0.7 then F.badgeBar:SetStatusBarColor(0,0.6,0)
        elseif ratio < 0.9 then F.badgeBar:SetStatusBarColor(1,0.60,0)
        else F.badgeBar:SetStatusBarColor(0.9,0.10,0.10) end
    end
end

-- ============================================================
-- TOGGLE / SLASH
-- ============================================================
local function Toggle()
    if not F.main then return end
    if F.main:IsShown() then
        F.main:Hide()
    else
        if F.titleFS then
            F.titleFS:SetText(
                (UnitName("player") or "?") .. "  –  " ..
                (L and L["HEADER_CHARACTER_LEVEL_CLASS"] or "Stufe %s %s"):format(
                    tostring(UnitLevel("player") or "?"), UnitClass("player") or "?"))
        end
        UpdateSafeMode(); UpdateBadge()
        F.main:Show()
    end
end

local oldSlash = SlashCmdList["NEXUS"]
SlashCmdList["NEXUS"] = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if cmd == "ui" then Toggle()
    elseif oldSlash then oldSlash(msg) end
end

-- ============================================================
-- STATE-INTEGRATION
-- ============================================================
NexusTabs.OnTabChanged(UpdateSafeMode)

local evFrame = CreateFrame("Frame", "NexusUIEvFrame")
evFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
evFrame:SetScript("OnEvent", function() C_Timer.After(0.05, UpdateSafeMode) end)

local tickAcc = 0
local tickF = CreateFrame("Frame", "NexusUITickFrame")
tickF:SetScript("OnUpdate", function(_,e)
    if not F.main or not F.main:IsShown() then return end
    tickAcc = tickAcc + e
    if tickAcc >= 2.0 then tickAcc=0; UpdateSafeMode(); UpdateBadge() end
end)

-- ============================================================
-- INITIALISIERUNG
-- ============================================================
local function Init()
    local main = BuildMainFrame()
    BuildHeader(main)
    -- FIX: mainBG TOPLEFT erst NACH BuildHeader() setzen,
    -- damit F.headerBG existiert (ChatGPT-Fix gegen Header-Überlapp)
    if main._mainBG and F.headerBG then
        main._mainBG:SetPoint("TOPLEFT", F.headerBG, "BOTTOMLEFT", -14, 0)
    end
    BuildCategoryPanel(main)
    BuildContentPanel(main)
    BuildBottomTabs(main)
    NexusTabs.RefreshPanelVisibility()
    NexusTabs.RefreshTabButtons()
    UpdateSafeMode()
    print(string.format("[Nexus UI] v%s – /nexus ui", UI_VERSION))
end

local initF = CreateFrame("Frame", "NexusUIInitFrame")
initF:RegisterEvent("PLAYER_ENTERING_WORLD")
initF:SetScript("OnEvent", function(self, e)
    if e == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        Init()
    end
end)

-- ============================================================
-- PUBLIC API
-- ============================================================
_G.NexusTabs     = NexusTabs
_G.NexusTabState = NexusTabState
_G.NexusTheme    = NexusTheme

_G.Nexus_UI = {
    Toggle       = Toggle,
    SetTab       = NexusTabs.SetActive,
    GetTab       = NexusTabs.GetActive,
    IsTabActive  = NexusTabs.IsActive,
    OnTabChanged = NexusTabs.OnTabChanged,
}

print(string.format("[Nexus UI] Modul geladen (v%s)", UI_VERSION))

-- ============================================================
-- UNIT TESTS
-- ============================================================
local function RunTests()
    print("\n=== NEXUS_UI TESTS (v0.9.3) ===")
    local p,f=0,0
    local function A(c,n) if c then p=p+1;print("  + "..n) else f=f+1;print("  FAIL: "..n) end end
    A(NexusTabs.GetActive()=="FEED",    "Default FEED")
    A(NexusTabs.IsActive("FEED"),       "IsActive FEED")
    A(not NexusTabs.IsActive("PROFILE"),"IsActive PROFILE false")
    NexusTabs.SetActive("PROFILE")
    A(NexusTabs.GetActive()=="PROFILE", "SetActive PROFILE")
    NexusTabs.SetActive("PROFILE")
    A(NexusTabs.GetActive()=="PROFILE", "Idempotent")
    NexusTabs.SetActive("FEED")
    NexusTabs.SetActive("INVALID")
    A(NexusTabs.GetActive()=="FEED",    "Unbekannt ignoriert")
    NexusTabs.SetActive("SETTINGS")
    A(NexusTabs.GetActive()=="SETTINGS","SETTINGS OK")
    local fired=false
    NexusTabs.OnTabChanged(function() fired=true end)
    NexusTabs.SetActive("FEED")
    A(fired,                            "Callback OK")
    NexusTabs.SetActive(nil)
    A(NexusTabs.GetActive()~=nil,       "Nie nil")
    NexusTabs.SetActive("FEED")
    print(string.format("Passed: %d  Failed: %d", p, f))
    if f==0 then print("+ ALL TESTS PASSED") end
end
_G.Nexus_UI.RunTests = RunTests
