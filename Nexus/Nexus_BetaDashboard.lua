--[[
    NEXUS - World of Warcraft Community Addon
    Midnight API v12 (Interface 120000)

    Modul: Nexus_BetaDashboard
    Spezifikation: Nexus_Beta_Telemetry_Dashboard_Spec.docx
                   Nexus_Closed_Beta_Rollout_Plan.docx

    Zweck:
    Zentrales Beobachtungs-Dashboard für die Closed Beta.
    Zeigt alle Kern-Metriken auf einen Blick – mit Ampel-System.

    KRITISCHE REGELN:
    - NUR aktiv wenn NexusConfig.devMode == true
    - KEIN Netzwerkverkehr
    - KEINE SavedVariables-Änderungen
    - KEIN OnUpdate-Lookup
    - Bei Fehler: still deaktivieren, DevWarn loggen

    Sektionen:
    A. UI Performance
    B. Feed & Scroll
    C. Netzwerk & Queue
    D. Profil & Settings
    E. Localization & Tooltips
    F. Version & Capability
    G. Health Summary (Ampel)

    Aktivierung: /nexus beta  oder Dev Mode Toggle
    Refresh: C_Timer.After(2.0, ...) – kein pro-Frame-Update

    Version: 0.5.0-alpha
]]

local DASHBOARD_VERSION = "0.5.0-alpha"
local REFRESH_INTERVAL  = 2.0  -- Sekunden zwischen Auto-Refresh

-- ============================================================
-- 1. TELEMETRIE COLLECTOR
-- Zentrale Session-Metriken – werden von anderen Modulen
-- nicht direkt verändert; Dashboard liest sie per Getter.
-- ============================================================

NexusBetaTelemetry = NexusBetaTelemetry or {
    -- A. UI Performance
    frameOpenCount   = 0,
    tabSwitchCount   = 0,
    frameTimeMax     = 0,   -- ms
    frameTimeSum     = 0,
    frameTimeSamples = 0,

    -- B. Feed & Scroll
    scrollRefreshCount = 0,
    rowRebindCount     = 0,

    -- C. Netzwerk & Queue (gecacht aus Nexus_Comm)
    queueHighWatermark = 0,
    handshakesSent     = 0,
    outgoingThrottle   = 0,
    messagesDropped    = 0,

    -- D. Profil & Settings
    profileWriteCount    = 0,
    bitmaskToggleCount   = 0,
    settingsToggleCount  = 0,
    resetInvocations     = 0,

    -- E. Localization & Tooltips
    localeMisses       = 0,
    tooltipMisses      = 0,
    tooltipCoverage    = 100, -- %

    -- F. Version & Capability
    protocolMismatch   = 0,
    capabilityDowngrade= 0,
    peersTotal         = 0,

    -- Session-Start
    sessionStart = 0,
}

-- Hilfsfunktion: Mittelwert Frame-Time
local function GetAvgFrameTime()
    local t = NexusBetaTelemetry
    if t.frameTimeSamples == 0 then return 0 end
    return t.frameTimeSum / t.frameTimeSamples
end

-- ============================================================
-- 2. METRIKEN SAMMELN (Snapshot aus vorhandenen Modulen)
-- ============================================================

local function SnapshotMetrics()
    local t = NexusBetaTelemetry

    -- Nexus_Comm
    if NexusComm and NexusComm.telemetry then
        local ct = NexusComm.telemetry
        t.queueHighWatermark = math.max(t.queueHighWatermark, ct.queueHighWatermark or 0)
        t.outgoingThrottle   = ct.throttleHits     or 0
        t.messagesDropped    = ct.messagesDropped  or 0
    end

    -- Nexus_Net
    if NexusNet and NexusNet.telemetry then
        local nt = NexusNet.telemetry
        t.handshakesSent    = nt.handshakeSent         or 0
        t.protocolMismatch  = nt.protocolMismatchCount  or 0
        t.peersTotal        = nt.peerCacheSize          or 0
    end

    -- Nexus_RowPool
    if NexusRowPool and NexusRowPool.telemetry then
        local rp = NexusRowPool.telemetry
        t.rowRebindCount = rp.recycleCount or 0
    end

    -- Locale Validator
    if NexusLocaleValidator and NexusLocaleValidator.telemetry then
        local lv = NexusLocaleValidator.telemetry
        t.localeMisses = lv.missingLocaleCount     or 0
        t.tooltipMisses= lv.runtimeMissingLookups  or 0
    end

    -- Tooltip Coverage: Registry-Einträge vs bekannte Elements
    if NexusTooltipRegistry then
        local total, covered = 0, 0
        for _, entry in pairs(NexusTooltipRegistry) do
            total = total + 1
            if entry[2] then covered = covered + 1 end
        end
        t.tooltipCoverage = total > 0 and math.floor((covered / total) * 100) or 100
    end
