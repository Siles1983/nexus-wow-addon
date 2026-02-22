--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_Comm (Netzwerk-Queue & Token-Bucket)
    Spezifikation: Nexus_Midnight_Hardening_Addendum.docx

    Architektur:
    Producer -> PayloadValidator -> OutQueue -> ThrottleGate -> SendAddonMessage

    Version: 0.0.2-alpha
]]

-- ============================================================
-- 1. KONSTANTEN & KONFIGURATION
-- ============================================================

local NEXUS_COMM_VERSION = "0.0.2-alpha"
local COMM_PREFIX        = "NEXUSv1"   -- Versionierter Prefix (bei Protocol-Aenderung: NEXUSv2)

-- Token-Bucket Parameter (VERBINDLICH)
local TOKEN_RATE  = 1.0   -- 1 Token pro Sekunde (= 1 msg/sec)
local TOKEN_BURST = 3     -- Max Burst: 3 Tokens

-- Queue-Limits (VERBINDLICH)
local QUEUE_SOFT_LIMIT = 50    -- Soft: Warnung
local QUEUE_HARD_LIMIT = 100   -- Hard: Drop-Policy greift

-- Payload-Limits (VERBINDLICH)
local MAX_PACKET_BYTES  = 512   -- Max Paketgroesse in Bytes
local MAX_BIO_CHARS     = 255   -- Max Bio-Laenge
local MAX_PROFILE_BYTES = 768   -- Max serialisiertes Profil

-- Backoff-Stufen in Sekunden (nur bei API-Fehler, NICHT bei Throttle)
local BACKOFF_STAGES = {
    [1] = 1,
    [2] = 2,
    [3] = 5,
    [4] = 10,   -- Maximum
}

-- Prioritaetsklassen (1 = hoch, 3 = niedrig)
local PRIORITY = {
    WHISPER  = 1,   -- Drop zuletzt
    GUILD    = 2,
    OFFICER  = 2,
    GLOBAL   = 3,   -- Drop zuerst
}

-- Eingehende Rate-Limits
local INCOMING_PER_SENDER_INTERVAL = 10   -- Sekunden zwischen Paketen pro Sender
local INCOMING_GLOBAL_BUDGET       = 5    -- Max Pakete/Sekunde global

-- ============================================================
-- 2. ZUSTANDSVARIABLEN
-- ============================================================

NexusComm = {
    -- Ausgehende Queue (FIFO, bounded)
    outQueue = {},

    -- Token-Bucket
    tokenBucket = {
        tokens     = TOKEN_BURST,   -- Starte voll
        lastRefill = 0,
    },

    -- Backoff-Tracking
    backoff = {
        level         = 0,   -- 0 = kein Backoff
        nextRetryTime = 0,
    },

    -- Eingehende Rate-Limits (pro Sender)
    incomingTracker = {
        perSender    = {},   -- [senderName] = letzter Empfangszeitpunkt
        globalTokens = INCOMING_GLOBAL_BUDGET,
        lastGlobalRefill = 0,
    },

    -- Telemetrie (lokal, kein Upload)
    telemetry = {
        messagesSent       = 0,
        messagesDropped    = 0,
        throttleHits       = 0,
        backoffActivations = 0,
        queueHighWatermark = 0,
        overflowEvents     = 0,
    },

    -- Status-Flags
    safeMode = false,
}

-- ============================================================
-- 3. TOKEN-BUCKET: REFILL & CONSUME
-- ============================================================

-- Tokens auffuellen basierend auf vergangener Zeit
local function refillTokens()
    local now   = GetTime()
    local delta = now - NexusComm.tokenBucket.lastRefill

    -- Neue Tokens berechnen (rate * delta, max burst)
    local newTokens = NexusComm.tokenBucket.tokens + (TOKEN_RATE * delta)
    if newTokens > TOKEN_BURST then
        newTokens = TOKEN_BURST
    end

    NexusComm.tokenBucket.tokens     = newTokens
    NexusComm.tokenBucket.lastRefill = now
end

-- Pruefe ob Token verfuegbar und verbrauche einen
local function consumeToken()
    refillTokens()

    if NexusComm.tokenBucket.tokens >= 1.0 then
        NexusComm.tokenBucket.tokens = NexusComm.tokenBucket.tokens - 1.0
        return true
    end

    -- Kein Token verfuegbar = Throttle-Hit (kein Backoff-Eskalation!)
    NexusComm.telemetry.throttleHits = NexusComm.telemetry.throttleHits + 1
    return false
end

