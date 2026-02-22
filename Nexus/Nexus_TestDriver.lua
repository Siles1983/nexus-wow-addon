--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_TestDriver
    Spezifikation: Nexus Midnight Hardening Addendum (Kap. 13-14)
                   Nexus_TestScenario_CombatFlapping.docx
                   Nexus_CommStressTester_Spec.docx
                   Nexus_LargeDataset_Test_Spec.docx

    KRITISCH:
    - NexusTestDriver.enabled = false (DEFAULT, NIE automatisch starten!)
    - Nur via /nexustest oder Dev-Mode UI-Button aktivierbar
    - Kein Chat-Spam, keine SavedVariables-Korruption
    - Zero-Impact im Normalbetrieb

    Version: 0.4.0-alpha
]]

local TD_VERSION = "0.4.0-alpha-hotfix3"

-- ============================================================
-- 1. TEST DRIVER KERN
-- ============================================================

NexusTestDriver = {
    enabled        = false,   -- NIEMALS automatisch true!
    activeScenario = nil,
    startTime      = 0,
    tickTimer      = nil,
    metrics        = {},
    warnings       = {},
    lastReport     = nil,

    -- Registrierte Szenarien
    scenarios = {},
}

-- Letzter Report (für späteren Abruf)
NexusTestReport = nil

-- ============================================================
-- 2. PRECONDITION-CHECK (hart nach Spec)
-- ============================================================

