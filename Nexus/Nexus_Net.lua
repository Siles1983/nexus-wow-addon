--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_Net (Version Handshake + Capability System)
    Spezifikation: Nexus_Version_Handshake_Spec.docx
                   Nexus_Capability_System_Spec.docx

    Grundsatz:
    - Minimaler Traffic: 1 Handshake pro Peer pro Session
    - Kein periodisches Spammen
    - Protocol-Version ist hartes Kompatibilitäts-Gate
    - capMask sind Soft-Features
    - System darf NIE hard crashen

    Version: 0.2.0-alpha
]]

-- ============================================================
-- 1. PROTOKOLL-KONSTANTEN (verbindlich)
-- ============================================================

local NET_VERSION      = "0.6.0-alpha"
local CURRENT_PROTOCOL = 1        -- Netzwerk-Kompatibilität (HART)
local CURRENT_SCHEMA   = 2        -- Profil-Schema
local CURRENT_VERSION  = NET_VERSION

-- Payload-Limit (VERBINDLICH ≤ 64 Bytes für Handshake)
local HANDSHAKE_MAX_BYTES = 64

-- Capability-Bitmaske (v1 Layout nach Spec)
local CAP_PROFILE_V2    = 0x01   -- bit 0: Profil v2 unterstützt
local CAP_PLAYSTYLE_EXT = 0x02   -- bit 1: erweiterte Playstyle-Filter
local CAP_POSE          = 0x04   -- bit 2: kosmetische Posen
local CAP_BACKGROUND    = 0x08   -- bit 3: kosmetische Hintergründe
local CAP_RAIDERIO      = 0x10   -- bit 4: RaiderIO-Integration
local CAP_POST_V1       = 0x20   -- bit 5: Structured Post System v1
local CAP_EXPERIMENTAL  = 0x40   -- bit 6: experimentelle Features

-- Eigene Capabilities (was dieser Client unterstützt)
local LOCAL_CAP_MASK = CAP_PROFILE_V2 + CAP_PLAYSTYLE_EXT + CAP_POSE + CAP_BACKGROUND + CAP_POST_V1
-- = 0x2F = 47

-- Peer-Cache Ablauf
local PEER_CACHE_MAX_AGE   = 30 * 86400  -- 30 Tage (Pruning)
local PEER_FRESH_THRESHOLD = 300         -- 5 Minuten (kein Re-Handshake)
local HANDSHAKE_DEBOUNCE   = 60          -- 1 Minute pro Peer min. Abstand

-- AddonMessage Prefix (muss mit Nexus_Comm übereinstimmen)
local MSG_PREFIX     = "NEXUSv1"
local MSG_HANDSHAKE  = "HS"    -- Handshake-Request
local MSG_HS_REPLY   = "HSR"   -- Handshake-Reply
local MSG_POST       = "PT"    -- Structured Post

-- ============================================================
-- 2. PEER CACHE
-- ============================================================

-- NexusPeerCache wird als SavedVariable persistiert
-- Struktur:
--   NexusPeerCache = {
--     ["Spieler-Realm"] = {
--       protocol   = number,
--       version    = string,
--       schema     = number,
--       capMask    = number,
--       lastSeen   = timestamp,
--       compat     = "FULL" | "LEGACY" | "LIMITED" | "INCOMPATIBLE"
--     }
--   }

local function ensurePeerCache()
    if type(NexusPeerCache) ~= "table" then
        NexusPeerCache = {}
    end
end

-- ============================================================
-- 3. HANDSHAKE THROTTLE
-- ============================================================

-- Pro-Peer: wann wurde zuletzt ein Handshake gesendet?
local handshakeSentAt = {}   -- [nameID] = GetTime()

-- Globales Handshake-Budget (1/sec, Burst 2) – vereinfacht
local hsTokens    = 2
local hsLastRefill = 0

local function canSendHandshake(nameID)
    local now = GetTime()

    -- Debounce: nicht öfter als 1× pro Minute pro Peer
    if handshakeSentAt[nameID] and (now - handshakeSentAt[nameID]) < HANDSHAKE_DEBOUNCE then
        return false
    end

    -- Globales Token-Budget auffüllen
    local elapsed = now - hsLastRefill
    if elapsed >= 1.0 then
        hsTokens = math.min(2, hsTokens + math.floor(elapsed))
        hsLastRefill = now
    end

    -- Token verfügbar?
    if hsTokens < 1 then return false end

    return true
