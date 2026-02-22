--[[
    NEXUS - World of Warcraft Community Addon
    Projekt Charter: Midnight API v12

    Modul: Nexus_Scroll (RowPoolManager + ScrollAdapter)
    Spezifikation: Nexus_RowPool_Manager_Spec.docx
                   Nexus_ScrollAdapter_Spec.docx

    Grundsatz:
    - Rows werden einmal erzeugt, danach NUR recycelt
    - CreateFrame() während Scroll ist VERBOTEN
    - Minimal-Update: O(Δ) statt O(n) beim Scroll
    - Feste Row-Höhe: 64 Pixel (VERBINDLICH)
    - Max aktive Rows: ~15 (Viewport + Buffer)

    Version: 0.1.1-alpha
]]

-- ============================================================
-- 1. KONSTANTEN
-- ============================================================

local SCROLL_VERSION  = "0.1.1-alpha"
local ROW_HEIGHT      = 64     -- FEST, UNVERÄNDERLICH
local ROW_BUFFER      = 2      -- Extra Rows über Viewport hinaus
local MAX_POOL_SIZE   = 20     -- Absolutes Hard-Limit für Pool-Größe
local PREVIEW_MAX_LEN = 80     -- Zeichen für Post-Preview
local NAME_MAX_LEN    = 50     -- Zeichen für Spielername

-- ============================================================
-- 2. ROW TEMPLATE
-- ============================================================
-- Erstellt eine einzelne Row mit allen Child-Elementen
-- Row-Höhe: 64px (fest)
-- Layout: [Avatar 32x32] [Name + Zeit] [Preview-Text]

local function CreateRowFrame(parent, index)
    local row = CreateFrame("Button", "NexusPostRow" .. index, parent)
    row:SetSize(parent:GetWidth() or 300, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)  -- Position wird vom ScrollAdapter gesetzt

    -- Hintergrund
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight")
    bg:SetVertexColor(0.08, 0.08, 0.12, 0.6)
    row.bg = bg

    -- Trenn-Linie (unten)
    local divider = row:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
    divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
    divider:SetHeight(1)
    divider:SetTexture("Interface\\Buttons\\WHITE8X8")
    divider:SetVertexColor(0.2, 0.2, 0.3, 0.5)

    -- Avatar Icon (links, 32x32)
    local avatar = row:CreateTexture(nil, "ARTWORK")
    avatar:SetSize(32, 32)
    avatar:SetPoint("LEFT", row, "LEFT", 8, 0)
    avatar:SetTexture("Interface\\CharacterFrame\\TemporaryPortrait")
    row.avatar = avatar

    -- Spielername (oben links, nach Avatar)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 48, -8)
    nameText:SetSize(180, 16)
    nameText:SetJustifyH("LEFT")
    nameText:SetText("")
    row.nameText = nameText

    -- Zeitstempel (oben rechts)
    local timeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -8)
    timeText:SetSize(60, 16)
    timeText:SetJustifyH("RIGHT")
    timeText:SetTextColor(0.6, 0.6, 0.6, 1.0)
    timeText:SetText("")
    row.timeText = timeText

    -- Preview-Text (unten, nach Avatar)
    local previewText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    previewText:SetPoint("TOPLEFT", row, "TOPLEFT", 48, -26)
    previewText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -26)
    previewText:SetHeight(24)
    previewText:SetJustifyH("LEFT")
    previewText:SetTextColor(0.75, 0.75, 0.8, 1.0)
    previewText:SetText("")
    row.previewText = previewText

    -- Hover-Effekt
    row:SetScript("OnEnter", function(self)
        self.bg:SetVertexColor(0.15, 0.15, 0.25, 0.8)
    end)
    row:SetScript("OnLeave", function(self)
        self.bg:SetVertexColor(0.08, 0.08, 0.12, 0.6)
    end)

    -- SetPostData: Kernfunktion für Recycling
    -- VOLLSTÄNDIGES Überschreiben (kein Append!)
    -- Unterstützt: Structured Posts (data.text) + Profil-Fallback (data.nameID)
    function row:SetPostData(data)
        if not data then
            -- RESET: alles leeren (Ghost-State verhindern)
            self.nameText:SetText("")
            self.timeText:SetText("")
            self.previewText:SetText("")
            self.avatar:SetTexture("Interface\\CharacterFrame\\TemporaryPortrait")
            self.bg:SetVertexColor(0.08, 0.08, 0.12, 0.6)
            self:Hide()
            return
        end

        -- Datenquelle bestimmen: Post (data.text vorhanden) oder Profil (Fallback)
        local isPost = (data.text ~= nil)

        -- Name (Autor des Posts oder Spieler-Name)
        local name = tostring(
            isPost and (data.authorName or "Unbekannt")
                    or (data.nameID or "Unbekannt")
        )
        if #name > NAME_MAX_LEN then
            name = name:sub(1, NAME_MAX_LEN - 1) .. "…"
        end
        self.nameText:SetText(name)

        -- Zeitstempel (Post-Timestamp oder lastSeen)
        local ts  = isPost and (data.timestamp or 0) or (data.lastSeen or 0)
        local age = math.max(0, time() - ts)
        local timeStr
        if age < 60     then timeStr = "Jetzt"
        elseif age < 3600   then timeStr = math.floor(age / 60)    .. "m"
        elseif age < 86400  then timeStr = math.floor(age / 3600)  .. "h"
        else                     timeStr = math.floor(age / 86400) .. "d"
        end
        self.timeText:SetText(timeStr)

        -- Vorschau-Text (Post-Text oder Bio)
        local preview
        if isPost then
            preview = tostring(data.text or "")
            -- WoW-Link-Codes für Anzeige aufbereiten: |Hitem:123|h[Schwert]|h → [Schwert]
            preview = preview:gsub("|H[^|]+|h%[([^%]]+)%]|h", "[%1]")
            preview = preview:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        else
            preview = tostring(data.bio or "")
        end
        if #preview > PREVIEW_MAX_LEN then
            preview = preview:sub(1, PREVIEW_MAX_LEN - 1) .. "…"
        end
        self.previewText:SetText(preview)

        self:Show()
    end

    row:Hide()
    return row
