--[[
    NEXUS - World of Warcraft Community Addon
    Project Charter: Midnight API v12
    Status: Week 1 Implementation - Core Module Skeleton
    
    Module: Nexus_State (Event-Driven Zustandsmaschine)
    Specification: Nexus_Midnight_Hardening_Addendum.docx
    
    Author: Development Team
    Created: 2026-02-20
]]

-------------------------------------------
-- NEXUS_STATE: EVENT-DRIVEN STATE MACHINE
-------------------------------------------

local NEXUS_VERSION = "0.0.3-alpha"
local NEXUS_ADDON_NAME = "Nexus"

-- ===========================
-- 1. STATE DEFINITION (MUSS)
-- ===========================

NexusState = {
    -- Core Combat State
    inCombat = false,
    inInstance = false,
    instanceType = nil,  -- "world", "dungeon", "raid", "arena", "housing", etc.
    
    -- Derived State
    commAllowed = false,
    
    -- Tracking
    lastUpdate = 0,
    lastCombatTime = 0,
    lastInstanceChange = 0
}

-- Instance Whitelist (VERBINDLICH)
local INSTANCE_POLICY = {
    ["world"] = true,      -- ✅ erlaubt
    ["none"] = true,       -- ✅ erlaubt
    ["housing"] = false,   -- ⚠️ default disabled (Feature-Flag required)
    -- Alles andere = false (Safe by default)
}

-- Feature Flag für Housing
NexusConfig = {
    enableHousingComm = false  -- DEFAULT: disabled
}

-- ===========================
-- 2. EVENT HANDLERS (MUSS)
-- ===========================

local function OnPlayerRegenDisabled()
    -- Spieler betritt Combat
    local prevCombat = NexusState.inCombat
    NexusState.inCombat = true
    NexusState.lastCombatTime = GetTime()
    
    if prevCombat ~= NexusState.inCombat then
        print("[Nexus] Combat started - commAllowed = false")
        NexusState:RecomputeCommAllowed()
    end
end

local function OnPlayerRegenEnabled()
    -- Spieler verlässt Combat
    local prevCombat = NexusState.inCombat
    NexusState.inCombat = false
    
    if prevCombat ~= NexusState.inCombat then
        print("[Nexus] Combat ended - commAllowed = " .. tostring(NexusState.commAllowed))
        NexusState:RecomputeCommAllowed()
    end
end

local function OnPlayerEnteringWorld()
    -- Spieler betritt die Welt (Login, Reload, etc.)
    print("[Nexus] PLAYER_ENTERING_WORLD triggered")
    NexusState:RefreshInstanceType()
end

local function OnZoneChangedNewArea()
    -- Spieler wechselt Zone/Instanz
    print("[Nexus] ZONE_CHANGED_NEW_AREA triggered")
    NexusState:RefreshInstanceType()
end

local function OnPlayerDifficultyChanged()
    -- Schwierigkeit ändert sich (Raid-Modi, etc.)
    print("[Nexus] PLAYER_DIFFICULTY_CHANGED triggered")
    NexusState:RefreshInstanceType()
end

-- ===========================
-- 3. STATE MACHINE METHODS
-- ===========================

function NexusState:RefreshInstanceType()
    -- Sichere Abfrage des Instanztyps
    local _, instanceType = IsInInstance()
    local prevType = self.instanceType
    
    self.instanceType = instanceType
    self.inInstance = (instanceType ~= nil and instanceType ~= "none")
    self.lastInstanceChange = GetTime()
    
    if prevType ~= self.instanceType then
        print(string.format("[Nexus] Instance changed: %s → %s", 
            tostring(prevType), tostring(self.instanceType)))
    end
    
    self:RecomputeCommAllowed()
end

function NexusState:IsInstanceTypeAllowed(instanceType)
    -- nil behandeln wie "none" (kein Instanz-Kontext = erlaubt)
    if instanceType == nil then
        return true
    end
    -- Pruefe ob dieser Instanztyp in der Policy erlaubt ist
    if INSTANCE_POLICY[instanceType] == nil then
        -- Unbekannter Typ: SAFE = false
        return false
    end
    
    if instanceType == "housing" and not NexusConfig.enableHousingComm then
        -- Housing spezial: Feature-Flag prüfen
        return false
    end
    
    return INSTANCE_POLICY[instanceType] == true