end

local function consumeHandshakeToken(nameID)
    hsTokens = hsTokens - 1
    handshakeSentAt[nameID] = GetTime()
end

-- ============================================================
-- 4. HANDSHAKE SENDEN
-- ============================================================

-- Handshake-Payload serialisieren (muss ≤ 64 Bytes bleiben)
local function buildHandshakePayload(msgType)
    -- Format: TYPE|protocol|version|schema|capMask
    -- Beispiel: "HS|1|0.2.0-alpha|2|15"
    return string.format("%s|%d|%s|%d|%d",
        msgType,
        CURRENT_PROTOCOL,
        CURRENT_VERSION,
        CURRENT_SCHEMA,
        LOCAL_CAP_MASK
    )
end

-- Handshake an einen Peer senden
local function SendHandshake(nameID, isReply)
    if not canSendHandshake(nameID) then
        NexusNet.telemetry.handshakeSkipped = NexusNet.telemetry.handshakeSkipped + 1
        return false
    end

    -- commAllowed prüfen (Nexus_State Gate)
    if NexusState and not NexusState.commAllowed then
        return false
    end

    local msgType = isReply and MSG_HS_REPLY or MSG_HANDSHAKE
    local payload = buildHandshakePayload(msgType)

    -- Größe prüfen (≤ 64 Bytes)
    if #payload > HANDSHAKE_MAX_BYTES then
        if NexusConfig and NexusConfig.devMode then
            print("[Nexus Net] FEHLER: Handshake-Payload zu gross: " .. #payload)
        end
        return false
    end

    -- Über Nexus_Comm senden (wenn verfügbar)
    if NexusComm and NexusComm.Enqueue then
        NexusComm.Enqueue(payload, nameID, "WHISPER")
    else
        -- Direkt senden (Fallback für Tests)
        C_ChatInfo.SendAddonMessage(MSG_PREFIX, payload, "WHISPER", nameID)
    end

    consumeHandshakeToken(nameID)
    NexusNet.telemetry.handshakeSent = NexusNet.telemetry.handshakeSent + 1

    if NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus Net] Handshake %s -> %s (payload: %d Bytes)",
            msgType, nameID, #payload))
    end

    return true
end

-- ============================================================
-- 5. HANDSHAKE EMPFANGEN
-- ============================================================

-- Payload parsen: "HS|1|0.2.0|2|15" → table
local function parseHandshakePayload(payload)
    local msgType, protocol, version, schema, capMask =
        payload:match("^(%a+)|(%d+)|([%d%.%a%-]+)|(%d+)|(%d+)$")

    if not msgType then return nil end

    protocol = tonumber(protocol)
    schema   = tonumber(schema)
    capMask  = tonumber(capMask)

    if not protocol or not schema or not capMask then return nil end

    return {
        msgType  = msgType,
        protocol = protocol,
        version  = version,
        schema   = schema,
        capMask  = capMask,
    }
end

-- Kompatibilität bestimmen (hart nach Spec)
local function determineCompatibility(remoteProtocol)
    if remoteProtocol == CURRENT_PROTOCOL then
        return "FULL"
    elseif remoteProtocol < CURRENT_PROTOCOL then
        return "LEGACY"     -- Remote ist älter: lesen erlaubt, unbekannte Felder ignorieren
    else
        return "LIMITED"    -- Remote ist neuer: nur bekannte Felder nutzen, Warnflag
    end
end

-- Peer im Cache aktualisieren
local function updatePeerCache(nameID, data)
    ensurePeerCache()
    NexusPeerCache[nameID] = {
        protocol = data.protocol,
        version  = data.version,
        schema   = data.schema,
        capMask  = data.capMask or 0,
        lastSeen = time(),
        compat   = determineCompatibility(data.protocol),
    }
    NexusNet.telemetry.peerCacheSize = 0
    for _ in pairs(NexusPeerCache) do
        NexusNet.telemetry.peerCacheSize = NexusNet.telemetry.peerCacheSize + 1
    end