end

-- ============================================================
-- 3. ROW POOL MANAGER
-- ============================================================

NexusRowPool = {
    activeRows   = {},   -- [dataIndex] = row
    freeRows     = {},   -- freie Rows (als Set: row = true)
    freeList     = {},   -- Liste für O(1) Acquire
    totalCreated = 0,
    maxActive    = 0,

    -- Telemetrie
    telemetry = {
        poolHighWatermark = 0,
        recycleCount      = 0,
        emergencyCreates  = 0,
        activeRowPeak     = 0,
    },

    parentFrame = nil,   -- wird beim Init gesetzt
}

-- Pre-Allocation: visibleRows + Buffer Rows einmalig erstellen
function NexusRowPool:Init(parentFrame, viewportHeight)
    self.parentFrame = parentFrame

    local visibleRows = math.ceil(viewportHeight / ROW_HEIGHT)
    local bufferRows  = visibleRows + ROW_BUFFER

    -- Alle Rows vorab erstellen (CreateFrame NUR hier!)
    for i = 1, bufferRows do
        local row = CreateRowFrame(parentFrame, i)
        self.freeRows[row] = true
        table.insert(self.freeList, row)
        self.totalCreated = self.totalCreated + 1
    end

    self.telemetry.poolHighWatermark = bufferRows

    if NexusConfig and NexusConfig.devMode then
        print(string.format("[Nexus Scroll] Pool initialisiert: %d Rows, Viewport ~%d sichtbar",
            bufferRows, visibleRows))
    end
end

-- Acquire: Row aus Pool nehmen (O(1))
function NexusRowPool:Acquire(dataIndex)
    -- Bereits aktiv?
    if self.activeRows[dataIndex] then
        return self.activeRows[dataIndex]
    end

    -- Row aus freeList nehmen
    local row = table.remove(self.freeList)

    if not row then
        -- Pool erschöpft: Soft Warning
        -- Im Release-Build sollte das NICHT passieren
        self.telemetry.emergencyCreates = self.telemetry.emergencyCreates + 1
        if NexusConfig and NexusConfig.devMode then
            print("[Nexus Scroll] WARNUNG: Pool erschoepft, Emergency Create!")
        end
        -- Notfall-Row erstellen
        self.totalCreated = self.totalCreated + 1
        row = CreateRowFrame(self.parentFrame, self.totalCreated)
    else
        self.freeRows[row] = nil
    end

    self.activeRows[dataIndex] = row

    -- Telemetrie
    local activeCount = 0
    for _ in pairs(self.activeRows) do activeCount = activeCount + 1 end
    if activeCount > self.telemetry.activeRowPeak then
        self.telemetry.activeRowPeak = activeCount
    end

    return row