end

function NexusState:RecomputeCommAllowed()
    -- Zentrale Freigabealgorithmus (HART)
    -- Kommunikation ist NUR erlaubt wenn:
    -- 1. NICHT im Combat
    -- 2. In erlaubter Instanz
    
    local prevAllowed = self.commAllowed
    
    self.commAllowed = (
        self.inCombat == false
        and self:IsInstanceTypeAllowed(self.instanceType)
    )
    
    self.lastUpdate = GetTime()
    
    if prevAllowed ~= self.commAllowed then
        print(string.format("[Nexus] commAllowed: %s → %s", 
            tostring(prevAllowed), tostring(self.commAllowed)))
    end
end

function NexusState:GetState()
    -- Public API für andere Module
    return {
        inCombat = self.inCombat,
        inInstance = self.inInstance,
        instanceType = self.instanceType,
        commAllowed = self.commAllowed
    }
end

-- ===========================
-- 4. DEBOUNCE PROTECTION
-- ===========================

local LastStateCompute = 0
local DEBOUNCE_INTERVAL = 0.05  -- 50 ms

function NexusState:DebounceRecompute()
    -- Verhindere mehrfache Recomputes pro Frame
    local now = GetTime()
    if (now - LastStateCompute) < DEBOUNCE_INTERVAL then
        return  -- Skip (zu nah beieinander)
    end
    LastStateCompute = now
    self:RecomputeCommAllowed()
end

-- ===========================
-- 5. FALLBACK POLL (Optional)
-- ===========================

local LastPollTime = 0
local POLL_INTERVAL = 5.0  -- 5 Sekunden (nur als Notfall)
local POLL_TIMEOUT = 30.0  -- Wenn länger als 30 Sek kein Event

function NexusState:TryFallbackPoll()
    -- ONLY wenn:
    -- - Länger als 30 Sekunden kein Event
    -- - Kommunikation würde erlaubt sein
    -- - Aber wir sind unsicher über den Zustand
    
    local now = GetTime()
    local timeSinceLastUpdate = now - self.lastUpdate
    
    if timeSinceLastUpdate > POLL_TIMEOUT and (now - LastPollTime) > POLL_INTERVAL then
        -- Fallback Poll durchführen
        print("[Nexus] Fallback Poll (timeout reached)")
        self:RefreshInstanceType()
        LastPollTime = now
    end
end

-- ===========================
-- 6. MODULE INITIALIZATION
-- ===========================

local function InitializeNexusState()
    print(string.format("[Nexus] Initializing NexusState (v%s)", NEXUS_VERSION))
    
    -- Registriere alle Pflicht-Events
    local frame = CreateFrame("Frame", "NexusStateFrame")
    
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    frame:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
    
    -- Event Handler
    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_REGEN_DISABLED" then
            OnPlayerRegenDisabled()
        elseif event == "PLAYER_REGEN_ENABLED" then
            OnPlayerRegenEnabled()
        elseif event == "PLAYER_ENTERING_WORLD" then
            OnPlayerEnteringWorld()
        elseif event == "ZONE_CHANGED_NEW_AREA" then
            OnZoneChangedNewArea()
        elseif event == "PLAYER_DIFFICULTY_CHANGED" then
            OnPlayerDifficultyChanged()
        end
        
        -- Debounce nach jedem Event
        NexusState:DebounceRecompute()
    end)
    
    -- Initial state berechnen
    NexusState:RefreshInstanceType()
    
    print("[Nexus] NexusState initialized - READY")
    return true
end

-- ===========================
-- 7. UNIT TESTS (Framework)
-- ===========================

local TestResults = {
    passed = 0,
    failed = 0,
    tests = {}
}

local function AssertEqual(actual, expected, testName)
    if actual == expected then
        TestResults.passed = TestResults.passed + 1
        print(string.format("  ✓ %s", testName))
    else
        TestResults.failed = TestResults.failed + 1
        print(string.format("  ✗ %s (expected %s, got %s)", testName, tostring(expected), tostring(actual)))
    end
end

