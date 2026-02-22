--[[
    NEXUS - World of Warcraft Community Addon
    Midnight API v12 (Interface 120000)

    Modul: Nexus_PostUI
    Spezifikation: Nexus_Post_Creation_UI_Spec.docx
                   Nexus_Structured_Post_System_Core_Design_Spec.docx

    Zweck:
    Post-Erstellungs-Panel (modal über Feed).
    - Multiline Editbox (max 500 Zeichen)
    - Live Zeichen-Counter
    - Scope-Auswahl (Gilde / Freunde / Öffentlich)
    - Live-Validierung → Post-Button aktiv/inaktiv
    - Optimistic Render: Post erscheint sofort lokal
    - Kein Rich-Text, keine Formatierung, keine Farben

    UX-Flow:
    [Create Post] → Panel öffnet → Text + Scope → [Post] →
    Lokal speichern → In Queue einreihen → Panel schließt → Feed aktualisiert

    Taint-Regeln:
    - Kein Combat-Lockdown-Blocking
    - Keine protected Frames
    - Kein ChatEdit-Hook

    Version: 0.6.0-alpha
]]

local POSTUI_VERSION = "0.9.1-alpha"
local MAX_TEXT_LEN   = 500

-- ============================================================
-- 1. ZUSTAND
-- ============================================================

local postUIState = {
    currentText  = "",
    currentScope = 1,  -- Default: Guild
    isVisible    = false,
    errorMsg     = "",
}

-- Frames
local postPanel       = nil
local postEditBox     = nil
local postCounter     = nil
local postButton      = nil
local postErrorLabel  = nil
local scopeButtons    = {}

-- Flag: verhindert dass programmatisches SetText() OnTextChanged auslöst
local suppressTextChanged = false

-- ============================================================
-- 2. STATUS-ANZEIGE & LIVE-VALIDIERUNG
-- ============================================================

-- Ticker läuft immer während das Panel offen ist (jede Sekunde)
local statusTicker = nil

local function StopStatusTicker()
    if statusTicker then
        statusTicker:Cancel()
        statusTicker = nil
    end
end

-- Hilfsfunktion: Zeit-String formatieren
local function FormatSecs(secs)
    if secs >= 60 then
        return string.format("%d:%02d", math.floor(secs/60), secs % 60)
    else
        return string.format("%ds", secs)
    end
end

-- Baut den Statustext auf Basis des aktuellen Token-Status + Scope
local function BuildStatusText(scope)
    -- Guild-Check zuerst
    if scope == (NexusPost and NexusPost.SCOPE and NexusPost.SCOPE.GUILD) then
        local guildName = GetGuildInfo("player")
        if not guildName or guildName == "" then
            return L and L["POST_NO_GUILD"] or "Du bist keiner Gilde zugehoerig.", true
        end
    end

    if not NexusPost or not NexusPost.GetTokenStatus then
        return "3/3 Postings verfügbar.", false
    end
    local avail, max, secsUntilNext = NexusPost.GetTokenStatus()

    if avail >= max then
        return string.format("%d/%d Postings verfügbar.", avail, max), false
    elseif avail > 0 then
        return string.format("%d/%d Postings verfügbar.  Nächster in %s",
            avail, max, FormatSecs(secsUntilNext)), false
    else
        return string.format("0/%d Kein Content mehr.  Nächster in %s",
            max, FormatSecs(secsUntilNext)), true
    end
end

local function UpdateStatusLabel()
    if not postErrorLabel then return end
    local scope = postUIState.currentScope
    local txt, isError = BuildStatusText(scope)
    postErrorLabel:SetText(txt)
    if isError then
        postErrorLabel:SetTextColor(1, 0.35, 0.1, 1)   -- rot-orange: Fehler/leer
    else
        postErrorLabel:SetTextColor(0.5, 0.8, 0.3, 1)  -- grün: OK
    end
end

local function GetCanPost()
    local scope = postUIState.currentScope
    -- Guild-Check
    if scope == (NexusPost and NexusPost.SCOPE and NexusPost.SCOPE.GUILD) then
        local guildName = GetGuildInfo("player")
        if not guildName or guildName == "" then return false end
    end
    return NexusPost and NexusPost.CanPost and NexusPost.CanPost(scope)
