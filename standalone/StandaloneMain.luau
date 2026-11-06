--[[
	StandaloneMain: bagian khusus format standalone (client-only).
	Di-bundle oleh standalone/build.py bersama modul yang SUDAH ADA di src/ menjadi
	standalone/RuntimeInspector.client.lua. Edit file ini, lalu jalankan build ulang.

	Tanpa server: tidak ada data ServerStorage/ServerScriptService, tidak ada verifikasi
	replikasi (semua Instance berstatus CLIENT_UNVERIFIED), tidak ada divergence check.
]]

---------------------------------------------------------------- pengaturan
local TOGGLE_KEY = Enum.KeyCode.F7
local ALLOW_IN_LIVE_GAME = false -- true hanya bila Anda paham kode ini ikut terkirim ke client
local ALLOWED_USER_IDS = {} -- [UserId] = true, dipakai bila ALLOW_IN_LIVE_GAME = true

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not RunService:IsStudio() and not (ALLOW_IN_LIVE_GAME and ALLOWED_USER_IDS[player.UserId]) then
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

local gui = New("ScreenGui", {
	Name = "RuntimeInspectorStandalone", ResetOnSpawn = false, IgnoreGuiInset = true,
	DisplayOrder = 999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
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
	task.spawn(function()
		agent.assets:Scan()
		agent.scripts:Collect()
	end)
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

---------------------------------------------------------------- jendela

local window = New("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.8, 0.78),
	BackgroundColor3 = C.Window, Active = true, Parent = gui,
}, { Widgets.Corner(10), Widgets.Stroke(), New("UISizeConstraint", { MinSize = Vector2.new(680, 400), MaxSize = Vector2.new(1400, 860) }) })
local header = New("Frame", { BackgroundColor3 = C.Sidebar, Size = UDim2.new(1, 0, 0, 36), Active = true, Parent = window }, { Widgets.Corner(10), Widgets.Padding(6), Widgets.HList(6) })
Widgets.Label({ Text = "Runtime Inspector (Standalone Client)", Font = Theme.FontBold, Size = UDim2.new(0, 230, 1, 0), LayoutOrder = 0, Parent = header })
local tabBar = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 8, 0, 42), Size = UDim2.new(1, -16, 0, 26), Parent = window }, { Widgets.HList(4) })
local content = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 8, 0, 74), Size = UDim2.new(1, -16, 1, -82), ClipsDescendants = true, Parent = window })
local status = Widgets.Label({ Text = "", TextColor3 = C.TextDim, TextSize = Theme.SmallText, Size = UDim2.new(0, 200, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 20, Parent = header })

do -- drag
	local dragging, start, startPos = false, nil, nil
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, start, startPos = true, input.Position, window.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - start
			window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

local launcher = Widgets.Button("Inspector (" .. TOGGLE_KEY.Name .. ")", function()
	window.Visible = true
end, { Position = UDim2.new(0, 12, 1, -40), Size = UDim2.new(0, 150, 0, 28), BackgroundColor3 = C.Accent, TextColor3 = C.AccentText, Visible = false, Parent = gui })
window:GetPropertyChangedSignal("Visible"):Connect(function()
	launcher.Visible = not window.Visible
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == TOGGLE_KEY then
		window.Visible = not window.Visible
	end
end)

---------------------------------------------------------------- tab berbasis ListDetailView

local function newest(list: { any }, keep: ((any) -> boolean)?): { any }
	local out = {}
	for i = #list, 1, -1 do
		if not keep or keep(list[i]) then
			table.insert(out, list[i])
		end
	end
	return out
end

local function chips(id: string, options: { { string } }): { [string]: any }
	local o = {}
	for _, pair in options do
		table.insert(o, { id = pair[1], label = pair[2] })
	end
	return { id = id, options = o }
end

local function lines(pairsList: { { any } }): string
	local out = {}
	for _, p in pairsList do
		table.insert(out, string.format("%-13s: %s", p[1], tostring(p[2])))
	end
	return table.concat(out, "\n")
end

local SPECS = {}

SPECS.Assets = {
	groups = { chips("cat", { { "all", "Semua" }, { "AnimationId", "Animation" }, { "SoundId", "Sound" }, { "MeshId", "Mesh" }, { "TextureId", "Texture" }, { "Image", "Image" }, { "Decal", "Decal" }, { "ParticleTexture", "Particle" }, { "unknown", "Runtime?" }, { "unreadable", "Unreadable" } }) },
	getItems = function(state)
		local r = agent.assets:Report()
		state._r = r
		if state.cat == "unreadable" then
			return r.unreadable
		end
		local out = {}
		for _, a in r.assets do
			if state.cat == "all" or (state.cat == "unknown" and a.unknownRuntime) or table.find(a.categories, state.cat) then
				table.insert(out, a)
			end
		end
		return out
	end,
	rowText = function(a, state)
		if state.cat == "unreadable" then
			return a.class .. " " .. a.path .. "." .. a.property
		end
		return string.format("[%-6s] %-14s x%-4d %-22s %s", a.level, a.key, a.count, table.concat(a.categories, "|"), tostring(a.locations[1]))
	end,
	rowColor = function(a, state)
		return state.cat ~= "unreadable" and Theme.Severity[a.level] or nil
	end,
	detail = function(a, state)
		if state.cat == "unreadable" then
			return a.path .. "\n" .. a.property .. "\n\n" .. tostring(a.error)
		end
		return lines({ { "Asset", a.key }, { "Jenis", a.kind }, { "Kategori", table.concat(a.categories, ", ") }, { "Properti", table.concat(a.properties, ", ") },
			{ "Service", table.concat(a.services, ", ") }, { "Kemunculan", a.count }, { "Penilaian", a.level }, { "Alasan", a.reason } }) .. "\n\n[Lokasi]\n" .. table.concat(a.locations, "\n")
	end,
	header = function(state, items)
		local r = state._r
		return r and string.format("%d tampil | unik %d, referensi %d | penilaian berbasis konteks client", #items, r.uniqueAssets, r.references) or ""
	end,
}

SPECS.Scripts = {
	groups = { chips("class", { { "all", "Semua" }, { "LocalScript", "LocalScript" }, { "Script", "Script" }, { "ModuleScript", "Module" }, { "errors", "Error" } }) },
	getItems = function(state)
		if state.class == "errors" then
			return newest(agent.scripts:Errors())
		end
		local out = {}
		for _, r in agent.scripts.records do
			if state.class == "all" or r.class == state.class then
				table.insert(out, r)
			end
		end
		return out
	end,
	rowText = function(r, state)
		if state.class == "errors" then
			return string.format("%.2f [%s] %s :: %s", r.t, r.kind, tostring(r.script), r.message)
		end
		return string.format("%-12s %-5s %s", r.class, r.enabled == nil and "-" or (r.enabled and "ON" or "OFF"), r.fullName)
	end,
	rowColor = function(r, state)
		return state.class == "errors" and Theme.Severity.CRITICAL or (r.exposure and r.class == "ModuleScript" and Theme.Severity.MEDIUM or nil)
	end,
	detail = function(r, state)
		if state.class == "errors" then
			return r.message .. "\n\nStack:\n" .. tostring(r.stack or "(tidak ada)")
		end
		return lines({ { "Name", r.name }, { "ClassName", r.class }, { "FullName", r.fullName }, { "Enabled", r.enabled }, { "RunContext", r.runContext }, { "Berjalan", r.runHint },
			{ "Keamanan", r.exposure or "-" }, { "Source", "tidak dibaca (ProtectedString; hanya plugin/Command Bar)" } })
	end,
	header = function(state, items)
		local c = agent.scripts:Counts()
		return string.format("%d tampil | LocalScript %d, Script %d, Module %d | error %d", #items, c.LocalScript or 0, c.Script or 0, c.ModuleScript or 0, agent.scripts.errorCount)
	end,
}

SPECS.Runtime = {
	groups = { chips("kind", { { "all", "Semua" }, { "added", "Baru" }, { "removed", "Dihapus" }, { "property", "Properti" }, { "attribute", "Atribut" } }) },
	getItems = function(state)
		return newest(agent.monitor:Entries(), function(e)
			return state.kind == "all" or e.kind == state.kind
		end)
	end,
	rowText = function(e)
		return string.format("%9.3f %-9s %-16s %s%s", e.t, e.kind, e.class, e.path, e.prop and string.format(" %s: %s -> %s", e.prop, e.old, e.new) or "")
	end,
	detail = function(e)
		return lines({ { "os.clock", e.t }, { "Jenis", e.kind }, { "ClassName", e.class }, { "FullName", e.path }, { "Parent", e.parent }, { "Properti", e.prop or "-" },
			{ "Sebelum", e.old or "-" }, { "Sesudah", e.new or "-" }, { "Sumber", e.source } })
	end,
	header = function(_, items)
		local s = agent.monitor:Stats()
		return string.format("%d entri | +%d -%d prop %d attr %d | watched %d dropped %d", #items, s.added, s.removed, s.property, s.attribute, s.watched, s.dropped)
	end,
}

SPECS.Actions = {
	groups = { chips("cat", { { "chains", "Rantai" }, { "all", "Semua" }, { "Jump", "Jump" }, { "Movement", "Movement" }, { "Attack", "Attack" }, { "Tool", "Tool" }, { "Animation", "Animation" }, { "Input", "Input" }, { "Hitbox", "Hitbox" } }) },
	getItems = function(state)
		if state.cat == "chains" then
			return agent.timeline:Correlate(Config.Character.Correlation)
		end
		return newest(agent.timeline:ToArray(), function(e)
			return state.cat == "all" or e.cat == state.cat
		end)
	end,
	rowText = function(e, state)
		if state.cat == "chains" then
			return string.format("%9.3f %-20s %s (+%d)", e.anchor.t, e.anchor.kind, e.anchor.summary, #e.events)
		end
		return string.format("%9.3f %-10s %-26s %s", e.t, e.cat, e.kind, e.summary)
	end,
	detail = function(e, state)
		if state.cat == "chains" then
			return Timeline.FormatChain(e) .. "\n\nKorelasi waktu, bukan bukti kausal."
		end
		return lines({ { "os.clock", e.t }, { "serverTime", e.st }, { "Kategori", e.cat }, { "Jenis", e.kind }, { "Ringkasan", e.summary } })
	end,
}

SPECS.Remotes = {
	groups = { chips("dir", { { "all", "Semua" }, { "in", "Server->Client" }, { "out", "Client->Server" }, { "local", "Bindable" }, { "issues", "Bermasalah" }, { "remotes", "Daftar" } }) },
	getItems = function(state)
		if state.dir == "remotes" then
			return agent.network:Remotes()
		end
		local want = { ["in"] = "Server->Client", out = "Client->Server", ["local"] = "Local" }
		return newest(agent.network:Entries(), function(e)
			return state.dir == "all" or e.direction == want[state.dir] or (state.dir == "issues" and #e.issues > 0)
		end)
	end,
	rowText = function(e, state)
		if state.dir == "remotes" then
			return string.format("%-21s n=%-5d %5.1f/s %s %s", e.class, e.count, e.rate, e.passive and "[pasif]" or "[wrapper]", e.path)
		end
		return string.format("%9.3f %-15s %-8s argc=%d %s", e.t, e.direction, e.via, e.argc, e.path)
	end,
	rowColor = function(e, state)
		return state.dir ~= "remotes" and #e.issues > 0 and Theme.Severity.MEDIUM or nil
	end,
	detail = function(e, state)
		if state.dir == "remotes" then
			return lines({ { "Remote", e.path }, { "Class", e.class }, { "Panggilan", e.count }, { "Rate", e.rate }, { "Peak", e.peakRate }, { "Catatan", e.note or "-" } })
		end
		return NetworkMonitor.FormatEntry(e)
	end,
	header = function(_, items)
		return #items .. " | Client->Server hanya terlihat bila game memakai ReplicatedStorage.RuntimeInspectorNet.Net"
	end,
}

SPECS.Security = {
	groups = { chips("min", { { "INFO", "Semua" }, { "LOW", "LOW+" }, { "MEDIUM", "MEDIUM+" }, { "HIGH", "HIGH+" }, { "CRITICAL", "CRITICAL" } }) },
	getItems = function(state)
		return agent.findings:List(state.min)
	end,
	rowText = function(f)
		return string.format("[%-8s] x%-4d %-32s %s", f.severity, f.count, f.rule, f.path)
	end,
	rowColor = function(f)
		return Theme.Severity[f.severity]
	end,
	detail = function(f)
		return lines({ { "Severity", f.severity }, { "Rule", f.rule }, { "Objek", f.object }, { "Path", f.path }, { "Jumlah", f.count }, { "Waktu UTC", f.clock } })
			.. "\n\nDetail:\n  " .. f.detail .. "\n\nAlasan:\n  " .. f.reason .. "\n\nRekomendasi:\n  " .. f.recommendation
			.. "\n\nCatatan: temuan client adalah indikator untuk uji Studio, bukan bukti otoritatif."
	end,
	header = function(_, items)
		local c = agent.findings:Counts()
		return string.format("risk %d | C%d H%d M%d L%d | standalone: tanpa validasi server", agent.findings:RiskScore(), c.CRITICAL, c.HIGH, c.MEDIUM, c.LOW)
	end,
}

---------------------------------------------------------------- Explorer (TreeView + search)

local function buildExplorer(frame: Frame)
	local toolbar = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), Parent = frame }, { Widgets.HList(6) })
	local left = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 32), Size = UDim2.new(0.55, -4, 1, -32), Parent = frame })
	local right = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0.55, 4, 0, 32), Size = UDim2.new(0.45, -4, 1, -32), Parent = frame })
	local _, setDetail = Widgets.DetailPane(right, MAX)
	setDetail("Klik node. Standalone tidak punya server, jadi visibilitas selalu CLIENT_UNVERIFIED dan ServerStorage/ServerScriptService tidak terlihat (memang tidak direplikasi).")
	local function node(inst: Instance, label: string?)
		local s = InstanceInfo.Summary(inst)
		return { key = inst, label = label, name = s.name, class = s.class, childCount = s.childCount, runtime = agent.explorer.runtime[inst] == true }
	end
	local function details(n)
		if typeof(n.key) == "Instance" then
			setDetail(InstanceInfo.FormatDetails(agent.explorer:Details(n.key)))
		end
	end
	local tree = TreeView.new(left, {
		Roots = function()
			local out = {}
			for _, p in agent.explorer:Roots() do
				table.insert(out, node(p[1], p[2]))
			end
			return out
		end,
		Children = function(_, key, offset, limit)
			local page, total = agent.explorer:Children(key, offset, limit)
			local out = {}
			for _, inst in page do
				table.insert(out, node(inst))
			end
			return out, total
		end,
	}, details)
	local results = VirtualList.new(left, {
		render = function(row, item)
			row.Text = "[" .. item.class .. "] " .. item.path
		end,
		onSelect = details,
	})
	results.frame.Visible = false
	local nameBox = Widgets.TextInput("Nama", { Size = UDim2.new(0, 150, 0, 24), LayoutOrder = 1, Parent = toolbar })
	local classBox = Widgets.TextInput("ClassName / IsA", { Size = UDim2.new(0, 130, 0, 24), LayoutOrder = 2, Parent = toolbar })
	local function btn(text: string, order: number, fn: () -> ())
		Widgets.Button(text, fn, { Size = UDim2.new(0, 64, 0, 24), TextSize = Theme.SmallText, LayoutOrder = order, Parent = toolbar })
	end
	btn("Cari", 3, function()
		results.frame.Visible, tree.list.frame.Visible = true, false
		results:SetItems({ { class = "...", path = "mencari..." } })
		task.spawn(function()
			local items = {}
			for _, inst in agent.explorer:Search(nameBox.Text, classBox.Text, Config.Scan.SearchLimit) do
				table.insert(items, { key = inst, class = inst.ClassName, path = inst:GetFullName() })
			end
			results:SetItems(items)
		end)
	end)
	btn("Tree", 4, function()
		results.frame.Visible, tree.list.frame.Visible = false, true
	end)
	btn("Reload", 5, function()
		tree:Load()
	end)
	tree:Load()
	return { Refresh = function() end, Reload = function()
		tree:Load()
	end }