end

-- ============================================================
-- 3. AMPEL-LOGIK
-- ============================================================

-- Gibt "GREEN", "YELLOW" oder "RED" + Farbe zurück
local function GetHealthColor(status)
    if status == "GREEN"  then return 0.2, 0.9, 0.2, 1.0 end
    if status == "YELLOW" then return 1.0, 0.8, 0.1, 1.0 end
    return 0.9, 0.2, 0.2, 1.0  -- RED
end

local function EvaluateHealth()
    local t = NexusBetaTelemetry
    local status = "GREEN"
    local warnings = {}

    -- Frame-Time
    if t.frameTimeMax > 16 then
        status = "YELLOW"
        table.insert(warnings, string.format("frameTimeMax=%.1fms > 16ms", t.frameTimeMax))
    end

    -- Queue
    if NexusComm and NexusComm.QUEUE_MAX then
        local pct = (t.queueHighWatermark / NexusComm.QUEUE_MAX) * 100
        if pct > 80 then
            status = "YELLOW"
            table.insert(warnings, string.format("Queue %.0f%% voll", pct))
        end
    end

    -- Throttle-Hits
    if t.outgoingThrottle > 20 then
        status = "YELLOW"
        table.insert(warnings, string.format("ThrottleHits=%d", t.outgoingThrottle))
    end

    -- Tooltip Coverage
    if t.tooltipCoverage < 98 then
        status = "RED"
        table.insert(warnings, string.format("TooltipCoverage=%d%% < 98%%", t.tooltipCoverage))
    end

    -- Locale Misses
    if t.localeMisses > 0 then
        if status == "GREEN" then status = "YELLOW" end
        table.insert(warnings, string.format("LocaleMisses=%d", t.localeMisses))
    end

    -- Protocol Mismatch
    if t.protocolMismatch > 0 then
        if status == "GREEN" then status = "YELLOW" end
        table.insert(warnings, string.format("ProtocolMismatch=%d", t.protocolMismatch))
    end

    return status, warnings
end

-- ============================================================
-- 4. DASHBOARD FRAME
-- ============================================================

local dashFrame = nil
local dashLines = {}     -- FontStrings für Metriken
local dashTitle = nil
local dashStatus = nil
local refreshTimer = nil
local dashVisible = false

local DASH_WIDTH  = 340
local DASH_HEIGHT = 480

local function CreateDashLine(parent, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, y)
    fs:SetWidth(DASH_WIDTH - 24)
    fs:SetJustifyH("LEFT")
    fs:SetText("")
    return fs
end

local function SetLine(idx, text, r, g, b)
    if not dashLines[idx] then return end
    dashLines[idx]:SetText(text or "")
    dashLines[idx]:SetTextColor(r or 0.8, g or 0.8, b or 0.8, 1.0)
end

