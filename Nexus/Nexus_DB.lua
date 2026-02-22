--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_DB (SavedVariables Management & Chunked Pruning)
    Spezifikation: Nexus_Midnight_Hardening_Addendum.docx
                   Nexus_Critical_Implementation_Checklist.docx

    Grundsatz:
    - Nur SavedVariables (kein externer Server)
    - Chunked Pruning (max 50 Einträge pro Frame, kein Frame-Spike)
    - Version-Migration v1 -> v2 beim Login
    - Shield-Validierung VOR jeder Speicherung

    Version: 0.0.4-alpha
]]

-- ============================================================
-- 1. KONSTANTEN
-- ============================================================

local DB_VERSION      = "0.6.0-alpha"
local CURRENT_SCHEMA  = 2              -- Aktuelle Schema-Version

local PRUNE_MAX_AGE_DAYS  = 30         -- Profile älter als 30 Tage werden gelöscht
local PRUNE_CHUNK_SIZE    = 50         -- Max Einträge pro Prune-Chunk
local PRUNE_CHUNK_DELAY   = 0.1        -- Sekunden zwischen Chunks

local SOFT_LIMIT_BYTES    = 2097152    -- 2 MB Soft-Limit
local WARN_PROFILE_COUNT  = 500        -- Warnung ab 500 Profilen

-- Sekunden pro Tag (für Altersberechnung)
local SECONDS_PER_DAY = 86400

-- ============================================================
-- 2. SAVEDVARIABLES STRUKTUR
-- ============================================================
-- NexusDB wird als globale SavedVariable deklariert (in .toc: ## SavedVariables: NexusDB NexusConfig)
-- Struktur:
--   NexusDB = {
--     schemaVersion = 2,
--     profiles = {
--       [nameID] = {
--         schemaVersion, nameID, guid, lastSeen, bio,
--         houseCoord, visibility, playDaysMask, playTimeMask,
--         playstyleMask, poseID, backgroundID
--       }
--     },
--     meta = {
--       lastPruneTime = number,
--       totalPruned   = number,
--       createdAt     = number,
--     }
--   }

-- ============================================================
-- 3. DB-INITIALISIERUNG & MIGRATION
-- ============================================================

local function ensureDBStructure()
    -- NexusDB existiert noch nicht (erster Start)
    if type(NexusDB) ~= "table" then
        NexusDB = {}
    end

    -- profiles-Tabelle sicherstellen
    if type(NexusDB.profiles) ~= "table" then
        NexusDB.profiles = {}
    end

    -- meta-Tabelle sicherstellen
    if type(NexusDB.meta) ~= "table" then
        NexusDB.meta = {
            lastPruneTime = 0,
            totalPruned   = 0,
            createdAt     = time(),
        }
    end

    -- schemaVersion sicherstellen
    if not NexusDB.schemaVersion then
        NexusDB.schemaVersion = 1  -- Alt: als v1 behandeln
    end
end

-- Schema v1 -> v2 Migration
-- v2 fügt hinzu: poseID, backgroundID (beide nil/default)
local function migrateV1toV2(profile)
    -- Neue Felder mit Defaults initialisieren
    if profile.poseID == nil then
        profile.poseID = 0
    end
    if profile.backgroundID == nil then
        profile.backgroundID = 0
    end
    if profile.guid == nil then
        profile.guid = nil  -- Optional, bleibt nil
    end
    profile.schemaVersion = 2
    return profile
end

-- Alle Profile auf aktuelles Schema migrieren
local function migrateAllProfiles()
    if not NexusDB or not NexusDB.profiles then return 0 end

    local migrated = 0
    for nameID, profile in pairs(NexusDB.profiles) do
        if type(profile) == "table" then
            local version = profile.schemaVersion or 1
            if version < 2 then
                NexusDB.profiles[nameID] = migrateV1toV2(profile)
                migrated = migrated + 1
            end
        end
    end

    if migrated > 0 then
        NexusDB.schemaVersion = CURRENT_SCHEMA
        if NexusConfig and NexusConfig.devMode then
            print(string.format("[Nexus DB] Migration: %d Profile auf Schema v2 aktualisiert", migrated))
        end
    end

    return migrated
end

-- ============================================================
-- 4. PROFIL SPEICHERN (mit Shield-Validierung)
-- ============================================================

local function SaveProfile(profile)
    -- Shield-Validierung VOR Speicherung (Zero-Trust)
    if NexusShield then
        local ok, reason = NexusShield.ValidateProfile(profile)
        if not ok then
            -- Stillschweigend verwerfen
            if NexusConfig and NexusConfig.devMode then
                print("[Nexus DB] Profil verworfen (Shield): " .. tostring(reason))
            end
            return false, reason
        end
    end

    -- nameID als Schlüssel prüfen
    if type(profile.nameID) ~= "string" or #profile.nameID == 0 then
        return false, "nameID ungültig"
    end

    -- Schema auf aktuell setzen
    profile.schemaVersion = CURRENT_SCHEMA

    -- Speichern
    NexusDB.profiles[profile.nameID] = profile

    -- Soft-Limit Warnung
    local count = 0
    for _ in pairs(NexusDB.profiles) do count = count + 1 end
    if count >= WARN_PROFILE_COUNT and NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus DB] Warnung: %d Profile gespeichert (Soft-Limit: %d)",
            count, WARN_PROFILE_COUNT))
    end

    return true