end

local function StartStatusTicker()
    StopStatusTicker()
    statusTicker = C_Timer.NewTicker(1.0, function()
        if not postPanel or not postPanel:IsShown() then
            StopStatusTicker()
            return
        end
        UpdateStatusLabel()
        if postButton and postEditBox then
            local text = postEditBox:GetText() or ""
            local len = #text
            local scope = postUIState.currentScope
            local textValid = len > 0 and len <= MAX_TEXT_LEN
                              and scope ~= nil and scope ~= 0
            if GetCanPost() and textValid then
                postButton:Enable()
            else
                postButton:Disable()
            end
        end
    end)
end

local function UpdatePostButton()
    if not postButton or not postEditBox then return end

    -- Zeichen-Counter
    local text  = postEditBox:GetText() or ""
    local scope = postUIState.currentScope
    postUIState.currentText = text
    local len = #text

    if postCounter then
        postCounter:SetText(string.format("%d / %d", len, MAX_TEXT_LEN))
        if len > MAX_TEXT_LEN then
            postCounter:SetTextColor(1, 0.2, 0.2, 1)
        elseif len > MAX_TEXT_LEN * 0.85 then
            postCounter:SetTextColor(1, 0.8, 0, 1)
        else
            postCounter:SetTextColor(0.7, 0.7, 0.7, 1)
        end
    end

    -- Statuslabel (inkl. Guild-Check + Token-Status)
    UpdateStatusLabel()

    -- Button-State: Token OK + kein Guild-Problem + Text gültig + Scope gesetzt
    local textValid = (len > 0) and (len <= MAX_TEXT_LEN) and
                      (scope ~= nil) and (scope ~= 0)
    if GetCanPost() and textValid then
        postButton:Enable()
    else
        postButton:Disable()
    end
end

-- ============================================================
-- 3. SCOPE-BUTTONS
-- ============================================================

local SCOPE_DEFS = {
    { id = 1, label = "Gilde",        key = "SCOPE_GUILD" },
    { id = 2, label = "Freunde",      key = "SCOPE_FRIENDS" },
    { id = 4, label = "Öffentlich",   key = "SCOPE_PUBLIC" },
}

local function SelectScope(scopeID)
    postUIState.currentScope = scopeID
    -- Buttons visuell aktualisieren
    for _, btn in ipairs(scopeButtons) do
        if btn.scopeID == scopeID then
            btn:SetNormalFontObject("GameFontHighlight")
            btn.bg:SetVertexColor(0.2, 0.5, 0.9, 0.8)
        else
            btn:SetNormalFontObject("GameFontNormal")
            btn.bg:SetVertexColor(0.1, 0.1, 0.15, 0.8)
        end
    end
    UpdatePostButton()
end

-- ============================================================
-- 4. POST ABSENDEN
-- ============================================================