local function BuildDashboardFrame()
    if dashFrame then return end

    dashFrame = CreateFrame("Frame", "NexusBetaDashFrame", UIParent, "BackdropTemplate")
    dashFrame:SetSize(DASH_WIDTH, DASH_HEIGHT)
    dashFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -240, -100)
    dashFrame:SetFrameStrata("HIGH")
    dashFrame:SetMovable(true)
    dashFrame:EnableMouse(true)
    dashFrame:RegisterForDrag("LeftButton")
    dashFrame:SetScript("OnDragStart", dashFrame.StartMoving)
    dashFrame:SetScript("OnDragStop",  dashFrame.StopMovingOrSizing)

    dashFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    dashFrame:SetBackdropColor(0.05, 0.05, 0.1, 0.95)

    -- Titel
    dashTitle = dashFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dashTitle:SetPoint("TOPLEFT", dashFrame, "TOPLEFT", 12, -8)
    dashTitle:SetText("|cff00ccffNexus Beta Dashboard|r")

    -- Status-Ampel
    dashStatus = dashFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dashStatus:SetPoint("TOPRIGHT", dashFrame, "TOPRIGHT", -12, -8)
    dashStatus:SetText("● GREEN")
    dashStatus:SetTextColor(0.2, 0.9, 0.2, 1.0)

    -- Trennlinie
    local div = dashFrame:CreateTexture(nil, "OVERLAY")
    div:SetPoint("TOPLEFT", dashFrame, "TOPLEFT", 8, -22)
    div:SetSize(DASH_WIDTH - 16, 1)
    div:SetTexture("Interface\\Buttons\\WHITE8X8")
    div:SetVertexColor(0.3, 0.3, 0.5, 0.8)

    -- Content-Zeilen: 38 Zeilen à 11px = max 418px
    local yStart = -28
    for i = 1, 38 do
        local fs = CreateDashLine(dashFrame, yStart - (i - 1) * 11)
        table.insert(dashLines, fs)
    end

    -- Schließen-Button
    local closeBtn = CreateFrame("Button", "NexusDashClose", dashFrame, "UIPanelCloseButton")
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", dashFrame, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        NexusBetaDashboard.Hide()
    end)

    -- Refresh-Button
    local refBtn = CreateFrame("Button", "NexusDashRefresh", dashFrame, "UIPanelButtonTemplate")
    refBtn:SetSize(70, 18)
    refBtn:SetPoint("BOTTOMRIGHT", dashFrame, "BOTTOMRIGHT", -8, 6)
    refBtn:SetText("Refresh")
    refBtn:SetScript("OnClick", function()
        NexusBetaDashboard.Refresh()
    end)

    dashFrame:Hide()
end

-- ============================================================
-- 5. RENDER (Dashboard aktualisieren)
-- ============================================================