end

-- ============================================================
-- 5. PROFIL LESEN
-- ============================================================

local function GetProfile(nameID)
    if type(nameID) ~= "string" or #nameID == 0 then
        return nil
    end
    return NexusDB.profiles[nameID]
end

local function GetAllProfiles()
    return NexusDB.profiles
end

local function GetProfileCount()
    local count = 0
    for _ in pairs(NexusDB.profiles) do count = count + 1 end
    return count
end

-- ============================================================
-- 6. PROFIL LÖSCHEN
-- ============================================================

local function DeleteProfile(nameID)
    if type(nameID) ~= "string" then return false end
    if NexusDB.profiles[nameID] == nil then return false end
    NexusDB.profiles[nameID] = nil
    return true
end

-- ============================================================
-- 7. CHUNKED PRUNING
-- ============================================================

local pruneFrame       = nil
local pruneQueue       = {}   -- Liste von nameIDs die geprüft werden sollen
local pruneInProgress  = false
local pruneTotalRemoved = 0

-- Pruning-Kandidaten sammeln (alle nameIDs in eine Liste)
local function buildPruneQueue(maxAgeSecs)
    local now       = time()
    local cutoff    = now - maxAgeSecs
    local candidates = {}

    for nameID, profile in pairs(NexusDB.profiles) do
        if type(profile) == "table" then
            local lastSeen = profile.lastSeen or 0
            if lastSeen < cutoff then
                table.insert(candidates, nameID)
            end
        else
            -- Korrupter Eintrag: auch löschen
            table.insert(candidates, nameID)
        end
    end

    return candidates
end

-- Einen Chunk verarbeiten (max PRUNE_CHUNK_SIZE Einträge)
local function processPruneChunk()
    local removed = 0
    local processed = 0

    while #pruneQueue > 0 and processed < PRUNE_CHUNK_SIZE do
        local nameID = table.remove(pruneQueue, 1)
        if NexusDB.profiles[nameID] then
            NexusDB.profiles[nameID] = nil
            removed = removed + 1
        end
        processed = processed + 1
    end

    pruneTotalRemoved = pruneTotalRemoved + removed
    return removed, #pruneQueue == 0  -- removed, isDone
end

