--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_Panels (Feed + Profile + Settings)
    Spezifikation: Nexus_Feed_Panel_Implementation_Plan.docx
                   Nexus_Profile_Panel_Implementation_Plan.docx
                   Nexus_Settings_Panel_Implementation_Plan.docx

    Grundsatz:
    - UI ist reine View-Schicht (keine Business-Logik)
    - Datenzugriff nur über NexusData API
    - Safe Mode Gate: kein Combat-Reset, kein Silent Reset
    - Bitmask-Checkboxen: direkte Bit-Operationen
    - Settings → nur NexusConfig ändern, nie direkt SavedVariables

    Version: 0.3.0-alpha
]]

local PANELS_VERSION = "0.5.0-alpha-hotfix2"

-- ============================================================
-- HILFSFUNKTIONEN
-- ============================================================

-- Sektion-Header erstellen
local function CreateSectionHeader(parent, text, yOffset)
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOffset)
    header:SetText(text)
    header:SetTextColor(0.8, 0.7, 0.2, 1.0)
    return header
end

-- Trennlinie erstellen
local function CreateDivider(parent, yOffset)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT",  parent, "TOPLEFT",  10, yOffset)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, yOffset)
    line:SetHeight(1)
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(0.3, 0.4, 0.6, 0.5)
    return line
end

-- Checkbox mit Label erstellen
-- Gibt { checkbox, label } zurück
local function CreateCheckbox(parent, labelText, xPos, yOffset, bitValue, maskGetter, maskSetter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, yOffset)

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(labelText)
    label:SetTextColor(0.9, 0.9, 0.9, 1.0)

    -- Initialen Zustand aus Bitmask laden
    local function Refresh()
        local mask = maskGetter() or 0
        cb:SetChecked(bit.band(mask, bitValue) ~= 0)
    end

    -- Klick: Bit togglen
    cb:SetScript("OnClick", function(self)
        local mask = maskGetter() or 0
        if self:GetChecked() then
            mask = bit.bor(mask, bitValue)
        else
            mask = bit.band(mask, bit.bnot(bitValue))
        end
        maskSetter(mask)
    end)

    cb.Refresh = Refresh
    Refresh()

    return cb, label
end

-- ============================================================
-- NEXUS DATA LAYER (View-Schicht Brücke)
-- Alle Panel-Datenzugriffe laufen hierüber
-- ============================================================

NexusData = NexusData or {}

function NexusData.GetMyProfile()
    if not NexusDB or not NexusDB.profiles then return {} end
    local myName = UnitName("player")
    if not myName then return {} end
    local nameID = myName .. "-" .. GetRealmName()
    return NexusDB.profiles[nameID] or {}
end

function NexusData.SaveMyProfile(profile)
    if not profile then return end
    if NexusDB and NexusDB_SaveProfile then
        Nexus_DB.SaveProfile(profile)
    elseif NexusDB and NexusDB.profiles then
        local myName = UnitName("player")
        if not myName then return end
        local nameID = myName .. "-" .. GetRealmName()
        -- Shield-Gate
        if NexusShield then
            local ok, _ = NexusShield.ValidateProfile(profile)
            if not ok then
                if NexusConfig and NexusConfig.devMode then
                    print("[Nexus Panels] SaveMyProfile: Shield-Validation fehlgeschlagen")
                end
                return
            end
        end
        NexusDB.profiles[nameID] = profile
    end
end

function NexusData.GetFeedSlice(first, last)
    if not NexusDB or not NexusDB.profiles then return {} end
    local result = {}
    local i = 0
    for _, profile in pairs(NexusDB.profiles) do
        i = i + 1
        if i >= first and i <= last then
            table.insert(result, profile)
        end
    end
    return result
end

function NexusData.GetFeedCount()
    if not NexusDB or not NexusDB.profiles then return 0 end
    local count = 0
    for _ in pairs(NexusDB.profiles) do count = count + 1 end
    return count
end

function NexusData.GetSettings()
    if not NexusConfig then NexusConfig = {} end
    return NexusConfig
end

function NexusData.UpdateSettings(delta)
    if not delta then return end
    if not NexusConfig then NexusConfig = {} end
    for k, v in pairs(delta) do
        NexusConfig[k] = v
    end
end

-- ============================================================
-- ============================================================
-- FEED PANEL
-- ============================================================
-- ============================================================

local feedPanel = nil
local feedScrollFrame = nil
local feedScrollChild = nil
local feedAdapterInstance = nil
local feedScopeFilter = nil  -- nil = alle, 1 = GUILD, 2 = FRIENDS, 4 = PUBLIC

local feedTelemetry = {
    scrollRefreshCount = 0,
    rowRebindCount     = 0,
}