end

---------------------------------------------------------------- Export

local exportState = { format = "json", pages = { "" }, page = 1, text = "" }
local exportOutput, exportStatus

local function showExport(text: string, label: string)
	exportState.text = text
	exportState.pages = ExportCenter.Paginate(text, Config.UI.ExportPageChars)
	exportState.page = 1
	exportOutput.Text = exportState.pages[1]
	exportStatus.Text = string.format("%s | halaman 1/%d | %d karakter", label, #exportState.pages, #text)
end

local function render(categories: { [string]: boolean }): string
	local report = ExportCenter.Collect(agent, categories, "client")
	report.note = "Standalone client: tanpa data server. Temuan adalah indikator client."
	if exportState.format == "csv" then
		return ExportCenter.ToCSV(report)
	elseif exportState.format == "txt" then
		return ExportCenter.ToTXT(report)
	end
	return ExportCenter.ToJSON(report)
end

local function buildExport(frame: Frame)
	local row = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), Parent = frame }, { Widgets.HList(6) })
	local setters = {}
	for i, f in { { "json", "JSON" }, { "txt", "TXT" }, { "csv", "CSV" } } do
		local chip, setOn = Widgets.Chip(f[2], f[1] == exportState.format, function()
			exportState.format = f[1]
			for id, s in setters do
				s(id == f[1])
			end
		end)
		chip.LayoutOrder = i
		chip.Parent = row
		setters[f[1]] = setOn
	end
	local function page(delta: number)
		exportState.page = math.clamp(exportState.page + delta, 1, #exportState.pages)
		exportOutput.Text = exportState.pages[exportState.page]
		exportStatus.Text = string.format("halaman %d/%d", exportState.page, #exportState.pages)
	end
	for i, b in { { "< Prev", function() page(-1) end }, { "Next >", function() page(1) end }, { "Print ke Output", function()
		task.spawn(ExportCenter.PrintToOutput, exportState.text, Config.LogPrefix)
	end } } do
		Widgets.Button(b[1], b[2], { Size = UDim2.new(0, 100, 0, 24), TextSize = Theme.SmallText, LayoutOrder = 10 + i, Parent = row })
	end
	exportStatus = Widgets.Label({ Text = "Tombol Export = laporan lengkap; Copy = data tab aktif.", TextColor3 = C.TextDim, TextSize = Theme.SmallText, Position = UDim2.new(0, 0, 0, 30), Size = UDim2.new(1, 0, 0, 18), Parent = frame })
	exportOutput = Widgets.TextInput("", { Position = UDim2.new(0, 0, 0, 52), Size = UDim2.new(1, 0, 1, -52), MultiLine = true, TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top, Font = Theme.Mono, TextSize = Theme.SmallText, Parent = frame })
	return { Refresh = function() end }
end

---------------------------------------------------------------- tab & tombol utama

local TAB_ORDER = { "Explorer", "Assets", "Scripts", "Runtime", "Actions", "Remotes", "Security", "Export" }
local COPY_CATEGORY = { Explorer = "overview", Assets = "assets", Scripts = "scripts", Runtime = "runtime", Actions = "actions", Remotes = "network", Security = "findings", Export = "findings" }
local tabs, tabButtons, active = {}, {}, nil

local function selectTab(name: string)
	active = name
	for n, t in tabs do
		t.frame.Visible = n == name
	end
	for n, b in tabButtons do
		b.BackgroundColor3 = n == name and C.RowSelected or C.ChipOff
	end
	if not tabs[name] then
		local frame = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = content })
		local api
		if name == "Explorer" then
			api = buildExplorer(frame)
		elseif name == "Export" then
			api = buildExport(frame)
		else
			local view = ListDetailView.new(frame, SPECS[name], MAX)
			api = { Refresh = function()
				view:Refresh()
			end }
		end
		tabs[name] = { frame = frame, api = api }
	end
	if agent.running or agent.explorer then
		pcall(tabs[name].api.Refresh)
	end