-- ============================================================
-- 4. BACKOFF-MANAGEMENT (NUR bei API-Fehler)
-- ============================================================

-- Backoff eskalieren (nur bei SendAddonMessage-Fehler aufrufen)
local function escalateBackoff()
    local level = NexusComm.backoff.level
    if level < 4 then
        level = level + 1
        NexusComm.backoff.level = level
        NexusComm.backoff.nextRetryTime = GetTime() + (BACKOFF_STAGES[level] or 10)
        NexusComm.telemetry.backoffActivations = NexusComm.telemetry.backoffActivations + 1

        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus Comm] Backoff eskaliert auf Level %d (%ds)",
                level, BACKOFF_STAGES[level] or 10))
        end
    end
end

-- Backoff zuruecksetzen nach erfolgreichem Send
local function resetBackoff()
    if NexusComm.backoff.level > 0 then
        NexusComm.backoff.level         = 0
        NexusComm.backoff.nextRetryTime = 0
    end
end

-- Pruefe ob Backoff aktiv
local function isBackoffActive()
    if NexusComm.backoff.level == 0 then
        return false
    end
    return GetTime() < NexusComm.backoff.nextRetryTime
end

-- ============================================================
-- 5. DROP-POLICY (bei Queue-Ueberlauf)
-- ============================================================

-- Entferne niedrigste Prioritaet aus Queue (GLOBAL zuerst, dann GUILD, WHISPER zuletzt)
local function dropLowestPriority()
    -- Suche Eintrag mit hoechster Prioritaetsnummer (= niedrigste Wichtigkeit)
    local dropIndex   = nil
    local dropPrio    = 0

    for i, msg in ipairs(NexusComm.outQueue) do
        if msg.priority > dropPrio then
            dropPrio  = msg.priority
            dropIndex = i
        end
    end

    if dropIndex then
        table.remove(NexusComm.outQueue, dropIndex)
        NexusComm.telemetry.messagesDropped = NexusComm.telemetry.messagesDropped + 1
        NexusComm.telemetry.overflowEvents  = NexusComm.telemetry.overflowEvents  + 1

        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus Comm] Queue-Overflow: Nachricht (Prio %d) verworfen", dropPrio))
        end
    end
end

-- ============================================================
-- 6. PAYLOAD-VALIDIERUNG
-- ============================================================

-- Pruefe Paketgroesse VOR dem Einreihen
local function validatePayloadSize(payload)
    if type(payload) ~= "string" then
        return false, "Payload muss ein String sein"
    end
    if #payload > MAX_PACKET_BYTES then
        return false, string.format("Payload zu gross: %d > %d Bytes", #payload, MAX_PACKET_BYTES)
    end
    return true
end

-- ============================================================
-- 7. NACHRICHT EINREIHEN (Enqueue)
-- ============================================================

-- Nachricht in Queue einreihen
-- channel: "WHISPER", "GUILD", "OFFICER", "YELL", "PARTY", etc.
-- payload: String (bereits serialisiert)
-- target:  Spielername fuer WHISPER, nil sonst
function NexusComm:Enqueue(channel, payload, target)
    -- 1. Payload-Groesse pruefen
    local ok, err = validatePayloadSize(payload)
    if not ok then
        if NexusConfig and NexusConfig.devMode then
            print("[Nexus Comm] Enqueue abgelehnt: " .. err)
        end
        self.telemetry.messagesDropped = self.telemetry.messagesDropped + 1
        return false, err
    end

    -- 2. Prioritaet bestimmen
    local prio = PRIORITY[channel] or PRIORITY.GLOBAL

    -- 3. Nachrichtenobjekt erstellen
    local msg = {
        channel   = channel,
        payload   = payload,
        target    = target,
        priority  = prio,
        timestamp = GetTime(),
    }

    -- 4. Hard-Limit pruefen → Drop-Policy
    if #self.outQueue >= QUEUE_HARD_LIMIT then
        dropLowestPriority()
    end

    -- 5. Einreihen
    table.insert(self.outQueue, msg)

    -- 6. High-Watermark aktualisieren
    if #self.outQueue > self.telemetry.queueHighWatermark then
        self.telemetry.queueHighWatermark = #self.outQueue
    end

    -- 7. Soft-Limit Warnung
    if #self.outQueue >= QUEUE_SOFT_LIMIT and NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus Comm] Queue Soft-Limit erreicht: %d/%d",
            #self.outQueue, QUEUE_HARD_LIMIT))
    end

    return true
end

-- ============================================================
-- 8. SEND-TICK (wird vom Frame-Ticker aufgerufen)
-- ============================================================

-- Versuche naechste Nachricht aus Queue zu senden
local function sendTick()
    -- Sende-Bedingungen pruefen
    if #NexusComm.outQueue == 0 then return end

    -- Gate 1: commAllowed (NexusState muss erlauben)
    if not NexusState or not NexusState.commAllowed then return end

    -- Gate 2: Safe-Mode
    if NexusComm.safeMode then return end

    -- Gate 3: Backoff aktiv
    if isBackoffActive() then return end

    -- Gate 4: Token verfuegbar
    if not consumeToken() then return end

    -- Naechste Nachricht (FIFO: index 1)
    local msg = NexusComm.outQueue[1]
    if not msg then return end

    -- Senden
    local success, err = pcall(function()
        if msg.channel == "WHISPER" and msg.target then
            C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg.payload, msg.channel, msg.target)
        else
            C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg.payload, msg.channel)
        end
    end)

    if success then
        -- Erfolgreich gesendet
        table.remove(NexusComm.outQueue, 1)
        NexusComm.telemetry.messagesSent = NexusComm.telemetry.messagesSent + 1
        resetBackoff()
    else
        -- API-Fehler → Backoff eskalieren
        escalateBackoff()
        if NexusConfig and NexusConfig.devMode then
            print("[Nexus Comm] SendAddonMessage Fehler: " .. tostring(err))
        end
    end