-- Chunked Pruning starten
local function StartChunkedPruning(maxAgeDays)
    if pruneInProgress then return end  -- Bereits läuft

    local maxAgeSecs = (maxAgeDays or PRUNE_MAX_AGE_DAYS) * SECONDS_PER_DAY
    pruneQueue = buildPruneQueue(maxAgeSecs)

    if #pruneQueue == 0 then
        if NexusConfig and NexusConfig.devMode then
            print("[Nexus DB] Pruning: Keine alten Profile gefunden")
        end
        return
    end

    pruneInProgress  = true
    pruneTotalRemoved = 0

    if NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus DB] Pruning gestartet: %d Kandidaten", #pruneQueue))
    end

    -- Pruning-Frame erstellen wenn noch nicht vorhanden
    if not pruneFrame then
        pruneFrame = CreateFrame("Frame", "NexusPruneFrame")
    end

    local accumTime = 0

    pruneFrame:SetScript("OnUpdate", function(self, dt)
        accumTime = accumTime + dt

        -- Warte PRUNE_CHUNK_DELAY zwischen Chunks
        if accumTime < PRUNE_CHUNK_DELAY then return end
        accumTime = 0

        local _, isDone = processPruneChunk()

        if isDone then
            -- Pruning abgeschlossen
            pruneFrame:SetScript("OnUpdate", nil)
            pruneInProgress = false

            NexusDB.meta.lastPruneTime = time()
            NexusDB.meta.totalPruned   = (NexusDB.meta.totalPruned or 0) + pruneTotalRemoved

            if NexusConfig and NexusConfig.devMode then
                print(string.format("[Nexus DB] Pruning abgeschlossen: %d Profile entfernt, %d verbleiben",
                    pruneTotalRemoved, GetProfileCount()))
            end
        end
    end)
end

-- ============================================================
-- 8. POST-SPEICHERUNG (Structured Post System)
-- ============================================================

-- Konstanten (gespiegelt aus NexusPost, damit DB unabhängig bleibt)
local POST_MAX_TOTAL      = 2000
local POST_MAX_PER_AUTHOR = 100
local POST_TTL_DAYS       = 30

-- Posts-Tabelle sicherstellen
local function ensurePostsTable()
    if type(NexusDB.posts) ~= "table" then
        NexusDB.posts = {}
    end
    if type(NexusDB.postIndex) ~= "table" then
        NexusDB.postIndex = {}  -- chronologische Liste: { postID, ... }
    end
    if type(NexusDB.postMeta) ~= "table" then
        NexusDB.postMeta = {
            totalSaved  = 0,
            lastPruneTime = 0,
        }
    end
end

-- Post speichern (neu oder Update)
local function SavePost(post)
    if not post or not post.id then return false end
    ensurePostsTable()

    local isNew = NexusDB.posts[post.id] == nil

    NexusDB.posts[post.id] = post

    -- Chronologischen Index pflegen (nur neue Posts)
    if isNew then
        table.insert(NexusDB.postIndex, post.id)
        NexusDB.postMeta.totalSaved = (NexusDB.postMeta.totalSaved or 0) + 1
    end

    return true
end

-- Post laden
local function GetPost(postID)
    if not NexusDB or not NexusDB.posts then return nil end
    return NexusDB.posts[postID]
end

