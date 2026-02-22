--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_Locale
    Spezifikation: Nexus_Localization_Tooltip_System_Spec.docx
                   Nexus_Locale_Key_Master_enUS.docx
                   Nexus_Tooltip_Registry_Design_Spec.docx
                   Nexus_Dev_Locale_Validator_Spec.docx

    Architektur:
    1. NexusLocale["enUS"] = { ... }   Master-Sprache (Fallback)
    2. NexusLocale["deDE"] = { ... }   Übersetzung
    3. L = aktive Tabelle (via Metatable mit enUS-Fallback)
    4. NexusTooltip_Show(frame, titleKey, bodyKey)
    5. NexusTooltipRegistry = { [elementID] = { titleKey, bodyKey, required } }
    6. NexusLocaleValidator (nur Dev Mode)

    Regeln:
    - Nutzer darf NIEMALS nil sehen
    - Kein Locale-Lookup in OnUpdate
    - Kein Tooltip-Neubau pro Frame
    - Validator: nur wenn NexusConfig.devMode == true

    Version: 0.5.0-alpha
]]

local LOCALE_VERSION = "0.5.0-alpha-hotfix1"

-- ============================================================
-- 1. LOCALE TABELLEN
-- ============================================================

NexusLocale = NexusLocale or {}

-- ------------------------------------------------------------
-- enUS (Master – Fallback – VOLLSTÄNDIG)
-- ------------------------------------------------------------
NexusLocale["enUS"] = {
    -- Fenster & Navigation
    NEXUS_TITLE              = "Nexus",
    NEXUS_ONLINE             = "[Nexus Online]",
    NEXUS_OFFLINE            = "[Nexus Offline]",
    TAB_FEED                 = "Feed",
    TAB_PROFILE              = "Profile",
    TAB_SETTINGS             = "Settings",

    -- Kategorie-Buttons (linke Spalte)
    CATEGORY_FEED            = "Feed",
    CATEGORY_GUILD           = "Guild",
    CATEGORY_FRIENDS         = "Friends",
    CATEGORY_PUBLIC          = "Public",
    CATEGORY_COMMUNITIES     = "Communities",

    -- Header & Status
    HEADER_CHARACTER_LEVEL_CLASS = "Level %d %s",
    POST_COUNT               = "Posts: %d / %d",
    POST_LIMIT_WARNING_SOFT  = "Your post storage is getting full.",
    POST_LIMIT_WARNING_HARD  = "Your post storage is almost full. Consider deleting old posts.",
    NEXUS_STATUS_ONLINE      = "Online",
    NEXUS_STATUS_OFFLINE     = "Offline",
    NEXUS_STATUS_SAFE_MODE   = "Safe Mode",

    -- Feed Panel
    FEED_EMPTY               = "No entries found.\nMove around the world to discover other players.",
    FEED_LOADING             = "Loading...",
    FEED_PLAYER_LEVEL_CLASS  = "Level %d %s",
    FEED_LAST_SEEN           = "Last seen: %s",
    FEED_COMPATIBILITY_FULL  = "Full compatibility",
    FEED_COMPATIBILITY_LEGACY= "Legacy mode",
    FEED_COMPATIBILITY_LIMITED = "Limited mode",

    -- Profil – Sektionen
    PROFILE_SECTION_PLAYDAYS    = "Play Days",
    PROFILE_SECTION_PLAYTIME    = "Play Schedule",
    PROFILE_SECTION_PLAYSTYLE   = "Playstyle",
    PROFILE_SECTION_APPEARANCE  = "Appearance",
    PROFILE_POSE_LABEL          = "Pose: %d",
    PROFILE_BACKGROUND_LABEL    = "Background: %d",
    PROFILE_CAPABILITY_HINT     = "(Pose/Background require Capability support)",
    PROFILE_SAVE                = "Save",
    PROFILE_RESET               = "Reset",
    PROFILE_SAVED_OK            = "Profile saved.",

    -- Profil – Spieltage
    PLAYDAY_MONDAY           = "Monday",
    PLAYDAY_TUESDAY          = "Tuesday",
    PLAYDAY_WEDNESDAY        = "Wednesday",
    PLAYDAY_THURSDAY         = "Thursday",
    PLAYDAY_FRIDAY           = "Friday",
    PLAYDAY_SATURDAY         = "Saturday",
    PLAYDAY_SUNDAY           = "Sunday",

    -- Profil – Spielzeiten
    PLAYTIME_MORNING         = "Morning",
    PLAYTIME_AFTERNOON       = "Afternoon",
    PLAYTIME_EVENING         = "Evening",
    PLAYTIME_NIGHT           = "Night",

    -- Profil – Spielstil
    PLAYSTYLE_ROLEPLAY       = "Roleplay",
    PLAYSTYLE_RAID           = "Raid",
    PLAYSTYLE_MYTHICPLUS     = "Mythic+",
    PLAYSTYLE_DELVES         = "Delves",
    PLAYSTYLE_QUESTS         = "Quests",
    PLAYSTYLE_PVP            = "PvP",
    PLAYSTYLE_CASUAL         = "Casual",
    PLAYSTYLE_COLLECTOR      = "Collector",

    -- Settings Panel
    SETTINGS_SECTION_GENERAL    = "General",
    SETTINGS_SECTION_SAFETY     = "Safety",
    SETTINGS_SECTION_DEVELOPER  = "Developer",
    SETTINGS_SECTION_DATABASE   = "Database",
    SETTINGS_VERSION_LABEL      = "Nexus Version: %s",
    SETTINGS_PROTOCOL_LABEL     = "Protocol: %d",
    SETTINGS_SAFE_MODE_LABEL    = "Safe Mode (disables network sending):",
    SETTINGS_SAFE_MODE_ON       = "ON",
    SETTINGS_SAFE_MODE_OFF      = "Off",
    SETTINGS_DEV_MODE_LABEL     = "Dev Mode (Telemetry + Debug output):",
    SETTINGS_DEV_MODE_ON        = "ON",
    SETTINGS_DEV_MODE_OFF       = "Off",
    SETTINGS_TELEMETRY_BTN      = "Print Telemetry",
    SETTINGS_DB_INFO            = "Profiles: %d stored",
    SETTINGS_DB_RESET_BTN       = "Reset Database",
    SETTINGS_DEV_MODE_ACTIVATED = "[Nexus] Dev Mode activated.",
    SETTINGS_RESET_CONFIRM      = "WARNING: All Nexus profile data will be deleted!\n\nContinue?",
    SETTINGS_RESET_YES          = "Yes, reset",
    SETTINGS_RESET_NO           = "Cancel",
    SETTINGS_RESET_DONE         = "[Nexus] Database reset.",
    SETTINGS_RESET_COMBAT       = "[Nexus] Reset not allowed during combat.",

    -- Tooltips – Tabs
    TOOLTIP_TAB_FEED_TITLE      = "Feed",
    TOOLTIP_TAB_FEED_BODY       = "Browse nearby players and their profiles.",
    TOOLTIP_TAB_PROFILE_TITLE   = "Profile",
    TOOLTIP_TAB_PROFILE_BODY    = "Edit your public Nexus profile.",
    TOOLTIP_TAB_SETTINGS_TITLE  = "Settings",
    TOOLTIP_TAB_SETTINGS_BODY   = "Configure Nexus behavior and preferences.",

    -- Tooltips – Kategorien
    TOOLTIP_CATEGORY_FEED_BODY       = "Show all visible players.",
    TOOLTIP_CATEGORY_GUILD_BODY      = "Show only guild members.",
    TOOLTIP_CATEGORY_FRIENDS_BODY    = "Show only friends.",
    TOOLTIP_CATEGORY_PUBLIC_BODY     = "Show all public profiles.",
    TOOLTIP_CATEGORY_COMMUNITIES_BODY= "Show community members.",

    -- Tooltips – Header
    TOOLTIP_POST_CAPACITY_TITLE = "Post Storage",
    TOOLTIP_POST_CAPACITY_BODY  = "Shows how many posts are currently stored locally.",

    -- Tooltips – Playstyle
    TOOLTIP_PLAYSTYLE_ROLEPLAY   = "Prefers roleplay-focused gameplay.",
    TOOLTIP_PLAYSTYLE_RAID       = "Prefers organized raid content.",
    TOOLTIP_PLAYSTYLE_MYTHICPLUS = "Actively plays Mythic+ dungeons.",
    TOOLTIP_PLAYSTYLE_DELVES     = "Enjoys Delves and deep exploration.",
    TOOLTIP_PLAYSTYLE_QUESTS     = "Focuses mainly on questing content.",
    TOOLTIP_PLAYSTYLE_PVP        = "Enjoys PvP combat.",
    TOOLTIP_PLAYSTYLE_CASUAL     = "Plays casually without strict goals.",
    TOOLTIP_PLAYSTYLE_COLLECTOR  = "Focuses on collecting mounts, pets and achievements.",

    -- Tooltips – Spielplan
    TOOLTIP_PLAYDAYS_TITLE  = "Play Days",
    TOOLTIP_PLAYDAYS_BODY   = "Preferred days for playing.",
    TOOLTIP_PLAYTIME_TITLE  = "Play Times",
    TOOLTIP_PLAYTIME_BODY   = "Preferred times of day for playing.",

    -- Tooltips – Settings
    TOOLTIP_SAFE_MODE_TITLE = "Safe Mode",
    TOOLTIP_SAFE_MODE_BODY  = "Pauses all Nexus network communication. Enable if you experience issues.",
    TOOLTIP_DEV_MODE_TITLE  = "Developer Mode",
    TOOLTIP_DEV_MODE_BODY   = "Activates debug output and telemetry. For developers only.",
    TOOLTIP_TELEMETRY_TITLE = "Telemetry",
    TOOLTIP_TELEMETRY_BODY  = "Prints current performance and network statistics to chat.",
    TOOLTIP_DB_RESET_TITLE  = "Reset Database",
    TOOLTIP_DB_RESET_BODY   = "Permanently deletes all locally stored Nexus profiles. Cannot be undone.",

    -- Versions- & Netzwerkhinweise
    VERSION_OUTDATED_TITLE        = "Addon Update Recommended",
    VERSION_OUTDATED_BODY         = "Your Nexus version is older than other players. Some features may be limited.",
    PROTOCOL_INCOMPATIBLE_TITLE   = "Limited Compatibility",
    PROTOCOL_INCOMPATIBLE_BODY    = "You are interacting with players using a newer Nexus protocol. Some data may be hidden.",

    -- Safe-Mode & Warnungen
    SAFE_MODE_ACTIVE              = "Nexus communication is currently paused.",
    SAFE_MODE_REASON_COMBAT       = "Disabled during combat.",
    SAFE_MODE_REASON_INSTANCE     = "Disabled in this instance type.",

    -- Dev & Debug
    DEV_MISSING_LOCALE            = "Missing locale key: %s",
    DEV_CAPABILITY_DOWNGRADE      = "Feature downgraded due to peer capabilities.",
    DEV_PROTOCOL_MISMATCH         = "Protocol mismatch detected.",

    -- Post-System (Structured Post System v1)
    CREATE_POST_TITLE     = "New Post",
    CREATE_POST_BTN       = "+ New Post",
    POST_PLACEHOLDER      = "What do you want to share?",
    POST_SUBMIT           = "Post",
    POST_CANCEL           = "Cancel",
    POST_SCOPE_LABEL      = "Visibility:",
    SCOPE_GUILD           = "Guild",
    SCOPE_FRIENDS         = "Friends",
    SCOPE_PUBLIC          = "Public",
    POST_COMBAT_BLOCKED   = "[Nexus] Cannot post during combat.",
    POST_TOO_LONG         = "Text too long (%d/%d characters).",
    POST_RATE_LIMITED     = "Please wait %ds before posting again.",
    FEED_EMPTY            = "No posts yet.\nBe the first to share something!",

    -- Scope Filter & Guild-Check
    POST_NO_GUILD         = "You are not in a guild. Guild posts are not available.",
    FEED_EMPTY_GUILD      = "No guild posts yet.",
    FEED_EMPTY_FRIENDS    = "No posts from friends yet.",
    FEED_EMPTY_PUBLIC     = "No public posts yet.",
}

