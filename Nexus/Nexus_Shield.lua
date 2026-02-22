--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_Shield (Zero-Trust Payload Validierung)
    Spezifikation: Nexus_Critical_Implementation_Checklist.docx
                   Nexus_ProfileSchema_v2.docx

    Grundsatz:
    Alle eingehenden Daten gelten als bösartig bis validiert.
    Ungültige Profile werden STILLSCHWEIGEND verworfen.
    Keine Exceptions, kein Chat-Spam.

    Version: 0.0.3-alpha
]]

-- ============================================================
-- 1. KONSTANTEN
-- ============================================================

local SHIELD_VERSION = "0.6.0-alpha"

-- Feldlängen-Limits (VERBINDLICH)
local LIMIT_BIO        = 255   -- Zeichen
local LIMIT_NAME_ID    = 50    -- Zeichen
local LIMIT_HOUSE_COORD = 30   -- Zeichen (Format: "mapID:x:y")
local LIMIT_PROFILE_BYTES = 768  -- Bytes serialisiert
local LIMIT_PACKET_BYTES  = 512  -- Bytes pro Paket

-- Bitmask-Grenzen (VERBINDLICH)
local BITMASK_PLAY_DAYS  = 127    -- 7 bits (Mo-So)
local BITMASK_PLAY_TIME  = 31     -- 5 bits
local BITMASK_PLAYSTYLE  = 255    -- 8 bits
local BITMASK_POSE_ID    = 255    -- 8 bits
local BITMASK_BACKGROUND = 255    -- 8 bits
local BITMASK_VISIBILITY = 2      -- 0-2 (drei Sichtbarkeits-Stufen)
local BITMASK_CAP_MASK   = 65535  -- 16 bits (Capability-System)

-- Erlaubte Felder (Whitelist - VERBINDLICH)
local ALLOWED_FIELDS = {
    schemaVersion  = true,
    nameID         = true,
    guid           = true,
    lastSeen       = true,
    bio            = true,
    houseCoord     = true,
    visibility     = true,
    playDaysMask   = true,
    playTimeMask   = true,
    playstyleMask  = true,
    poseID         = true,
    backgroundID   = true,
}

-- ============================================================
-- 2. HILFSFUNKTIONEN (intern)
-- ============================================================

-- Einfache Serialisierung für Größenprüfung
-- Gibt approximative Byte-Anzahl zurück
local function estimateSize(t)
    if type(t) == "string" then
        return #t
    elseif type(t) == "number" then
        return 8
    elseif type(t) == "boolean" then
        return 1
    elseif type(t) == "table" then
        local size = 2  -- {} overhead
        for k, v in pairs(t) do
            size = size + estimateSize(k) + estimateSize(v) + 2
        end
        return size
    end
    return 0
end

-- Bitmask-Validierung
local function validateBitmask(value, maxValue, fieldName)
    if type(value) ~= "number" then
        return false
    end
    if value < 0 or value > maxValue then
        return false
    end
    -- Keine Dezimalzahlen (muss Integer sein)
    if value ~= math.floor(value) then
        return false
    end
    return true
end

-- houseCoord Format prüfen: "mapID:x:y"
-- mapID = Zahl, x = 0.0-1.0, y = 0.0-1.0
local function validateHouseCoord(coord)
    if type(coord) ~= "string" then return false end
    if #coord > LIMIT_HOUSE_COORD then return false end

    -- Kein Leerzeichen erlaubt
    if coord:find(" ") then return false end

    -- Format parsen: mapID:x:y
    local mapID, x, y = coord:match("^(%d+):([%d%.]+):([%d%.]+)$")
    if not mapID or not x or not y then
        return false
    end

    -- x und y müssen zwischen 0 und 1 sein
    local xNum = tonumber(x)
    local yNum = tonumber(y)
    if not xNum or not yNum then return false end
    if xNum < 0 or xNum > 1 then return false end
    if yNum < 0 or yNum > 1 then return false end

    return true