-- Alle Posts als sortierte Liste (neueste zuerst)
local function GetAllPosts(scopeFilter)
    ensurePostsTable()
    local result = {}
    for _, postID in ipairs(NexusDB.postIndex) do
        local p = NexusDB.posts[postID]
        if p and p.state ~= "locally_deleted" then
            if not scopeFilter or p.scope == scopeFilter then
                table.insert(result, p)
            end
        end
    end
    -- Neueste zuerst
    table.sort(result, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    return result
end

-- Post-Anzahl
local function GetPostCount()
    ensurePostsTable()
    local count = 0
    for _, postID in ipairs(NexusDB.postIndex) do
        local p = NexusDB.posts[postID]
        if p and p.state ~= "locally_deleted" then
            count = count + 1
        end
    end
    return count
end

-- Post lokal löschen (kein Tombstone, kein Netzwerk)
local function DeletePost(postID)
    ensurePostsTable()
    if not NexusDB.posts[postID] then return false end
    NexusDB.posts[postID].state = "locally_deleted"
    return true
end

-- Post-Pruning: TTL + Gesamtlimit + Pro-Autor-Limit
local function PrunePosts()
    ensurePostsTable()
    local now = time()
    local ttlCutoff = now - (POST_TTL_DAYS * 86400)

    -- Schritt 1: TTL-Pruning (zu alte Posts)
    local authorCounts = {}
    local toRemove = {}

    for _, postID in ipairs(NexusDB.postIndex) do
        local p = NexusDB.posts[postID]
        if p then
            -- TTL abgelaufen?
            if (p.timestamp or 0) < ttlCutoff then
                toRemove[postID] = true
            else
                -- Pro-Autor zählen
                local name = p.authorName or "?"
                authorCounts[name] = (authorCounts[name] or 0) + 1
            end
        else
            toRemove[postID] = true  -- verwaiste Einträge
        end
    end

    -- Schritt 2: Pro-Autor-Limit
    -- Für Autoren über Limit: älteste zuerst entfernen
    local byAuthor = {}
    for _, postID in ipairs(NexusDB.postIndex) do
        local p = NexusDB.posts[postID]
        if p and not toRemove[postID] then
            local name = p.authorName or "?"
            byAuthor[name] = byAuthor[name] or {}
            table.insert(byAuthor[name], { id = postID, ts = p.timestamp or 0 })
        end
    end
    for name, posts in pairs(byAuthor) do
        if #posts > POST_MAX_PER_AUTHOR then
            table.sort(posts, function(a, b) return a.ts < b.ts end)
            for i = 1, #posts - POST_MAX_PER_AUTHOR do
                toRemove[posts[i].id] = true
            end
        end
    end

    -- Schritt 3: Gesamtlimit
    local activeIDs = {}
    for _, postID in ipairs(NexusDB.postIndex) do
        if not toRemove[postID] then
            table.insert(activeIDs, postID)
        end
    end
    if #activeIDs > POST_MAX_TOTAL then
        -- Älteste entfernen bis Limit
        local sorted = {}
        for _, postID in ipairs(activeIDs) do
            local p = NexusDB.posts[postID]
            table.insert(sorted, { id = postID, ts = p and p.timestamp or 0 })
        end
        table.sort(sorted, function(a, b) return a.ts < b.ts end)
        for i = 1, #sorted - POST_MAX_TOTAL do
            toRemove[sorted[i].id] = true
        end
    end

    -- Schritt 4: Tatsächlich entfernen
    local pruned = 0
    for postID, _ in pairs(toRemove) do
        NexusDB.posts[postID] = nil
        pruned = pruned + 1
    end

    -- Index neu aufbauen (sauber)
    local newIndex = {}
    for _, postID in ipairs(NexusDB.postIndex) do
        if NexusDB.posts[postID] then
            table.insert(newIndex, postID)
        end
    end
    NexusDB.postIndex = newIndex
    NexusDB.postMeta.lastPruneTime = now

    if pruned > 0 and NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus DB] Post-Pruning: %d Posts entfernt.", pruned))
    end
    return pruned
end

-- ============================================================
-- 8b. DB ZURÜCKSETZEN (für Settings Panel / Dev)
-- ============================================================

local function ResetDatabase()
    NexusDB.profiles = {}
    NexusDB.posts    = {}
    NexusDB.postIndex = {}
    NexusDB.postMeta  = { totalSaved = 0, lastPruneTime = 0 }
    NexusDB.meta = {
        lastPruneTime = 0,
        totalPruned   = 0,
        createdAt     = time(),
    }
    NexusDB.schemaVersion = CURRENT_SCHEMA
    print("[Nexus DB] Datenbank zurückgesetzt")
end

-- ============================================================
-- 9. INITIALISIERUNG (beim Login)
-- ============================================================