-- ------------------------------------------------------------
-- deDE (Deutsch – vollständig)
-- ------------------------------------------------------------
NexusLocale["deDE"] = {
    -- Fenster & Navigation
    NEXUS_TITLE              = "Nexus",
    NEXUS_ONLINE             = "[Nexus Online]",
    NEXUS_OFFLINE            = "[Nexus Offline]",
    TAB_FEED                 = "Feed",
    TAB_PROFILE              = "Profil",
    TAB_SETTINGS             = "Einstellungen",

    -- Kategorie-Buttons
    CATEGORY_FEED            = "Feed",
    CATEGORY_GUILD           = "Gilde",
    CATEGORY_FRIENDS         = "Freunde",
    CATEGORY_PUBLIC          = "Oeffentlich",
    CATEGORY_COMMUNITIES     = "Communities",

    -- Header & Status
    HEADER_CHARACTER_LEVEL_CLASS = "Stufe %d %s",
    POST_COUNT               = "Posts: %d / %d",
    POST_LIMIT_WARNING_SOFT  = "Dein Post-Speicher wird knapp.",
    POST_LIMIT_WARNING_HARD  = "Dein Post-Speicher ist fast voll. Loesche alte Posts.",
    NEXUS_STATUS_ONLINE      = "Online",
    NEXUS_STATUS_OFFLINE     = "Offline",
    NEXUS_STATUS_SAFE_MODE   = "Sicherheitsmodus",

    -- Feed Panel
    FEED_EMPTY               = "Keine Eintraege gefunden.\nBewege dich in der Welt um Spieler zu sehen.",
    FEED_LOADING             = "Wird geladen...",
    FEED_PLAYER_LEVEL_CLASS  = "Stufe %d %s",
    FEED_LAST_SEEN           = "Zuletzt gesehen: %s",
    FEED_COMPATIBILITY_FULL  = "Volle Kompatibilitaet",
    FEED_COMPATIBILITY_LEGACY= "Legacy-Modus",
    FEED_COMPATIBILITY_LIMITED = "Eingeschraenkter Modus",

    -- Profil – Sektionen
    PROFILE_SECTION_PLAYDAYS    = "Spieltage",
    PROFILE_SECTION_PLAYTIME    = "Spielzeiten",
    PROFILE_SECTION_PLAYSTYLE   = "Spielstil",
    PROFILE_SECTION_APPEARANCE  = "Aussehen",
    PROFILE_POSE_LABEL          = "Pose: %d",
    PROFILE_BACKGROUND_LABEL    = "Hintergrund: %d",
    PROFILE_CAPABILITY_HINT     = "(Pose/Hintergrund erfordern Capability-Unterstuetzung)",
    PROFILE_SAVE                = "Speichern",
    PROFILE_RESET               = "Zuruecksetzen",
    PROFILE_SAVED_OK            = "[Nexus] Profil gespeichert.",

    -- Profil – Spieltage
    PLAYDAY_MONDAY           = "Montag",
    PLAYDAY_TUESDAY          = "Dienstag",
    PLAYDAY_WEDNESDAY        = "Mittwoch",
    PLAYDAY_THURSDAY         = "Donnerstag",
    PLAYDAY_FRIDAY           = "Freitag",
    PLAYDAY_SATURDAY         = "Samstag",
    PLAYDAY_SUNDAY           = "Sonntag",

    -- Profil – Spielzeiten
    PLAYTIME_MORNING         = "Morgens",
    PLAYTIME_AFTERNOON       = "Nachmittags",
    PLAYTIME_EVENING         = "Abends",
    PLAYTIME_NIGHT           = "Nachts",

    -- Profil – Spielstil
    PLAYSTYLE_ROLEPLAY       = "Roleplay",
    PLAYSTYLE_RAID           = "Raid",
    PLAYSTYLE_MYTHICPLUS     = "Mythic+",
    PLAYSTYLE_DELVES         = "Tiefensuchen",
    PLAYSTYLE_QUESTS         = "Quests",
    PLAYSTYLE_PVP            = "PvP",
    PLAYSTYLE_CASUAL         = "Casual",
    PLAYSTYLE_COLLECTOR      = "Sammler",

    -- Settings Panel
    SETTINGS_SECTION_GENERAL    = "Allgemein",
    SETTINGS_SECTION_SAFETY     = "Sicherheit",
    SETTINGS_SECTION_DEVELOPER  = "Entwickler",
    SETTINGS_SECTION_DATABASE   = "Datenbank",
    SETTINGS_VERSION_LABEL      = "Nexus Version: %s",
    SETTINGS_PROTOCOL_LABEL     = "Protokoll: %d",
    SETTINGS_SAFE_MODE_LABEL    = "Sicherheitsmodus (deaktiviert Netzwerk-Senden):",
    SETTINGS_SAFE_MODE_ON       = "AN",
    SETTINGS_SAFE_MODE_OFF      = "Aus",
    SETTINGS_DEV_MODE_LABEL     = "Dev Mode (Telemetrie + Debug-Output):",
    SETTINGS_DEV_MODE_ON        = "AN",
    SETTINGS_DEV_MODE_OFF       = "Aus",
    SETTINGS_TELEMETRY_BTN      = "Telemetrie ausgeben",
    SETTINGS_DB_INFO            = "Profile: %d gespeichert",
    SETTINGS_DB_RESET_BTN       = "Datenbank zuruecksetzen",
    SETTINGS_DEV_MODE_ACTIVATED = "[Nexus] Dev Mode aktiviert.",
    SETTINGS_RESET_CONFIRM      = "ACHTUNG: Alle Nexus-Profildaten werden geloescht!\n\nFortfahren?",
    SETTINGS_RESET_YES          = "Ja, zuruecksetzen",
    SETTINGS_RESET_NO           = "Abbrechen",
    SETTINGS_RESET_DONE         = "[Nexus] Datenbank zurueckgesetzt.",
    SETTINGS_RESET_COMBAT       = "[Nexus] Reset im Combat nicht erlaubt.",

    -- Tooltips – Tabs
    TOOLTIP_TAB_FEED_TITLE      = "Feed",
    TOOLTIP_TAB_FEED_BODY       = "Spieler in der Naehe und ihre Profile durchstoebern.",
    TOOLTIP_TAB_PROFILE_TITLE   = "Profil",
    TOOLTIP_TAB_PROFILE_BODY    = "Dein oeffentliches Nexus-Profil bearbeiten.",
    TOOLTIP_TAB_SETTINGS_TITLE  = "Einstellungen",
    TOOLTIP_TAB_SETTINGS_BODY   = "Nexus-Verhalten und Einstellungen konfigurieren.",

    -- Tooltips – Kategorien
    TOOLTIP_CATEGORY_FEED_BODY       = "Alle sichtbaren Spieler anzeigen.",
    TOOLTIP_CATEGORY_GUILD_BODY      = "Nur Gildenmitglieder anzeigen.",
    TOOLTIP_CATEGORY_FRIENDS_BODY    = "Nur Freunde anzeigen.",
    TOOLTIP_CATEGORY_PUBLIC_BODY     = "Alle oeffentlichen Profile anzeigen.",
    TOOLTIP_CATEGORY_COMMUNITIES_BODY= "Community-Mitglieder anzeigen.",

    -- Tooltips – Header
    TOOLTIP_POST_CAPACITY_TITLE = "Post-Speicher",
    TOOLTIP_POST_CAPACITY_BODY  = "Zeigt wie viele Posts aktuell lokal gespeichert sind.",

    -- Tooltips – Playstile
    TOOLTIP_PLAYSTYLE_ROLEPLAY   = "Bevorzugt Roleplay-orientierten Spielstil.",
    TOOLTIP_PLAYSTYLE_RAID       = "Bevorzugt organisierten Raid-Inhalt.",
    TOOLTIP_PLAYSTYLE_MYTHICPLUS = "Spielt aktiv Mythic+ Dungeons.",
    TOOLTIP_PLAYSTYLE_DELVES     = "Erkundet Tiefensuchen und Dungeons.",
    TOOLTIP_PLAYSTYLE_QUESTS     = "Konzentriert sich hauptsaechlich auf Quests.",
    TOOLTIP_PLAYSTYLE_PVP        = "Geniesst PvP-Kaempfe.",
    TOOLTIP_PLAYSTYLE_CASUAL     = "Spielt entspannt ohne feste Ziele.",
    TOOLTIP_PLAYSTYLE_COLLECTOR  = "Sammelt Reittiere, Haustiere und Erfolge.",

    -- Tooltips – Spielplan
    TOOLTIP_PLAYDAYS_TITLE  = "Spieltage",
    TOOLTIP_PLAYDAYS_BODY   = "Bevorzugte Tage zum Spielen.",
    TOOLTIP_PLAYTIME_TITLE  = "Spielzeiten",
    TOOLTIP_PLAYTIME_BODY   = "Bevorzugte Tageszeiten zum Spielen.",

    -- Tooltips – Settings
    TOOLTIP_SAFE_MODE_TITLE = "Sicherheitsmodus",
    TOOLTIP_SAFE_MODE_BODY  = "Pausiert die gesamte Nexus-Netzwerkkommunikation.",
    TOOLTIP_DEV_MODE_TITLE  = "Entwicklermodus",
    TOOLTIP_DEV_MODE_BODY   = "Aktiviert Debug-Ausgaben und Telemetrie. Nur fuer Entwickler.",
    TOOLTIP_TELEMETRY_TITLE = "Telemetrie",
    TOOLTIP_TELEMETRY_BODY  = "Gibt aktuelle Performance- und Netzwerkstatistiken im Chat aus.",
    TOOLTIP_DB_RESET_TITLE  = "Datenbank zuruecksetzen",
    TOOLTIP_DB_RESET_BODY   = "Loescht alle lokal gespeicherten Nexus-Profile dauerhaft.",

    -- Versions- & Netzwerkhinweise
    VERSION_OUTDATED_TITLE        = "Addon-Update empfohlen",
    VERSION_OUTDATED_BODY         = "Deine Nexus-Version ist aelter als die anderer Spieler. Einige Funktionen koennen eingeschraenkt sein.",
    PROTOCOL_INCOMPATIBLE_TITLE   = "Eingeschraenkte Kompatibilitaet",
    PROTOCOL_INCOMPATIBLE_BODY    = "Du spielst mit Spielern die ein neueres Nexus-Protokoll nutzen. Einige Daten koennen ausgeblendet sein.",

    -- Safe-Mode & Warnungen
    SAFE_MODE_ACTIVE              = "Nexus-Kommunikation ist derzeit pausiert.",
    SAFE_MODE_REASON_COMBAT       = "Im Kampf deaktiviert.",
    SAFE_MODE_REASON_INSTANCE     = "In diesem Instanztyp deaktiviert.",

    -- Dev & Debug
    DEV_MISSING_LOCALE            = "Fehlender Locale-Key: %s",
    DEV_CAPABILITY_DOWNGRADE      = "Feature durch Peer-Capabilities herabgestuft.",
    DEV_PROTOCOL_MISMATCH         = "Protokoll-Konflikt erkannt.",

    -- Post-System (Structured Post System v1)
    CREATE_POST_TITLE     = "Neuer Post",
    CREATE_POST_BTN       = "+ Neuer Post",
    POST_PLACEHOLDER      = "Was moechtest du teilen?",
    POST_SUBMIT           = "Posten",
    POST_CANCEL           = "Abbrechen",
    POST_SCOPE_LABEL      = "Sichtbarkeit:",
    SCOPE_GUILD           = "Gilde",
    SCOPE_FRIENDS         = "Freunde",
    SCOPE_PUBLIC          = "Oeffentlich",
    POST_COMBAT_BLOCKED   = "[Nexus] Im Kampf nicht moeglich.",
    POST_TOO_LONG         = "Text zu lang (%d/%d Zeichen).",
    POST_RATE_LIMITED     = "Bitte %ds warten.",
    FEED_EMPTY            = "Noch keine Posts.\nSei der Erste der etwas teilt!",

    -- Scope Filter & Gilde-Check
    POST_NO_GUILD         = "Du bist keiner Gilde zugehoerig. Gilde-Posts nicht verfuegbar.",
    FEED_EMPTY_GUILD      = "Noch keine Gilde-Posts.",
    FEED_EMPTY_FRIENDS    = "Noch keine Posts von Freunden.",
    FEED_EMPTY_PUBLIC     = "Noch keine oeffentlichen Posts.",
}