end

for i, name in TAB_ORDER do
	tabButtons[name] = Widgets.Button(name, function()
		selectTab(name)
	end, { Size = UDim2.new(0, 92, 0, 24), TextSize = Theme.SmallText, LayoutOrder = i, Parent = tabBar })
end

local function copyText(text: string, label: string)
	selectTab("Export")
	showExport(text, label)
	exportOutput:CaptureFocus()
	exportOutput.SelectionStart = 1
	exportOutput.CursorPosition = #exportOutput.Text + 1
	exportStatus.Text ..= " | teks terpilih: tekan Ctrl+C (tidak ada API clipboard resmi untuk game script)"
end

local function headerButton(text: string, order: number, fn: () -> ())
	Widgets.Button(text, function()
		if text ~= "Start" and not agent.explorer then
			status.Text = "Belum ada sesi. Tekan Start."
			return
		end
		fn()
	end, { Size = UDim2.new(0, 64, 0, 24), TextSize = Theme.SmallText, LayoutOrder = order, Parent = header })
end
headerButton("Start", 1, function()
	startAgent()
	if tabs.Explorer then
		tabs.Explorer.api.Reload()
	end
end)
headerButton("Stop", 2, stopAgent)
headerButton("Refresh", 3, function()
	if agent.running then
		task.spawn(function()
			agent.assets:Scan()
			agent.scripts:Collect()
		end)
	end
	if tabs.Explorer and active == "Explorer" then
		tabs.Explorer.api.Reload()
	end
end)
headerButton("Copy", 4, function()
	local cat = COPY_CATEGORY[active or "Security"]
	local saved = exportState.format
	exportState.format = "txt"
	copyText(render({ [cat] = true }), "Copy: " .. tostring(active))
	exportState.format = saved
end)
headerButton("Export", 5, function()
	local all = {}
	for _, c in ExportCenter.Categories do
		all[c] = true
	end
	copyText(render(all), "Export lengkap (" .. exportState.format .. ")")
end)

startAgent()
selectTab("Explorer")

task.spawn(function()
	while gui.Parent do
		task.wait(1 / Config.UI.RefreshHz)
		if window.Visible and active and tabs[active] and active ~= "Export" and active ~= "Explorer" then
			local ok, err = pcall(tabs[active].api.Refresh)
			if not ok then
				status.Text = "refresh error: " .. string.sub(tostring(err), 1, 80)
			end
		end
		status.Text = string.format("%s | %s | net %d | risk %d", agent.running and "RUNNING" or "STOPPED",
			RunService:IsStudio() and "Studio" or "Live", agent.network and agent.network.ring.count or 0, agent.findings and agent.findings:RiskScore() or 0)
	end
end)

print(Config.LogPrefix .. " standalone client aktif. Tekan " .. TOGGLE_KEY.Name .. " untuk menampilkan/menyembunyikan.")