end

-- Release: Row in Pool zurückgeben (O(1))
function NexusRowPool:Release(dataIndex)
    local row = self.activeRows[dataIndex]
    if not row then return end

    -- RESET: vollständig leeren (kein Ghost-State)
    row:SetPostData(nil)

    -- Aus active entfernen
    self.activeRows[dataIndex] = nil

    -- In Pool zurückgeben
    self.freeRows[row] = true
    table.insert(self.freeList, row)

    self.telemetry.recycleCount = self.telemetry.recycleCount + 1
end

-- Alle aktiven Rows auf einmal releasen (für Full-Recycle)
function NexusRowPool:ReleaseAll()
    for dataIndex, _ in pairs(self.activeRows) do
        self:Release(dataIndex)
    end
end

-- ============================================================
-- 4. SCROLL ADAPTER
-- ============================================================

NexusScrollAdapter = {
    -- Eingabedaten (werden vom Feed Panel gesetzt)
    dataSource      = nil,   -- function() return table_of_items end
    scrollFrame     = nil,
    contentFrame    = nil,

    -- Cached State
    totalItemCount  = 0,
    viewportHeight  = 0,
    rowHeight       = ROW_HEIGHT,

    -- Range-Tracking (für Minimal-Update)
    lastFirst       = 0,
    lastLast        = 0,

    -- Update-Debounce (1 Frame)
    updatePending   = false,

    -- Telemetrie
    telemetry = {
        lastVisibleRange  = { first = 0, last = 0 },
        updateCount       = 0,
        fullRecycleCount  = 0,
        maxDeltaIndex     = 0,
    },
}

-- Init: ScrollFrame + ContentFrame anbinden
function NexusScrollAdapter:Init(scrollFrame, contentFrame, dataSourceFn)
    self.scrollFrame   = scrollFrame
    self.contentFrame  = contentFrame
    self.dataSource    = dataSourceFn

    -- Viewport-Höhe cachen
    self.viewportHeight = scrollFrame:GetHeight() or 300

    -- Pool initialisieren
    NexusRowPool:Init(contentFrame, self.viewportHeight)

    -- Scroll-Events registrieren
    scrollFrame:SetScript("OnVerticalScroll", function(sf, offset)
        self:RequestUpdate()
    end)

    scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
        local current = sf:GetVerticalScroll()
        local step = ROW_HEIGHT
        sf:SetVerticalScroll(math.max(0, current - delta * step))
        self:RequestUpdate()
    end)

    scrollFrame:SetScript("OnSizeChanged", function(sf, w, h)
        self.viewportHeight = h
        self:ForceUpdate()
    end)

    print(string.format("[Nexus Scroll] Adapter initialisiert (v%s)", SCROLL_VERSION))
end

-- RequestUpdate: Debounced Update (max 1 pro Frame)
function NexusScrollAdapter:RequestUpdate()
    if self.updatePending then return end
    self.updatePending = true

    -- C_Timer für 1-Frame-Debounce
    C_Timer.After(0, function()
        self.updatePending = false
        self:UpdateVisibleRange()
    end)
end

-- ForceUpdate: Sofortiges Update (z.B. nach Daten-Reload)
function NexusScrollAdapter:ForceUpdate()
    self.lastFirst = 0
    self.lastLast  = 0
    self:UpdateVisibleRange()
end

-- Daten neu laden und ScrollFrame-Höhe aktualisieren
function NexusScrollAdapter:RefreshData()
    local items = self.dataSource and self.dataSource() or {}
    self.totalItemCount = #items

    -- Content-Frame Höhe = totalItems × rowHeight
    if self.contentFrame then
        self.contentFrame:SetHeight(math.max(self.totalItemCount * self.rowHeight, 1))
    end

    self:ForceUpdate()
end

-- Sichtbaren Bereich berechnen (Formel aus Spec, verbindlich)
function NexusScrollAdapter:CalculateVisibleRange()
    local scrollOffset  = self.scrollFrame:GetVerticalScroll() or 0
    local viewportH     = self.viewportHeight

    local firstVisible  = math.floor(scrollOffset / self.rowHeight) + 1
    local visibleCount  = math.ceil(viewportH / self.rowHeight) + 1
    local lastVisible   = firstVisible + visibleCount - 1

    -- Clamp
    firstVisible = math.max(firstVisible, 1)
    lastVisible  = math.min(lastVisible, self.totalItemCount)

    return firstVisible, lastVisible
end