-- ============================================================
-- 2. LOCALE LOADER (Fallback-Metatable)
-- ============================================================

local enUS = NexusLocale["enUS"]

local function BuildLocale(locale)
    local base = NexusLocale[locale]
    if not base then
        return enUS  -- Sprache unbekannt → enUS direkt
    end
    if base == enUS then
        return enUS  -- enUS braucht keine Metatable
    end

    -- Metatable: fehlende Keys → enUS Fallback
    return setmetatable(base, {
        __index = function(_, key)
            local fallback = enUS[key]
            if fallback then
                if NexusConfig and NexusConfig.devMode then
                    print(string.format(
                        "|cffff8800[Nexus Locale] WARN: Key '%s' fehlt in %s → enUS Fallback|r",
                        tostring(key), locale))
                end
                return fallback
            end
            -- Key existiert auch in enUS nicht
            if NexusConfig and NexusConfig.devMode then
                print(string.format(
                    "|cffff4444[Nexus Locale] ERROR: Key '%s' existiert nicht!|r",
                    tostring(key)))
            end
            return "???" .. tostring(key) .. "???"  -- Nutzer sieht nie nil
        end
    })
end

-- Aktive Locale setzen
local gameLocale = GetLocale and GetLocale() or "enUS"
L = BuildLocale(gameLocale)
_G.L = L  -- global verfügbar

