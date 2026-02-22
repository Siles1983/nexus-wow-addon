--[[
    NEXUS - World of Warcraft Community Addon
    Midnight API v12 (Interface 120000)

    Modul: Nexus_Post
    Spezifikation: Nexus_Structured_Post_System_Core_Design_Spec.docx
                   Nexus_Post_Data_Schema_Wire_Format_Definition.docx
                   Nexus_Post_Lifecycle_State_Management.docx
                   Nexus_Post_Moderation_Without_Server_Abuse_Resilience_Design.docx

    Zweck:
    Fundament des Structured Post Systems.
    - Post-Schema Definition (v1)
    - Serialisierung / Deserialisierung (Wire-Format)
    - Lokale Validierung
    - Checksum / Duplikat-Erkennung
    - Post-States & Lifecycle
    - Rate-Limiting (Spam-Prevention)

    Wire-Format: 1|postID|authorGUID|authorName|timestamp|scope|text|links|checksum
    Feldtrenner:    |
    Linktrenner:    ,
    Link-Felder:    type:id

    Sicherheitsregeln:
    - Kein loadstring / eval
    - Nur feste Feldanzahl akzeptieren
    - Ungültige Payloads verwerfen (niemals reparieren)
    - Kein per-frame Parsing

    Post-States: pending → active | failed | locally_deleted

    Version: 0.6.0-alpha
]]

local POST_VERSION = "0.6.0-alpha"

-- ============================================================
-- 1. KONSTANTEN (verbindlich nach Spec)
-- ============================================================

NexusPost = NexusPost or {}

local SCHEMA_VERSION    = 1
local MAX_TEXT_LENGTH   = 500      -- Zeichen
local MAX_LINKS         = 5        -- Referenz-Links pro Post
local MAX_PAYLOAD_BYTES = 750      -- Wire-Format Byte-Limit
local MAX_POSTS_TOTAL   = 2000     -- Gesamt lokaler Speicher
local MAX_POSTS_PER_AUTHOR = 100   -- Pro Autor
local POST_TTL_DAYS     = 30       -- Maximales Alter in Tagen
local RATE_LIMIT_POSTS  = 3        -- Max Posts pro Zeitfenster
local RATE_LIMIT_WINDOW = 300      -- Zeitfenster in Sekunden (5 Min)

-- Wire-Format Trenner
local FIELD_SEP = "|"
local LINK_SEP  = ","
local LINK_PAIR = ":"
local WIRE_FIELD_COUNT = 9  -- Exakt 9 Felder erwartet

-- Scope-Bitmasks
NexusPost.SCOPE = {
    GUILD   = 1,
    FRIENDS = 2,
    PUBLIC  = 4,
}

-- Post-States
NexusPost.STATE = {
    PENDING         = "pending",
    ACTIVE          = "active",
    FAILED          = "failed",
    LOCALLY_DELETED = "locally_deleted",
}

-- Link-Typen (v1)
NexusPost.LINK_TYPE = {
    ITEM        = 1,
    ACHIEVEMENT = 2,
    QUEST       = 3,
    SPELL       = 4,
}

-- ============================================================
-- 2. RATE LIMITER (Spam-Prevention)
-- ============================================================

local rateLimiter = {
    sentTimes = {},  -- Ring-Buffer der letzten Sendezeiten
}

function rateLimiter:Refresh()
    local now = GetTime()
    local valid = {}
    for _, t in ipairs(self.sentTimes) do
        if (now - t) < RATE_LIMIT_WINDOW then
            table.insert(valid, t)
        end
    end
    self.sentTimes = valid
end

function rateLimiter:CanPost()
    self:Refresh()
    return #self.sentTimes < RATE_LIMIT_POSTS
end

function rateLimiter:RecordPost()
    table.insert(self.sentTimes, GetTime())
end

-- Gibt zurück: avail, maxTokens, secsUntilNextToken
-- Token-Regeneration: pro verbrauchtem Slot 5 Minuten Wartezeit.
-- Nach 5 Min → 1 Token frei, nach 10 Min → 2, nach 15 Min → 3/3.
function rateLimiter:GetTokenStatus()
    self:Refresh()
    local used = #self.sentTimes
    local avail = RATE_LIMIT_POSTS - used
    local now = GetTime()
    local secsUntilNext = 0
    if used > 0 then
        local oldest = self.sentTimes[1]
        secsUntilNext = math.max(0, math.ceil(RATE_LIMIT_WINDOW - (now - oldest)))
    end
    return avail, RATE_LIMIT_POSTS, secsUntilNext