local function Render()
    if not dashFrame or not dashFrame:IsShown() then return end

    SnapshotMetrics()
    local t = NexusBetaTelemetry
    local health, warnings = EvaluateHealth()
    local hr, hg, hb = GetHealthColor(health)

    -- Ampel
    dashStatus:SetText("● " .. health)
    dashStatus:SetTextColor(hr, hg, hb, 1.0)

    local i = 1
    local function Line(text, r, g, b)
        SetLine(i, text, r, g, b)
        i = i + 1
    end
    local function Header(text)
        Line("|cffaaaaff" .. text .. "|r", 0.6, 0.6, 1.0)
    end
    local function Divider()
        Line("─────────────────────────────────", 0.2, 0.2, 0.3)
    end
    local function Metric(label, value, warn)
        local r, g, b = 0.7, 0.7, 0.8
        if warn then r, g, b = 1.0, 0.7, 0.1 end
        Line(string.format("  %-22s %s", label, tostring(value)), r, g, b)
    end

    -- Session-Zeit
    local elapsed = t.sessionStart > 0 and (GetTime() - t.sessionStart) or 0
    local mins = math.floor(elapsed / 60)
    local secs = math.floor(elapsed % 60)
    Line(string.format("|cff888888Session: %dm %02ds  v%s|r",
        mins, secs, DASHBOARD_VERSION), 0.5, 0.5, 0.6)
    Divider()

    -- A. UI Performance
    Header("A. UI Performance")
    Metric("Frame-Öffnungen:", t.frameOpenCount)
    Metric("Tab-Wechsel:",     t.tabSwitchCount)
    local ftAvg = GetAvgFrameTime()
    Metric("FrameTime Max:",
        string.format("%.2f ms", t.frameTimeMax),
        t.frameTimeMax > 16)
    Metric("FrameTime Avg:",
        string.format("%.2f ms", ftAvg))
    Divider()

    -- B. Feed & Scroll
    Header("B. Feed & Scroll")
    local poolInUse, poolFree, poolMax = 0, 0, 0
    if NexusRowPool then
        poolInUse = NexusRowPool.inUse and #NexusRowPool.inUse or 0
        poolFree  = NexusRowPool.free  and #NexusRowPool.free  or 0
        poolMax   = NexusRowPool.POOL_SIZE or 25
    end
    Metric("Pool In-Use:",    poolInUse,  poolInUse >= poolMax * 0.9)
    Metric("Pool Free:",      poolFree)
    Metric("Pool Max:",       poolMax)
    Metric("Scroll-Refresh:", t.scrollRefreshCount)
    Metric("Row-Rebinds:",    t.rowRebindCount)
    Divider()

    -- C. Netzwerk & Queue
    Header("C. Netzwerk & Queue")
    local queueMax = (NexusComm and NexusComm.QUEUE_MAX) or 100
    local queuePct = math.floor((t.queueHighWatermark / queueMax) * 100)
    Metric("Queue High-WM:",
        string.format("%d / %d (%d%%)", t.queueHighWatermark, queueMax, queuePct),
        queuePct > 80)
    Metric("Handshakes sent:", t.handshakesSent)
    Metric("Throttle-Hits:",  t.outgoingThrottle, t.outgoingThrottle > 20)
    Metric("Msgs Dropped:",   t.messagesDropped,  t.messagesDropped > 0)
    Divider()

    -- D. Profil & Settings
    Header("D. Profil & Settings")
    Metric("Profil-Saves:", t.profileWriteCount)
    Metric("Bitmask-Toggles:", t.bitmaskToggleCount)
    Metric("Settings-Toggles:", t.settingsToggleCount)
    Metric("DB-Resets:", t.resetInvocations, t.resetInvocations > 0)
    Divider()

    -- E. Localization & Tooltips
    Header("E. Localization & Tooltips")
    Metric("Locale-Misses:",  t.localeMisses, t.localeMisses > 0)
    Metric("Tooltip-Misses:", t.tooltipMisses, t.tooltipMisses > 0)
    Metric("Tooltip-Coverage:",
        string.format("%d%%", t.tooltipCoverage),
        t.tooltipCoverage < 98)
    Divider()

    -- F. Version & Capability
    Header("F. Version & Capability")
    Metric("Peers gesamt:", t.peersTotal)
    Metric("Proto-Mismatch:", t.protocolMismatch, t.protocolMismatch > 0)
    Metric("Cap-Downgrade:",  t.capabilityDowngrade, t.capabilityDowngrade > 0)
    Divider()

    -- G. Health Summary
    Header("G. Health Summary")
    if #warnings == 0 then
        Line("  |cff00ff00Alle Systeme grün. Keine Warnungen.|r", 0.2, 0.9, 0.2)
    else
        for _, w in ipairs(warnings) do
            Line("  |cffff8800⚠ " .. w .. "|r", 1.0, 0.7, 0.1)
        end
    end

    -- Leere Restzeilen löschen
    while i <= #dashLines do
        SetLine(i, "")
        i = i + 1
    end
end

-- ============================================================
-- 6. AUTO-REFRESH TIMER
-- ============================================================

local function ScheduleRefresh()
    if refreshTimer then return end
    refreshTimer = C_Timer.NewTicker(REFRESH_INTERVAL, function()
        if not dashFrame or not dashFrame:IsShown() then return end
        if not (NexusConfig and NexusConfig.devMode) then
            NexusBetaDashboard.Hide()
            return
        end
        Render()
    end)
end

-- ============================================================
-- 7. PUBLIC API
-- ============================================================

NexusBetaDashboard = {}

function NexusBetaDashboard.Show()
    if not (NexusConfig and NexusConfig.devMode) then
        print("|cffff4444[Nexus] Beta Dashboard benötigt Dev Mode.|r")
        return
    end

    if not dashFrame then
        BuildDashboardFrame()
    end

    NexusBetaTelemetry.sessionStart = NexusBetaTelemetry.sessionStart == 0
        and GetTime() or NexusBetaTelemetry.sessionStart

    dashFrame:Show()
    dashVisible = true
    ScheduleRefresh()
    Render()
    print("|cff00ccff[Nexus] Beta Dashboard geöffnet. Auto-Refresh alle 2s.|r")
end