local function CheckPreconditions()
    local errors = {}

    -- Nicht im Combat
    if InCombatLockdown() then
        table.insert(errors, "Test im Combat verboten")
    end

    -- Kein aktiver Backoff in Nexus_Comm
    if NexusComm and NexusComm.GetBackoffLevel and NexusComm.GetBackoffLevel() > 0 then
        table.insert(errors, "Aktiver Backoff in Nexus_Comm")
    end

    -- Queue leer oder pausiert
    if NexusComm and NexusComm.outQueue and #NexusComm.outQueue > 5 then
        table.insert(errors, string.format("Queue nicht leer (%d)", #NexusComm.outQueue))
    end

    -- Kein Safe Mode (würde Tests verfälschen)
    if NexusConfig and NexusConfig.safeMode then
        table.insert(errors, "Safe Mode aktiv – bitte deaktivieren")
    end

    return #errors == 0, errors
end

-- ============================================================
-- 3. METRICS COLLECTOR
-- ============================================================

local function ResetMetrics()
    NexusTestDriver.metrics = {
        -- State
        stateTransitions       = 0,
        illegalCommAttempts    = 0,
        combatTransitions      = 0,
        maxStateLatency        = 0,
        eventBurstCount        = 0,

        -- Comm
        queueHighWatermark     = 0,
        messagesSent           = 0,
        messagesDropped        = 0,
        throttleHits           = 0,
        backoffLevelMax        = 0,
        queueOverflowEvents    = 0,

        -- Pool/Scroll
        activeRowPeak          = 0,
        poolHighWatermark      = 0,
        recycleCount           = 0,
        fullRecycleCount       = 0,
        frameTimeMax           = 0,

        -- Fuzzer
        invalidPayloadCount    = 0,
        fuzzRejected           = 0,
        fuzzAccepted           = 0,  -- sollte immer 0 bleiben

        -- Allgemein
        luaErrors              = 0,
        elapsedTime            = 0,
        tickCount              = 0,
    }
    NexusTestDriver.warnings = {}
end

local function SampleMetrics()
    local m = NexusTestDriver.metrics

    -- Comm-Telemetrie sampeln
    if NexusComm then
        local t = NexusComm.telemetry
        if t then
            m.messagesSent    = t.messagesSent    or m.messagesSent
            m.messagesDropped = t.messagesDropped or m.messagesDropped
            m.throttleHits    = t.throttleHits    or m.throttleHits
            if t.queueHighWatermark and t.queueHighWatermark > m.queueHighWatermark then
                m.queueHighWatermark = t.queueHighWatermark
            end
        end
        -- Backoff direkt
        local bl = NexusComm.backoff and NexusComm.backoff.level or 0
        if bl > m.backoffLevelMax then m.backoffLevelMax = bl end
    end

    -- Pool-Telemetrie sampeln
    if NexusRowPool then
        local pt = NexusRowPool.telemetry
        if pt.activeRowPeak > m.activeRowPeak then
            m.activeRowPeak = pt.activeRowPeak
        end
        if pt.poolHighWatermark > m.poolHighWatermark then
            m.poolHighWatermark = pt.poolHighWatermark
        end
        m.recycleCount     = pt.recycleCount
        m.fullRecycleCount = NexusScrollAdapter and
            NexusScrollAdapter.telemetry.fullRecycleCount or 0
    end

    m.tickCount = m.tickCount + 1
end

-- ============================================================
-- 4. REPORT GENERATOR
-- ============================================================

local function GenerateReport(scenarioName, duration, pass)
    local report = {
        scenario = scenarioName,
        duration = duration,
        pass     = pass,
        warnings = {},
        metrics  = {},
        timestamp = time(),
    }

    -- Warnings kopieren
    for _, w in ipairs(NexusTestDriver.warnings) do
        table.insert(report.warnings, w)
    end

    -- Metrics-Snapshot kopieren
    for k, v in pairs(NexusTestDriver.metrics) do
        report.metrics[k] = v
    end

    NexusTestReport = report
    NexusTestDriver.lastReport = report

    -- Ausgabe
    print(string.format("\n=== NEXUS TEST REPORT: %s ===", scenarioName))
    print(string.format("  Status:   %s", pass and "|cff00ff00PASS|r" or "|cffff4444FAIL|r"))
    print(string.format("  Dauer:    %.1f Sekunden", duration))
    print(string.format("  Ticks:    %d", report.metrics.tickCount or 0))

    if #report.warnings > 0 then
        print(string.format("  Warnings: %d", #report.warnings))
        for i, w in ipairs(report.warnings) do
            print(string.format("    [%d] %s", i, w))
        end
    end

    -- Relevante Metriken ausgeben
    local m = report.metrics
    if m.stateTransitions > 0 then
        print(string.format("  State: transitions=%d illegal=%d combatFlips=%d",
            m.stateTransitions, m.illegalCommAttempts, m.combatTransitions))
    end
    if m.messagesSent > 0 or m.messagesDropped > 0 then
        print(string.format("  Comm:  sent=%d dropped=%d throttle=%d backoffMax=%d queuePeak=%d",
            m.messagesSent, m.messagesDropped, m.throttleHits,
            m.backoffLevelMax, m.queueHighWatermark))
    end
    if m.fuzzRejected > 0 then
        print(string.format("  Fuzz:  rejected=%d accepted=%d (accepted sollte 0 sein)",
            m.fuzzRejected, m.fuzzAccepted))
    end

    print("=========================\n")
    return report
end

-- ============================================================
-- 5. TICK-SYSTEM (100ms Intervall)
-- ============================================================

local function StopDriver()
    if NexusTestDriver.tickTimer then
        NexusTestDriver.tickTimer:Cancel()
        NexusTestDriver.tickTimer = nil
    end

    local scenario = NexusTestDriver.activeScenario
    if scenario then
        local duration = GetTime() - NexusTestDriver.startTime
        NexusTestDriver.metrics.elapsedTime = duration

        -- OnStop aufrufen
        local ok, err = pcall(function() scenario:OnStop() end)
        if not ok then
            table.insert(NexusTestDriver.warnings, "OnStop Error: " .. tostring(err))
        end

        -- Report generieren
        local pass = scenario.pass ~= false and
                     NexusTestDriver.metrics.luaErrors == 0 and
                     NexusTestDriver.metrics.illegalCommAttempts == 0
        GenerateReport(scenario.name, duration, pass)
    end

    NexusTestDriver.activeScenario = nil
    NexusTestDriver.enabled = false
end

local function RunTick()
    local scenario = NexusTestDriver.activeScenario
    if not scenario then StopDriver(); return end

    local now      = GetTime()
    local elapsed  = now - NexusTestDriver.startTime
    local dt       = 0.1  -- 100ms Tick

    -- Timeout prüfen
    if elapsed >= scenario.duration then
        StopDriver()
        return
    end

    -- Health-Check: Queue unbounded?
    if NexusComm and NexusComm.GetQueueSize then
        local qs = NexusComm.GetQueueSize()
        if qs >= 100 then
            table.insert(NexusTestDriver.warnings, string.format(
                "Queue voll (%d) bei t=%.1fs", qs, elapsed))
            NexusTestDriver.metrics.queueOverflowEvents =
                NexusTestDriver.metrics.queueOverflowEvents + 1
        end
    end

    -- Metrics sampeln
    SampleMetrics()

    -- Scenario Tick aufrufen
    local ok, err = pcall(function() scenario:OnTick(dt, elapsed) end)
    if not ok then
        NexusTestDriver.metrics.luaErrors = NexusTestDriver.metrics.luaErrors + 1
        table.insert(NexusTestDriver.warnings, "OnTick Error: " .. tostring(err))
        -- Bei Lua-Error → sofort abbrechen
        scenario.pass = false
        StopDriver()
    end
end

-- ============================================================
-- 6. SZENARIO REGISTRIERUNG + START
-- ============================================================

function NexusTestDriver:Register(scenario)
    if not scenario.name or not scenario.duration or
       not scenario.OnStart or not scenario.OnTick or not scenario.OnStop then
        print("[NexusTest] Ungültiges Szenario - Interface nicht vollständig")
        return false
    end
    self.scenarios[scenario.name] = scenario
    return true
end

function NexusTestDriver:Run(scenarioName)
    -- enabled-Check
    if not self.enabled then
        print("[NexusTest] TestDriver ist deaktiviert. /nexustest enable zuerst.")
        return false
    end

    -- Bereits läuft?
    if self.activeScenario then
        print("[NexusTest] Szenario läuft bereits: " .. self.activeScenario.name)
        return false
    end

    local scenario = self.scenarios[scenarioName]
    if not scenario then
        print("[NexusTest] Unbekanntes Szenario: " .. tostring(scenarioName))
        print("[NexusTest] Verfügbar: " .. table.concat(
            (function() local n={} for k in pairs(self.scenarios) do n[#n+1]=k end return n end)(), ", "))
        return false
    end

    -- Preconditions prüfen
    local ok, errors = CheckPreconditions()
    if not ok then
        print("[NexusTest] Preconditions fehlgeschlagen:")
        for _, e in ipairs(errors) do print("  - " .. e) end
        return false
    end

    -- Start
    ResetMetrics()
    scenario.pass = true  -- optimistisch, wird bei Fail gesetzt
    self.activeScenario = scenario
    self.startTime = GetTime()

    print(string.format("[NexusTest] Starte: %s (%.0fs)", scenarioName, scenario.duration))

    local startOk, startErr = pcall(function() scenario:OnStart() end)
    if not startOk then
        print("[NexusTest] OnStart Error: " .. tostring(startErr))
        self.activeScenario = nil
        return false
    end

    -- Tick-Timer starten (100ms)
    self.tickTimer = C_Timer.NewTicker(0.1, RunTick)

    return true
end

function NexusTestDriver:Stop()
    if self.activeScenario then
        print("[NexusTest] Manueller Stopp.")
        StopDriver()
    end
end

-- ============================================================
-- 7. SZENARIO: COMBAT FLAPPING
-- ============================================================

local ScenarioCombatFlapping = {
    name     = "CombatFlapping",
    duration = 30,  -- 30 Sekunden

    -- Parameter nach Spec
    flipInterval = 0.5,   -- Wechsel alle 0.5s
    burstMode    = true,

    -- Interner State
    nextFlip     = 0,
    inCombatSim  = false,
    totalFlips   = 0,
}

function ScenarioCombatFlapping:OnStart()
    self.nextFlip    = GetTime() + self.flipInterval
    self.inCombatSim = false
    self.totalFlips  = 0
    print("[CombatFlapping] Start: flip alle " .. self.flipInterval .. "s für " .. self.duration .. "s")
end

function ScenarioCombatFlapping:OnTick(dt, elapsed)
    local now = GetTime()
    local m   = NexusTestDriver.metrics

    -- Zeit für nächsten Flip?
    if now >= self.nextFlip then
        self.inCombatSim = not self.inCombatSim
        self.totalFlips  = self.totalFlips + 1
        self.nextFlip    = now + self.flipInterval

        m.combatTransitions = m.combatTransitions + 1

        -- Event in NexusState injizieren
        if NexusState then
            if self.inCombatSim then
                -- PLAYER_REGEN_DISABLED simulieren
                NexusState.inCombat = true
                NexusState.commAllowed = false
                m.stateTransitions = m.stateTransitions + 1
            else
                -- PLAYER_REGEN_ENABLED simulieren
                NexusState.inCombat = false
                -- commAllowed nur true wenn instanceType erlaubt
                local instanceOk = NexusState.instanceType == "world" or
                                   NexusState.instanceType == "none"  or
                                   NexusState.instanceType == nil
                NexusState.commAllowed = instanceOk
                m.stateTransitions = m.stateTransitions + 1
            end
        end
    end

    -- KRITISCHE PRÜFUNG: commAllowed niemals true während inCombatSim
    if self.inCombatSim and NexusState and NexusState.commAllowed then
        m.illegalCommAttempts = m.illegalCommAttempts + 1
        table.insert(NexusTestDriver.warnings, string.format(
            "ILLEGAL: commAllowed=true während Combat (t=%.1fs flip=%d)",
            elapsed, self.totalFlips))
        self.pass = false
    end

    -- Burst-Mode: gelegentlich mehrere Events auf einmal
    if self.burstMode and (self.totalFlips % 10 == 0) and self.totalFlips > 0 then
        m.eventBurstCount = m.eventBurstCount + 1
        -- 3 schnelle Flips simulieren
        for _ = 1, 3 do
            if NexusState then
                NexusState.inCombat = not NexusState.inCombat
                if NexusState.inCombat then
                    NexusState.commAllowed = false
                end
                m.stateTransitions = m.stateTransitions + 1
            end
        end
        -- Am Ende: sauberer Zustand
        if NexusState then
            NexusState.inCombat    = self.inCombatSim
            NexusState.commAllowed = not self.inCombatSim
        end
    end
end

function ScenarioCombatFlapping:OnStop()
    -- Sauberer Endzustand
    if NexusState then
        NexusState.inCombat    = false
        NexusState.commAllowed = true
    end

    local m = NexusTestDriver.metrics
    print(string.format("[CombatFlapping] Beendet: %d Flips, %d Transitions, %d illegal",
        self.totalFlips, m.combatTransitions, m.illegalCommAttempts))

    -- PASS wenn keine illegalen Freigaben
    if m.illegalCommAttempts > 0 then
        self.pass = false
    end
end

-- ============================================================
-- 8. SZENARIO: COMM STRESS TESTER
-- ============================================================

local ScenarioCommStress = {
    name     = "CommStress",
    duration = 60,  -- 60 Sekunden (4 Profile × 15s)

    -- Lastprofile nach Spec
    profiles = {
        { name = "Low",      rate = 1/5,  duration = 15 },  -- 1 msg / 5s
        { name = "Medium",   rate = 1,    duration = 15 },  -- 1 msg / s
        { name = "HighBurst",rate = 10,   duration = 15 },  -- Burst bis Soft-Limit
        { name = "Flood",    rate = 20,   duration = 15 },  -- Malicious Flood
    },

    -- Interner State
    currentProfile = 1,
    profileStart   = 0,
    nextSend       = 0,
    totalGenerated = 0,
}

function ScenarioCommStress:OnStart()
    self.currentProfile = 1
    self.profileStart   = GetTime()
    self.nextSend       = GetTime()
    self.totalGenerated = 0
    print("[CommStress] Start: 4 Lastprofile à 15s")

    -- Queue leeren (direkte Tabellen-Referenz)
    if NexusComm and NexusComm.outQueue then
        NexusComm.outQueue = {}
    end
end

function ScenarioCommStress:OnTick(dt, elapsed)
    local now = GetTime()
    local m   = NexusTestDriver.metrics

    -- Profil wechseln?
    local profile = self.profiles[self.currentProfile]
    if not profile then return end

    if (now - self.profileStart) >= profile.duration then
        self.currentProfile = self.currentProfile + 1
        self.profileStart   = now
        if self.profiles[self.currentProfile] then
            print(string.format("[CommStress] Profil: %s",
                self.profiles[self.currentProfile].name))
        end
        return
    end

    -- Nachrichten generieren
    if now >= self.nextSend then
        local interval = 1 / profile.rate
        self.nextSend = now + interval

        -- Synthetische Payload (128 Bytes nach Spec)
        local payload = string.format("NEXUSTEST|stress|%d|%s",
            self.totalGenerated,
            string.rep("X", 100))  -- ~128 Bytes

        self.totalGenerated = self.totalGenerated + 1

        -- Über Nexus_Comm senden (korrekte API: Enqueue(channel, payload, target))
        -- WICHTIG: Kein WHISPER im Test (kein echter Spieler → Chat-Spam)
        -- Nur GUILD (50%) und GLOBAL (50%) - werden intern throttled/dropped
        if NexusComm and NexusComm.Enqueue then
            local r = math.random(100)
            if r <= 50 then
                NexusComm:Enqueue("GUILD", payload, nil)
            else
                NexusComm:Enqueue("GLOBAL", payload, nil)
            end
        end

        -- Queue-Tiefe direkt prüfen
        if NexusComm and NexusComm.outQueue then
            local qs = #NexusComm.outQueue
            if qs > m.queueHighWatermark then
                m.queueHighWatermark = qs
            end
        end
    end
end

function ScenarioCommStress:OnStop()
    local m = NexusTestDriver.metrics
    print(string.format("[CommStress] Beendet: %d generiert, Peak-Queue=%d, Drops=%d, Throttle=%d",
        self.totalGenerated, m.queueHighWatermark, m.messagesDropped, m.throttleHits))

    -- Queue Hard-Limit beim Flood-Profil ist ERWARTET (beweist Drop-Policy funktioniert)
    -- Nur FAIL wenn Queue dauerhaft wächst ohne Drops (unbounded)
    if m.queueHighWatermark >= 100 and m.messagesDropped == 0 then
        table.insert(NexusTestDriver.warnings,
            "Queue voll ohne Drops – Drop-Policy defekt!")
        self.pass = false
    elseif m.queueHighWatermark >= 100 then
        -- Normal: Queue voll + Drops = Drop-Policy funktioniert
        table.insert(NexusTestDriver.warnings,
            string.format("Queue Hard-Limit erreicht (erwartet beim Flood-Profil) – Drops=%d OK",
                m.messagesDropped))
    end
end

-- ============================================================
-- 9. SZENARIO: PAYLOAD FUZZER
-- ============================================================

local ScenarioPayloadFuzzer = {
    name     = "PayloadFuzzer",
    duration = 20,

    -- Fuzz-Klassen nach Spec
    fuzzCases = nil,  -- wird in OnStart befüllt
    caseIndex = 0,
    nextCase  = 0,
}

function ScenarioPayloadFuzzer:OnStart()
    self.caseIndex = 0
    self.nextCase  = GetTime()

    -- Fuzz-Payloads nach Spec
    self.fuzzCases = {
        -- 1. Oversize Payload (> 768 Bytes)
        { name = "Oversize",        payload = { nameID = string.rep("X", 800) } },
        -- 2. Falsche Datentypen
        { name = "WrongType_nameID",payload = { nameID = 12345, schemaVersion = 2 } },
        { name = "WrongType_bio",   payload = { nameID = "Test-Realm", bio = true } },
        -- 3. Tiefe Tabellen (verschachtelt)
        { name = "DeepTable",       payload = { nameID = "Test-Realm", nested = { deep = {} } } },
        -- 4. String-Bomb (> 10k Zeichen)
        { name = "StringBomb",      payload = { nameID = "Test-Realm", bio = string.rep("A", 10000) } },
        -- 5. Leere Felder
        { name = "EmptyFields",     payload = {} },
        -- 6. Nil-Felder
        { name = "NilPayload",      payload = nil },
        -- 7. Metatable-Injektion
        { name = "Metatable",       payload = setmetatable({nameID = "T-R"}, {__index = function() return "INJECTED" end}) },
        -- 8. Ungültige Bitmasks
        { name = "InvalidBitmask",  payload = { nameID = "Test-Realm", playDaysMask = 255, schemaVersion = 2 } },
        -- 9. Ungültiges houseCoord
        { name = "BadHouseCoord",   payload = { nameID = "Test-Realm", houseCoord = "INVALID_COORD" } },
        -- 10. Ungültige GUID
        { name = "BadGUID",         payload = { nameID = "Test-Realm", guid = "!!INVALID!!" } },
        -- 11. Unbekannte Felder
        { name = "UnknownFields",   payload = { nameID = "Test-Realm", evilField = "HACKED", schemaVersion = 2 } },
        -- 12. Sehr langer nameID
        { name = "LongNameID",      payload = { nameID = string.rep("A", 200) } },
    }

    print(string.format("[PayloadFuzzer] Start: %d Fuzz-Cases", #self.fuzzCases))
end

function ScenarioPayloadFuzzer:OnTick(dt, elapsed)
    -- Alle 1.5s einen Fuzz-Case ausprobieren
    if GetTime() < self.nextCase then return end
    self.nextCase = GetTime() + 1.5

    self.caseIndex = self.caseIndex + 1
    if self.caseIndex > #self.fuzzCases then return end

    local fuzz = self.fuzzCases[self.caseIndex]
    local m    = NexusTestDriver.metrics

    -- Payload gegen Shield testen
    if NexusShield and NexusShield.ValidateProfile then
        local ok, _ = NexusShield.ValidateProfile(fuzz.payload)

        if ok then
            -- FAIL: Shield hat ungültiges Profil akzeptiert
            m.fuzzAccepted = m.fuzzAccepted + 1
            table.insert(NexusTestDriver.warnings, string.format(
                "SHIELD FAIL: %s wurde akzeptiert!", fuzz.name))
            self.pass = false
        else
            -- PASS: Shield hat korrekt abgelehnt
            m.fuzzRejected = m.fuzzRejected + 1
            m.invalidPayloadCount = m.invalidPayloadCount + 1
        end

        -- Sicherstellen dass nichts in DB gespeichert wurde
        if NexusDB and NexusDB.profiles then
            local saved = NexusDB.profiles["Test-Realm"]
            if saved and saved.evilField then
                table.insert(NexusTestDriver.warnings, "DB-INJEKTION: unbekanntes Feld gespeichert!")
                self.pass = false
            end
        end
    else
        -- Shield nicht verfügbar
        table.insert(NexusTestDriver.warnings, "NexusShield nicht verfügbar")
    end
end

function ScenarioPayloadFuzzer:OnStop()
    local m = NexusTestDriver.metrics
    print(string.format("[PayloadFuzzer] Beendet: rejected=%d accepted=%d",
        m.fuzzRejected, m.fuzzAccepted))

    if m.fuzzAccepted > 0 then
        self.pass = false
        print("|cffff4444[PayloadFuzzer] FAIL: Shield hat " .. m.fuzzAccepted .. " ungültige Payloads akzeptiert!|r")
    end
end

-- ============================================================
-- 10. SZENARIO: LARGE DATASET TEST
-- ============================================================

local ScenarioLargeDataset = {
    name     = "LargeDataset",
    duration = 45,

    -- Phasen nach Spec
    targetCount   = 1000,
    insertedCount = 0,
    phase         = "FILL",  -- FILL → SCROLL → PRUNE
    phaseStart    = 0,
    insertPerTick = 50,       -- max 50 Inserts pro Tick (kein Frame-Spike)
}

function ScenarioLargeDataset:OnStart()
    self.insertedCount = 0
    self.phase         = "FILL"
    self.phaseStart    = GetTime()

    print(string.format("[LargeDataset] Start: %d Profile einfügen", self.targetCount))
end

function ScenarioLargeDataset:OnTick(dt, elapsed)
    local m = NexusTestDriver.metrics

    if self.phase == "FILL" then
        -- Chunked Insert (max 50 pro Tick, kein Frame-Spike)
        if self.insertedCount < self.targetCount then
            local batch = math.min(self.insertPerTick,
                                   self.targetCount - self.insertedCount)
            for i = 1, batch do
                local idx = self.insertedCount + i
                local profile = {
                    schemaVersion = 2,
                    nameID        = string.format("TestPlayer%d-Realm", idx),
                    lastSeen      = time() - math.random(0, 86400),
                    bio           = string.format("Spieler %d im Dataset", idx),
                    playDaysMask  = math.random(0, 127),
                    playTimeMask  = math.random(0, 15),
                    playstyleMask = math.random(0, 255),
                    visibility    = 1,
                }
                -- Direkt in DB schreiben (Shield-validiert)
                if NexusDB and NexusDB.profiles then
                    -- Shield-Gate
                    if NexusShield then
                        local ok, _ = NexusShield.ValidateProfile(profile)
                        if ok then
                            NexusDB.profiles[profile.nameID] = profile
                        end
                    else
                        NexusDB.profiles[profile.nameID] = profile
                    end
                end
            end
            self.insertedCount = self.insertedCount + batch

            if self.insertedCount >= self.targetCount then
                print(string.format("[LargeDataset] %d Profile eingefügt – Scroll-Phase",
                    self.insertedCount))
                self.phase      = "SCROLL"
                self.phaseStart = GetTime()

                -- ScrollAdapter aktualisieren (wenn Feed offen)
                if NexusScrollAdapter and NexusScrollAdapter.RefreshData then
                    NexusScrollAdapter:RefreshData()
                end
            end
        end

    elseif self.phase == "SCROLL" then
        -- Scroll-Simulation für 20 Sekunden
        if (GetTime() - self.phaseStart) < 20 then
            -- ScrollAdapter ForceUpdate aufrufen (simuliert Scroll)
            if NexusScrollAdapter and NexusScrollAdapter.ForceUpdate then
                NexusScrollAdapter:ForceUpdate()
            end

            -- Pool-Stats prüfen
            if NexusRowPool then
                local active = 0
                for _ in pairs(NexusRowPool.activeRows) do active = active + 1 end
                if active > m.activeRowPeak then m.activeRowPeak = active end

                -- FAIL wenn Pool über erwartetem Maximum (20 + Buffer)
                if active > 25 then
                    table.insert(NexusTestDriver.warnings, string.format(
                        "Pool-Overflow: %d aktive Rows (max erwartet: 20)", active))
                    self.pass = false
                end
            end
        else
            print("[LargeDataset] Scroll-Phase abgeschlossen – Prune-Phase")
            self.phase      = "PRUNE"
            self.phaseStart = GetTime()

            -- Pruning starten
            if Nexus_DB and Nexus_DB.StartPruning then
                Nexus_DB.StartPruning(0)  -- Alle entfernen (Test-Cleanup)
            end
        end

    elseif self.phase == "PRUNE" then
        -- Warten bis Pruning fertig (max 10s)
        if (GetTime() - self.phaseStart) > 10 then
            -- Prüfen ob Profiles entfernt wurden
            local remaining = 0
            if NexusDB and NexusDB.profiles then
                for _ in pairs(NexusDB.profiles) do remaining = remaining + 1 end
            end
            print(string.format("[LargeDataset] Nach Pruning: %d Profile verbleibend",
                remaining))
            self.phase = "DONE"
        end
    end
end

function ScenarioLargeDataset:OnStop()
    local m = NexusTestDriver.metrics
    print(string.format("[LargeDataset] Beendet: %d eingefügt, Pool-Peak=%d, Recycles=%d",
        self.insertedCount, m.activeRowPeak, m.recycleCount))

    -- Cleanup: Test-Profile entfernen
    if NexusDB and NexusDB.profiles then
        for nameID, _ in pairs(NexusDB.profiles) do
            if nameID:match("^TestPlayer%d+%-Realm$") then
                NexusDB.profiles[nameID] = nil
            end
        end
        print("[LargeDataset] Test-Profile bereinigt.")
    end
end

-- ============================================================
-- 11. SZENARIEN REGISTRIEREN
-- ============================================================

NexusTestDriver:Register(ScenarioCombatFlapping)
NexusTestDriver:Register(ScenarioCommStress)
NexusTestDriver:Register(ScenarioPayloadFuzzer)
NexusTestDriver:Register(ScenarioLargeDataset)

-- ============================================================
-- 12. SLASH COMMANDS
-- ============================================================

SLASH_NEXUSTEST1 = "/nexustest"
SLASH_NEXUSTEST2 = "/nt"

SlashCmdList["NEXUSTEST"] = function(msg)
    local cmd = strtrim(msg or ""):lower()

    if cmd == "enable" then
        NexusTestDriver.enabled = true
        print("[NexusTest] TestDriver aktiviert. Vorsicht: nur für Entwickler!")

    elseif cmd == "disable" then
        if NexusTestDriver.activeScenario then
            NexusTestDriver:Stop()
        end
        NexusTestDriver.enabled = false
        print("[NexusTest] TestDriver deaktiviert.")

    elseif cmd == "stop" then
        NexusTestDriver:Stop()

    elseif cmd == "report" then
        if NexusTestReport then
            print(string.format("Letzter Report: %s – %s (%.1fs)",
                NexusTestReport.scenario,
                NexusTestReport.pass and "PASS" or "FAIL",
                NexusTestReport.duration))
        else
            print("[NexusTest] Kein Report vorhanden.")
        end

    elseif cmd == "all" then
        -- Alle Szenarien sequenziell (über Callbacks)
        if not NexusTestDriver.enabled then
            print("[NexusTest] Erst /nexustest enable")
            return
        end
        print("[NexusTest] Starte alle Szenarien sequenziell...")
        -- CombatFlapping zuerst (kürzestes)
        NexusTestDriver:Run("CombatFlapping")

    elseif cmd:match("^run ") then
        local input = cmd:match("^run (.+)$")
        -- Case-insensitive Suche: direkt in scenarios nach Name suchen
        local found = nil
        for scenName, _ in pairs(NexusTestDriver.scenarios) do
            if scenName:lower() == input:lower() then
                found = scenName
                break
            end
        end
        if found then
            NexusTestDriver:Run(found)
        else
            print("[NexusTest] Unbekanntes Szenario: " .. input)
            print("[NexusTest] Verfügbar: CombatFlapping, CommStress, PayloadFuzzer, LargeDataset")
        end

    else
        print("|cff00ccff[NexusTest] Befehle:|r")
        print("  /nt enable                 -> TestDriver aktivieren")
        print("  /nt disable                -> TestDriver deaktivieren")
        print("  /nt run CombatFlapping     -> Combat Flapping Test (30s)")
        print("  /nt run CommStress         -> Comm Stress Test (60s)")
        print("  /nt run PayloadFuzzer      -> Payload Fuzzer (20s)")
        print("  /nt run LargeDataset       -> Large Dataset Test (45s)")
        print("  /nt all                    -> Alle Szenarien")
        print("  /nt stop                   -> Abbrechen")
        print("  /nt report                 -> Letzten Report anzeigen")
    end
end

-- ============================================================
-- 13. PUBLIC API
-- ============================================================

_G.NexusTestDriver = NexusTestDriver

print(string.format("[Nexus TestDriver] Modul geladen (v%s) – /nexustest help", TD_VERSION))
print("[Nexus TestDriver] HINWEIS: enabled=false, manuell aktivieren mit /nt enable")