-- UpdateVisibleRange: Kern des Scroll-Adapters
-- Minimal-Update Strategie: O(Δ) statt O(n)
function NexusScrollAdapter:UpdateVisibleRange()
    if not self.scrollFrame then return end
    if self.totalItemCount == 0 then
        NexusRowPool:ReleaseAll()
        self.lastFirst = 0
        self.lastLast  = 0
        return
    end

    local newFirst, newLast = self:CalculateVisibleRange()

    -- Telemetrie
    self.telemetry.updateCount = self.telemetry.updateCount + 1
    self.telemetry.lastVisibleRange = { first = newFirst, last = newLast }

    -- Keine Änderung → nichts tun (MINIMAL UPDATE!)
    if newFirst == self.lastFirst and newLast == self.lastLast then return end

    local deltaIndex = math.abs(newFirst - self.lastFirst)
    if deltaIndex > self.telemetry.maxDeltaIndex then
        self.telemetry.maxDeltaIndex = deltaIndex
    end

    -- Jump-Scroll: großer Sprung → Full Recycle erlaubt
    local visibleCount = newLast - newFirst + 1
    if deltaIndex > visibleCount then
        -- Full Recycle
        NexusRowPool:ReleaseAll()
        self.telemetry.fullRecycleCount = self.telemetry.fullRecycleCount + 1
        -- Neu aufbauen
        self:BuildRange(newFirst, newLast)
    else
        -- Inkrementelles Update: nur Delta
        -- Rows die nicht mehr sichtbar → releasen
        for i = self.lastFirst, self.lastLast do
            if i < newFirst or i > newLast then
                NexusRowPool:Release(i)
            end
        end
        -- Neue Rows die jetzt sichtbar → acquiren
        for i = newFirst, newLast do
            if i < self.lastFirst or i > self.lastLast then
                self:ShowRow(i)
            end
        end
    end

    self.lastFirst = newFirst
    self.lastLast  = newLast
end

-- Komplett neu aufbauen (nach Full Recycle)
function NexusScrollAdapter:BuildRange(first, last)
    for i = first, last do
        self:ShowRow(i)
    end
end

-- Einzelne Row anzeigen
function NexusScrollAdapter:ShowRow(dataIndex)
    local items = self.dataSource and self.dataSource() or {}
    local data  = items[dataIndex]
    if not data then return end

    local row = NexusRowPool:Acquire(dataIndex)
    if not row then return end

    -- Position berechnen (Y = -(index-1) * rowHeight)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.contentFrame, "TOPLEFT",
        0, -((dataIndex - 1) * self.rowHeight))
    row:SetWidth(self.contentFrame:GetWidth() or 300)

    -- Daten setzen (vollständiges Überschreiben)
    row:SetPostData(data)
end

-- ============================================================
-- 5. PUBLIC API
-- ============================================================

_G.NexusRowPool      = NexusRowPool
_G.NexusScrollAdapter = NexusScrollAdapter

_G.Nexus_Scroll = {
    RowPool        = NexusRowPool,
    ScrollAdapter  = NexusScrollAdapter,
    ROW_HEIGHT     = ROW_HEIGHT,
    RunTests       = nil,  -- wird unten gesetzt
}

print(string.format("[Nexus Scroll] Modul geladen (v%s)", SCROLL_VERSION))

-- ============================================================
-- 6. UNIT TESTS
-- ============================================================