end

-- ============================================================
-- 9. EINGEHENDE NACHRICHTEN
-- ============================================================

-- Rate-Limit fuer eingehende Nachrichten pruefen
local function checkIncomingRateLimit(sender)
    local now = GetTime()

    -- Globales Budget auffuellen (1x pro Sekunde)
    local globalDelta = now - NexusComm.incomingTracker.lastGlobalRefill
    if globalDelta >= 1.0 then
        NexusComm.incomingTracker.globalTokens    = INCOMING_GLOBAL_BUDGET
        NexusComm.incomingTracker.lastGlobalRefill = now
    end

    -- Globales Budget pruefen
    if NexusComm.incomingTracker.globalTokens <= 0 then
        return false, "Globales Eingangsbudget erschoepft"
    end

    -- Per-Sender Rate-Limit pruefen
    local lastTime = NexusComm.incomingTracker.perSender[sender]
    if lastTime and (now - lastTime) < INCOMING_PER_SENDER_INTERVAL then
        return false, string.format("Sender %s zu schnell", sender)
    end

    -- Akzeptieren
    NexusComm.incomingTracker.globalTokens         = NexusComm.incomingTracker.globalTokens - 1
    NexusComm.incomingTracker.perSender[sender]    = now
    return true
end

-- Eingehende Nachricht verarbeiten
function NexusComm:OnIncomingMessage(prefix, payload, channel, sender)
    -- Nur unser Prefix
    if prefix ~= COMM_PREFIX then return end

    -- Rate-Limit pruefen
    local ok, reason = checkIncomingRateLimit(sender)
    if not ok then
        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus Comm] Eingehend von %s verworfen: %s", sender, reason))
        end
        return
    end

    -- Payload-Groesse pruefen
    local valid, err = validatePayloadSize(payload)
    if not valid then
        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus Comm] Eingehend von %s ungueltig: %s", sender, err))
        end
        return
    end

    -- Weiterleitung an Handler (wird von anderen Modulen registriert)
    if NexusComm.onMessageReceived then
        NexusComm.onMessageReceived(payload, channel, sender)
    end
end

-- ============================================================
-- 10. SEND-TICKER FRAME
-- ============================================================

local tickerFrame = CreateFrame("Frame", "NexusCommTickerFrame")

-- Ticker laeuft im OnUpdate, sendet maximal 1x pro Token-Intervall
local tickerAccum = 0
local TICKER_INTERVAL = 0.1   -- Pruefe alle 100ms (aber Token limitiert den echten Send)

tickerFrame:SetScript("OnUpdate", function(self, dt)
    tickerAccum = tickerAccum + dt
    if tickerAccum >= TICKER_INTERVAL then
        tickerAccum = 0
        sendTick()
    end
end)

-- ============================================================
-- 11. INITIALISIERUNG
-- ============================================================