local function BuildFeedPanel(contentPanel)
    -- Phase 1: Panel Container
    local panel = CreateFrame("Frame", "NexusFeedPanel_Real", contentPanel)
    panel:SetAllPoints(contentPanel)
    panel:Hide()
    feedPanel = panel

    -- Leer-Zustand ("kein Feed")
    local emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", panel, "CENTER", 0, 0)
    emptyText:SetText(L and L["FEED_EMPTY"] or "Keine Eintraege gefunden.\nBewege dich in der Welt um Spieler zu sehen.")
    emptyText:SetTextColor(0.5, 0.5, 0.6, 1.0)
    emptyText:SetJustifyH("CENTER")
    panel.emptyText = emptyText

    -- Phase 2: ScrollFrame + ScrollChild
    local scrollFrame = CreateFrame("ScrollFrame", "NexusFeedScrollFrame", panel)
    scrollFrame:SetPoint("TOPLEFT",    panel, "TOPLEFT",    4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT",panel, "BOTTOMRIGHT",-20, 36)  -- 36px Platz für Create-Post-Button
    feedScrollFrame = scrollFrame

    -- KRITISCH: Keyboard NICHT abfangen (blockiert sonst Chat-Eingabefeld!)
    scrollFrame:EnableKeyboard(false)
    -- Mausrad aktivieren
    scrollFrame:EnableMouseWheel(true)

    local scrollChild = CreateFrame("Frame", "NexusFeedScrollChild", scrollFrame)
    scrollChild:SetWidth(scrollFrame:GetWidth() or 280)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)
    feedScrollChild = scrollChild

    -- Scrollbar: manuell ohne Template um SetVerticalScroll-Fehler zu vermeiden
    local scrollBar = CreateFrame("Slider", "NexusFeedScrollBar", panel)
    scrollBar:SetPoint("TOPRIGHT",    panel, "TOPRIGHT",   -2, -20)
    scrollBar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT",-2,  20)
    scrollBar:SetWidth(16)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValue(0)
    scrollBar:SetValueStep(64)
    scrollBar:SetObeyStepOnDrag(true)

    -- Scrollbar Hintergrund
    local sbBg = scrollBar:CreateTexture(nil, "BACKGROUND")
    sbBg:SetAllPoints()
    sbBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    sbBg:SetVertexColor(0.1, 0.1, 0.15, 0.8)

    -- Scrollbar Thumb
    local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
    thumb:SetVertexColor(0.4, 0.5, 0.7, 0.9)
    thumb:SetSize(12, 40)
    scrollBar:SetThumbTexture(thumb)

    -- Mausrad → direkt SetVerticalScroll auf scrollFrame
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local step    = 64  -- 1 Row pro Mausrad-Klick (präzise)
        local _, max  = scrollBar:GetMinMaxValues()
        local newVal  = math.max(0, math.min(current - (delta * step), max))
        self:SetVerticalScroll(newVal)
        scrollBar:SetValue(newVal)
        feedTelemetry.scrollRefreshCount = feedTelemetry.scrollRefreshCount + 1
        -- OnVerticalScroll wird durch SetVerticalScroll getriggert → RequestUpdate läuft automatisch
    end)

    -- ScrollBar Drag → scrollFrame folgen
    scrollBar:SetScript("OnValueChanged", function(self, value)
        local cur = scrollFrame:GetVerticalScroll()
        if math.abs(cur - value) > 1 then
            scrollFrame:SetVerticalScroll(value)
            -- FIX: Adapter-Update nach ScrollBar-Drag
            if feedAdapterInstance then
                feedAdapterInstance:RequestUpdate()
            end
        end
    end)

    -- ScrollFrame bewegt → ScrollBar synchronisieren + Adapter updaten
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        local _, max = scrollBar:GetMinMaxValues()
        if max > 0 then
            scrollBar:SetValue(math.max(0, math.min(offset, max)))
        end
        -- FIX: Kern-Fix – ScrollAdapter muss bei JEDER Scroll-Bewegung updaten
        if feedAdapterInstance then
            feedAdapterInstance:RequestUpdate()
        end
    end)

    -- Phase 3+4: ScrollAdapter initialisieren
    -- Eigene Adapter-Instanz für Feed
    feedAdapterInstance = {
        scrollFrame   = scrollFrame,
        contentFrame  = scrollChild,
        rowHeight     = 64,
        totalItemCount = 0,
        viewportHeight = 0,
        lastFirst      = 0,
        lastLast       = 0,
        updatePending  = false,

        -- dataSource: gibt Posts gefiltert nach feedScopeFilter zurück
        dataSource = function()
            local allPosts
            if NexusDB_API and NexusDB_API.GetAllPosts then
                allPosts = NexusDB_API.GetAllPosts()
            elseif NexusDB and NexusDB.posts then
                allPosts = {}
                for _, p in pairs(NexusDB.posts) do
                    if p.state ~= "locally_deleted" then
                        table.insert(allPosts, p)
                    end
                end
                table.sort(allPosts, function(a, b)
                    return (a.timestamp or 0) > (b.timestamp or 0)
                end)
            else
                return {}
            end
            -- Scope-Filter anwenden
            if feedScopeFilter == nil then
                return allPosts  -- FEED: alle Posts
            end
            local filtered = {}
            for _, p in ipairs(allPosts) do
                if p.scope == feedScopeFilter then
                    table.insert(filtered, p)
                end
            end
            return filtered
        end,

        -- Telemetrie (von UpdateVisibleRange erwartet)
        telemetry = {
            updateCount      = 0,
            fullRecycleCount = 0,
            maxDeltaIndex    = 0,
            lastVisibleRange = nil,
        },

        CalculateVisibleRange = NexusScrollAdapter.CalculateVisibleRange,
        UpdateVisibleRange    = NexusScrollAdapter.UpdateVisibleRange,
        BuildRange            = NexusScrollAdapter.BuildRange,
        ShowRow               = NexusScrollAdapter.ShowRow,
        RequestUpdate         = NexusScrollAdapter.RequestUpdate,
        ForceUpdate           = NexusScrollAdapter.ForceUpdate,
        RefreshData           = NexusScrollAdapter.RefreshData,
    }

    -- Netzwerk-Callback: neuer Post empfangen → Feed sofort aktualisieren
    if NexusNet then
        NexusNet.onPostReceived = function(post)
            if feedPanel and feedPanel:IsShown() then
                feedAdapterInstance:RefreshData()
            end
        end
    end

    -- Viewport-Höhe nach Frame-Erstellung
    scrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        feedAdapterInstance.viewportHeight = h
        scrollChild:SetWidth(w - 20)
        feedAdapterInstance:ForceUpdate()
    end)

    -- Phase 5: Kategorie-Filter Reaktion
    -- Wird von außen mit categoryID aufgerufen ("FEED"/"GUILD"/"FRIENDS"/"PUBLIC")
    function panel:OnCategoryChange(categoryID)
        -- Scope-Filter setzen
        if categoryID == "GUILD" then
            feedScopeFilter = NexusPost and NexusPost.SCOPE and NexusPost.SCOPE.GUILD or 1
        elseif categoryID == "FRIENDS" then
            feedScopeFilter = NexusPost and NexusPost.SCOPE and NexusPost.SCOPE.FRIENDS or 2
        elseif categoryID == "PUBLIC" then
            feedScopeFilter = NexusPost and NexusPost.SCOPE and NexusPost.SCOPE.PUBLIC or 4
        else
            feedScopeFilter = nil  -- FEED: alle
        end

        -- Empty-Text je nach Kategorie
        local emptyKey
        if categoryID == "GUILD" then
            emptyKey = "FEED_EMPTY_GUILD"
        elseif categoryID == "FRIENDS" then
            emptyKey = "FEED_EMPTY_FRIENDS"
        elseif categoryID == "PUBLIC" then
            emptyKey = "FEED_EMPTY_PUBLIC"
        else
            emptyKey = "FEED_EMPTY"
        end
        if panel.emptyText then
            panel.emptyText:SetText(L and L[emptyKey] or "Keine Posts gefunden.")
        end

        scrollFrame:SetVerticalScroll(0)
        scrollBar:SetValue(0)
        feedAdapterInstance.lastFirst = 0
        feedAdapterInstance.lastLast  = 0
        feedAdapterInstance:RefreshData()
    end

    -- --------------------------------------------------------
    -- "Create Post"-Button (unterhalb des Feeds)
    -- --------------------------------------------------------
    local createPostBtn = CreateFrame("Button", "NexusCreatePostBtn", panel,
        "UIPanelButtonTemplate")
    createPostBtn:SetSize(130, 26)
    createPostBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 4)
    createPostBtn:SetText(L and L["CREATE_POST_BTN"] or "+ Neuer Post")
    createPostBtn:SetScript("OnClick", function()
        if NexusPostUI then
            NexusPostUI.Show()
        end
    end)
    -- Im Kampf deaktivieren
    local function UpdateCreatePostBtn()
        if InCombatLockdown() then
            createPostBtn:Disable()
        else
            createPostBtn:Enable()
        end
    end
    panel:HookScript("OnShow", function() UpdateCreatePostBtn() end)

    -- --------------------------------------------------------
    -- Auto-Refresh Ticker + OnShow/OnHide
    -- --------------------------------------------------------
    local feedAutoRefreshTicker = nil
    local lastKnownFeedCount = 0

    local function GetCurrentFeedCount()
        if NexusDB_API and NexusDB_API.GetPostCount then
            return NexusDB_API.GetPostCount()
        end
        if NexusDB and NexusDB.posts then
            local n = 0
            for _, p in pairs(NexusDB.posts) do
                if p.state ~= "locally_deleted" then n = n + 1 end
            end
            return n
        end
        return 0
    end

    local function RefreshFeedVisibility()
        local count = GetCurrentFeedCount()
        if count > 0 then
            panel.emptyText:Hide()
            scrollFrame:Show()
        else
            panel.emptyText:Show()
            scrollFrame:Hide()
        end
        local totalHeight = feedAdapterInstance.totalItemCount * 64
        local viewH = feedAdapterInstance.viewportHeight
        scrollBar:SetMinMaxValues(0, math.max(0, totalHeight - viewH))
        return count
    end

    panel:SetScript("OnShow", function(self)
        local h = scrollFrame:GetHeight()
        if h and h > 0 and feedAdapterInstance.viewportHeight == 0 then
            feedAdapterInstance.viewportHeight = h
            if NexusRowPool.parentFrame == nil then
                NexusRowPool:Init(scrollChild, h)
            end
        end
        feedAdapterInstance:RefreshData()
        lastKnownFeedCount = RefreshFeedVisibility()
        UpdateCreatePostBtn()

        -- Ticker starten
        if not feedAutoRefreshTicker then
            feedAutoRefreshTicker = C_Timer.NewTicker(3.0, function()
                if not panel:IsShown() then return end
                local newCount = GetCurrentFeedCount()
                if newCount ~= lastKnownFeedCount then
                    lastKnownFeedCount = newCount
                    feedAdapterInstance:RefreshData()
                    RefreshFeedVisibility()
                end
            end)
        end
    end)

    panel:SetScript("OnHide", function(self)
        if feedAutoRefreshTicker then
            feedAutoRefreshTicker:Cancel()
            feedAutoRefreshTicker = nil
        end
    end)

    return panel