local function RunUnitTests()
    -- Reset: Zaehler vor jedem Lauf auf 0 setzen
    TestResults.passed = 0
    TestResults.failed = 0

    print("\n=== NEXUS_STATE UNIT TESTS ===\n")
    
    -- Test 1: Initial state
    print("Test Group 1: Initial State")
    AssertEqual(NexusState.inCombat, false, "Initial inCombat = false")
    AssertEqual(NexusState.commAllowed, true, "Initial commAllowed = true (not in combat)")
    
    -- Test 2: Combat transition
    print("\nTest Group 2: Combat Transitions")
    OnPlayerRegenDisabled()
    AssertEqual(NexusState.inCombat, true, "After REGEN_DISABLED → inCombat = true")
    AssertEqual(NexusState.commAllowed, false, "After REGEN_DISABLED → commAllowed = false")
    
    OnPlayerRegenEnabled()
    AssertEqual(NexusState.inCombat, false, "After REGEN_ENABLED → inCombat = false")
    -- commAllowed depends on instance, so just check it recomputed
    
    -- Test 3: Instance whitelist
    print("\nTest Group 3: Instance Whitelist")
    AssertEqual(NexusState:IsInstanceTypeAllowed("world"), true, "world is allowed")
    AssertEqual(NexusState:IsInstanceTypeAllowed("none"), true, "none is allowed")
    AssertEqual(NexusState:IsInstanceTypeAllowed("housing"), false, "housing blocked (feature-flag off)")
    AssertEqual(NexusState:IsInstanceTypeAllowed("unknown"), false, "unknown types are blocked")
    
    -- Test 4: CommAllowed logic
    print("\nTest Group 4: CommAllowed Logic")
    NexusState.inCombat = false
    NexusState.instanceType = "world"
    NexusState:RecomputeCommAllowed()
    AssertEqual(NexusState.commAllowed, true, "world + not combat = commAllowed")
    
    NexusState.inCombat = true
    NexusState:RecomputeCommAllowed()
    AssertEqual(NexusState.commAllowed, false, "in combat = NOT commAllowed")
    
    -- TEARDOWN: Live-State wiederherstellen nach Tests
    print("\n[Nexus] Teardown: Live-State wird wiederhergestellt...")
    NexusState.inCombat = false
    NexusState:RefreshInstanceType()  -- Echter instanceType aus WoW API
    
    -- Summary
    print(string.format("\n=== TEST SUMMARY ===\nPassed: %d\nFailed: %d\nTotal: %d\n", 
        TestResults.passed, TestResults.failed, 
        TestResults.passed + TestResults.failed))
    
    if TestResults.failed == 0 then
        print("✓ ALL TESTS PASSED")
    else
        print(string.format("✗ %d TESTS FAILED", TestResults.failed))
    end
    
    return TestResults.failed == 0
end

-- ===========================
-- 8. PUBLIC API EXPORT
-- ===========================

-- Globaler Export (erreichbar via /run und andere Module)
_G.NexusState = NexusState
_G.NexusConfig = NexusConfig

_G.Nexus_State = {
    Initialize = InitializeNexusState,
    GetState = function() return NexusState:GetState() end,
    RunTests = RunUnitTests,
    IsCommAllowed = function() return NexusState.commAllowed end,
    GetInstanceType = function() return NexusState.instanceType end
}

-- Slash-Command: /nexus
SLASH_NEXUS1 = "/nexus"
SlashCmdList["NEXUS"] = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if cmd == "test" then
        RunUnitTests()
    else
        -- Status-Ausgabe
        print("|cff00ccff[Nexus]|r === Status ===")
        print(string.format("|cff00ccff[Nexus]|r inCombat     : %s", tostring(NexusState.inCombat)))
        print(string.format("|cff00ccff[Nexus]|r inInstance   : %s", tostring(NexusState.inInstance)))
        print(string.format("|cff00ccff[Nexus]|r instanceType : %s", tostring(NexusState.instanceType)))
        print(string.format("|cff00ccff[Nexus]|r commAllowed  : %s", tostring(NexusState.commAllowed)))
        print("|cff00ccff[Nexus]|r Befehle: /nexus | /nexus test")
    end
end

print("[Nexus] Nexus_State module loaded - Ready to Initialize")

-- ===========================
-- 9. AUTO-INITIALIZATION (Optional)
-- ===========================

-- Uncomment to auto-init on load
InitializeNexusState()
-- RunUnitTests()

