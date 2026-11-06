--[[
	StandaloneMain: bagian khusus format standalone (client-only).
	Di-bundle oleh standalone/build.py bersama modul yang SUDAH ADA di src/ menjadi
	standalone/RuntimeInspector.client.lua. Edit file ini, lalu jalankan build ulang.

	Tanpa server: tidak ada data ServerStorage/ServerScriptService, tidak ada verifikasi
	replikasi (semua Instance berstatus CLIENT_UNVERIFIED), tidak ada divergence check.
]]

---------------------------------------------------------------- pengaturan
-- Delta Android: script berjalan pada sisi client. Data server yang tidak direplikasi
-- memang tidak dapat dibaca dari executor client.
local TOGGLE_KEY = Enum.KeyCode.F7

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then
	warn("[RuntimeInspector] LocalPlayer tidak tersedia; jalankan dari dalam game.")
	return
end

local Config = __require("Config")
local Theme = __require("Theme")
local Widgets = __require("Widgets")
local VirtualList = __require("VirtualList")
local TreeView = __require("TreeView")
local ListDetailView = __require("ListDetailView")
local ExportCenter = __require("ExportCenter")
local InstanceInfo = __require("InstanceInfo")
local Scheduler = __require("Scheduler")
local Findings = __require("Findings")
local Timeline = __require("Timeline")
local NetworkMonitor = __require("NetworkMonitor")
local Explorer = __require("DataModelExplorer")
local ScriptInspector = __require("ScriptInspector")
local AssetAuditor = __require("AssetAuditor")
local InstanceMonitor = __require("InstanceMonitor")
local CharacterProfiler = __require("CharacterProfiler")
local AnomalyDetector = __require("AnomalyDetector")
local New, C = Widgets.New, Theme.Colors
local MAX = Config.UI.DetailMaxChars

-- Gunakan UI host executor bila tersedia; fallback ke PlayerGui standar.
local guiParent = nil
local okGetHui, hui = pcall(function()
	if type(gethui) == "function" then
		return gethui()
	end
	return nil
end)
if okGetHui and hui then
	guiParent = hui
else
	guiParent = player:WaitForChild("PlayerGui")
end

-- Bersihkan GUI dari eksekusi sebelumnya agar tidak menumpuk.
pcall(function()
	local previous = guiParent:FindFirstChild("RuntimeInspectorDelta")
	if previous then previous:Destroy() end
end)

local gui = New("ScreenGui", {
	Name = "RuntimeInspectorDelta", ResetOnSpawn = false, IgnoreGuiInset = true,
	DisplayOrder = 9999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = guiParent,
}) :: ScreenGui

local function ignore(inst: Instance): boolean
	return inst == gui or inst:IsDescendantOf(gui) or inst.Name == "RuntimeInspectorGui" or inst:FindFirstAncestor("RuntimeInspectorGui") ~= nil
end

---------------------------------------------------------------- agent client (Start / Stop)

local agent = { player = player, Config = Config, TimelineLib = Timeline, FindingsLib = Findings, server = {}, running = false }

local function startAgent()
	if agent.running then
		return
	end
	agent.explorer = Explorer.new(Config, ignore)
	agent.timeline = Timeline.new(Config.Character.RingSize)
	agent.scripts = ScriptInspector.new(Config, agent.explorer, Config.LogPrefix)
	agent.assets = AssetAuditor.new(Config, agent.explorer, nil)
	agent.monitor = InstanceMonitor.new(Config, agent.explorer:ServiceRoots(), ignore, nil)
	agent.profiler = CharacterProfiler.new(Config, agent.timeline)
	agent.network = NetworkMonitor.new(Config, agent.explorer, agent.timeline)
	agent.findings = Findings.new(Config.Anomaly.Capacity, Config.Anomaly.DedupeWindow)
	agent.detector = AnomalyDetector.new(Config, agent.findings)
	agent.monitor.InstanceAdded:Connect(function(inst)
		agent.profiler:OnInstanceAdded(inst)
		agent.network:OnInstanceAdded(inst)
		agent.assets:OnInstanceAdded(inst)
	end)
	agent.detector:Bind({ monitor = agent.monitor, profiler = agent.profiler, network = agent.network, scripts = agent.scripts, assets = agent.assets })
	agent.scripts:StartErrorCapture()
	agent.explorer:Start()
	agent.monitor:Start()
	agent.profiler:Start()
	agent.network:Start()
	agent.running = true
end