local function InitializeNexusComm()
    -- Prefix registrieren
    local registered = C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
    if not registered then
        print("[Nexus Comm] FEHLER: Prefix konnte nicht registriert werden!")
        return false
    end

    -- Token-Bucket initialisieren
    NexusComm.tokenBucket.tokens     = TOKEN_BURST
    NexusComm.tokenBucket.lastRefill = GetTime()

    -- Incoming Global Refill initialisieren
    NexusComm.incomingTracker.lastGlobalRefill = GetTime()

    print(string.format("[Nexus Comm] Initialisiert (v%s, Prefix: %s)",
        NEXUS_COMM_VERSION, COMM_PREFIX))
    return true
end

-- Event-Handler fuer eingehende AddonMessages
local commEventFrame = CreateFrame("Frame", "NexusCommEventFrame")
commEventFrame:RegisterEvent("CHAT_MSG_ADDON")
commEventFrame:SetScript("OnEvent", function(self, event, prefix, payload, channel, sender)
    if event == "CHAT_MSG_ADDON" then
        NexusComm:OnIncomingMessage(prefix, payload, channel, sender)
    end
end)

-- ============================================================
-- 12. PUBLIC API
-- ============================================================

_G.NexusComm = NexusComm

_G.Nexus_Comm = {
    Initialize      = InitializeNexusComm,
    Enqueue         = function(channel, payload, target) return NexusComm:Enqueue(channel, payload, target) end,
    GetQueueSize    = function() return #NexusComm.outQueue end,
    GetTelemetry    = function() return NexusComm.telemetry end,
    SetSafeMode     = function(enabled) NexusComm.safeMode = enabled end,
    GetBackoffLevel = function() return NexusComm.backoff.level end,
    IsBackoffActive = function() return isBackoffActive() end,
    RunTests        = nil,  -- wird unten gesetzt
}

-- ============================================================
-- 13. UNIT TESTS (15+)
-- ============================================================