end

-- GUID Format prüfen: optional, wenn vorhanden "0x..." 10-20 Zeichen
local function validateGUID(guid)
    if guid == nil then return true end  -- Optional
    if type(guid) ~= "string" then return false end
    if #guid < 10 or #guid > 20 then return false end
    -- Darf nur alphanumerische Zeichen und Bindestrich enthalten
    if guid:find("[^%w%-]") then return false end
    return true
end

-- ============================================================
-- 3. HAUPT-VALIDATOR: PROFIL
-- ============================================================

-- Validiert ein eingehendes Profil-Objekt vollständig
-- Gibt (true) oder (false, reason) zurück
-- Bei false: Profil STILLSCHWEIGEND verwerfen
local function ValidateProfile(profile)
    -- Nil-Check
    if profile == nil then
        return false, "nil"
    end

    -- Typ-Check: muss table sein
    if type(profile) ~= "table" then
        return false, "kein table"
    end

    -- Metatable-Check: keine Metatables erlaubt
    if getmetatable(profile) ~= nil then
        return false, "metatable"
    end

    -- Tiefenprüfung: keine verschachtelten Tabellen (max 1 Ebene)
    for k, v in pairs(profile) do
        if type(v) == "table" then
            return false, "verschachtelte table: " .. tostring(k)
        end
        if type(v) == "function" then
            return false, "funktion im profil: " .. tostring(k)
        end
    end

    -- Whitelist: nur erlaubte Felder
    for k, _ in pairs(profile) do
        if not ALLOWED_FIELDS[k] then
            return false, "unbekanntes Feld: " .. tostring(k)
        end
    end

    -- Pflichtfeld: schemaVersion
    if type(profile.schemaVersion) ~= "number" then
        return false, "schemaVersion fehlt oder kein number"
    end
    -- Nur Schema v1 oder v2 akzeptieren
    if profile.schemaVersion ~= 1 and profile.schemaVersion ~= 2 then
        return false, "schemaVersion unbekannt: " .. tostring(profile.schemaVersion)
    end

    -- Pflichtfeld: nameID
    if type(profile.nameID) ~= "string" then
        return false, "nameID fehlt oder kein string"
    end
    if #profile.nameID == 0 then
        return false, "nameID leer"
    end
    if #profile.nameID > LIMIT_NAME_ID then
        return false, "nameID zu lang"
    end

    -- Pflichtfeld: lastSeen
    if type(profile.lastSeen) ~= "number" then
        return false, "lastSeen fehlt oder kein number"
    end
    if profile.lastSeen < 0 then
        return false, "lastSeen negativ"
    end

    -- Optionales Feld: guid
    if not validateGUID(profile.guid) then
        return false, "guid Format ungültig"
    end

    -- Optionales Feld: bio
    if profile.bio ~= nil then
        if type(profile.bio) ~= "string" then
            return false, "bio kein string"
        end
        if #profile.bio > LIMIT_BIO then
            return false, "bio zu lang"
        end
    end

    -- Optionales Feld: houseCoord
    if profile.houseCoord ~= nil then
        if not validateHouseCoord(profile.houseCoord) then
            return false, "houseCoord Format ungültig"
        end
    end

    -- Pflichtfeld: visibility
    if profile.visibility ~= nil then
        if not validateBitmask(profile.visibility, BITMASK_VISIBILITY, "visibility") then
            return false, "visibility ungültig (muss 0-2 sein)"
        end
    end

    -- Bitmask-Felder
    if profile.playDaysMask ~= nil then
        if not validateBitmask(profile.playDaysMask, BITMASK_PLAY_DAYS, "playDaysMask") then
            return false, "playDaysMask ungültig (muss 0-127)"
        end
    end

    if profile.playTimeMask ~= nil then
        if not validateBitmask(profile.playTimeMask, BITMASK_PLAY_TIME, "playTimeMask") then
            return false, "playTimeMask ungültig (muss 0-31)"
        end
    end

    if profile.playstyleMask ~= nil then
        if not validateBitmask(profile.playstyleMask, BITMASK_PLAYSTYLE, "playstyleMask") then
            return false, "playstyleMask ungültig (muss 0-255)"
        end
    end

    if profile.poseID ~= nil then
        if not validateBitmask(profile.poseID, BITMASK_POSE_ID, "poseID") then
            return false, "poseID ungültig (muss 0-255)"
        end
    end

    if profile.backgroundID ~= nil then
        if not validateBitmask(profile.backgroundID, BITMASK_BACKGROUND, "backgroundID") then
            return false, "backgroundID ungültig (muss 0-255)"
        end
    end

    -- Größenprüfung (approximativ)
    local estimatedSize = estimateSize(profile)
    if estimatedSize > LIMIT_PROFILE_BYTES then
        return false, string.format("Profil zu gross: ~%d > %d Bytes", estimatedSize, LIMIT_PROFILE_BYTES)
    end

    return true