local function InitializeNexusDB()
    -- Struktur sicherstellen
    ensureDBStructure()
    ensurePostsTable()  -- Post-Tabellen sicherstellen

    -- Migration durchführen
    local migrated = migrateAllProfiles()

    -- Pruning starten (asynchron, chunked)
    StartChunkedPruning(PRUNE_MAX_AGE_DAYS)

    -- Post-Pruning (einmalig beim Login)
    C_Timer.After(2.0, function()
        PrunePosts()
    end)

    local profileCount = GetProfileCount()

    print(string.format("[Nexus DB] Initialisiert (v%s): %d Profile, %d Posts, Schema v%d, %d migriert",
        DB_VERSION, profileCount, GetPostCount(), CURRENT_SCHEMA, migrated))

    return true
end

-- Event-Listener: Beim Login initialisieren
local dbEventFrame = CreateFrame("Frame", "NexusDBEventFrame")
dbEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
dbEventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Nur einmal initialisieren
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        InitializeNexusDB()
    end
end)

-- ============================================================
-- 10. PUBLIC API
-- ============================================================

NexusDB_API = {
    SaveProfile        = SaveProfile,
    GetProfile         = GetProfile,
    GetAllProfiles     = GetAllProfiles,
    GetProfileCount    = GetProfileCount,
    DeleteProfile      = DeleteProfile,
    StartPruning       = StartChunkedPruning,
    ResetDatabase      = ResetDatabase,
    Initialize         = InitializeNexusDB,
    -- Post API
    SavePost           = SavePost,
    GetPost            = GetPost,
    GetAllPosts        = GetAllPosts,
    GetPostCount       = GetPostCount,
    DeletePost         = DeletePost,
    PrunePosts         = PrunePosts,
}

_G.NexusDB_API = NexusDB_API

_G.Nexus_DB = {
    SaveProfile     = SaveProfile,
    GetProfile      = GetProfile,
    GetAllProfiles  = GetAllProfiles,
    GetProfileCount = GetProfileCount,
    DeleteProfile   = DeleteProfile,
    StartPruning    = StartChunkedPruning,
    ResetDatabase   = ResetDatabase,
    -- Post API
    SavePost        = SavePost,
    GetPost         = GetPost,
    GetAllPosts     = GetAllPosts,
    GetPostCount    = GetPostCount,
    DeletePost      = DeletePost,
    PrunePosts      = PrunePosts,
    RunTests        = nil,  -- wird unten gesetzt
}

print(string.format("[Nexus DB] Modul geladen (v%s)", DB_VERSION))

-- ============================================================
-- 11. UNIT TESTS (10+)
-- ============================================================