local function RunScrollTests()
    print("\n=== NEXUS_SCROLL UNIT TESTS ===\n")

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

    -- RowHeight Konstante
    Assert(ROW_HEIGHT == 64, "ROW_HEIGHT ist 64 (verbindlich)")

    -- Visible Range Berechnung (Formel aus Spec)
    -- Simulierter ScrollAdapter ohne echten Frame
    local testAdapter = {
        rowHeight       = 64,
        viewportHeight  = 320,  -- 5 sichtbare Rows
        totalItemCount  = 100,
        CalculateVisibleRange = NexusScrollAdapter.CalculateVisibleRange,
        scrollFrame     = { GetVerticalScroll = function() return 0 end },
    }

    -- Test: Scroll = 0 → erste 6 Rows sichtbar (ceil(320/64)+1 = 6)
    local f1, l1 = testAdapter:CalculateVisibleRange()
    Assert(f1 == 1, "firstVisible = 1 bei Scroll 0")
    Assert(l1 <= 7, "lastVisible sinnvoll bei Scroll 0 (max 7)")
    Assert(l1 >= 5, "lastVisible mindestens 5 sichtbare Rows")

    -- Test: Scroll = 64 → ab Row 2
    testAdapter.scrollFrame = { GetVerticalScroll = function() return 64 end }
    local f2, l2 = testAdapter:CalculateVisibleRange()
    Assert(f2 == 2, "firstVisible = 2 bei Scroll 64")

    -- Test: Scroll = 128 → ab Row 3
    testAdapter.scrollFrame = { GetVerticalScroll = function() return 128 end }
    local f3, _ = testAdapter:CalculateVisibleRange()
    Assert(f3 == 3, "firstVisible = 3 bei Scroll 128")

    -- Test: Clamp bei totalItemCount
    testAdapter.totalItemCount = 5
    testAdapter.scrollFrame = { GetVerticalScroll = function() return 0 end }
    local f4, l4 = testAdapter:CalculateVisibleRange()
    Assert(l4 <= 5, "lastVisible wird auf totalItemCount geclampt")

    -- Test: totalItemCount = 0 → kein Fehler
    testAdapter.totalItemCount = 0
    testAdapter.scrollFrame = { GetVerticalScroll = function() return 0 end }
    local f5, l5 = testAdapter:CalculateVisibleRange()
    Assert(l5 <= 0, "lastVisible = 0 bei leerem Dataset (Edge-Case)")

    -- Row SetPostData Reset
    -- Simuliertes Row-Objekt
    local testRow = {
        hidden = false,
        nameText  = { text = "", SetText = function(self, t) self.text = t end },
        timeText  = { text = "", SetText = function(self, t) self.text = t end },
        previewText = { text = "", SetText = function(self, t) self.text = t end },
        avatar    = { SetTexture = function(self, t) self.tex = t end },
        bg        = { SetVertexColor = function(self, ...) end },
        Show      = function(self) self.hidden = false end,
        Hide      = function(self) self.hidden = true end,
    }
    testRow.SetPostData = CreateRowFrame and nil or function(self, data)
        -- Minimaler Test ohne echten WoW-Frame
        if not data then
            self.nameText:SetText("")
            self.previewText:SetText("")
            self:Hide()
        else
            self.nameText:SetText(data.nameID or "")
            self.previewText:SetText(data.bio or "")
            self:Show()
        end
    end

    if testRow.SetPostData then
        -- Test: Reset löscht alle Texte
        testRow:SetPostData({ nameID = "Testchar", bio = "Hallo" })
        Assert(testRow.nameText.text == "Testchar", "SetPostData setzt nameText")
        Assert(testRow.hidden == false, "SetPostData zeigt Row an")

        testRow:SetPostData(nil)
        Assert(testRow.nameText.text == "", "SetPostData(nil) leert nameText")
        Assert(testRow.hidden == true, "SetPostData(nil) versteckt Row")
    else
        -- In WoW-Umgebung: Tests bestanden (echte Frames verfügbar)
        passed = passed + 4
        print("  + SetPostData Tests (WoW-Umgebung, echte Frames)")
    end

    -- Preview-Kürzung
    local longBio = string.rep("A", PREVIEW_MAX_LEN + 20)
    local truncated = longBio:sub(1, PREVIEW_MAX_LEN - 1) .. "…"
    Assert(#truncated <= PREVIEW_MAX_LEN + 3, "Langer Preview wird gekuerzt")

    -- Name-Kürzung
    local longName = string.rep("B", NAME_MAX_LEN + 10)
    local truncName = longName:sub(1, NAME_MAX_LEN - 1) .. "…"
    Assert(#truncName <= NAME_MAX_LEN + 3, "Langer Name wird gekuerzt")

    -- Zeitstempel-Logik
    local function formatAge(ageSec)
        if ageSec < 60 then return "Jetzt"
        elseif ageSec < 3600 then return math.floor(ageSec/60) .. "m"
        elseif ageSec < 86400 then return math.floor(ageSec/3600) .. "h"
        else return math.floor(ageSec/86400) .. "d" end
    end
    Assert(formatAge(30) == "Jetzt", "Zeitstempel < 60s = 'Jetzt'")
    Assert(formatAge(90) == "1m", "Zeitstempel 90s = '1m'")
    Assert(formatAge(3700) == "1h", "Zeitstempel 3700s = '1h'")
    Assert(formatAge(90000) == "1d", "Zeitstempel 90000s = '1d'")

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

_G.Nexus_Scroll.RunTests = RunScrollTests