end

-- ============================================================
-- 4. PAKET-VALIDATOR
-- ============================================================

-- Validiert ein rohes Paket (String) vor dem Parsen
local function ValidatePacket(payload)
    if type(payload) ~= "string" then
        return false, "payload kein string"
    end
    if #payload == 0 then
        return false, "payload leer"
    end
    if #payload > LIMIT_PACKET_BYTES then
        return false, string.format("payload zu gross: %d > %d Bytes", #payload, LIMIT_PACKET_BYTES)
    end
    return true
end

-- ============================================================
-- 5. HANDSHAKE-VALIDATOR
-- ============================================================

-- Validiert ein Handshake-Payload
local function ValidateHandshake(hs)
    if type(hs) ~= "table" then return false, "kein table" end
    if getmetatable(hs) ~= nil then return false, "metatable" end

    if type(hs.protocol) ~= "number" or hs.protocol < 1 then
        return false, "protocol ungültig"
    end
    if type(hs.version) ~= "string" or #hs.version == 0 or #hs.version > 20 then
        return false, "version ungültig"
    end
    if type(hs.schema) ~= "number" or hs.schema < 1 then
        return false, "schema ungültig"
    end
    -- capMask optional
    if hs.capMask ~= nil then
        if not validateBitmask(hs.capMask, BITMASK_CAP_MASK, "capMask") then
            return false, "capMask ungültig (muss 0-65535)"
        end
    end

    return true
end

-- ============================================================
-- 5b. POST-PAYLOAD VALIDIERUNG (Structured Post System)
-- ============================================================

local POST_MAX_WIRE_BYTES = 750
local POST_MAX_TEXT_LEN   = 500
local POST_MAX_LINKS      = 5
local POST_WIRE_FIELDS    = 9
local POST_SCHEMA_MAX     = 1   -- Höchste bekannte Schema-Version

-- Validiert einen rohen Wire-String BEVOR Deserialisierung
-- Erste Sicherheitslinie – kein NexusPost.Deserialize nötig
local function ValidatePostWire(wire, senderName)
    -- Nil / leer
    if not wire or wire == "" then
        return false, "Wire-String leer."
    end

    -- Größe prüfen (Byte-Limit – vor jedem Split!)
    if #wire > POST_MAX_WIRE_BYTES then
        return false, string.format("Payload zu groß: %d Bytes (max %d).", #wire, POST_MAX_WIRE_BYTES)
    end

    -- Keine Lua-Code-Injection (loadstring, eval-ähnliche Konstrukte)
    if wire:find("loadstring") or wire:find("dofile") or wire:find("load%(") then
        return false, "Verbotene Konstrukte in Payload."
    end

    -- Feldanzahl prüfen (exakt 9 Felder, getrennt durch |)
    local fieldCount = 0
    for _ in wire:gmatch("[^|]+") do
        fieldCount = fieldCount + 1
    end
    -- Auch leere Felder zählen
    local pipeCount = 0
    for _ in wire:gmatch("|") do pipeCount = pipeCount + 1 end
    local totalFields = pipeCount + 1
    if totalFields ~= POST_WIRE_FIELDS then
        return false, string.format("Falsche Feldanzahl: %d (erwartet %d).", totalFields, POST_WIRE_FIELDS)
    end

    -- Felder auslesen (minimal, ohne volles Parsing)
    local fields = {}
    for field in (wire .. "|"):gmatch("([^|]*)|") do
        table.insert(fields, field)
    end

    -- version (Feld 1) muss numerisch sein
    local version = tonumber(fields[1])
    if not version or version < 1 or version > POST_SCHEMA_MAX then
        -- Neuere Version: warnen aber nicht blockieren (Forward-Compat)
        if version and version > POST_SCHEMA_MAX then
            -- Akzeptieren, aber Telemetrie
        else
            return false, "Ungültige Schema-Version."
        end
    end

    -- postID (Feld 2) muss vorhanden und nicht leer sein
    if not fields[2] or fields[2] == "" then
        return false, "Fehlende postID."
    end
    if #fields[2] > 32 then
        return false, "postID zu lang."
    end

    -- authorGUID (Feld 3)
    if not fields[3] or fields[3] == "" then
        return false, "Fehlende authorGUID."
    end

    -- authorName (Feld 4) – max 100 Zeichen (Name-Realm)
    if not fields[4] or #fields[4] > 100 then
        return false, "Ungültiger authorName."
    end

    -- timestamp (Feld 5) muss numerisch und plausibel sein
    local ts = tonumber(fields[5])
    if not ts or ts < 1000000000 or ts > (time() + 300) then
        return false, "Ungültiger Timestamp."
    end

    -- scope (Feld 6) muss 1, 2 oder 4 sein
    local scope = tonumber(fields[6])
    if scope ~= 1 and scope ~= 2 and scope ~= 4 then
        return false, "Ungültiger Scope-Wert."
    end

    -- text (Feld 7) Länge prüfen
    local text = fields[7] or ""
    if #text > POST_MAX_TEXT_LEN then
        return false, string.format("Text zu lang: %d Zeichen (max %d).", #text, POST_MAX_TEXT_LEN)
    end

    -- Links (Feld 8) Anzahl prüfen
    local linksStr = fields[8] or ""
    if linksStr ~= "0" and linksStr ~= "" then
        local linkCount = 0
        for _ in linksStr:gmatch("[^,]+") do linkCount = linkCount + 1 end
        if linkCount > POST_MAX_LINKS then
            return false, string.format("Zu viele Links: %d (max %d).", linkCount, POST_MAX_LINKS)
        end
        -- Jedes Link-Paar muss "number:number" sein
        for pair in linksStr:gmatch("[^,]+") do
            local t, i = pair:match("^(%d+):(%d+)$")
            if not t or not i then
                return false, "Ungültiges Link-Format."
            end
        end
    end

    -- checksum (Feld 9) muss 6-stelliger Hex sein
    local checksum = fields[9] or ""
    if not checksum:match("^%x%x%x%x%x%x$") then
        return false, "Ungültige Checksum-Format."
    end

    return true, nil
end

-- ============================================================
-- 6. PUBLIC API
-- ============================================================

NexusShield = {
    ValidateProfile    = ValidateProfile,
    ValidatePacket     = ValidatePacket,
    ValidateHandshake  = ValidateHandshake,
    ValidateBitmask    = validateBitmask,
    ValidateGUID       = validateGUID,
    ValidateHouseCoord = validateHouseCoord,
    -- Post-System
    ValidatePostWire   = ValidatePostWire,
}

_G.NexusShield = NexusShield

_G.Nexus_Shield = {
    ValidateProfile    = ValidateProfile,
    ValidatePacket     = ValidatePacket,
    ValidateHandshake  = ValidateHandshake,
    ValidatePostWire   = ValidatePostWire,
    RunTests           = nil,  -- wird unten gesetzt
}

print(string.format("[Nexus Shield] Modul geladen (v%s)", SHIELD_VERSION))

-- ============================================================
-- 7. UNIT TESTS (20+)
-- ============================================================

local function RunShieldTests()
    print("\n=== NEXUS_SHIELD UNIT TESTS ===\n")

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

    -- Basis-Profil fuer Tests
    local function baseProfile()
        return {
            schemaVersion = 2,
            nameID        = "Testchar-Realm",
            lastSeen      = 1700000000,
            bio           = "Hallo Nexus!",
            visibility    = 1,
            playDaysMask  = 63,
            playTimeMask  = 15,
            playstyleMask = 7,
        }
    end

    -- Test 1: Gueltiges Profil wird akzeptiert
    local ok, _ = ValidateProfile(baseProfile())
    Assert(ok == true, "Gueltiges Profil wird akzeptiert")

    -- Test 2: nil wird abgelehnt
    local ok2, _ = ValidateProfile(nil)
    Assert(ok2 == false, "nil wird abgelehnt")

    -- Test 3: Kein table wird abgelehnt
    local ok3, _ = ValidateProfile("string")
    Assert(ok3 == false, "String wird als Profil abgelehnt")

    -- Test 4: Metatable wird abgelehnt
    local badProfile = setmetatable({}, {})
    local ok4, _ = ValidateProfile(badProfile)
    Assert(ok4 == false, "Profil mit Metatable wird abgelehnt")

    -- Test 5: Unbekanntes Feld wird abgelehnt
    local p5 = baseProfile()
    p5.hackerField = "exploit"
    local ok5, _ = ValidateProfile(p5)
    Assert(ok5 == false, "Unbekanntes Feld wird abgelehnt")

    -- Test 6: Funktion im Profil wird abgelehnt
    local p6 = baseProfile()
    p6.bio = function() end
    local ok6, _ = ValidateProfile(p6)
    Assert(ok6 == false, "Funktion im Profil wird abgelehnt")

    -- Test 7: Verschachtelte Tabelle wird abgelehnt
    local p7 = baseProfile()
    p7.bio = { nested = "table" }
    local ok7, _ = ValidateProfile(p7)
    Assert(ok7 == false, "Verschachtelte Tabelle wird abgelehnt")

    -- Test 8: schemaVersion fehlt
    local p8 = baseProfile()
    p8.schemaVersion = nil
    local ok8, _ = ValidateProfile(p8)
    Assert(ok8 == false, "Fehlendes schemaVersion wird abgelehnt")

    -- Test 9: Unbekannte schemaVersion
    local p9 = baseProfile()
    p9.schemaVersion = 99
    local ok9, _ = ValidateProfile(p9)
    Assert(ok9 == false, "Unbekannte schemaVersion (99) wird abgelehnt")

    -- Test 10: nameID leer
    local p10 = baseProfile()
    p10.nameID = ""
    local ok10, _ = ValidateProfile(p10)
    Assert(ok10 == false, "Leere nameID wird abgelehnt")

    -- Test 11: nameID zu lang
    local p11 = baseProfile()
    p11.nameID = string.rep("A", LIMIT_NAME_ID + 1)
    local ok11, _ = ValidateProfile(p11)
    Assert(ok11 == false, "Zu lange nameID wird abgelehnt")

    -- Test 12: bio zu lang (String-Bombe)
    local p12 = baseProfile()
    p12.bio = string.rep("X", LIMIT_BIO + 1)
    local ok12, _ = ValidateProfile(p12)
    Assert(ok12 == false, "Zu lange bio wird abgelehnt (>" .. LIMIT_BIO .. " Zeichen)")

    -- Test 13: playDaysMask zu gross
    local p13 = baseProfile()
    p13.playDaysMask = BITMASK_PLAY_DAYS + 1
    local ok13, _ = ValidateProfile(p13)
    Assert(ok13 == false, "playDaysMask > 127 wird abgelehnt")

    -- Test 14: playTimeMask zu gross
    local p14 = baseProfile()
    p14.playTimeMask = BITMASK_PLAY_TIME + 1
    local ok14, _ = ValidateProfile(p14)
    Assert(ok14 == false, "playTimeMask > 31 wird abgelehnt")

    -- Test 15: playstyleMask negativ
    local p15 = baseProfile()
    p15.playstyleMask = -1
    local ok15, _ = ValidateProfile(p15)
    Assert(ok15 == false, "Negative playstyleMask wird abgelehnt")

    -- Test 16: visibility ausserhalb 0-2
    local p16 = baseProfile()
    p16.visibility = 3
    local ok16, _ = ValidateProfile(p16)
    Assert(ok16 == false, "visibility > 2 wird abgelehnt")

    -- Test 17: Gueltiger houseCoord
    local p17 = baseProfile()
    p17.houseCoord = "1234:0.5:0.75"
    local ok17, _ = ValidateProfile(p17)
    Assert(ok17 == true, "Gueltiger houseCoord wird akzeptiert")

    -- Test 18: Ungültiger houseCoord (Leerzeichen)
    local p18 = baseProfile()
    p18.houseCoord = "1234: 0.5:0.75"
    local ok18, _ = ValidateProfile(p18)
    Assert(ok18 == false, "houseCoord mit Leerzeichen wird abgelehnt")

    -- Test 19: Ungültiger houseCoord (x > 1)
    local p19 = baseProfile()
    p19.houseCoord = "1234:1.5:0.5"
    local ok19, _ = ValidateProfile(p19)
    Assert(ok19 == false, "houseCoord mit x > 1 wird abgelehnt")

    -- Test 20: Gueltiger GUID
    local p20 = baseProfile()
    p20.guid = "0xF1234ABCD"
    local ok20, _ = ValidateProfile(p20)
    Assert(ok20 == true, "Gueltiger GUID wird akzeptiert")

    -- Test 21: GUID zu kurz
    local ok21 = validateGUID("abc")
    Assert(ok21 == false, "Zu kurzer GUID wird abgelehnt")

    -- Test 22: GUID mit Sonderzeichen
    local ok22 = validateGUID("0xABCD!@#$%")
    Assert(ok22 == false, "GUID mit Sonderzeichen wird abgelehnt")

    -- Test 23: Paket-Validator - gueltig
    local ok23, _ = ValidatePacket("Hallo Nexus Paket")
    Assert(ok23 == true, "Gueltiges Paket wird akzeptiert")

    -- Test 24: Paket-Validator - zu gross
    local ok24, _ = ValidatePacket(string.rep("X", LIMIT_PACKET_BYTES + 1))
    Assert(ok24 == false, "Zu grosses Paket wird abgelehnt (>" .. LIMIT_PACKET_BYTES .. " Bytes)")

    -- Test 25: Paket-Validator - leer
    local ok25, _ = ValidatePacket("")
    Assert(ok25 == false, "Leeres Paket wird abgelehnt")

    -- Test 26: Handshake-Validator - gueltig
    local ok26, _ = ValidateHandshake({ protocol = 1, version = "0.0.3", schema = 2, capMask = 7 })
    Assert(ok26 == true, "Gueltiger Handshake wird akzeptiert")

    -- Test 27: Handshake - capMask zu gross
    local ok27, _ = ValidateHandshake({ protocol = 1, version = "0.0.3", schema = 2, capMask = 99999 })
    Assert(ok27 == false, "Handshake mit capMask > 65535 wird abgelehnt")

    -- Test 28: lastSeen negativ
    local p28 = baseProfile()
    p28.lastSeen = -100
    local ok28, _ = ValidateProfile(p28)
    Assert(ok28 == false, "Negatives lastSeen wird abgelehnt")

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

_G.Nexus_Shield.RunTests = RunShieldTests