-- ============================================================
-- 3. TOOLTIP REGISTRY
-- ============================================================

NexusTooltipRegistry = {
    -- Format: [elementID] = { titleKey, bodyKey, required }

    -- Tabs
    ["TAB_FEED"]                  = { "TOOLTIP_TAB_FEED_TITLE",       "TOOLTIP_TAB_FEED_BODY",       true },
    ["TAB_PROFILE"]               = { "TOOLTIP_TAB_PROFILE_TITLE",    "TOOLTIP_TAB_PROFILE_BODY",    true },
    ["TAB_SETTINGS"]              = { "TOOLTIP_TAB_SETTINGS_TITLE",   "TOOLTIP_TAB_SETTINGS_BODY",   true },

    -- Kategorie-Buttons
    ["CATEGORY_FEED"]             = { nil, "TOOLTIP_CATEGORY_FEED_BODY",        true },
    ["CATEGORY_GUILD"]            = { nil, "TOOLTIP_CATEGORY_GUILD_BODY",       true },
    ["CATEGORY_FRIENDS"]          = { nil, "TOOLTIP_CATEGORY_FRIENDS_BODY",     true },
    ["CATEGORY_PUBLIC"]           = { nil, "TOOLTIP_CATEGORY_PUBLIC_BODY",      true },
    ["CATEGORY_COMMUNITIES"]      = { nil, "TOOLTIP_CATEGORY_COMMUNITIES_BODY", true },

    -- Header
    ["HEADER_POST_CAPACITY"]      = { "TOOLTIP_POST_CAPACITY_TITLE", "TOOLTIP_POST_CAPACITY_BODY", true },

    -- Profil – Playstil Checkboxen
    ["PROFILE_PLAYSTYLE_ROLEPLAY"]   = { nil, "TOOLTIP_PLAYSTYLE_ROLEPLAY",   true },
    ["PROFILE_PLAYSTYLE_RAID"]       = { nil, "TOOLTIP_PLAYSTYLE_RAID",       true },
    ["PROFILE_PLAYSTYLE_MYTHICPLUS"] = { nil, "TOOLTIP_PLAYSTYLE_MYTHICPLUS", true },
    ["PROFILE_PLAYSTYLE_DELVES"]     = { nil, "TOOLTIP_PLAYSTYLE_DELVES",     true },
    ["PROFILE_PLAYSTYLE_QUESTS"]     = { nil, "TOOLTIP_PLAYSTYLE_QUESTS",     true },
    ["PROFILE_PLAYSTYLE_PVP"]        = { nil, "TOOLTIP_PLAYSTYLE_PVP",        true },
    ["PROFILE_PLAYSTYLE_CASUAL"]     = { nil, "TOOLTIP_PLAYSTYLE_CASUAL",     true },
    ["PROFILE_PLAYSTYLE_COLLECTOR"]  = { nil, "TOOLTIP_PLAYSTYLE_COLLECTOR",  true },

    -- Profil – Spielplan
    ["PROFILE_PLAYDAYS"]          = { "TOOLTIP_PLAYDAYS_TITLE", "TOOLTIP_PLAYDAYS_BODY",  false },
    ["PROFILE_PLAYTIME"]          = { "TOOLTIP_PLAYTIME_TITLE", "TOOLTIP_PLAYTIME_BODY",  false },

    -- Settings
    ["SETTINGS_SAFE_MODE_TOGGLE"] = { "TOOLTIP_SAFE_MODE_TITLE", "TOOLTIP_SAFE_MODE_BODY",  true },
    ["SETTINGS_DEV_MODE_TOGGLE"]  = { "TOOLTIP_DEV_MODE_TITLE",  "TOOLTIP_DEV_MODE_BODY",   true },
    ["SETTINGS_TELEMETRY_BTN"]    = { "TOOLTIP_TELEMETRY_TITLE", "TOOLTIP_TELEMETRY_BODY",  false },
    ["SETTINGS_RESET_BUTTON"]     = { "TOOLTIP_DB_RESET_TITLE",  "TOOLTIP_DB_RESET_BODY",   true },
}