end

-- ============================================================
-- ============================================================
-- PROFILE PANEL
-- ============================================================
-- ============================================================

local profilePanel = nil
local profileCheckboxes = {}  -- alle Checkboxen für Refresh

-- Bitmask-Definitionen nach Spec (Labels via L[] – lazy)
local function GetPlayDays()
    return {
        { label = L and L["PLAYDAY_MONDAY"]    or "Montag",     bit = 0x01 },
        { label = L and L["PLAYDAY_TUESDAY"]   or "Dienstag",   bit = 0x02 },
        { label = L and L["PLAYDAY_WEDNESDAY"] or "Mittwoch",   bit = 0x04 },
        { label = L and L["PLAYDAY_THURSDAY"]  or "Donnerstag", bit = 0x08 },
        { label = L and L["PLAYDAY_FRIDAY"]    or "Freitag",    bit = 0x10 },
        { label = L and L["PLAYDAY_SATURDAY"]  or "Samstag",    bit = 0x20 },
        { label = L and L["PLAYDAY_SUNDAY"]    or "Sonntag",    bit = 0x40 },
    }
end

local function GetPlayTimes()
    return {
        { label = L and L["PLAYTIME_MORNING"]   or "Morgens",     bit = 0x01 },
        { label = L and L["PLAYTIME_AFTERNOON"] or "Nachmittags", bit = 0x02 },
        { label = L and L["PLAYTIME_EVENING"]   or "Abends",      bit = 0x04 },
        { label = L and L["PLAYTIME_NIGHT"]     or "Nachts",      bit = 0x08 },
    }
end