end

-- Handshake-Nachricht verarbeiten
local function HandleHandshake(senderID, payload)
    -- Shield-Validierung
    if NexusShield then
        local ok, _ = NexusShield.ValidatePacket(payload)
        if not ok then return end
    end

    local data = parseHandshakePayload(payload)
    if not data then return end

    -- Nur HS oder HSR akzeptieren
    if data.msgType ~= MSG_HANDSHAKE and data.msgType ~= MSG_HS_REPLY then
        return
    end

    NexusNet.telemetry.handshakeReceived = NexusNet.telemetry.handshakeReceived + 1

    -- Kompatibilität prüfen
    local compat = determineCompatibility(data.protocol)
    if compat == "INCOMPATIBLE" then
        NexusNet.telemetry.protocolMismatchCount =
            NexusNet.telemetry.protocolMismatchCount + 1
        -- Soft Warning, aber nicht blocken
        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus Net] Protocol-Mismatch: %s (remote: %d, local: %d)",
                senderID, data.protocol, CURRENT_PROTOCOL))
        end
        return
    end

    -- Cache aktualisieren
    updatePeerCache(senderID, data)

    -- Auf HS antworten (nicht auf HSR, sonst Loop)
    if data.msgType == MSG_HANDSHAKE then
        SendHandshake(senderID, true)  -- isReply = true
    end

    if NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus Net] Peer %s: Protocol=%d Schema=%d capMask=%d Compat=%s",
            senderID, data.protocol, data.schema, data.capMask, compat))
    end
end

-- ============================================================
-- 6. SOLL HANDSHAKE GESENDET WERDEN?
-- ============================================================

local function ShouldHandshake(nameID)
    ensurePeerCache()
    local cached = NexusPeerCache[nameID]

    -- Unbekannter Peer → immer Handshake
    if not cached then return true end

    -- Peer kürzlich gesehen (< 5 Min) → kein Re-Handshake
    local age = time() - (cached.lastSeen or 0)
    if age < PEER_FRESH_THRESHOLD then return false end

    -- Älter als 5 Min → Handshake wiederholen
    return true
end

-- ============================================================
-- 7. CAPABILITY-AUSWERTUNG
-- ============================================================

-- Prüft ob ein Feature mit einem Peer aktiv sein darf
-- Feature darf nur aktiv sein wenn BEIDE es unterstützen
local function PeerSupportsFeature(nameID, capBit)
    ensurePeerCache()
    local cached = NexusPeerCache[nameID]
    if not cached then return false end  -- Unbekannter Peer: konservativ

    local remoteCaps = cached.capMask or 0
    local localCaps  = LOCAL_CAP_MASK

    -- Feature aktiv wenn beide Seiten das Bit gesetzt haben
    return (bit.band(localCaps, capBit) ~= 0) and
           (bit.band(remoteCaps, capBit) ~= 0)
end

-- Eigene capMask zurückgeben
local function GetLocalCapMask()
    return LOCAL_CAP_MASK
end

-- Peer-Kompatibilität abfragen
local function GetPeerCompat(nameID)
    ensurePeerCache()
    local cached = NexusPeerCache[nameID]
    if not cached then return "UNKNOWN" end
    return cached.compat or "UNKNOWN"
end

-- ============================================================
-- 8. PEER CACHE PRUNING
-- ============================================================

local function PrunePeerCache()
    ensurePeerCache()
    local now    = time()
    local cutoff = now - PEER_CACHE_MAX_AGE
    local removed = 0

    for nameID, entry in pairs(NexusPeerCache) do
        if (entry.lastSeen or 0) < cutoff then
            NexusPeerCache[nameID] = nil
            removed = removed + 1
        end
    end

    if removed > 0 and NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus Net] PeerCache Pruning: %d Eintraege entfernt", removed))
    end

    return removed
end

-- ============================================================
-- 9. ADDON-MESSAGE EVENT HANDLER
-- ============================================================