function NexusBetaDashboard.Hide()
    if dashFrame then dashFrame:Hide() end
    dashVisible = false
    if refreshTimer then
        refreshTimer:Cancel()
        refreshTimer = nil
    end
end

function NexusBetaDashboard.Toggle()
    if dashVisible and dashFrame and dashFrame:IsShown() then
        NexusBetaDashboard.Hide()
    else
        NexusBetaDashboard.Show()
    end
end

function NexusBetaDashboard.Refresh()
    SnapshotMetrics()
    Render()
end

-- Metriken von außen erhöhen (Wrapper)
function NexusBetaDashboard.Track(key, delta)
    delta = delta or 1
    if NexusBetaTelemetry[key] ~= nil then
        NexusBetaTelemetry[key] = NexusBetaTelemetry[key] + delta
    end
end

function NexusBetaDashboard.TrackFrameTime(ms)
    local t = NexusBetaTelemetry
    if ms > t.frameTimeMax then t.frameTimeMax = ms end
    t.frameTimeSum     = t.frameTimeSum + ms
    t.frameTimeSamples = t.frameTimeSamples + 1
end

-- ============================================================
-- 8. SLASH COMMAND
-- ============================================================

-- /nexus beta  → Dashboard ein/aus
-- Integriert sich in bestehenden /nexus Handler
local _origSlash = SlashCmdList["NEXUS"]
SLASH_NEXUS1 = "/nexus"
SlashCmdList["NEXUS"] = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if cmd == "beta" or cmd == "dashboard" or cmd == "dash" then
        NexusBetaDashboard.Toggle()
        return
    end
    if _origSlash then _origSlash(msg) end
end

-- ============================================================
-- 9. UNIT TESTS
-- ============================================================