local function SubmitPost()
    local text  = postUIState.currentText
    local scope = postUIState.currentScope

    -- Doppelt absichern (sollte durch Button-Deaktivierung bereits verhindert sein)
    if not NexusPost or not NexusPost.Create then
        print("[Nexus PostUI] NexusPost.Create nicht verfügbar.")
        return
    end

    local post, err = NexusPost.Create(text, scope)
    if not post then
        if postErrorLabel then postErrorLabel:SetText(err or "Unbekannter Fehler.") end
        return
    end

    -- 1. Lokal speichern (optimistic render)
    post.state = "active"
    if NexusDB_API and NexusDB_API.SavePost then
        NexusDB_API.SavePost(post)
        NexusPost.MarkKnown(post.id)
    end

    -- 2. In Netzwerk-Queue einreihen
    if NexusNet and NexusNet.SendPost then
        NexusNet.SendPost(post)
    end

    -- 3. Feed-Refresh auslösen
    if NexusNet and NexusNet.onPostReceived then
        NexusNet.onPostReceived(post)
    end

    -- 4. Panel schließen + zurücksetzen
    NexusPostUI.Hide()

    print(string.format("[Nexus] Post erstellt (Scope: %s, %d Zeichen).",
        NexusPost.ScopeName and NexusPost.ScopeName(scope) or tostring(scope), #text))
end

-- ============================================================
-- 5. PANEL AUFBAUEN
-- ============================================================

local function BuildPostPanel()
    -- Root-Frame: modal über Feed, zentriert im Hauptfenster
    local panel = CreateFrame("Frame", nil, UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(460, 360)
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    panel:SetFrameStrata("DIALOG")
    panel:SetFrameLevel(100)
    panel:Hide()

    -- Hintergrund
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    else
        local bg = panel:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        bg:SetVertexColor(0.05, 0.05, 0.08, 0.95)
    end

    -- Drag-Unterstützung
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop",  panel.StopMovingOrSizing)

    -- Titel
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -18)
    title:SetText(L and L["CREATE_POST_TITLE"] or "Neuer Post")
    title:SetTextColor(0.9, 0.8, 0.5, 1)

    -- Trennlinie
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -40)
    divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, -40)
    divider:SetHeight(1)
    divider:SetTexture("Interface\\Buttons\\WHITE8X8")
    divider:SetVertexColor(0.3, 0.3, 0.4, 0.6)

    -- --------------------------------------------------------
    -- Multiline Editbox
    -- --------------------------------------------------------
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel,
        "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",  panel, "TOPLEFT",  18, -56)
    scrollFrame:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -36, -56)
    scrollFrame:SetHeight(120)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetMaxLetters(MAX_TEXT_LEN)
    editBox:SetWidth(scrollFrame:GetWidth() or 400)
    editBox:SetHeight(120)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetTextColor(0.9, 0.9, 0.9, 1)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:SetScript("OnEscapePressed", function(self) NexusPostUI.Hide() end)
    editBox:SetScript("OnTextChanged", function(self)
        if not suppressTextChanged then UpdatePostButton() end
    end)
    scrollFrame:SetScrollChild(editBox)
    postEditBox = editBox

    -- Placeholder-Text
    local placeholder = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    placeholder:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 4, -4)
    placeholder:SetText(L and L["POST_PLACEHOLDER"] or "Was möchtest du teilen?")
    placeholder:SetTextColor(0.4, 0.4, 0.45, 1)
    editBox:SetScript("OnTextChanged", function(self)
        placeholder:SetShown(#(self:GetText() or "") == 0)
        if not suppressTextChanged then UpdatePostButton() end
    end)
    editBox:SetScript("OnShow", function(self)
        placeholder:SetShown(#(self:GetText() or "") == 0)
    end)

    -- Editbox-Hintergrund
    local editBG = CreateFrame("Frame", nil, panel)
    editBG:SetPoint("TOPLEFT",  scrollFrame, "TOPLEFT",  -4, 4)
    editBG:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 4, -4)
    editBG:SetFrameLevel(scrollFrame:GetFrameLevel() - 1)
    local editBGTex = editBG:CreateTexture(nil, "BACKGROUND")
    editBGTex:SetAllPoints()
    editBGTex:SetTexture("Interface\\Buttons\\WHITE8X8")
    editBGTex:SetVertexColor(0.05, 0.05, 0.08, 0.85)

    -- --------------------------------------------------------
    -- Zeichen-Counter
    -- --------------------------------------------------------
    local counter = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    counter:SetPoint("TOPRIGHT", scrollFrame, "BOTTOMRIGHT", 0, -4)
    counter:SetText("0 / 500")
    counter:SetTextColor(0.7, 0.7, 0.7, 1)
    postCounter = counter

    -- --------------------------------------------------------
    -- Scope-Buttons
    -- --------------------------------------------------------
    local scopeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scopeLabel:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -28)
    scopeLabel:SetText(L and L["POST_SCOPE_LABEL"] or "Sichtbarkeit:")
    scopeLabel:SetTextColor(0.7, 0.7, 0.7, 1)

    scopeButtons = {}
    local btnW, btnH = 100, 26
    local btnY = -28

    for i, def in ipairs(SCOPE_DEFS) do
        local btn = CreateFrame("Button", nil, panel)
        btn:SetSize(btnW, btnH)
        btn:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT",
            (i - 1) * (btnW + 6) + 105, btnY)

        -- Hintergrund-Textur
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        bg:SetVertexColor(0.1, 0.1, 0.15, 0.8)
        btn.bg = bg

        -- Rahmen
        local border = btn:CreateTexture(nil, "BORDER")
        border:SetPoint("TOPLEFT",     btn, "TOPLEFT",     -1,  1)
        border:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT",  1, -1)
        border:SetTexture("Interface\\Buttons\\WHITE8X8")
        border:SetVertexColor(0.3, 0.3, 0.4, 0.5)

        btn:SetNormalFontObject("GameFontNormal")
        btn:SetText(L and L[def.key] or def.label)
        btn.scopeID = def.id

        btn:SetScript("OnClick", function(self)
            SelectScope(self.scopeID)
            -- Focus nach WoW-Click-Verarbeitung zurueckgeben (C_Timer.After(0) = naechster Frame)
            -- Direktes SetFocus() reicht nicht - WoW setzt Focus nach dem Click-Event zurueck
            C_Timer.After(0, function()
                if postEditBox and postPanel and postPanel:IsShown() then
                    postEditBox:SetFocus()
                end
            end)
        end)
        btn:SetScript("OnEnter", function(self)
            self.bg:SetVertexColor(0.25, 0.4, 0.7, 0.9)
        end)
        btn:SetScript("OnLeave", function(self)
            if postUIState.currentScope == self.scopeID then
                self.bg:SetVertexColor(0.2, 0.5, 0.9, 0.8)
            else
                self.bg:SetVertexColor(0.1, 0.1, 0.15, 0.8)
            end
        end)

        table.insert(scopeButtons, btn)
    end

    -- --------------------------------------------------------
    -- Buttons: [Abbrechen]  (Mitte: Status/Timer)  [Posten]
    -- Layout: Abbrechen links, Posten rechts, Status zentriert dazwischen
    -- --------------------------------------------------------
    local cancelBtn = CreateFrame("Button", nil, panel,
        "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 28)
    cancelBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 14)
    cancelBtn:SetText(L and L["POST_CANCEL"] or "Abbrechen")
    cancelBtn:SetScript("OnClick", function() NexusPostUI.Hide() end)

    local submitBtn = CreateFrame("Button", nil, panel,
        "UIPanelButtonTemplate")
    submitBtn:SetSize(100, 28)
    submitBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 14)
    submitBtn:SetText(L and L["POST_SUBMIT"] or "Posten")
    submitBtn:Disable()
    submitBtn:SetScript("OnClick", function() SubmitPost() end)
    postButton = submitBtn

    -- Status-Label: volle Breite zwischen Trennlinie und Buttons
    -- Verankert über dem Button-Bereich für genug Platz beim langen Text
    local statusFrame = CreateFrame("Frame", nil, panel)
    statusFrame:SetSize(420, 22)
    statusFrame:SetPoint("BOTTOM", panel, "BOTTOM", 0, 48)
    statusFrame:SetFrameLevel(200)

    local statusText = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetSize(420, 22)
    statusText:SetPoint("CENTER", statusFrame, "CENTER", 0, 0)
    statusText:SetJustifyH("CENTER")
    statusText:SetJustifyV("MIDDLE")
    statusText:SetTextColor(1, 0.6, 0.1, 1)
    statusText:SetText("")

    statusFrame:Show()
    postErrorLabel = statusText

    -- Schließen-Button (X)
    local closeBtn = CreateFrame("Button", nil, panel,
        "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() NexusPostUI.Hide() end)

    postPanel = panel

    -- Default Scope setzen (NACH postErrorLabel-Zuweisung!)
    SelectScope(NexusPost.SCOPE and NexusPost.SCOPE.GUILD or 1)

    -- Initialen Button-State setzen (jetzt sind alle Variablen gesetzt)
    UpdatePostButton()

    return panel
end

-- ============================================================
-- 6. PUBLIC API
-- ============================================================

NexusPostUI = {}

function NexusPostUI.Show()
    -- Combat-Lockdown Check
    if InCombatLockdown() then
        print(L and L["POST_COMBAT_BLOCKED"] or "[Nexus] Posten im Kampf nicht möglich.")
        return
    end

    -- Immer neu aufbauen wenn postPanel nil (nach reload) oder nicht mehr gültig
    if not postPanel or not postPanel.IsShown then
        postPanel = nil
        postButton = nil
        postEditBox = nil
        postCounter = nil
        postErrorLabel = nil
        scopeButtons = {}
        BuildPostPanel()
    end

    -- Zurücksetzen: suppress damit SetText("") kein OnTextChanged feuert
    suppressTextChanged = true
    postEditBox:SetText("")
    suppressTextChanged = false
    postUIState.currentText = ""
    postUIState.isVisible   = true
    SelectScope(NexusPost.SCOPE and NexusPost.SCOPE.GUILD or 1)

    postPanel:Show()

    -- Sofort Status + Button aktualisieren, dann Ticker starten
    C_Timer.After(0, function()
        UpdatePostButton()
        StartStatusTicker()
    end)
    -- Fokus auf Editbox setzen (nach Show, damit kein Taint)
    C_Timer.After(0.05, function()
        if postEditBox and postPanel:IsShown() then
            postEditBox:SetFocus()
        end
    end)
end

function NexusPostUI.Hide()
    postUIState.isVisible = false
    StopStatusTicker()
    if postPanel then
        postPanel:Hide()
    end
    -- Editbox leeren
    if postEditBox then
        postEditBox:SetText("")
        postEditBox:ClearFocus()
    end
end

function NexusPostUI.Toggle()
    if postUIState.isVisible then
        NexusPostUI.Hide()
    else
        NexusPostUI.Show()
    end
end

function NexusPostUI.IsVisible()
    return postUIState.isVisible
end

_G.NexusPostUI = NexusPostUI

-- ============================================================
-- 7. UNIT TESTS
-- ============================================================

local function RunPostUITests()
    print("\n=== NEXUS_POSTUI UNIT TESTS ===\n")

    local passed, failed = 0, 0
    local function Assert(cond, name)
        if cond then passed = passed + 1; print("  + " .. name)
        else         failed = failed + 1; print("  FAIL: " .. name) end
    end

    -- Test 1: Public API vorhanden
    Assert(type(NexusPostUI.Show)    == "function", "API: Show vorhanden")
    Assert(type(NexusPostUI.Hide)    == "function", "API: Hide vorhanden")
    Assert(type(NexusPostUI.Toggle)  == "function", "API: Toggle vorhanden")
    Assert(type(NexusPostUI.IsVisible) == "function", "API: IsVisible vorhanden")

    -- Test 2: Scope-Defs vollständig
    Assert(#SCOPE_DEFS == 3, "SCOPE_DEFS: 3 Einträge (Guild/Friends/Public)")
    Assert(SCOPE_DEFS[1].id == 1, "SCOPE_DEFS[1]: Guild = 1")
    Assert(SCOPE_DEFS[2].id == 2, "SCOPE_DEFS[2]: Friends = 2")
    Assert(SCOPE_DEFS[3].id == 4, "SCOPE_DEFS[3]: Public = 4")

    -- Test 3: Initialer Zustand
    Assert(postUIState.isVisible    == false, "State: initial nicht sichtbar")
    Assert(postUIState.currentScope == 1,     "State: Default Scope = Guild")

    -- Test 4: SelectScope ändert State
    SelectScope(2)
    Assert(postUIState.currentScope == 2, "SelectScope: Friends gesetzt")
    SelectScope(1)
    Assert(postUIState.currentScope == 1, "SelectScope: Guild zurückgesetzt")

    -- Test 5: IsVisible nach Hide
    postUIState.isVisible = true
    NexusPostUI.Hide()
    Assert(NexusPostUI.IsVisible() == false, "Hide: IsVisible = false")

    -- Zusammenfassung
    print(string.format("\n=== TEST SUMMARY ===\nPassed: %d\nFailed: %d\n",
        passed, failed))
    if failed == 0 then print("+ ALL TESTS PASSED")
    else print(string.format("FAIL: %d TESTS FEHLGESCHLAGEN", failed)) end
    return failed == 0
end

_G.Nexus_PostUI = {
    Show     = NexusPostUI.Show,
    Hide     = NexusPostUI.Hide,
    Toggle   = NexusPostUI.Toggle,
    RunTests = RunPostUITests,
    VERSION  = POSTUI_VERSION,
}

print(string.format("[Nexus PostUI] Modul geladen (v%s)", POSTUI_VERSION))