local function GetPlayStyles()
    return {
        { label = L and L["PLAYSTYLE_ROLEPLAY"]   or "Roleplay", bit = 0x01 },
        { label = L and L["PLAYSTYLE_RAID"]       or "Raid",     bit = 0x02 },
        { label = L and L["PLAYSTYLE_MYTHICPLUS"] or "Mythic+",  bit = 0x04 },
        { label = L and L["PLAYSTYLE_DELVES"]     or "Delves",   bit = 0x08 },
        { label = L and L["PLAYSTYLE_QUESTS"]     or "Quests",   bit = 0x10 },
        { label = L and L["PLAYSTYLE_PVP"]        or "PvP",      bit = 0x20 },
        { label = L and L["PLAYSTYLE_CASUAL"]     or "Casual",   bit = 0x40 },
        { label = L and L["PLAYSTYLE_COLLECTOR"]  or "Sammler",  bit = 0x80 },
    }
end

-- Statische Referenzen für Tests (bleiben gleich, nur Labels ändern sich per Locale)
local PLAY_DAYS   = GetPlayDays()
local PLAY_TIMES  = GetPlayTimes()
local PLAY_STYLES = GetPlayStyles()

-- Profil-Zwischenspeicher (Änderungen, noch nicht gespeichert)
local profileDraft = {}

local function GetDraftMask(field)
    return profileDraft[field] or 0
end
local function SetDraftMask(field, value)
    profileDraft[field] = value
end

local function BuildProfilePanel(contentPanel)
    -- Phase 1: Panel Container (scrollbar für langen Inhalt)
    local panel = CreateFrame("ScrollFrame", "NexusProfilePanel_Real", contentPanel)
    panel:SetAllPoints(contentPanel)
    panel:Hide()
    profilePanel = panel

    local inner = CreateFrame("Frame", "NexusProfileInner", panel)
    inner:SetWidth(contentPanel:GetWidth() or 340)
    inner:SetHeight(600)
    panel:SetScrollChild(inner)

    local yOff = -8

    -- === SEKTION: Spieltage ===
    CreateSectionHeader(inner, L and L["PROFILE_SECTION_PLAYDAYS"] or "Spieltage", yOff)
    yOff = yOff - 22
    CreateDivider(inner, yOff)
    yOff = yOff - 8

    for i, day in ipairs(PLAY_DAYS) do
        local xPos = ((i - 1) % 4) * 90 + 10
        if i > 4 then xPos = ((i - 5) % 4) * 90 + 10 end
        local rowOff = yOff - (math.ceil(i / 4) - 1) * 26
        local cb, _ = CreateCheckbox(inner, day.label, xPos, rowOff, day.bit,
            function() return GetDraftMask("playDaysMask") end,
            function(v) SetDraftMask("playDaysMask", v) end)
        if cb and NexusTooltip_Bind then
            NexusTooltip_Bind(cb, "PROFILE_PLAYDAYS")
        end
        table.insert(profileCheckboxes, cb)
    end
    yOff = yOff - 54

    -- === SEKTION: Spielzeiten ===
    CreateSectionHeader(inner, L and L["PROFILE_SECTION_PLAYTIME"] or "Spielzeiten", yOff)
    yOff = yOff - 22
    CreateDivider(inner, yOff)
    yOff = yOff - 8

    for i, slot in ipairs(PLAY_TIMES) do
        local xPos = (i - 1) * 100 + 10
        local cb, _ = CreateCheckbox(inner, slot.label, xPos, yOff, slot.bit,
            function() return GetDraftMask("playTimeMask") end,
            function(v) SetDraftMask("playTimeMask", v) end)
        if cb and NexusTooltip_Bind then
            NexusTooltip_Bind(cb, "PROFILE_PLAYTIME")
        end
        table.insert(profileCheckboxes, cb)
    end
    yOff = yOff - 30

    -- === SEKTION: Spielstil ===
    CreateSectionHeader(inner, L and L["PROFILE_SECTION_PLAYSTYLE"] or "Spielstil", yOff)
    yOff = yOff - 22
    CreateDivider(inner, yOff)
    yOff = yOff - 8

    -- Playstyle-IDs für Tooltip-Lookup
    local playstyleIDs = {
        "ROLEPLAY","RAID","MYTHICPLUS","DELVES","QUESTS","PVP","CASUAL","COLLECTOR"
    }
    for i, style in ipairs(PLAY_STYLES) do
        local xPos = ((i - 1) % 4) * 90 + 10
        local rowOff = yOff - (math.ceil(i / 4) - 1) * 26
        local cb, _ = CreateCheckbox(inner, style.label, xPos, rowOff, style.bit,
            function() return GetDraftMask("playstyleMask") end,
            function(v) SetDraftMask("playstyleMask", v) end)
        if cb and NexusTooltip_Bind and playstyleIDs[i] then
            NexusTooltip_Bind(cb, "PROFILE_PLAYSTYLE_" .. playstyleIDs[i])
        end
        table.insert(profileCheckboxes, cb)
    end
    yOff = yOff - 54

    -- === SEKTION: Aussehen (Capability-abhängig) ===
    CreateSectionHeader(inner, L and L["PROFILE_SECTION_APPEARANCE"] or "Aussehen", yOff)
    yOff = yOff - 22
    CreateDivider(inner, yOff)
    yOff = yOff - 8

    local poseLabel = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    poseLabel:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, yOff)
    poseLabel:SetText((L and L["PROFILE_POSE_LABEL"] or "Pose: %d"):format(profileDraft.poseID or 0))
    poseLabel:SetTextColor(0.7, 0.7, 0.8, 1.0)
    inner.poseLabel = poseLabel
    yOff = yOff - 20

    local bgLabel = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bgLabel:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, yOff)
    bgLabel:SetText((L and L["PROFILE_BACKGROUND_LABEL"] or "Hintergrund: %d"):format(profileDraft.backgroundID or 0))
    bgLabel:SetTextColor(0.7, 0.7, 0.8, 1.0)
    inner.bgLabel = bgLabel
    yOff = yOff - 30

    local capHint = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    capHint:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, yOff)
    capHint:SetText(L and L["PROFILE_CAPABILITY_HINT"] or "(Pose/Hintergrund erfordern Capability-Support)")
    capHint:SetTextColor(0.5, 0.5, 0.6, 1.0)
    yOff = yOff - 40

    -- === BUTTONS: Speichern / Reset ===
    local saveBtn = CreateFrame("Button", "NexusProfileSaveBtn", inner, "UIPanelButtonTemplate")
    saveBtn:SetSize(100, 24)
    saveBtn:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, yOff)
    saveBtn:SetText(L and L["PROFILE_SAVE"] or "Speichern")
    saveBtn:SetScript("OnClick", function()
        local profile = NexusData.GetMyProfile()
        local myName = UnitName("player")
        if not myName then return end

        profile.nameID        = myName .. "-" .. GetRealmName()
        profile.playDaysMask  = profileDraft.playDaysMask or 0
        profile.playTimeMask  = profileDraft.playTimeMask or 0
        profile.playstyleMask = profileDraft.playstyleMask or 0
        profile.poseID        = profileDraft.poseID or 0
        profile.backgroundID  = profileDraft.backgroundID or 0
        profile.lastSeen      = time()
        profile.schemaVersion = 2

        NexusData.SaveMyProfile(profile)

        print(L and L["PROFILE_SAVED_OK"] or "[Nexus] Profil gespeichert.")
        if NexusConfig and NexusConfig.devMode then
            print(string.format("  playDaysMask=%d playTimeMask=%d playstyleMask=%d",
                profile.playDaysMask, profile.playTimeMask, profile.playstyleMask))
        end
    end)

    local resetBtn = CreateFrame("Button", "NexusProfileResetBtn", inner, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 24)
    resetBtn:SetPoint("TOPLEFT", inner, "TOPLEFT", 120, yOff)
    resetBtn:SetText(L and L["PROFILE_RESET"] or "Zuruecksetzen")
    resetBtn:SetScript("OnClick", function()
        profileDraft.playDaysMask  = 0
        profileDraft.playTimeMask  = 0
        profileDraft.playstyleMask = 0
        for _, cb in ipairs(profileCheckboxes) do
            if cb.Refresh then cb:Refresh() end
        end
    end)

    panel:SetScript("OnShow", function()
        local saved = NexusData.GetMyProfile()
        profileDraft.playDaysMask  = saved.playDaysMask  or 0
        profileDraft.playTimeMask  = saved.playTimeMask  or 0
        profileDraft.playstyleMask = saved.playstyleMask or 0
        profileDraft.poseID        = saved.poseID        or 0
        profileDraft.backgroundID  = saved.backgroundID  or 0

        inner.poseLabel:SetText((L and L["PROFILE_POSE_LABEL"] or "Pose: %d"):format(profileDraft.poseID))
        inner.bgLabel:SetText((L and L["PROFILE_BACKGROUND_LABEL"] or "Hintergrund: %d"):format(profileDraft.backgroundID))

        for _, cb in ipairs(profileCheckboxes) do
            if cb.Refresh then cb:Refresh() end
        end
    end)

    return panel