-- Data terakhir tetap bisa dilihat/diekspor setelah Stop; Start membuat sesi baru.
local function stopAgent()
	if not agent.running then
		return
	end
	agent.running = false
	for _, key in { "detector", "monitor", "profiler", "network", "scripts", "explorer" } do
		pcall(agent[key].Destroy, agent[key])
	end
end

---------------------------------------------------------------- Game Scanner UI (single action)

local HttpService = game:GetService("HttpService")
-- Gunakan ScreenGui yang sudah dibuat di atas; tidak membuat GUI kedua.

local panel = New("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromScale(0.94, 0.78), BackgroundColor3 = C.Window,
    BorderSizePixel = 0, Parent = gui,
})
Widgets.Corner(12).Parent = panel
Widgets.Stroke().Parent = panel
New("UISizeConstraint", { MinSize = Vector2.new(280, 260), MaxSize = Vector2.new(900, 760), Parent = panel })

local title = Widgets.Label({ Text = "GAME SCANNER", Font = Theme.FontBold, TextSize = 20,
    Position = UDim2.new(0, 14, 0, 10), Size = UDim2.new(1, -28, 0, 30), Parent = panel })
local subtitle = Widgets.Label({ Text = "Scan data game yang tersedia dari sisi client", TextColor3 = C.TextDim,
    TextSize = Theme.SmallText, Position = UDim2.new(0, 14, 0, 40), Size = UDim2.new(1, -28, 0, 22), Parent = panel })
local scanButton = Widgets.Button("SCAN GAME", function() end, {
    Position = UDim2.new(0, 14, 0, 72), Size = UDim2.new(1, -28, 0, 46),
    BackgroundColor3 = C.Accent, TextColor3 = C.AccentText, TextSize = 17, Parent = panel,
})
local statusLabel = Widgets.Label({ Text = "Siap memindai", TextColor3 = C.TextDim,
    Position = UDim2.new(0, 14, 0, 124), Size = UDim2.new(1, -28, 0, 24), Parent = panel })
local resultBox = New("TextBox", {
    Position = UDim2.new(0, 14, 0, 152), Size = UDim2.new(1, -28, 1, -218),
    BackgroundColor3 = C.Sidebar, TextColor3 = C.Text, PlaceholderText = "Hasil scan akan muncul di sini...",
    Text = "", ClearTextOnFocus = false, MultiLine = true, TextWrapped = false,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    Font = Theme.Mono, TextSize = 12, Parent = panel,
})
Widgets.Corner(8).Parent = resultBox
local copyButton = Widgets.Button("COPY", function() end, {
    Position = UDim2.new(0, 14, 1, -54), Size = UDim2.new(0.5, -20, 0, 40),
    BackgroundColor3 = C.ChipOff, TextColor3 = C.Text, Parent = panel,
})
local saveButton = Widgets.Button("DOWNLOAD JSON", function() end, {
    Position = UDim2.new(0.5, 6, 1, -54), Size = UDim2.new(0.5, -20, 0, 40),
    BackgroundColor3 = C.Accent, TextColor3 = C.AccentText, Parent = panel,
})

local scanText = ""
local scanned = false
local busy = false

