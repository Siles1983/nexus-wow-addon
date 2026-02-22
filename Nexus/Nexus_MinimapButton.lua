--[[
    NEXUS - World of Warcraft Community Addon
    Midnight API v12 (Interface 120000)

    Modul: Nexus_MinimapButton
    Zweck: Minimap-Button zum Öffnen/Schließen des Nexus-Fensters

    Linksklick → Toggle Nexus UI
    Drag       → Position um die Minimap drehen
]]

-- ============================================================
-- KONFIGURATION
-- ============================================================
local BUTTON_RADIUS = 80      -- Abstand vom Minimap-Mittelpunkt (px)
local DEFAULT_ANGLE = 225     -- Startwinkel in Grad (unten-links)
local ICON_SIZE     = 32      -- Button-Größe in px

-- ============================================================
-- PERSISTENTE POSITION
-- ============================================================
local function GetSavedAngle()
    if NexusConfig and NexusConfig.minimapAngle then
        return NexusConfig.minimapAngle
    end
    return DEFAULT_ANGLE
end

local function SaveAngle(angle)
    if NexusConfig then
        NexusConfig.minimapAngle = angle
    end
end

-- ============================================================
-- POSITION (Polarkoordinaten um Minimap-Mittelpunkt)
-- ============================================================
local function SetButtonPosition(btn, angle)
    local rad = math.rad(angle)
    local x   = math.cos(rad) * BUTTON_RADIUS
    local y   = math.sin(rad) * BUTTON_RADIUS
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- ============================================================
-- BUTTON ERSTELLEN
-- ============================================================
local function CreateMinimapButton()
    local btn = CreateFrame("Button", "NexusMinimapButton", Minimap)
    btn:SetSize(ICON_SIZE, ICON_SIZE)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)

    -- ── Hintergrund ──
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, 0)
    bg:SetTexture("Interface\\AchievementFrame\\UI-Achievement-AchievementBackground")
    bg:SetAllPoints(btn)
    bg:SetTexCoord(0, 1, 0, 0.5)

    local bgCover = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
    bgCover:SetTexture("Interface\\Buttons\\WHITE8X8")
    bgCover:SetAllPoints(btn)
    bgCover:SetVertexColor(0, 0, 0, 0.55)

    -- ── Icon: Achievement-Schild (gold) ──
    local icon = btn:CreateTexture(nil, "ARTWORK", nil, 0)
    icon:SetTexture("Interface\\AchievementFrame\\UI-Achievement-TinyShield")
    icon:SetSize(ICON_SIZE - 6, ICON_SIZE - 6)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    icon:SetTexCoord(0, 0.625, 0, 0.625)
    icon:SetVertexColor(1.00, 0.82, 0.00, 1)

    -- ── Rahmen: Achievement-IconFrame ──
    local frame = btn:CreateTexture(nil, "OVERLAY", nil, 0)
    frame:SetTexture("Interface\\AchievementFrame\\UI-Achievement-IconFrame")
    frame:SetAllPoints(btn)
    frame:SetTexCoord(0, 0.5625, 0, 0.5625)

    -- ── Hover-Highlight ──
    local hl = btn:CreateTexture(nil, "HIGHLIGHT", nil, 0)
    hl:SetTexture("Interface\\Buttons\\WHITE8X8")
    hl:SetAllPoints(btn)
    hl:SetVertexColor(1, 1, 1, 0.18)
    hl:SetBlendMode("ADD")

    -- ── Klick-Feedback ──
    local pushed = btn:CreateTexture(nil, "ARTWORK", nil, 1)
    pushed:SetTexture("Interface\\Buttons\\WHITE8X8")
    pushed:SetAllPoints(btn)
    pushed:SetVertexColor(0, 0, 0, 0.35)
    pushed:Hide()

    -- ============================================================
    -- DRAG: um die Minimap rotieren
    -- ============================================================
    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")

    local dragging = false
    local dragThreshold = 0.15  -- Sekunden bis Drag aktiv

    btn:SetScript("OnDragStart", function(self)
        dragging = false
        -- Erst nach threshold als Drag werten
        C_Timer.After(dragThreshold, function()
            if IsMouseButtonDown("LeftButton") then
                dragging = true
                self:SetScript("OnUpdate", function(s)
                    local mx, my = Minimap:GetCenter()
                    local cx, cy = GetCursorPosition()
                    local scale  = UIParent:GetEffectiveScale()
                    local angle  = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
                    SetButtonPosition(s, angle)
                    SaveAngle(angle)
                end)
            end
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        dragging = false
        self:SetScript("OnUpdate", nil)
    end)

    -- ============================================================
    -- KLICK: Nexus UI öffnen / schließen
    -- ============================================================
    btn:SetScript("OnClick", function(self, mouseBtn)
        if dragging then return end
        if mouseBtn == "LeftButton" then
            pushed:Show()
            C_Timer.After(0.1, function() pushed:Hide() end)
            -- Toggle: direkte API nutzen falls verfügbar
            if _G.Nexus_UI and _G.Nexus_UI.Toggle then
                _G.Nexus_UI.Toggle()
            elseif SlashCmdList["NEXUS"] then
                SlashCmdList["NEXUS"]("ui")
            end
        end
    end)

    -- ============================================================
    -- TOOLTIP
    -- ============================================================
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("|cffFFD700Nexus|r")
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffFFFFFFLinksklick:|r Nexus öffnen/schließen", 1, 1, 1)
        GameTooltip:AddLine("|cffFFFFFFZiehen:|r Position anpassen", 1, 1, 1)
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- ============================================================
    -- STARTPOSITION
    -- ============================================================
    SetButtonPosition(btn, GetSavedAngle())

    return btn
end

-- ============================================================
-- INITIALISIERUNG (nach PLAYER_ENTERING_WORLD)
-- ============================================================
local mmInitFrame = CreateFrame("Frame", "NexusMinimapInitFrame")
mmInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
mmInitFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        -- Kurze Verzögerung: NexusConfig muss geladen sein
        C_Timer.After(0.3, function()
            local btn = CreateMinimapButton()
            _G.NexusMinimapBtn = btn
        end)
    end
end)

print("[Nexus MinimapButton] Modul geladen")