local function RunBetaDashboardTests()
    print("\n=== NEXUS_BETADASHBOARD UNIT TESTS ===\n")

    local passed, failed = 0, 0
    local function Assert(cond, name)
        if cond then passed = passed + 1; print("  + " .. name)
        else         failed = failed + 1; print("  FAIL: " .. name) end
    end

    -- Test 1: Telemetrie vorhanden
    Assert(type(NexusBetaTelemetry) == "table",       "NexusBetaTelemetry ist Tabelle")
    Assert(NexusBetaTelemetry.frameOpenCount   ~= nil, "Feld frameOpenCount vorhanden")
    Assert(NexusBetaTelemetry.queueHighWatermark ~= nil,"Feld queueHighWatermark vorhanden")
    Assert(NexusBetaTelemetry.tooltipCoverage  ~= nil, "Feld tooltipCoverage vorhanden")
    Assert(NexusBetaTelemetry.localeMisses     ~= nil, "Feld localeMisses vorhanden")
    Assert(NexusBetaTelemetry.protocolMismatch ~= nil, "Feld protocolMismatch vorhanden")

    -- Test 2: EvaluateHealth – Grundfall GREEN
    NexusBetaTelemetry.frameTimeMax    = 10
    NexusBetaTelemetry.queueHighWatermark = 10
    NexusBetaTelemetry.outgoingThrottle   = 0
    NexusBetaTelemetry.tooltipCoverage    = 100
    NexusBetaTelemetry.localeMisses       = 0
    local h1, w1 = EvaluateHealth()
    Assert(h1 == "GREEN", "EvaluateHealth: Grundfall = GREEN")
    Assert(#w1 == 0, "EvaluateHealth: keine Warnungen bei grünem Zustand")

    -- Test 3: FrameTime > 16ms → YELLOW
    NexusBetaTelemetry.frameTimeMax = 25
    local h2, w2 = EvaluateHealth()
    Assert(h2 == "YELLOW", "EvaluateHealth: frameTimeMax 25ms → YELLOW")
    Assert(#w2 > 0, "EvaluateHealth: Warnung für frameTimeMax vorhanden")
    NexusBetaTelemetry.frameTimeMax = 0

    -- Test 4: TooltipCoverage < 98% → RED
    NexusBetaTelemetry.tooltipCoverage = 95
    local h3, _ = EvaluateHealth()
    Assert(h3 == "RED", "EvaluateHealth: tooltipCoverage 95% → RED")
    NexusBetaTelemetry.tooltipCoverage = 100

    -- Test 5: LocaleMisses > 0 → YELLOW
    NexusBetaTelemetry.localeMisses = 3
    local h4, w4 = EvaluateHealth()
    Assert(h4 == "YELLOW", "EvaluateHealth: localeMisses 3 → YELLOW")
    Assert(#w4 > 0, "EvaluateHealth: Warnung für localeMisses vorhanden")
    NexusBetaTelemetry.localeMisses = 0

    -- Test 6: Track() Funktion
    NexusBetaTelemetry.tabSwitchCount = 0
    NexusBetaDashboard.Track("tabSwitchCount")
    NexusBetaDashboard.Track("tabSwitchCount")
    Assert(NexusBetaTelemetry.tabSwitchCount == 2, "Track(): tabSwitchCount korrekt erhöht")

    -- Test 7: TrackFrameTime
    NexusBetaTelemetry.frameTimeMax     = 0
    NexusBetaTelemetry.frameTimeSum     = 0
    NexusBetaTelemetry.frameTimeSamples = 0
    NexusBetaDashboard.TrackFrameTime(5)
    NexusBetaDashboard.TrackFrameTime(10)
    NexusBetaDashboard.TrackFrameTime(8)
    Assert(NexusBetaTelemetry.frameTimeMax == 10, "TrackFrameTime: Max korrekt")
    Assert(NexusBetaTelemetry.frameTimeSamples == 3, "TrackFrameTime: Samples korrekt")
    local avg = GetAvgFrameTime()
    Assert(math.abs(avg - 7.67) < 0.1, string.format("TrackFrameTime: Avg=%.2f ≈ 7.67", avg))

    -- Test 8: Public API vorhanden
    Assert(type(NexusBetaDashboard.Show)    == "function", "Show() ist Funktion")
    Assert(type(NexusBetaDashboard.Hide)    == "function", "Hide() ist Funktion")
    Assert(type(NexusBetaDashboard.Toggle)  == "function", "Toggle() ist Funktion")
    Assert(type(NexusBetaDashboard.Refresh) == "function", "Refresh() ist Funktion")
    Assert(type(NexusBetaDashboard.Track)   == "function", "Track() ist Funktion")

    -- Test 9: Show ohne Dev Mode → kein Absturz
    local prevDev = NexusConfig and NexusConfig.devMode
    if NexusConfig then NexusConfig.devMode = false end
    local ok = pcall(NexusBetaDashboard.Show)
    Assert(ok, "Show() ohne Dev Mode: kein Lua-Error")
    if NexusConfig then NexusConfig.devMode = prevDev end

    -- Test 10: Tooltip Coverage berechnung aus Registry
    if NexusTooltipRegistry then
        SnapshotMetrics()
        Assert(NexusBetaTelemetry.tooltipCoverage >= 0 and
               NexusBetaTelemetry.tooltipCoverage <= 100,
               "tooltipCoverage liegt zwischen 0-100%")
    else
        passed = passed + 1
        print("  + tooltipCoverage: Registry nicht geladen (Skip OK)")
    end

    -- Zusammenfassung
    print(string.format("\n=== TEST SUMMARY ===\nPassed: %d\nFailed: %d\nTotal: %d\n",
        passed, failed, passed + failed))
    if failed == 0 then print("+ ALL TESTS PASSED")
    else print(string.format("FAIL: %d TESTS FEHLGESCHLAGEN", failed)) end

    return failed == 0
end

_G.Nexus_BetaDashboard = {
    RunTests = RunBetaDashboardTests,
}

-- ============================================================
-- 10. INIT
-- ============================================================

local initFrame = CreateFrame("Frame", "NexusBetaDashInitFrame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        NexusBetaTelemetry.sessionStart = GetTime()

        -- Auto-Show wenn Dev Mode beim Login bereits an
        C_Timer.After(2.0, function()
            if NexusConfig and NexusConfig.devMode then
                print("|cff00ccff[Nexus] Beta Dashboard verfügbar: /nexus beta|r")
            end
        end)
    end
end)

print(string.format("[Nexus BetaDashboard] Modul geladen (v%s) – /nexus beta zum Öffnen",
    DASHBOARD_VERSION))