-- Post empfangen und verarbeiten
local function HandleIncomingPost(senderFull, payload)
    -- Präfix "PT" entfernen
    local wireData = payload:sub(3)  -- "PT" = 2 Zeichen

    -- Shield-Validierung (wenn verfügbar)
    if NexusShield and NexusShield.ValidatePostWire then
        local shieldOK, shieldErr = NexusShield.ValidatePostWire(wireData, senderFull)
        if not shieldOK then
            if NexusConfig and NexusConfig.devMode then
                print(string.format("[Nexus Net] Post von %s durch Shield abgelehnt: %s",
                    senderFull, shieldErr or "?"))
            end
            return
        end
    end

    -- Deserialisieren
    if not NexusPost or not NexusPost.Deserialize then return end
    local post, err = NexusPost.Deserialize(wireData)
    if not post then
        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus Net] Post-Deserialisierung fehlgeschlagen (%s): %s",
                senderFull, err or "?"))
        end
        return
    end

    -- Duplikat-Check
    if NexusPost.IsDuplicate(post.id) then return end
    NexusPost.MarkKnown(post.id)

    -- In DB speichern
    if NexusDB_API and NexusDB_API.SavePost then
        NexusDB_API.SavePost(post)
    end

    -- Feed-Refresh auslösen (wenn UI aktiv)
    if NexusNet.onPostReceived then
        NexusNet.onPostReceived(post)
    end

    if NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus Net] Post empfangen von %s (ID: %s)",
            senderFull, post.id))
    end

    NexusNet.telemetry.postsReceived = (NexusNet.telemetry.postsReceived or 0) + 1
end

-- Post versenden (an Scope-Channel)
local function SendPost(post)
    if not post then return false, "Kein Post-Objekt." end

    -- Serialisieren
    local wire, serErr = NexusPost.Serialize(post)
    if not wire then
        return false, serErr or "Serialisierung fehlgeschlagen."
    end

    -- Nachrichtentyp-Präfix voranstellen
    local payload = MSG_POST .. wire

    -- Channel basierend auf Scope wählen
    local channel
    if post.scope == (NexusPost.SCOPE and NexusPost.SCOPE.GUILD or 1) then
        channel = "GUILD"
    else
        channel = "YELL"  -- Public / Friends → YELL (Zone-weit, kein Server-Spam)
    end

    -- In Comm-Queue einreihen
    if NexusComm and NexusComm.Enqueue then
        NexusComm:Enqueue(channel, payload)
    end

    -- Telemetrie
    NexusNet.telemetry.postsSent = (NexusNet.telemetry.postsSent or 0) + 1

    if NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus Net] Post gesendet (ID: %s, Channel: %s, %d Bytes)",
            post.id, channel, #payload))
    end

    return true, nil
end

local netEventFrame = CreateFrame("Frame", "NexusNetEventFrame")
netEventFrame:RegisterEvent("CHAT_MSG_ADDON")
netEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

netEventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        ensurePeerCache()
        PrunePeerCache()
        -- Prefix registrieren
        C_ChatInfo.RegisterAddonMessagePrefix(MSG_PREFIX)
        print(string.format("[Nexus Net] Initialisiert (v%s)", NET_VERSION))

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, payload, channel, senderFull = ...

        -- Nur NEXUSv1 Nachrichten
        if prefix ~= MSG_PREFIX then return end

        -- Eigene Nachrichten ignorieren
        local myName = UnitName("player") .. "-" .. GetRealmName()
        if senderFull == myName then return end

        -- Message-Type anhand Präfix dispatchen
        local msgType = payload:sub(1, 2)

        if msgType == MSG_HANDSHAKE or msgType == MSG_HS_REPLY then
            HandleHandshake(senderFull, payload)
        elseif msgType == MSG_POST then
            HandleIncomingPost(senderFull, payload)
        end

        -- Wenn unbekannter Peer: Handshake initiieren
        if ShouldHandshake(senderFull) then
            SendHandshake(senderFull, false)
        end
    end
end)

-- ============================================================
-- 10. PUBLIC API
-- ============================================================