local function RunDBTests()
    print("\n=== NEXUS_DB UNIT TESTS ===\n")

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

    -- Backup echter DB
    local realDB = NexusDB
    -- Test-DB verwenden
    NexusDB = { profiles = {}, meta = { lastPruneTime = 0, totalPruned = 0, createdAt = 0 }, schemaVersion = 2 }

    local function testProfile(overrides)
        local p = {
            schemaVersion = 2,
            nameID        = "Testchar-Realm",
            lastSeen      = time(),
            bio           = "Test Bio",
            visibility    = 1,
            playDaysMask  = 63,
            playTimeMask  = 15,
            playstyleMask = 7,
        }
        if overrides then
            for k, v in pairs(overrides) do p[k] = v end
        end
        return p
    end

    -- Test 1: Gültiges Profil speichern
    NexusDB.profiles = {}
    local ok1 = SaveProfile(testProfile())
    Assert(ok1 == true, "Gueltiges Profil wird gespeichert")

    -- Test 2: Profil wieder lesen
    local loaded = GetProfile("Testchar-Realm")
    Assert(loaded ~= nil, "Gespeichertes Profil kann gelesen werden")

    -- Test 3: Profil-Inhalt korrekt
    Assert(loaded and loaded.bio == "Test Bio", "Profil-Inhalt ist korrekt")

    -- Test 4: Unbekanntes Feld wird durch Shield abgelehnt
    NexusDB.profiles = {}
    local ok4 = SaveProfile(testProfile({ hackerField = "exploit" }))
    Assert(ok4 == false, "Profil mit unbekanntem Feld wird abgelehnt (Shield)")

    -- Test 5: Profil löschen
    NexusDB.profiles = {}
    SaveProfile(testProfile())
    local del = DeleteProfile("Testchar-Realm")
    Assert(del == true, "Profil kann gelöscht werden")
    Assert(GetProfile("Testchar-Realm") == nil, "Gelöschtes Profil ist nicht mehr abrufbar")

    -- Test 6: ProfileCount korrekt
    NexusDB.profiles = {}
    SaveProfile(testProfile({ nameID = "Char1-Realm" }))
    SaveProfile(testProfile({ nameID = "Char2-Realm" }))
    SaveProfile(testProfile({ nameID = "Char3-Realm" }))
    Assert(GetProfileCount() == 3, "ProfileCount gibt korrekte Anzahl zurueck (3)")

    -- Test 7: Migration v1 -> v2
    NexusDB.profiles = {}
    -- Altes v1-Profil ohne poseID/backgroundID
    NexusDB.profiles["OldChar-Realm"] = {
        schemaVersion = 1,
        nameID        = "OldChar-Realm",
        lastSeen      = time(),
    }
    local migrated = migrateAllProfiles()
    local migratedProfile = GetProfile("OldChar-Realm")
    Assert(migrated == 1, "Migration erkennt 1 altes Profil")
    Assert(migratedProfile and migratedProfile.schemaVersion == 2, "Migriertes Profil hat schemaVersion 2")
    Assert(migratedProfile and migratedProfile.poseID == 0, "Migriertes Profil hat poseID = 0 (Default)")

    -- Test 8: Pruning entfernt alte Profile
    NexusDB.profiles = {}
    local oldTime = time() - (PRUNE_MAX_AGE_DAYS + 1) * SECONDS_PER_DAY
    NexusDB.profiles["OldProfile"] = { nameID = "OldProfile", lastSeen = oldTime, schemaVersion = 2 }
    NexusDB.profiles["NewProfile"] = testProfile({ nameID = "NewProfile" })
    local candidates = buildPruneQueue(PRUNE_MAX_AGE_DAYS * SECONDS_PER_DAY)
    Assert(#candidates == 1, "Pruning findet genau 1 altes Profil")
    Assert(candidates[1] == "OldProfile", "Pruning identifiziert korrektes altes Profil")

    -- Test 9: Pruning lässt neue Profile in Ruhe
    local newFound = false
    for _, id in ipairs(candidates) do
        if id == "NewProfile" then newFound = true end
    end
    Assert(newFound == false, "Pruning beruehrt neue Profile nicht")

    -- Test 10: ResetDatabase leert alles
    NexusDB.profiles = {}
    SaveProfile(testProfile())
    ResetDatabase()
    Assert(GetProfileCount() == 0, "ResetDatabase leert alle Profile")

    -- Test 11: ensureDBStructure bei leerem NexusDB
    NexusDB = nil
    ensureDBStructure()
    Assert(type(NexusDB) == "table", "ensureDBStructure erstellt NexusDB wenn nil")
    Assert(type(NexusDB.profiles) == "table", "ensureDBStructure erstellt profiles-Tabelle")
    Assert(type(NexusDB.meta) == "table", "ensureDBStructure erstellt meta-Tabelle")

    -- Test 12: Doppeltes Speichern überschreibt korrekt
    NexusDB = { profiles = {}, meta = {}, schemaVersion = 2 }
    SaveProfile(testProfile({ bio = "Erster Inhalt" }))
    SaveProfile(testProfile({ bio = "Zweiter Inhalt" }))
    local updated = GetProfile("Testchar-Realm")
    Assert(updated and updated.bio == "Zweiter Inhalt", "Doppeltes Speichern ueberschreibt korrekt")

    -- Echte DB wiederherstellen
    NexusDB = realDB

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

_G.Nexus_DB.RunTests = RunDBTests