-- ============================================================
-- 4. TOOLTIP API WRAPPER
-- ============================================================

function NexusTooltip_Show(frame, titleKey, bodyKey)
    if not frame then return end

    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    local title = titleKey and L[titleKey]
    local body  = bodyKey  and L[bodyKey]

    if title and title ~= "" then
        GameTooltip:AddLine(title, 1, 0.82, 0, true)
    end
    if body and body ~= "" then
        GameTooltip:AddLine(body, 1, 1, 1, true)
    end

    GameTooltip:Show()
end

function NexusTooltip_Hide()
    GameTooltip:Hide()
end

-- Tooltip an Frame binden via Registry
function NexusTooltip_Bind(frame, elementID)
    if not frame or not elementID then return end

    local entry = NexusTooltipRegistry[elementID]
    if not entry then
        if NexusConfig and NexusConfig.devMode then
            print(string.format(
                "|cffff8800[Nexus Tooltip] WARN: Kein Registry-Eintrag für '%s'|r", elementID))
        end
        return
    end

    local titleKey = entry[1]
    local bodyKey  = entry[2]

    frame:SetScript("OnEnter", function(self)
        NexusTooltip_Show(self, titleKey, bodyKey)
    end)
    frame:SetScript("OnLeave", function()
        NexusTooltip_Hide()
    end)