local function RunCommTests()
    print("\n=== NEXUS_COMM UNIT TESTS ===\n")

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

    -- Hilfsfunktion: Queue leeren
    local function clearQueue()
        NexusComm.outQueue = {}
    end

    -- Hilfsfunktion: Token-Bucket fuellen
    local function fillTokens()
        NexusComm.tokenBucket.tokens = TOKEN_BURST
        NexusComm.backoff.level = 0
        NexusComm.backoff.nextRetryTime = 0
    end

    -- Test 1: Payload-Validierung - gueltiger Payload
    clearQueue()
    local ok, _ = validatePayloadSize("Hallo Nexus")
    Assert(ok == true, "Gueltiger Payload wird akzeptiert")

    -- Test 2: Payload-Validierung - zu grosser Payload
    local bigPayload = string.rep("X", MAX_PACKET_BYTES + 1)
    local ok2, _ = validatePayloadSize(bigPayload)
    Assert(ok2 == false, "Zu grosser Payload wird abgelehnt (>" .. MAX_PACKET_BYTES .. " Bytes)")

    -- Test 3: Payload-Validierung - kein String
    local ok3, _ = validatePayloadSize(12345)
    Assert(ok3 == false, "Nicht-String Payload wird abgelehnt")

    -- Test 4: Enqueue - gueltige Nachricht
    clearQueue()
    NexusComm:Enqueue("GUILD", "TestNachricht", nil)
    Assert(#NexusComm.outQueue == 1, "Enqueue: Nachricht landet in Queue")

    -- Test 5: Enqueue - zu grosser Payload wird abgelehnt
    clearQueue()
    local prevDropped = NexusComm.telemetry.messagesDropped
    NexusComm:Enqueue("GUILD", string.rep("X", 600), nil)
    Assert(#NexusComm.outQueue == 0, "Enqueue: Zu grosser Payload landet NICHT in Queue")
    Assert(NexusComm.telemetry.messagesDropped > prevDropped, "Enqueue: Dropped-Counter erhoet sich")

    -- Test 6: Prioritaet - WHISPER hat Prio 1
    clearQueue()
    NexusComm:Enqueue("WHISPER", "Test", "Spieler1")
    Assert(NexusComm.outQueue[1].priority == 1, "WHISPER hat Prioritaet 1")

    -- Test 7: Prioritaet - GLOBAL hat Prio 3
    clearQueue()
    NexusComm:Enqueue("GLOBAL", "Test", nil)
    Assert(NexusComm.outQueue[1].priority == 3, "GLOBAL hat Prioritaet 3")

    -- Test 8: Hard-Limit Drop-Policy
    clearQueue()
    fillTokens()
    local prevOverflow = NexusComm.telemetry.overflowEvents
    for i = 1, QUEUE_HARD_LIMIT + 5 do
        NexusComm:Enqueue("GLOBAL", "msg" .. i, nil)
    end
    Assert(#NexusComm.outQueue <= QUEUE_HARD_LIMIT, "Hard-Limit: Queue ueberschreitet nie " .. QUEUE_HARD_LIMIT)
    Assert(NexusComm.telemetry.overflowEvents > prevOverflow, "Hard-Limit: Overflow-Events werden gezaehlt")

    -- Test 9: Drop-Policy - GLOBAL wird zuerst gedroppt
    clearQueue()
    NexusComm:Enqueue("WHISPER", "whisper_msg", "Target")
    NexusComm:Enqueue("GLOBAL", "global_msg", nil)
    -- Queue voll machen und pruefen dass GLOBAL geht, WHISPER bleibt
    for i = 1, QUEUE_HARD_LIMIT do
        NexusComm:Enqueue("GLOBAL", "filler" .. i, nil)
    end
    local whisperFound = false
    for _, msg in ipairs(NexusComm.outQueue) do
        if msg.payload == "whisper_msg" then
            whisperFound = true
            break
        end
    end
    Assert(whisperFound, "Drop-Policy: WHISPER bleibt bei Overflow erhalten")

    -- Test 10: Token-Bucket - voller Bucket hat TOKEN_BURST Tokens
    fillTokens()
    Assert(NexusComm.tokenBucket.tokens == TOKEN_BURST, "Token-Bucket: Startet mit " .. TOKEN_BURST .. " Tokens")

    -- Test 11: Token-Bucket - Token wird verbraucht
    fillTokens()
    local prevTokens = NexusComm.tokenBucket.tokens
    consumeToken()
    Assert(NexusComm.tokenBucket.tokens < prevTokens, "Token-Bucket: Consume reduziert Token-Anzahl")

    -- Test 12: Token-Bucket - leer nach 3 Consumes
    fillTokens()
    consumeToken()
    consumeToken()
    consumeToken()
    local noToken = consumeToken()
    Assert(noToken == false, "Token-Bucket: Nach 3 Consumes kein Token mehr verfuegbar")

    -- Test 13: Backoff - eskaliert korrekt
    NexusComm.backoff.level = 0
    escalateBackoff()
    Assert(NexusComm.backoff.level == 1, "Backoff: Level eskaliert von 0 auf 1")
    escalateBackoff()
    Assert(NexusComm.backoff.level == 2, "Backoff: Level eskaliert von 1 auf 2")

    -- Test 14: Backoff - max Level 4
    NexusComm.backoff.level = 4
    escalateBackoff()
    Assert(NexusComm.backoff.level == 4, "Backoff: Bleibt bei Level 4 (Maximum)")

    -- Test 15: Backoff - Reset nach Erfolg
    NexusComm.backoff.level = 3
    resetBackoff()
    Assert(NexusComm.backoff.level == 0, "Backoff: Reset setzt Level auf 0")
    Assert(NexusComm.backoff.nextRetryTime == 0, "Backoff: Reset setzt nextRetryTime auf 0")

    -- Test 16: Eingehend - Rate-Limit per Sender
    NexusComm.incomingTracker.perSender = {}
    NexusComm.incomingTracker.globalTokens = INCOMING_GLOBAL_BUDGET
    NexusComm.incomingTracker.lastGlobalRefill = GetTime()
    local ok16a, _ = checkIncomingRateLimit("TestSpieler")
    local ok16b, _ = checkIncomingRateLimit("TestSpieler")  -- Zweites sofort danach
    Assert(ok16a == true, "Eingehend: Erste Nachricht von Sender akzeptiert")
    Assert(ok16b == false, "Eingehend: Zweite Nachricht von Sender sofort abgelehnt (Rate-Limit)")

    -- Test 17: Telemetrie - High-Watermark wird getrackt
    clearQueue()
    local prevWatermark = NexusComm.telemetry.queueHighWatermark
    NexusComm.telemetry.queueHighWatermark = 0
    for i = 1, 5 do
        NexusComm:Enqueue("GUILD", "msg" .. i, nil)
    end
    Assert(NexusComm.telemetry.queueHighWatermark >= 5, "Telemetrie: High-Watermark wird korrekt getrackt")

    -- Teardown: Queue leeren, Backoff reset
    clearQueue()
    fillTokens()
    NexusComm.incomingTracker.perSender = {}

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

_G.Nexus_Comm.RunTests = RunCommTests

-- ============================================================
-- 14. AUTO-INITIALISIERUNG
-- ============================================================

InitializeNexusComm()

print("[Nexus Comm] Nexus_Comm Modul geladen")