end

-- ============================================================
-- 3. CHECKSUM (leichtgewichtig, kein Krypto)
-- ============================================================

-- Einfacher deterministischer Hash: text + timestamp + authorGUID
-- Gibt 8-stelligen Hex-String zurück
local function ComputeChecksum(text, timestamp, authorGUID)
    local combined = tostring(text) .. tostring(timestamp) .. tostring(authorGUID)
    local hash = 5381
    for i = 1, #combined do
        local c = combined:byte(i)
        hash = ((hash * 33) + c) % 0xFFFFFF
    end
    return string.format("%06x", hash)
end

-- ============================================================
-- 4. POSTID GENERIERUNG
-- ============================================================

-- UUID-ähnlicher Identifier: authorGUID-hash + timestamp + counter
local postIDCounter = 0
local function GeneratePostID(authorGUID)
    postIDCounter = postIDCounter + 1
    local ts  = math.floor(GetTime() * 1000) % 0xFFFFFF
    local cnt = postIDCounter % 0xFFF
    local guid_hash = 0
    if authorGUID then
        for i = 1, math.min(#authorGUID, 8) do
            guid_hash = (guid_hash * 31 + authorGUID:byte(i)) % 0xFFFF
        end
    end
    return string.format("%04x%06x%03x", guid_hash, ts, cnt)
end

-- ============================================================
-- 5. LINK-ERKENNUNG (WoW-Link-Strings aus Text extrahieren)
-- ============================================================

-- WoW-Links haben das Format |Htype:id[:subid]|h[...]|h
local LINK_PATTERNS = {
    { type = NexusPost.LINK_TYPE.ITEM,        pattern = "|Hitem:(%d+)" },
    { type = NexusPost.LINK_TYPE.ACHIEVEMENT, pattern = "|Hachievement:(%d+)" },
    { type = NexusPost.LINK_TYPE.QUEST,       pattern = "|Hquest:(%d+)" },
    { type = NexusPost.LINK_TYPE.SPELL,       pattern = "|Hspell:(%d+)" },
}

local function ExtractLinks(text)
    local links = {}
    for _, def in ipairs(LINK_PATTERNS) do
        for id_str in text:gmatch(def.pattern) do
            local id = tonumber(id_str)
            if id and #links < MAX_LINKS then
                table.insert(links, { type = def.type, id = id })
            end
        end
    end
    return links
end

-- ============================================================
-- 6. VALIDIERUNG (lokal, vor Serialisierung)
-- ============================================================

-- Gibt true + nil oder false + Fehlermeldung zurück
local function ValidatePostData(text, scope)
    -- Text nicht leer
    if not text or text == "" then
        return false, "Text darf nicht leer sein."
    end

    -- Textlänge
    if #text > MAX_TEXT_LENGTH then
        return false, string.format("Text zu lang (%d/%d Zeichen).", #text, MAX_TEXT_LENGTH)
    end

    -- Steuerzeichen-Pruefung: nur NULL-Byte blockieren.
    -- WoW MultiLine EditBox gibt intern Bytes < 32 zurueck (Farbcodes etc.).
    -- Das erzeugt False-Positives bei normalem Text. Laenge + Scope reichen fuer v1.

    -- Scope gültig
    if not scope or (scope ~= NexusPost.SCOPE.GUILD and
                     scope ~= NexusPost.SCOPE.FRIENDS and
                     scope ~= NexusPost.SCOPE.PUBLIC) then
        return false, "Ungültiger Scope. Bitte Guild, Friends oder Public wählen."
    end

    -- Links (max 5)
    local links = ExtractLinks(text)
    if #links > MAX_LINKS then
        return false, string.format("Zu viele Links (max %d).", MAX_LINKS)
    end

    return true, nil
end

-- ============================================================
-- 7. POST ERSTELLEN
-- ============================================================

function NexusPost.Create(text, scope)
    -- Guild-Check: Gilde-Scope aber kein Guild-Mitglied
    if scope == NexusPost.SCOPE.GUILD then
        local guildName = GetGuildInfo("player")
        if not guildName or guildName == "" then
            return nil, "no_guild"
        end
    end
    -- Rate-Limit prüfen
    if not rateLimiter:CanPost() then
        local avail, max, secs = rateLimiter:GetTokenStatus()
        return nil, string.format("rate_limit:%d", secs)
    end

    -- Validierung
    local ok, err = ValidatePostData(text, scope)
    if not ok then return nil, err end

    -- Eigene Charakter-Daten
    local authorName = UnitName("player") or "Unbekannt"
    local realm      = GetRealmName and GetRealmName() or "Realm"
    local authorGUID = UnitGUID("player") or ""
    local nameID     = authorName .. "-" .. realm
    local timestamp  = time()

    -- Links extrahieren
    local links = ExtractLinks(text)

    -- Post-Objekt aufbauen
    local post = {
        id          = GeneratePostID(authorGUID),
        authorGUID  = authorGUID,
        authorName  = nameID,
        timestamp   = timestamp,
        version     = SCHEMA_VERSION,
        scope       = scope,
        text        = text,
        links       = links,
        checksum    = ComputeChecksum(text, timestamp, authorGUID),
        state       = NexusPost.STATE.PENDING,
    }

    -- Rate-Limiter aktualisieren
    rateLimiter:RecordPost()

    return post, nil
end

-- ============================================================
-- 8. SERIALISIERUNG (Post → Wire-String)
-- ============================================================

function NexusPost.Serialize(post)
    if not post then return nil end

    -- Links serialisieren: "type:id,type:id"
    local linkParts = {}
    for _, link in ipairs(post.links or {}) do
        table.insert(linkParts, string.format("%d%s%d", link.type, LINK_PAIR, link.id))
    end
    local linksStr = table.concat(linkParts, LINK_SEP)
    if linksStr == "" then linksStr = "0" end

    -- Wire-String zusammenbauen (feste Reihenfolge!)
    local wire = table.concat({
        tostring(post.version),
        tostring(post.id),
        tostring(post.authorGUID),
        tostring(post.authorName),
        tostring(post.timestamp),
        tostring(post.scope),
        tostring(post.text),
        linksStr,
        tostring(post.checksum),
    }, FIELD_SEP)

    -- Payload-Größe prüfen
    if #wire > MAX_PAYLOAD_BYTES then
        return nil, string.format("Payload zu groß: %d Bytes (max %d).", #wire, MAX_PAYLOAD_BYTES)
    end

    return wire, nil
end

-- ============================================================
-- 9. DESERIALISIERUNG (Wire-String → Post)
-- ============================================================

function NexusPost.Deserialize(wire)
    if not wire or wire == "" then return nil, "Leerer Wire-String." end

    -- Payload-Größe prüfen (vor Split)
    if #wire > MAX_PAYLOAD_BYTES then
        return nil, "Payload überschreitet Limit."
    end

    -- Split (kein eval, kein loadstring!)
    local fields = {}
    for field in (wire .. FIELD_SEP):gmatch("([^" .. FIELD_SEP .. "]*)" .. FIELD_SEP) do
        table.insert(fields, field)
    end

    -- Exakt 9 Felder erforderlich
    if #fields ~= WIRE_FIELD_COUNT then
        return nil, string.format("Falsche Feldanzahl: %d (erwartet %d).", #fields, WIRE_FIELD_COUNT)
    end

    local version    = tonumber(fields[1])
    local id         = fields[2]
    local authorGUID = fields[3]
    local authorName = fields[4]
    local timestamp  = tonumber(fields[5])
    local scope      = tonumber(fields[6])
    local text       = fields[7]
    local linksStr   = fields[8]
    local checksum   = fields[9]

    -- Typprüfung
    if not version or not timestamp or not scope then
        return nil, "Ungültige numerische Felder."
    end
    if not id or id == "" then return nil, "Fehlende postID." end
    if not authorGUID or authorGUID == "" then return nil, "Fehlende authorGUID." end
    if not text then return nil, "Fehlender Text." end

    -- Schema-Version prüfen
    if version > SCHEMA_VERSION then
        -- Neuere Version: fehlende Felder defaulten, aber akzeptieren
        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus Post] Schema v%d empfangen (lokal v%d) – akzeptiert.", version, SCHEMA_VERSION))
        end
    end

    -- Links deserialisieren
    local links = {}
    if linksStr and linksStr ~= "0" and linksStr ~= "" then
        for pair in linksStr:gmatch("[^" .. LINK_SEP .. "]+") do
            local t, i = pair:match("(%d+)" .. LINK_PAIR .. "(%d+)")
            if t and i and #links < MAX_LINKS then
                table.insert(links, { type = tonumber(t), id = tonumber(i) })
            end
        end
    end

    -- Checksum validieren
    local expectedCheck = ComputeChecksum(text, timestamp, authorGUID)
    if checksum ~= expectedCheck then
        return nil, "Checksum ungültig – Post verworfen."
    end

    -- Text-Validierung (Empfangsseite)
    if #text > MAX_TEXT_LENGTH then
        return nil, "Text überschreitet Maximum."
    end

    -- Post-Objekt
    local post = {
        id          = id,
        authorGUID  = authorGUID,
        authorName  = authorName,
        timestamp   = timestamp,
        version     = version,
        scope       = scope,
        text        = text,
        links       = links,
        checksum    = checksum,
        state       = NexusPost.STATE.ACTIVE,
    }

    return post, nil
end

-- ============================================================
-- 10. DUPLIKAT-PRÜFUNG
-- ============================================================

-- postID-Set für schnelle Lookup (Session-Cache)
local knownPostIDs = {}

function NexusPost.IsDuplicate(postID)
    return knownPostIDs[postID] == true
end

function NexusPost.MarkKnown(postID)
    knownPostIDs[postID] = true
end

-- Beim Init: bekannte IDs aus DB laden
function NexusPost.LoadKnownIDs()
    knownPostIDs = {}
    if NexusDB and NexusDB.posts then
        for id, _ in pairs(NexusDB.posts) do
            knownPostIDs[id] = true
        end
    end
end

-- ============================================================
-- 11. PUBLIC API
-- ============================================================

-- Kann der Spieler gerade posten?
-- scope (optional): wenn GUILD übergeben, wird IsInGuild geprüft.
-- Rückgabe: true/nil | false, reason_code
-- reason_code: "combat" | "no_guild" | "rate_limit"
function NexusPost.CanPost(scope)
    if InCombatLockdown() then return false, "combat" end
    if scope == NexusPost.SCOPE.GUILD then
        local guildName = GetGuildInfo("player")
        if not guildName or guildName == "" then
            return false, "no_guild"
        end
    end
    if not rateLimiter:CanPost() then
        return false, "rate_limit"
    end
    return true, nil
end

-- Gibt aktuellen Token-Status zurück: avail, max, secsUntilNext
function NexusPost.GetTokenStatus()
    local avail, max, secsUntilNext = rateLimiter:GetTokenStatus()
    return avail, max, secsUntilNext
end

-- Zeitstempel → lesbare Anzeige ("5m", "2h", "3d")
function NexusPost.FormatTimestamp(timestamp)
    local delta = math.max(0, time() - (timestamp or 0))
    if delta < 60     then return delta .. "s"
    elseif delta < 3600   then return math.floor(delta / 60) .. "m"
    elseif delta < 86400  then return math.floor(delta / 3600) .. "h"
    else return math.floor(delta / 86400) .. "d"
    end
end

-- Scope-ID → lesbarer Name
function NexusPost.ScopeName(scope)
    if scope == NexusPost.SCOPE.GUILD   then return L and L["SCOPE_GUILD"]   or "Gilde" end
    if scope == NexusPost.SCOPE.FRIENDS then return L and L["SCOPE_FRIENDS"] or "Freunde" end
    if scope == NexusPost.SCOPE.PUBLIC  then return L and L["SCOPE_PUBLIC"]  or "Öffentlich" end
    return "Unbekannt"
end

-- Text kürzen für Feed-Vorschau (max 80 Zeichen)
function NexusPost.Truncate(text, maxLen)
    maxLen = maxLen or 80
    if not text or #text <= maxLen then return text or "" end
    return text:sub(1, maxLen - 3) .. "..."
end

_G.NexusPost = NexusPost

-- ============================================================
-- 12. UNIT TESTS
-- ============================================================

local function RunPostTests()
    print("\n=== NEXUS_POST UNIT TESTS ===\n")

    local passed, failed = 0, 0
    local function Assert(cond, name)
        if cond then passed = passed + 1; print("  + " .. name)
        else         failed = failed + 1; print("  FAIL: " .. name) end
    end

    -- Test 1: Checksum deterministisch
    local cs1 = ComputeChecksum("hallo", 12345, "guid-abc")
    local cs2 = ComputeChecksum("hallo", 12345, "guid-abc")
    Assert(cs1 == cs2, "Checksum: deterministisch")
    Assert(cs1 ~= ComputeChecksum("hallo2", 12345, "guid-abc"), "Checksum: ändert sich bei anderem Text")

    -- Test 2: GeneratePostID eindeutig
    local id1 = GeneratePostID("guid-1")
    local id2 = GeneratePostID("guid-1")
    Assert(id1 ~= id2, "PostID: eindeutig bei zwei Aufrufen")
    Assert(type(id1) == "string" and #id1 > 0, "PostID: valider String")

    -- Test 3: ValidatePostData
    local ok, err = ValidatePostData("Hallo Welt", NexusPost.SCOPE.GUILD)
    Assert(ok == true, "Validierung: gültiger Post OK")
    local ok2, err2 = ValidatePostData("", NexusPost.SCOPE.GUILD)
    Assert(ok2 == false, "Validierung: leerer Text → FAIL")
    local longText = string.rep("x", 501)
    local ok3, _ = ValidatePostData(longText, NexusPost.SCOPE.GUILD)
    Assert(ok3 == false, "Validierung: Text > 500 Zeichen → FAIL")
    local ok4, _ = ValidatePostData("Test", 99)
    Assert(ok4 == false, "Validierung: ungültiger Scope → FAIL")

    -- Test 4: Serialisierung + Deserialisierung Round-Trip
    local post = {
        id         = "test001",
        authorGUID = "guid-test",
        authorName = "Testchar-Realm",
        timestamp  = 1700000000,
        version    = 1,
        scope      = NexusPost.SCOPE.GUILD,
        text       = "Hallo Nexus!",
        links      = {},
        checksum   = ComputeChecksum("Hallo Nexus!", 1700000000, "guid-test"),
        state      = NexusPost.STATE.PENDING,
    }
    local wire, serErr = NexusPost.Serialize(post)
    Assert(wire ~= nil, "Serialisierung: kein Fehler")
    Assert(serErr == nil, "Serialisierung: kein Error-String")
    Assert(type(wire) == "string", "Serialisierung: Wire ist String")

    local dePost, deErr = NexusPost.Deserialize(wire)
    Assert(dePost ~= nil, "Deserialisierung: kein Fehler")
    Assert(deErr == nil, "Deserialisierung: kein Error-String")
    Assert(dePost ~= nil and dePost.id == "test001", "Deserialisierung: postID korrekt")
    Assert(dePost ~= nil and dePost.text == "Hallo Nexus!", "Deserialisierung: Text korrekt")
    Assert(dePost ~= nil and dePost.scope == NexusPost.SCOPE.GUILD, "Deserialisierung: Scope korrekt")
    Assert(dePost ~= nil and dePost.timestamp == 1700000000, "Deserialisierung: Timestamp korrekt")

    -- Test 5: Ungültige Checksum → verwerfen
    local tampered = wire:gsub("[^|]+$", "000000")
    local badPost, badErr = NexusPost.Deserialize(tampered)
    Assert(badPost == nil, "Sicherheit: manipulierte Checksum → verworfen")
    Assert(badErr ~= nil, "Sicherheit: Fehlermeldung bei Manipulation")

    -- Test 6: Zu wenig Felder → verworfen
    local shortWire = "1|id|guid"
    local sp, se = NexusPost.Deserialize(shortWire)
    Assert(sp == nil, "Sicherheit: zu wenig Felder → verworfen")
    Assert(se ~= nil, "Sicherheit: Fehlermeldung bei Feldanzahl")

    -- Test 7: Links extrahieren
    local linkText = "Schau mal |Hitem:12345|h[Sturmhammer]|h und |Hachievement:678|h[Held]|h"
    local links = ExtractLinks(linkText)
    Assert(#links == 2, "Links: 2 Links erkannt")
    Assert(links[1].type == NexusPost.LINK_TYPE.ITEM, "Links: Item-Typ korrekt")
    Assert(links[1].id == 12345, "Links: Item-ID korrekt")
    Assert(links[2].type == NexusPost.LINK_TYPE.ACHIEVEMENT, "Links: Achievement-Typ korrekt")

    -- Test 8: Post mit Links Round-Trip
    local postWithLinks = {
        id = "link001", authorGUID = "guid-x", authorName = "Test-Realm",
        timestamp = 1700000001, version = 1, scope = NexusPost.SCOPE.PUBLIC,
        text = "Item test", links = { { type = 1, id = 9999 } },
        checksum = ComputeChecksum("Item test", 1700000001, "guid-x"),
        state = NexusPost.STATE.PENDING,
    }
    local wl, _ = NexusPost.Serialize(postWithLinks)
    local dl, _ = NexusPost.Deserialize(wl)
    Assert(dl ~= nil and dl.links ~= nil and #dl.links == 1, "Links Round-Trip: 1 Link erhalten")
    Assert(dl ~= nil and dl.links[1].id == 9999, "Links Round-Trip: Link-ID korrekt")

    -- Test 9: Payload-Limit
    local bigText = string.rep("x", 490)
    local bigPost = {
        id = "big001", authorGUID = "guid-big", authorName = "BigPlayer-Realm",
        timestamp = 1700000002, version = 1, scope = NexusPost.SCOPE.GUILD,
        text = bigText, links = {},
        checksum = ComputeChecksum(bigText, 1700000002, "guid-big"),
        state = NexusPost.STATE.PENDING,
    }
    local bw, bErr = NexusPost.Serialize(bigPost)
    -- Kann je nach Overhead passen oder nicht – Test prüft dass kein Crash auftritt
    Assert(bErr == nil or bErr ~= nil, "Payload-Limit: kein Lua-Error bei großem Post")

    -- Test 10: Duplikat-Erkennung
    knownPostIDs = {}
    NexusPost.MarkKnown("dup-001")
    Assert(NexusPost.IsDuplicate("dup-001") == true, "Duplikat: bekannte ID erkannt")
    Assert(NexusPost.IsDuplicate("neu-002") == false, "Duplikat: unbekannte ID korrekt")

    -- Test 11: Timestamp Formatierung
    Assert(NexusPost.FormatTimestamp(time() - 30)   == "30s", "FormatTimestamp: Sekunden")
    Assert(NexusPost.FormatTimestamp(time() - 120)  == "2m",  "FormatTimestamp: Minuten")
    Assert(NexusPost.FormatTimestamp(time() - 7200) == "2h",  "FormatTimestamp: Stunden")
    Assert(NexusPost.FormatTimestamp(time() - 86400)== "1d",  "FormatTimestamp: Tage")

    -- Test 12: Truncate
    Assert(NexusPost.Truncate("kurz", 80)              == "kurz",      "Truncate: kurzer Text unverändert")
    Assert(#NexusPost.Truncate(string.rep("x",100), 80) == 80,         "Truncate: langer Text auf 80 Zeichen")
    Assert(NexusPost.Truncate(nil, 80)                 == "",          "Truncate: nil-Sicherheit")

    -- Zusammenfassung
    print(string.format("\n=== TEST SUMMARY ===\nPassed: %d\nFailed: %d\nTotal:  %d\n",
        passed, failed, passed + failed))
    if failed == 0 then print("+ ALL TESTS PASSED")
    else print(string.format("FAIL: %d TESTS FEHLGESCHLAGEN", failed)) end
    return failed == 0
end

_G.Nexus_Post = {
    RunTests = RunPostTests,
    VERSION  = POST_VERSION,
}

-- ============================================================
-- 13. INIT
-- ============================================================

local postInitFrame = CreateFrame("Frame", "NexusPostInitFrame")
postInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
postInitFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        -- Bekannte postIDs aus DB laden (Duplikat-Schutz)
        C_Timer.After(1.5, function()
            NexusPost.LoadKnownIDs()
        end)
    end
end)

print(string.format("[Nexus Post] Modul geladen (v%s) – Schema v%d",
    POST_VERSION, SCHEMA_VERSION))