end

-- ============================================================
-- 5. DEV LOCALE VALIDATOR (nur Dev Mode)
-- ============================================================

NexusLocaleValidator = {
    telemetry = {
        missingLocaleCount    = 0,
        formatMismatchCount   = 0,
        unusedKeyCount        = 0,
        runtimeMissingLookups = 0,
    }
}

local function CountFormatSpecifiers(str)
    if type(str) ~= "string" then return 0 end
    local count = 0
    for _ in str:gmatch("%%[sdifq]") do count = count + 1 end
    return count
end

function NexusLocaleValidator:RunStartupScan(force)
    -- force=true: auch ohne Dev Mode ausführbar (z.B. via Slash-Command)
    if not force and not (NexusConfig and NexusConfig.devMode) then
        print("|cffff8800[Nexus] Locale Scan benötigt Dev Mode (oder: /nexus localescan force)|r")
        return
    end

    print("|cff00ccff[Nexus Locale Validator] Startup-Scan...|r")

    local missing        = 0
    local formatMismatch = 0

    -- Phase 1: Alle aktiven Locales gegen enUS prüfen
    for locale, tbl in pairs(NexusLocale) do
        if locale ~= "enUS" then
            for key, enVal in pairs(enUS) do
                local locVal = rawget(tbl, key)
                if locVal == nil or locVal == "" then
                    missing = missing + 1
                    print(string.format(
                        "|cffff8800  WARN [%s] Fehlender Key: %s|r", locale, key))
                elseif type(locVal) == "string" and type(enVal) == "string" then
                    -- Phase 3: Format-Specifier Check
                    local enCount  = CountFormatSpecifiers(enVal)
                    local locCount = CountFormatSpecifiers(locVal)
                    if enCount ~= locCount then
                        formatMismatch = formatMismatch + 1
                        print(string.format(
                            "|cffff4444  ERROR [%s] Format-Mismatch '%s': enUS=%d %%%%-Specifier, %s=%d|r",
                            locale, key, enCount, locale, locCount))
                    end
                end
            end
        end
    end

    -- Phase 2: Tooltip Registry – Keys vorhanden?
    local tooltipErrors = 0
    for elementID, entry in pairs(NexusTooltipRegistry) do
        local titleKey = entry[1]
        local bodyKey  = entry[2]
        if titleKey and not enUS[titleKey] then
            tooltipErrors = tooltipErrors + 1
            print(string.format(
                "|cffff4444  ERROR Registry '%s': titleKey '%s' nicht in enUS!|r",
                elementID, titleKey))
        end
        if bodyKey and not enUS[bodyKey] then
            tooltipErrors = tooltipErrors + 1
            print(string.format(
                "|cffff4444  ERROR Registry '%s': bodyKey '%s' nicht in enUS!|r",
                elementID, bodyKey))
        end
    end

    -- Telemetrie speichern
    self.telemetry.missingLocaleCount  = missing
    self.telemetry.formatMismatchCount = formatMismatch

    -- Ergebnis
    if missing == 0 and formatMismatch == 0 and tooltipErrors == 0 then
        print("|cff00ff00[Nexus Locale Validator] PASS – keine Fehler gefunden.|r")
    else
        print(string.format(
            "|cffff4444[Nexus Locale Validator] %d fehlend, %d Format-Mismatch, %d Tooltip-Fehler|r",
            missing, formatMismatch, tooltipErrors))
    end