NexusNet = {
    -- Handshake
    SendHandshake        = SendHandshake,
    ShouldHandshake      = ShouldHandshake,

    -- Post-System
    SendPost             = SendPost,
    onPostReceived       = nil,  -- Callback: function(post) end – wird von Feed-Panel gesetzt

    -- Capability-System
    PeerSupportsFeature  = PeerSupportsFeature,
    GetLocalCapMask      = GetLocalCapMask,
    GetPeerCompat        = GetPeerCompat,

    -- Capability-Konstanten (public)
    CAP_PROFILE_V2       = CAP_PROFILE_V2,
    CAP_PLAYSTYLE_EXT    = CAP_PLAYSTYLE_EXT,
    CAP_POSE             = CAP_POSE,
    CAP_BACKGROUND       = CAP_BACKGROUND,
    CAP_RAIDERIO         = CAP_RAIDERIO,
    CAP_POST_V1          = CAP_POST_V1,
    CAP_EXPERIMENTAL     = CAP_EXPERIMENTAL,

    -- Cache
    PrunePeerCache       = PrunePeerCache,

    -- Protokoll-Info
    PROTOCOL             = CURRENT_PROTOCOL,
    SCHEMA               = CURRENT_SCHEMA,
    VERSION              = CURRENT_VERSION,

    -- Telemetrie
    telemetry = {
        handshakeSent         = 0,
        handshakeReceived     = 0,
        handshakeSkipped      = 0,
        protocolMismatchCount = 0,
        peerCacheSize         = 0,
        postsSent             = 0,
        postsReceived         = 0,
    },

    RunTests = nil,  -- wird unten gesetzt
}

_G.NexusNet = NexusNet

print(string.format("[Nexus Net] Modul geladen (v%s, Protocol %d)",
    NET_VERSION, CURRENT_PROTOCOL))

-- ============================================================
-- 11. UNIT TESTS
-- ============================================================