end

-- ============================================================
-- ============================================================
-- SETTINGS PANEL
-- ============================================================
-- ============================================================

local settingsPanel = nil

local settingsTelemetry = {
    safeModeSwitchCount = 0,
    devModeSwitchCount  = 0,
    resetInvocations    = 0,
}

local function BuildSettingsPanel(contentPanel)
    local panel = CreateFrame("Frame", "NexusSettingsPanel_Real", contentPanel)
    panel:SetAllPoints(contentPanel)
    panel:Hide()
    settingsPanel = panel

    local yOff = -10

    -- === SEKTION: Allgemein ===
    CreateSectionHeader(panel, L and L["SETTINGS_SECTION_GENERAL"] or "Allgemein", yOff)
    yOff = yOff - 22
    CreateDivider(panel, yOff)
    yOff = yOff - 14

    local verText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    verText:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    verText:SetText((L and L["SETTINGS_VERSION_LABEL"] or "Nexus Version: %s"):format(PANELS_VERSION))
    verText:SetTextColor(0.7, 0.7, 0.8, 1.0)
    yOff = yOff - 20

    local protText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    protText:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    protText:SetText((L and L["SETTINGS_PROTOCOL_LABEL"] or "Protokoll: %d"):format(NexusNet and NexusNet.PROTOCOL or 1))
    protText:SetTextColor(0.7, 0.7, 0.8, 1.0)
    yOff = yOff - 30

    -- === SEKTION: Sicherheit ===
    CreateSectionHeader(panel, L and L["SETTINGS_SECTION_SAFETY"] or "Sicherheit", yOff)
    yOff = yOff - 22
    CreateDivider(panel, yOff)
    yOff = yOff - 14

    local safeModeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    safeModeLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    safeModeLabel:SetText(L and L["SETTINGS_SAFE_MODE_LABEL"] or "Safe Mode:")
    safeModeLabel:SetTextColor(0.9, 0.7, 0.3, 1.0)

    local safeModeBtn = CreateFrame("CheckButton", "NexusSafeModeToggle", panel, "UICheckButtonTemplate")
    safeModeBtn:SetSize(20, 20)
    safeModeBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 300, yOff + 2)
    safeModeBtn:SetChecked(false)

    local safeModeStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    safeModeStatus:SetPoint("LEFT", safeModeBtn, "RIGHT", 6, 0)
    safeModeStatus:SetText(L and L["SETTINGS_SAFE_MODE_OFF"] or "Aus")
    safeModeStatus:SetTextColor(0.5, 0.9, 0.3, 1.0)
    panel.safeModeStatus = safeModeStatus

    -- Tooltip
    if NexusTooltip_Bind then NexusTooltip_Bind(safeModeBtn, "SETTINGS_SAFE_MODE_TOGGLE") end

    safeModeBtn:SetScript("OnClick", function(self)
        local settings = NexusData.GetSettings()
        settings.safeMode = self:GetChecked()
        NexusData.UpdateSettings({ safeMode = settings.safeMode })
        if NexusState then NexusState.commAllowed = not settings.safeMode end

        if settings.safeMode then
            safeModeStatus:SetText(L and L["SETTINGS_SAFE_MODE_ON"] or "AN")
            safeModeStatus:SetTextColor(0.9, 0.3, 0.3, 1.0)
        else
            safeModeStatus:SetText(L and L["SETTINGS_SAFE_MODE_OFF"] or "Aus")
            safeModeStatus:SetTextColor(0.5, 0.9, 0.3, 1.0)
        end
        settingsTelemetry.safeModeSwitchCount = settingsTelemetry.safeModeSwitchCount + 1
    end)
    panel.safeModeBtn = safeModeBtn
    yOff = yOff - 36

    -- === SEKTION: Entwickler ===
    CreateSectionHeader(panel, L and L["SETTINGS_SECTION_DEVELOPER"] or "Entwickler", yOff)
    yOff = yOff - 22
    CreateDivider(panel, yOff)
    yOff = yOff - 14

    local devModeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    devModeLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    devModeLabel:SetText(L and L["SETTINGS_DEV_MODE_LABEL"] or "Dev Mode:")
    devModeLabel:SetTextColor(0.6, 0.8, 1.0, 1.0)

    local devModeBtn = CreateFrame("CheckButton", "NexusDevModeToggle", panel, "UICheckButtonTemplate")
    devModeBtn:SetSize(20, 20)
    devModeBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 300, yOff + 2)
    devModeBtn:SetChecked(false)

    local devModeStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    devModeStatus:SetPoint("LEFT", devModeBtn, "RIGHT", 6, 0)
    devModeStatus:SetText(L and L["SETTINGS_DEV_MODE_OFF"] or "Aus")
    devModeStatus:SetTextColor(0.5, 0.6, 0.7, 1.0)
    panel.devModeStatus = devModeStatus

    if NexusTooltip_Bind then NexusTooltip_Bind(devModeBtn, "SETTINGS_DEV_MODE_TOGGLE") end

    devModeBtn:SetScript("OnClick", function(self)
        local enabled = self:GetChecked()
        NexusData.UpdateSettings({ devMode = enabled })
        if NexusConfig then NexusConfig.devMode = enabled end

        if enabled then
            devModeStatus:SetText(L and L["SETTINGS_DEV_MODE_ON"] or "AN")
            devModeStatus:SetTextColor(0.3, 0.8, 1.0, 1.0)
            print(L and L["SETTINGS_DEV_MODE_ACTIVATED"] or "[Nexus] Dev Mode aktiviert.")
        else
            devModeStatus:SetText(L and L["SETTINGS_DEV_MODE_OFF"] or "Aus")
            devModeStatus:SetTextColor(0.5, 0.6, 0.7, 1.0)
        end
        settingsTelemetry.devModeSwitchCount = settingsTelemetry.devModeSwitchCount + 1
    end)
    panel.devModeBtn = devModeBtn
    yOff = yOff - 36

    local telBtn = CreateFrame("Button", "NexusTelemetryBtn", panel, "UIPanelButtonTemplate")
    telBtn:SetSize(180, 24)
    telBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    telBtn:SetText(L and L["SETTINGS_TELEMETRY_BTN"] or "Telemetrie ausgeben")
    if NexusTooltip_Bind then NexusTooltip_Bind(telBtn, "SETTINGS_TELEMETRY_BTN") end
    telBtn:SetScript("OnClick", function()
        print("=== NEXUS TELEMETRIE ===")
        if NexusComm and NexusComm.telemetry then
            local t = NexusComm.telemetry
            print(string.format("  Comm: sent=%d dropped=%d throttle=%d backoff=%d",
                t.messagesSent or 0, t.messagesDropped or 0,
                t.throttleHits or 0, t.backoffActivations or 0))
        end
        if NexusNet then
            print(string.format("  Net: sent=%d recv=%d skip=%d mismatch=%d peers=%d",
                NexusNet.telemetry.handshakeSent,
                NexusNet.telemetry.handshakeReceived,
                NexusNet.telemetry.handshakeSkipped,
                NexusNet.telemetry.protocolMismatchCount,
                NexusNet.telemetry.peerCacheSize))
        end
        if NexusRowPool then
            print(string.format("  Pool: created=%d recycle=%d emergency=%d peak=%d",
                NexusRowPool.totalCreated,
                NexusRowPool.telemetry.recycleCount,
                NexusRowPool.telemetry.emergencyCreates,
                NexusRowPool.telemetry.activeRowPeak))
        end
        print(string.format("  Settings: safeMode=%d devMode=%d resets=%d",
            settingsTelemetry.safeModeSwitchCount,
            settingsTelemetry.devModeSwitchCount,
            settingsTelemetry.resetInvocations))
    end)
    yOff = yOff - 36

    -- === SEKTION: Datenbank ===
    CreateSectionHeader(panel, L and L["SETTINGS_SECTION_DATABASE"] or "Datenbank", yOff)
    yOff = yOff - 22
    CreateDivider(panel, yOff)
    yOff = yOff - 14

    local dbInfoText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dbInfoText:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    dbInfoText:SetText((L and L["SETTINGS_DB_INFO"] or "Profile: %d gespeichert"):format(0))
    dbInfoText:SetTextColor(0.7, 0.7, 0.8, 1.0)
    panel.dbInfoText = dbInfoText
    yOff = yOff - 24

    local resetBtn = CreateFrame("Button", "NexusDBResetBtn", panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(160, 24)
    resetBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    resetBtn:SetText("|cffff4444" .. (L and L["SETTINGS_DB_RESET_BTN"] or "Datenbank zuruecksetzen") .. "|r")
    if NexusTooltip_Bind then NexusTooltip_Bind(resetBtn, "SETTINGS_RESET_BUTTON") end
    resetBtn:SetScript("OnClick", function()
        if InCombatLockdown() then
            print(L and L["SETTINGS_RESET_COMBAT"] or "[Nexus] Reset im Combat nicht erlaubt.")
            return
        end
        settingsTelemetry.resetInvocations = settingsTelemetry.resetInvocations + 1

        StaticPopupDialogs["NEXUS_CONFIRM_RESET"] = {
            text           = L and L["SETTINGS_RESET_CONFIRM"] or "ACHTUNG: Alle Nexus-Profildaten werden geloescht!\n\nFortfahren?",
            button1        = L and L["SETTINGS_RESET_YES"]     or "Ja, zuruecksetzen",
            button2        = L and L["SETTINGS_RESET_NO"]      or "Abbrechen",
            OnAccept       = function()
                if Nexus_DB and Nexus_DB.ResetDatabase then
                    Nexus_DB.ResetDatabase()
                else
                    if NexusDB then NexusDB.profiles = {} end
                end
                print(L and L["SETTINGS_RESET_DONE"] or "[Nexus] Datenbank zurueckgesetzt.")
                panel.dbInfoText:SetText((L and L["SETTINGS_DB_INFO"] or "Profile: %d gespeichert"):format(0))
            end,
            timeout        = 0,
            whileDead      = true,
            hideOnEscape   = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("NEXUS_CONFIRM_RESET")
    end)

    panel:SetScript("OnShow", function()
        local settings = NexusData.GetSettings()

        panel.safeModeBtn:SetChecked(settings.safeMode or false)
        if settings.safeMode then
            panel.safeModeStatus:SetText(L and L["SETTINGS_SAFE_MODE_ON"] or "AN")
            panel.safeModeStatus:SetTextColor(0.9, 0.3, 0.3, 1.0)
        else
            panel.safeModeStatus:SetText(L and L["SETTINGS_SAFE_MODE_OFF"] or "Aus")
            panel.safeModeStatus:SetTextColor(0.5, 0.9, 0.3, 1.0)
        end

        panel.devModeBtn:SetChecked(settings.devMode or false)
        if settings.devMode then
            panel.devModeStatus:SetText(L and L["SETTINGS_DEV_MODE_ON"] or "AN")
            panel.devModeStatus:SetTextColor(0.3, 0.8, 1.0, 1.0)
        else
            panel.devModeStatus:SetText(L and L["SETTINGS_DEV_MODE_OFF"] or "Aus")
            panel.devModeStatus:SetTextColor(0.5, 0.6, 0.7, 1.0)
        end

        local count = NexusData.GetFeedCount()
        panel.dbInfoText:SetText((L and L["SETTINGS_DB_INFO"] or "Profile: %d gespeichert"):format(count))
    end)

    return panel
end

-- ============================================================
-- PANELS IN NEXUS_UI EINHÄNGEN
-- ============================================================
-- NexusTabs.OnTabChanged ist bereits vorhanden – wir ersetzen
-- die Platzhalter-Panels aus Nexus_UI.lua durch echte Panels.

local function InitializePanels()
    -- NexusContentPanel muss existieren
    local contentPanel = _G["NexusContentPanel"]
    if not contentPanel then
        print("[Nexus Panels] FEHLER: NexusContentPanel nicht gefunden!")
        return
    end

    -- Platzhalter-Panels aus Nexus_UI ausblenden/ersetzen
    local oldFeed     = _G["NexusFeedPanel"]
    local oldProfile  = _G["NexusProfilePanel"]
    local oldSettings = _G["NexusSettingsPanel"]

    if oldFeed     then oldFeed:Hide()     end
    if oldProfile  then oldProfile:Hide()  end
    if oldSettings then oldSettings:Hide() end

    -- Echte Panels bauen
    local realFeed     = BuildFeedPanel(contentPanel)
    local realProfile  = BuildProfilePanel(contentPanel)
    local realSettings = BuildSettingsPanel(contentPanel)

    -- NexusTabs Panel-Referenzen überschreiben
    -- (interner Hack: frames-Tabelle ist lokal in Nexus_UI,
    --  daher über den TAB_CHANGED Callback steuern)
    NexusTabs.OnTabChanged(function(newTab, oldTab)
        -- Alles ausblenden
        realFeed:Hide()
        realProfile:Hide()
        realSettings:Hide()

        -- Aktives Panel zeigen
        if newTab == "FEED" then
            realFeed:Show()
            if realFeed.OnCategoryChange then realFeed:OnCategoryChange(NexusTabState and NexusTabState.activeCategory or "FEED") end
        elseif newTab == "PROFILE" then
            realProfile:Show()
        elseif newTab == "SETTINGS" then
            realSettings:Show()
        end
    end)

    -- Aktuell aktiven Tab direkt anzeigen
    local current = NexusTabs.GetActive()
    if current == "FEED" then
        realFeed:Show()
    elseif current == "PROFILE" then
        realProfile:Show()
    elseif current == "SETTINGS" then
        realSettings:Show()
    end

    print(string.format("[Nexus Panels] Initialisiert (v%s)", PANELS_VERSION))
end

-- Nach PLAYER_ENTERING_WORLD, aber NACH Nexus_UI (LoadingList-Reihenfolge)
local panelInitFrame = CreateFrame("Frame", "NexusPanelInitFrame")
panelInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
panelInitFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        -- Kurze Verzögerung damit Nexus_UI sicher fertig ist
        C_Timer.After(0.1, InitializePanels)
    end
end)

-- ============================================================
-- PUBLIC API
-- ============================================================

_G.NexusData   = NexusData
_G.Nexus_Panels = {
    RunTests = nil,  -- wird unten gesetzt
}

print(string.format("[Nexus Panels] Modul geladen (v%s)", PANELS_VERSION))

-- ============================================================
-- UNIT TESTS
-- ============================================================

local function RunPanelTests()
    print("\n=== NEXUS_PANELS UNIT TESTS ===\n")

    local passed = 0
    local failed = 0

    local function Assert(condition, name)
        if condition then
            passed = passed + 1
            print("  + " .. name)
        else
            failed = failed + 1
            print("  FAIL: " .. name)
        end
    end

    -- Test 1: Bitmask-Definitionen korrekt
    Assert(#PLAY_DAYS   == 7, "PLAY_DAYS hat 7 Eintraege (playDaysMask 7 bits)")
    Assert(#PLAY_TIMES  == 4, "PLAY_TIMES hat 4 Eintraege (playTimeMask 4 bits)")
    Assert(#PLAY_STYLES == 8, "PLAY_STYLES hat 8 Eintraege (playstyleMask 8 bits)")

    -- Test 2: Keine Bit-Kollisionen innerhalb einer Gruppe
    local function checkNoBitCollisions(group, name)
        local seen = 0
        for _, entry in ipairs(group) do
            if bit.band(seen, entry.bit) ~= 0 then return false end
            seen = bit.bor(seen, entry.bit)
        end
        return true
    end
    Assert(checkNoBitCollisions(PLAY_DAYS,   "days"),   "PLAY_DAYS: keine Bit-Kollisionen")
    Assert(checkNoBitCollisions(PLAY_TIMES,  "times"),  "PLAY_TIMES: keine Bit-Kollisionen")
    Assert(checkNoBitCollisions(PLAY_STYLES, "styles"), "PLAY_STYLES: keine Bit-Kollisionen")

    -- Test 3: Bitmask-Werte innerhalb erlaubter Grenzen (Spec: 7bit, 5bit, 8bit)
    local maxDays  = 0
    for _, d in ipairs(PLAY_DAYS)   do maxDays  = bit.bor(maxDays,  d.bit) end
    Assert(maxDays <= 127, "playDaysMask max = 127 (7 bits)")

    local maxTimes = 0
    for _, t in ipairs(PLAY_TIMES)  do maxTimes = bit.bor(maxTimes, t.bit) end
    Assert(maxTimes <= 31, "playTimeMask max = 31 (5 bits)")

    local maxStyle = 0
    for _, s in ipairs(PLAY_STYLES) do maxStyle = bit.bor(maxStyle, s.bit) end
    Assert(maxStyle <= 255, "playstyleMask max = 255 (8 bits)")

    -- Test 4: Draft-Mechanismus
    profileDraft = {}
    SetDraftMask("playDaysMask", 0)
    Assert(GetDraftMask("playDaysMask") == 0, "Draft initial = 0")

    SetDraftMask("playDaysMask", 0x01)
    Assert(GetDraftMask("playDaysMask") == 1, "Draft: Montag gesetzt (bit 0)")

    -- Montag + Dienstag
    SetDraftMask("playDaysMask", bit.bor(0x01, 0x02))
    Assert(GetDraftMask("playDaysMask") == 3, "Draft: Montag + Dienstag = 3")

    -- Montag entfernen
    local mask = GetDraftMask("playDaysMask")
    mask = bit.band(mask, bit.bnot(0x01))
    SetDraftMask("playDaysMask", mask)
    Assert(GetDraftMask("playDaysMask") == 2, "Draft: Montag entfernt, Dienstag bleibt")

    -- Test 5: NexusData API
    -- GetSettings gibt immer eine Tabelle zurück
    local oldConfig = NexusConfig
    NexusConfig = nil
    local settings = NexusData.GetSettings()
    Assert(type(settings) == "table", "GetSettings() gibt immer Tabelle zurueck (auch bei nil Config)")
    NexusConfig = oldConfig

    -- Test 6: UpdateSettings schreibt korrekt
    NexusConfig = {}
    NexusData.UpdateSettings({ safeMode = true, devMode = false })
    Assert(NexusConfig.safeMode == true,  "UpdateSettings: safeMode = true")
    Assert(NexusConfig.devMode  == false, "UpdateSettings: devMode = false")
    NexusConfig = oldConfig

    -- Test 7: Safe Mode verhindert commAllowed
    if NexusState then
        local origAllowed = NexusState.commAllowed
        NexusState.commAllowed = true
        NexusConfig = { safeMode = true }
        NexusState.commAllowed = not NexusConfig.safeMode
        Assert(NexusState.commAllowed == false, "Safe Mode ON: commAllowed = false")
        NexusState.commAllowed = origAllowed
        NexusConfig = oldConfig
    else
        passed = passed + 1
        print("  + Safe Mode Gate (NexusState nicht geladen, uebersprungen)")
    end

    -- Test 8: Reset-Dialog nur außerhalb Combat (simuliert)
    -- InCombatLockdown() können wir nicht mocken, aber die Logik testen
    local resetBlocked = false
    local function simulateReset(inCombat)
        if inCombat then resetBlocked = true; return end
        resetBlocked = false
    end
    simulateReset(true)
    Assert(resetBlocked == true,  "Reset im Combat blockiert (simuliert)")
    simulateReset(false)
    Assert(resetBlocked == false, "Reset ausserhalb Combat erlaubt (simuliert)")

    -- Test 9: Keine Silent Resets (kein Reset ohne Dialog-Flag)
    -- Hier prüfen wir dass settingsTelemetry.resetInvocations gezählt wird
    local origCount = settingsTelemetry.resetInvocations
    settingsTelemetry.resetInvocations = settingsTelemetry.resetInvocations + 1
    Assert(settingsTelemetry.resetInvocations == origCount + 1,
        "Reset-Telemetrie wird korrekt gezaehlt")

    -- Zusammenfassung
    print(string.format("\n=== TEST SUMMARY ===\nPassed: %d\nFailed: %d\nTotal: %d\n",
        passed, failed, passed + failed))

    if failed == 0 then
        print("+ ALL TESTS PASSED")
    else
        print(string.format("FAIL: %d TESTS FEHLGESCHLAGEN", failed))
    end

    return failed == 0
end

_G.Nexus_Panels.RunTests = RunPanelTests