end

-- ============================================================
-- 6. INITIALISIERUNG
-- ============================================================

local localeInitFrame = CreateFrame("Frame", "NexusLocaleInitFrame")
localeInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
localeInitFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")

        -- Locale neu laden (NexusConfig könnte jetzt verfügbar sein)
        local gl = GetLocale and GetLocale() or "enUS"
        L = BuildLocale(gl)
        _G.L = L

        -- Dev Mode: Validator starten
        C_Timer.After(1.0, function()
            if NexusConfig and NexusConfig.devMode then
                NexusLocaleValidator:RunStartupScan()
            end
        end)
    end
end)

-- ============================================================
-- 7. UNIT TESTS
-- ============================================================

local function RunLocaleTests()
    print("\n=== NEXUS_LOCALE UNIT TESTS ===\n")

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

    -- Test 1: enUS vollständig vorhanden
    Assert(type(NexusLocale["enUS"]) == "table", "enUS Tabelle vorhanden")
    Assert(NexusLocale["enUS"]["NEXUS_TITLE"] == "Nexus", "enUS NEXUS_TITLE korrekt")
    Assert(NexusLocale["enUS"]["TAB_FEED"] == "Feed", "enUS TAB_FEED korrekt")

    -- Test 2: deDE vorhanden
    Assert(type(NexusLocale["deDE"]) == "table", "deDE Tabelle vorhanden")
    Assert(NexusLocale["deDE"]["TAB_PROFILE"] == "Profil", "deDE TAB_PROFILE korrekt")
    Assert(NexusLocale["deDE"]["TAB_SETTINGS"] == "Einstellungen", "deDE TAB_SETTINGS korrekt")

    -- Test 3: Spieltage deDE
    Assert(NexusLocale["deDE"]["PLAYDAY_MONDAY"] == "Montag", "deDE PLAYDAY_MONDAY = Montag")
    Assert(NexusLocale["deDE"]["PLAYDAY_SUNDAY"] == "Sonntag", "deDE PLAYDAY_SUNDAY = Sonntag")

    -- Test 4: Fallback-Metatable
    local testLocale = BuildLocale("deDE")
    Assert(testLocale["NEXUS_TITLE"] == "Nexus", "Metatable: vorhandener Key direkt")
    -- Key der nur in enUS existiert (simuliert fehlenden deDE Key)
    local onlyEnUS = NexusLocale["enUS"]["VERSION_OUTDATED_TITLE"]
    Assert(type(onlyEnUS) == "string", "enUS VERSION_OUTDATED_TITLE vorhanden")

    -- Test 5: Unbekannte Locale → enUS Fallback
    local unknownLocale = BuildLocale("xxXX")
    Assert(unknownLocale == enUS, "Unbekannte Locale → enUS direkt")

    -- Test 6: Nil-Schutz – kein nil zurückgegeben
    local testL = BuildLocale("deDE")
    local val = testL["NEXUS_TITLE"]
    Assert(val ~= nil and val ~= "", "Kein nil-Wert bei gueltigem Key")

    -- Test 7: Format-Specifier konsistent (POST_COUNT)
    local enCount  = CountFormatSpecifiers(NexusLocale["enUS"]["POST_COUNT"])
    local deCount  = CountFormatSpecifiers(NexusLocale["deDE"]["POST_COUNT"])
    Assert(enCount == deCount, "POST_COUNT: gleiche Format-Specifier in enUS und deDE")

    Assert(enCount == 2, "POST_COUNT: 2 Format-Specifier (%d / %d)")

    -- Test 8: Tooltip Registry vollständig
    Assert(type(NexusTooltipRegistry) == "table", "NexusTooltipRegistry vorhanden")
    Assert(NexusTooltipRegistry["TAB_FEED"] ~= nil, "Registry: TAB_FEED vorhanden")
    Assert(NexusTooltipRegistry["SETTINGS_SAFE_MODE_TOGGLE"] ~= nil,
        "Registry: SETTINGS_SAFE_MODE_TOGGLE vorhanden")
    Assert(NexusTooltipRegistry["SETTINGS_RESET_BUTTON"] ~= nil,
        "Registry: SETTINGS_RESET_BUTTON vorhanden")

    -- Test 9: Alle required Registry-Keys existieren in enUS
    local regErrors = 0
    for elementID, entry in pairs(NexusTooltipRegistry) do
        if entry[1] and not enUS[entry[1]] then regErrors = regErrors + 1 end
        if entry[2] and not enUS[entry[2]] then regErrors = regErrors + 1 end
    end
    Assert(regErrors == 0, "Alle Tooltip Registry Keys existieren in enUS (" ..
        (regErrors > 0 and regErrors .. " Fehler" or "OK") .. ")")

    -- Test 10: NexusTooltip_Show / NexusTooltip_Bind existieren
    Assert(type(NexusTooltip_Show) == "function", "NexusTooltip_Show ist Funktion")
    Assert(type(NexusTooltip_Bind) == "function", "NexusTooltip_Bind ist Funktion")
    Assert(type(NexusTooltip_Hide) == "function", "NexusTooltip_Hide ist Funktion")

    -- Test 11: HEADER_CHARACTER_LEVEL_CLASS Format
    local fmtTest = L["HEADER_CHARACTER_LEVEL_CLASS"]:format(80, "Shaman")
    Assert(type(fmtTest) == "string" and fmtTest ~= "", "HEADER_CHARACTER_LEVEL_CLASS :format() funktioniert")

    -- Test 12: enUS und deDE haben gleiche Key-Anzahl (Vollständigkeitsprüfung)
    local enCount2, deCount2 = 0, 0
    for _ in pairs(NexusLocale["enUS"]) do enCount2 = enCount2 + 1 end
    for _ in pairs(NexusLocale["deDE"]) do deCount2 = deCount2 + 1 end
    Assert(enCount2 == deCount2,
        string.format("enUS (%d) und deDE (%d) haben gleiche Key-Anzahl", enCount2, deCount2))

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

_G.Nexus_Locale = {
    RunTests  = RunLocaleTests,
    Validator = NexusLocaleValidator,
}

-- FIX: /nexus localescan – Scan immer ausführbar, auch ohne Dev Mode
-- Integriert sich in bestehenden /nexus Handler
local _origLocaleSlash = SlashCmdList["NEXUS"]
SLASH_NEXUS1 = "/nexus"
SlashCmdList["NEXUS"] = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if cmd == "localescan" or cmd == "locale" then
        NexusLocaleValidator:RunStartupScan(true)  -- force=true
        return
    end
    if _origLocaleSlash then _origLocaleSlash(msg) end
end

print(string.format("[Nexus Locale] Modul geladen (v%s) – Sprache: %s",
    LOCALE_VERSION, gameLocale))