local function RunNetTests()
    print("\n=== NEXUS_NET UNIT TESTS ===\n")

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

    -- Backup echter Cache
    local realCache = NexusPeerCache
    NexusPeerCache = {}

    -- Test 1: Payload-Größe ≤ 64 Bytes
    local payload = buildHandshakePayload(MSG_HANDSHAKE)
    Assert(#payload <= HANDSHAKE_MAX_BYTES,
        string.format("Handshake-Payload <= 64 Bytes (aktuell: %d)", #payload))

    -- Test 2: Payload parsen - gültig
    local data = parseHandshakePayload("HS|1|0.2.0-alpha|2|15")
    Assert(data ~= nil, "Gueltiger Handshake-Payload wird geparst")
    Assert(data and data.protocol == 1, "Protokoll korrekt geparst (1)")
    Assert(data and data.schema == 2, "Schema korrekt geparst (2)")
    Assert(data and data.capMask == 15, "capMask korrekt geparst (15)")
    Assert(data and data.version == "0.2.0-alpha", "Version korrekt geparst")

    -- Test 3: Payload parsen - ungültig
    local bad = parseHandshakePayload("INVALID_DATA")
    Assert(bad == nil, "Ungueltiger Payload gibt nil zurueck")

    -- Test 4: Kompatibilitätsmatrix
    Assert(determineCompatibility(1) == "FULL",    "Protocol gleich → FULL")
    Assert(determineCompatibility(0) == "LEGACY",  "Protocol aelter → LEGACY")
    Assert(determineCompatibility(2) == "LIMITED", "Protocol neuer → LIMITED")

    -- Test 5: ShouldHandshake - unbekannter Peer
    NexusPeerCache = {}
    Assert(ShouldHandshake("Unbekannt-Realm") == true,
        "Unbekannter Peer: ShouldHandshake = true")

    -- Test 6: ShouldHandshake - frischer Peer (< 5 Min)
    NexusPeerCache["Bekannt-Realm"] = {
        protocol = 1, version = "0.2.0", schema = 2, capMask = 15,
        lastSeen = time(),  -- Jetzt
        compat = "FULL"
    }
    Assert(ShouldHandshake("Bekannt-Realm") == false,
        "Frischer Peer (< 5 Min): ShouldHandshake = false")

    -- Test 7: ShouldHandshake - alter Peer (> 5 Min)
    NexusPeerCache["AlterPeer-Realm"] = {
        protocol = 1, version = "0.1.0", schema = 2, capMask = 0,
        lastSeen = time() - 600,  -- 10 Min alt
        compat = "FULL"
    }
    Assert(ShouldHandshake("AlterPeer-Realm") == true,
        "Alter Peer (> 5 Min): ShouldHandshake = true")

    -- Test 8: updatePeerCache schreibt korrekt
    updatePeerCache("TestPeer-Realm", {
        protocol = 1, version = "0.2.0", schema = 2, capMask = 7
    })
    local entry = NexusPeerCache["TestPeer-Realm"]
    Assert(entry ~= nil, "updatePeerCache erstellt Eintrag")
    Assert(entry and entry.protocol == 1, "Peer-Cache: protocol korrekt")
    Assert(entry and entry.capMask == 7, "Peer-Cache: capMask korrekt")
    Assert(entry and entry.compat == "FULL", "Peer-Cache: compat = FULL")

    -- Test 9: Capability-Auswertung
    -- Beide haben CAP_PROFILE_V2 (bit 0)
    NexusPeerCache["CapPeer-Realm"] = {
        protocol = 1, version = "0.2.0", schema = 2,
        capMask = CAP_PROFILE_V2 + CAP_POSE,
        lastSeen = time(), compat = "FULL"
    }
    Assert(PeerSupportsFeature("CapPeer-Realm", CAP_PROFILE_V2) == true,
        "Capability: beide haben CAP_PROFILE_V2 → true")
    Assert(PeerSupportsFeature("CapPeer-Realm", CAP_EXPERIMENTAL) == false,
        "Capability: Peer hat CAP_EXPERIMENTAL nicht → false")
    Assert(PeerSupportsFeature("CapPeer-Realm", CAP_RAIDERIO) == false,
        "Capability: Peer hat CAP_RAIDERIO nicht → false")

    -- Test 10: Capability - unbekannter Peer konservativ
    Assert(PeerSupportsFeature("Unbekannt-Realm", CAP_PROFILE_V2) == false,
        "Unbekannter Peer: Feature konservativ = false")

    -- Test 11: PeerCache Pruning
    NexusPeerCache["AlterEintrag-Realm"] = {
        protocol = 1, version = "0.1.0", schema = 1, capMask = 0,
        lastSeen = time() - (PEER_CACHE_MAX_AGE + 1),
        compat = "FULL"
    }
    NexusPeerCache["NeuerEintrag-Realm"] = {
        protocol = 1, version = "0.2.0", schema = 2, capMask = 15,
        lastSeen = time(),
        compat = "FULL"
    }
    local pruned = PrunePeerCache()
    Assert(pruned >= 1, "Pruning entfernt alte Eintraege")
    Assert(NexusPeerCache["NeuerEintrag-Realm"] ~= nil,
        "Pruning belaesst neue Eintraege")
    Assert(NexusPeerCache["AlterEintrag-Realm"] == nil,
        "Pruning entfernt alten Eintrag")

    -- Test 12: GetPeerCompat
    Assert(GetPeerCompat("NeuerEintrag-Realm") == "FULL",
        "GetPeerCompat gibt FULL zurueck")
    Assert(GetPeerCompat("Unbekannt-Realm") == "UNKNOWN",
        "GetPeerCompat gibt UNKNOWN fuer unbekannte Peers")

    -- Test 13: Local capMask korrekt
    local localCap = GetLocalCapMask()
    Assert(bit.band(localCap, CAP_PROFILE_V2) ~= 0,
        "LocalCapMask hat CAP_PROFILE_V2 gesetzt")
    Assert(bit.band(localCap, CAP_EXPERIMENTAL) == 0,
        "LocalCapMask hat CAP_EXPERIMENTAL NICHT gesetzt")

    -- Test 14: HSR wird nicht als neuer Handshake behandelt
    local hsr = parseHandshakePayload("HSR|1|0.2.0-alpha|2|15")
    Assert(hsr ~= nil, "HSR-Payload wird geparst")
    Assert(hsr and hsr.msgType == "HSR", "HSR msgType korrekt erkannt")

    -- Echter Cache wiederherstellen
    NexusPeerCache = realCache

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

NexusNet.RunTests = RunNetTests