local function collectInstanceInventory()
    local inventory = {}
    local limit = math.min(tonumber(Config.Scan.MaxNodes) or 250000, 25000)
    local truncated = false
    local visited = 0
    local roots = agent.explorer:ServiceRoots()
    for _, root in roots do
        if visited >= limit then
            truncated = true
            break
        end
        statusLabel.Text = "Mengumpulkan objek: " .. root.ClassName .. " (" .. tostring(visited) .. ")"
        local count, hitLimit = Scheduler.Walk(root, function(inst)
            local okPath, fullName = pcall(inst.GetFullName, inst)
            local summary = InstanceInfo.Summary(inst)
            local record = {
                path = okPath and fullName or inst.Name,
                name = summary.name,
                class = summary.class,
                childCount = summary.childCount,
                enabled = summary.enabled,
                service = root.ClassName,
                attributes = InstanceInfo.Attributes(inst),
                tags = InstanceInfo.Tags(inst),
                properties = InstanceInfo.Properties(inst),
                visibility = InstanceInfo.StaticVisibility(inst),
            }
            table.insert(inventory, record)
            return true
        end, {
            budgetMs = Config.Scan.FrameBudgetMs,
            maxNodes = math.max(1, limit - visited),
            includeRoot = false,
            skip = ignore,
        })
        visited += count
        if hitLimit then
            truncated = true
            break
        end
    end
    return inventory, { count = #inventory, limit = limit, truncated = truncated }
end

local function makeReport()
    local categories = {}
    for _, category in ExportCenter.Categories do categories[category] = true end
    local report = ExportCenter.Collect(agent, categories, "client")
    report.note = "Pemindaian client-only. Data server, ServerStorage, ServerScriptService, dan Script.Source yang dilindungi tidak dapat dibaca dari client. Batas MaxNodes dapat membuat scan terpotong."
    local inventory, inventoryStats = collectInstanceInventory()
    report.instances = inventory
    report.scan = {
        baselineComplete = agent.explorer.baselineDone == true,
        baselineTruncated = agent.explorer.baselineTruncated == true,
        instanceCount = agent.explorer:Stats().total or 0,
        exportedInstanceCount = inventoryStats.count,
        inventoryLimit = inventoryStats.limit,
        inventoryTruncated = inventoryStats.truncated,
        accessibleServices = {},
    }
    for _, service in agent.explorer:ServiceRoots() do
        table.insert(report.scan.accessibleServices, service.Name)
    end
    return HttpService:JSONEncode(ExportCenter.Sanitize(report))
end

local function doScan()
    if busy then return end
    busy = true
    scanned = false
    scanButton.Text = "SCANNING..."
    statusLabel.Text = "Memulai pemindaian instance..."
    resultBox.Text = ""
    task.spawn(function()
        local ok, err = pcall(function()
            if not agent.running then startAgent() end
            local deadline = os.clock() + 90
            while not agent.explorer.baselineDone and os.clock() < deadline do
                statusLabel.Text = "Memindai hierarki game... " .. tostring(agent.explorer:Stats().total or 0) .. " instance"
                task.wait(0.2)
            end
            statusLabel.Text = "Memindai asset dan metadata script..."
            agent.assets:Scan()
            agent.scripts:Collect()
            statusLabel.Text = "Menyusun laporan..."
            scanText = makeReport()
            local previewLimit = 8000
            resultBox.Text = string.sub(scanText, 1, previewLimit)
            if #scanText > previewLimit then
                resultBox.Text ..= "\n\n... PREVIEW DIPOTONG. Gunakan COPY atau DOWNLOAD JSON untuk seluruh laporan."
            end
            scanned = true
            local stats = agent.explorer:Stats()
            statusLabel.Text = string.format("Selesai: %s instance | %d karakter JSON%s", tostring(stats.total or 0), #scanText,
                agent.explorer.baselineTruncated and " | scan mencapai batas" or "")
        end)
        if not ok then
            statusLabel.Text = "Scan gagal: " .. string.sub(tostring(err), 1, 150)
            resultBox.Text = tostring(err)
        end
        busy = false
        scanButton.Text = "SCAN ULANG"
    end)
end

scanButton.MouseButton1Click:Connect(doScan)
copyButton.MouseButton1Click:Connect(function()
    if not scanned then statusLabel.Text = "Jalankan Scan terlebih dahulu"; return end
    local copied = false
    local env = nil
    if type(getgenv) == "function" then
        local okEnv, value = pcall(getgenv)
        if okEnv then env = value end
    end
    local clipboard = (type(env) == "table" and env.setclipboard) or (type(syn) == "table" and syn.write_clipboard) or setclipboard
    if type(clipboard) == "function" then
        local ok = pcall(clipboard, scanText)
        copied = ok
    end
    if copied then
        statusLabel.Text = "JSON berhasil disalin ke clipboard"
    else
        resultBox:CaptureFocus()
        resultBox.SelectionStart = 1
        resultBox.CursorPosition = #resultBox.Text + 1
        statusLabel.Text = "Clipboard tidak tersedia: pilih teks di kotak lalu Copy"
    end
end)
saveButton.MouseButton1Click:Connect(function()
    if not scanned then statusLabel.Text = "Jalankan Scan terlebih dahulu"; return end
    local filename = "GameScan_" .. tostring(game.PlaceId) .. ".json"
    local env = nil
    if type(getgenv) == "function" then
        local okEnv, value = pcall(getgenv)
        if okEnv then env = value end
    end
    local writer = (type(env) == "table" and env.writefile) or writefile
    if type(writer) == "function" then
        local ok, err = pcall(writer, filename, scanText)
        statusLabel.Text = ok and ("Tersimpan: " .. filename) or ("Gagal menyimpan: " .. tostring(err))
    else
        resultBox:CaptureFocus()
        resultBox.SelectionStart = 1
        resultBox.CursorPosition = #resultBox.Text + 1
        statusLabel.Text = "writefile tidak tersedia. Salin JSON dari kotak hasil."
    end
end)

print("[GameScanner] Siap. Tekan SCAN GAME untuk memindai data client yang dapat diakses.")
