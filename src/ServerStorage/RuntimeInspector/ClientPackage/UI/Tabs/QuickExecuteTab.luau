--[[
	Tab 10: Quick Execute
	Kartu modul diagnostik yang SUDAH ADA (RUN / STOP / VIEW LOG), live console, dan
	Script Panel berisi snippet Luau siap salin. Semua aksi memanggil modul/aksi bridge
	yang sudah ada lewat ExecutionManager; tidak ada eksekusi kode bebas.
]]

local ExecutionManager = require(script.Parent.Parent.Parent.ExecutionManager)

local SNIPPETS = {
	{
		id = "analyzer", label = "Source Analyzer",
		info = "Tempel di Command Bar Studio (mode Edit). Menulis ServerStorage.RuntimeInspectorManifest.",
		code = [==[require(game.ServerStorage.RuntimeInspector.Tools.SourceAnalyzer).Run()]==],
	},
	{
		id = "client", label = "Client: kirim aman",
		info = "LocalScript (StarterPlayerScripts / Tool). Tercatat di Network Monitor; pasangkan dengan SecureRemote replay=true.",
		code = [==[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("RuntimeInspectorNet"):WaitForChild("Net"))
local remote = ReplicatedStorage:WaitForChild("GameRemotes"):WaitForChild("CombatRequest")

Net.FireServerSecure(remote, "Attack", workspace.CurrentCamera.CFrame.LookVector)]==],
	},
	{
		id = "server", label = "Server: SecureRemote",
		info = "Script di ServerScriptService. Validasi skema, rate limit, anti-replay, xpcall handler.",
		code = [==[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local API = require(game:GetService("ServerScriptService").RuntimeInspectorServer.API).WaitReady()
local S = require(ReplicatedStorage.RuntimeInspectorNet.Schema)

local remote = Instance.new("RemoteEvent")
remote.Name = "MyAction"
remote.Parent = ReplicatedStorage:WaitForChild("GameRemotes")

API.SecureRemote:Bind(remote, {
	schema = S.Tuple({ S.OneOf({ "Use" }), S.Number({ min = 1, max = 10, integer = true }) }),
	rate = { perSecond = 4, burst = 6 },
	replay = true,
	handler = function(player, action, slot)
		print(player.Name, action, slot)
	end,
})]==],
	},
	{
		id = "teleport", label = "Server: teleport & damage",
		info = "Izinkan teleport sah sebelum memindahkan karakter; semua damage lewat ValidateDamage.",
		code = [==[local API = require(game:GetService("ServerScriptService").RuntimeInspectorServer.API).WaitReady()

local function teleport(player: Player, cf: CFrame)
	API.MovementValidator:AllowTeleport(player, 2)
	if player.Character then
		player.Character:PivotTo(cf)
	end
end

local function damage(attacker: Player, target: Humanoid, amount: number)
	local ok, final = API.CombatAuthority:ValidateDamage(attacker, target, amount, "ExampleSword")
	if ok then
		target:TakeDamage(final)
	end
end]==],
	},
	{
		id = "admin", label = "Config admin live",
		info = "Edit ServerStorage.RuntimeInspector.ServerData.ServerConfig (server-only).",
		code = [==[EnableInLiveGame = true,
AllowAllInStudio = true,
AdminUserIds = {
	[123456789] = true, -- ganti dengan UserId Anda
},]==],
	},
}

local function defineModules(em: any, agent: any)
	local A = agent.Protocol.Actions
	local Config = agent.Config
	local function call(action: string, payload: any?)
		local r, err = agent.link:Call(action, payload)
		if r == nil or err then
			error(err or "tidak ada jawaban server", 0)
		end
		return r
	end

	-- Client: tugas sekali jalan
	em:Register({ id = "asset_scan", name = "Asset Scan", env = "client", category = "client", desc = "AssetAuditor:Scan() ulang di client",
		run = function(ctx)
			agent.assets:Scan()
			local r = agent.assets:Report()
			ctx.log(string.format("aset unik %d, referensi %d, unreadable %d", r.uniqueAssets, r.references, #r.unreadable))
		end })
	em:Register({ id = "script_collect", name = "Script Collect", env = "client", category = "client", desc = "ScriptInspector:Collect() ulang",
		run = function(ctx)
			agent.scripts:Collect()
			local c = agent.scripts:Counts()
			ctx.log(string.format("Script %d, LocalScript %d, ModuleScript %d, error %d", c.Script or 0, c.LocalScript or 0, c.ModuleScript or 0, agent.scripts.errorCount))
		end })
	em:Register({ id = "verify_workspace", name = "Verify Replication", env = "client", category = "client", desc = "Antrekan anak Workspace ke verifikasi CLIENT_LOCAL / CLIENT_REPLICATED",
		run = function(ctx)
			local n = 0
			for _, inst in workspace:GetChildren() do
				if not agent.ignore(inst) then
					agent:QueueVerify(inst)
					n += 1
				end
			end
			ctx.log(n .. " Instance diantrekan; lihat warna node di DataModel Explorer")
		end })
	em:Register({ id = "correlate", name = "Correlate Actions", env = "client", category = "client", desc = "Timeline:Correlate() rantai input/lompat/serang",
		run = function(ctx)
			local chains = agent.timeline:Correlate(Config.Character.Correlation)
			ctx.log(#chains .. " rantai")
			if chains[1] then
				ctx.log(agent.TimelineLib.FormatChain(chains[1]))
			end
		end })
	em:Register({ id = "explorer_stats", name = "Explorer Stats", env = "client", category = "client", desc = "Explorer:Stats() jumlah Instance per service",
		run = function(ctx)
			local s = agent.explorer:Stats()
			ctx.log(string.format("total %d, baseline %s (%.2fs)%s", s.total, tostring(s.baselineDone), s.baselineDuration, s.baselineTruncated and " TRUNCATED" or ""))
		end })
	em:Register({ id = "findings_summary", name = "Findings Summary", env = "client+server", category = "client", desc = "Ringkasan temuan & risk score",
		run = function(ctx)
			local c, s = agent.findings:Counts(), agent.serverFindings:Counts()
			ctx.log(string.format("client total %d risk %d | server total %d risk %d (C%d H%d)", c.total, agent.findings:RiskScore(), s.total, agent.serverFindings:RiskScore(), s.CRITICAL, s.HIGH))
		end })

	-- Modul kontinu: RUN = snapshot status; STOP = NOT IMPLEMENTED (tidak ada API pause)
	em:Register({ id = "instance_monitor", name = "Instance Monitor", env = "client", category = "continuous", continuous = true, desc = "InstanceMonitor:Stats()",
		run = function(ctx)
			local s = agent.monitor:Stats()
			ctx.log(string.format("+%d -%d prop %d attr %d watched %d dropped %d", s.added, s.removed, s.property, s.attribute, s.watched, s.dropped))
		end })
	em:Register({ id = "character_profiler", name = "Character Profiler", env = "client", category = "continuous", continuous = true, desc = "CharacterProfiler:Snapshot(LocalPlayer)",
		run = function(ctx)
			local snap = agent.profiler:Snapshot(agent.player)
			if not snap then
				error("karakter/Humanoid belum ada", 0)
			end
			ctx.log(string.format("WalkSpeed %.1f JumpPower %.1f JumpHeight %.1f State %s", snap.WalkSpeed, snap.JumpPower, snap.JumpHeight, snap.State))
		end })
	em:Register({ id = "network_monitor", name = "Network Monitor", env = "client", category = "continuous", continuous = true, desc = "NetworkMonitor:Remotes() 3 teratas",
		run = function(ctx)
			local list = agent.network:Remotes()
			ctx.log(#list .. " remote, " .. agent.network.ring.count .. " entri log")
			for i = 1, math.min(3, #list) do
				ctx.log(string.format("  %s n=%d %.1f/s", list[i].path, list[i].count, list[i].rate))
			end
		end })

	-- Server lewat InspectorBridge (aksi yang sudah ada)
	em:Register({ id = "server_overview", name = "Server Overview", env = "server", category = "server", desc = "Aksi bridge overview",
		run = function(ctx)
			local r = call(A.Overview)
			agent.server.overview = r
			ctx.log(string.format("Instance %s, remote %s, risk %s, heartbeat %s ms", tostring(r.explorer and r.explorer.total), tostring(r.remotes), tostring(r.riskScore), tostring(r.heartbeatMs)))
		end })
	em:Register({ id = "server_scripts", name = "Server Script Rescan", env = "server", category = "server", desc = "scripts.list refresh=true",
		run = function(ctx)
			local r = call(A.ScriptsList, { refresh = true, offset = 0, limit = 1 })
			agent.server.scripts = nil -- tab Script Inspector memuat ulang
			ctx.log("total script server " .. tostring(r.total))
		end })
	em:Register({ id = "server_assets", name = "Server Asset Report", env = "server", category = "server", desc = "assets.report",
		run = function(ctx)
			local r = call(A.AssetsReport, { offset = 0, limit = 1 })
			agent.server.assets = nil
			ctx.log(string.format("aset unik %s, referensi %s", tostring(r.uniqueAssets), tostring(r.references)))
		end })
	em:Register({ id = "server_findings", name = "Server Findings Sync", env = "server", category = "server", desc = "findings.since seq=0",
		run = function(ctx)
			local r = call(A.FindingsSince, { seq = 0 })
			for _, f in r.items or {} do
				agent.serverFindings:Upsert(f)
			end
			ctx.log(#(r.items or {}) .. " temuan disinkronkan")
		end })
	em:Register({ id = "server_export", name = "Server Export", env = "server", category = "server", desc = "export.server halaman 1",
		run = function(ctx)
			local r = call(A.ExportServer, { page = 1 })
			ctx.log(string.format("%s halaman JSON; buka Export Center untuk isinya", tostring(r.pages)))
		end })

	-- Belum tersedia
	em:Register({ id = "source_analyzer", name = "Source Analyzer", env = "studio", category = "studio", implemented = false, desc = "Analisis Source semua script",
		note = "script runtime tidak bisa membaca Source; jalankan via plugin atau Command Bar (lihat Script Panel)" })
	em:Register({ id = "require_probe", name = "Require Probe", env = "client/server", category = "studio", implemented = false, desc = "require() terkontrol",
		note = "butuh pilihan ModuleScript; gunakan tombol Probe di tab Script Inspector" })
	em:Register({ id = "server_rescan_assets", name = "Server Asset Rescan", env = "server", category = "server", implemented = false, desc = "AssetAuditor:Scan() ulang di server",
		note = "InspectorBridge belum punya aksi rescan aset server" })
	em:Register({ id = "monitor_pause", name = "Pause Monitors", env = "client", category = "continuous", implemented = false, desc = "Jeda semua monitor kontinu",
		note = "InstanceMonitor/CharacterProfiler/NetworkMonitor tidak punya API pause" })
end

return function(ctx: any, container: Frame)
	local agent, W, Theme = ctx.agent, ctx.Widgets, ctx.Theme
	local New, C = W.New, Theme.Colors

	local em = agent.executionManager
	if not em then
		em = ExecutionManager.new(agent)
		defineModules(em, agent)
		agent.executionManager = em
		agent.scripts.ErrorAdded:Connect(function(e)
			em:Log(nil, e.kind == "warning" and "WARN" or "ERROR", tostring(e.script or "?") .. ": " .. string.sub(tostring(e.message), 1, 200))
		end)
		em:Log(nil, "INFO", "Quick Execute siap: " .. #em.order .. " modul")
	end

	local statusColor = {
		RUNNING = C.Accent, DONE = Theme.Severity.LOW, ACTIVE = Theme.Severity.LOW,
		ERROR = Theme.Severity.CRITICAL, STOPPED = Theme.Severity.MEDIUM,
		IDLE = C.TextDim, ["NOT IMPLEMENTED"] = C.TextDim,
	}
	local levelColor = { INFO = C.Text, WARN = Theme.Severity.MEDIUM, ERROR = Theme.Severity.CRITICAL }

	local category, query, consoleFilter = "all", "", nil

	-- sidebar kategori
	local side = New("Frame", { BackgroundColor3 = C.Sidebar, Size = UDim2.new(0, 130, 1, 0), Parent = container }, { W.Corner(6), W.Padding(6), W.VList(4) })
	local main = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 138, 0, 0), Size = UDim2.new(1, -138, 1, 0), Parent = container })
	local top = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = main }, { W.HList(6) })
	local cardsArea = New("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, 34), Size = UDim2.new(1, 0, 1, -224),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, ScrollBarImageColor3 = C.Border, Parent = main,
	}, { New("UIGridLayout", { CellSize = UDim2.new(0.5, -6, 0, 104), CellPadding = UDim2.new(0, 8, 0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
	local scriptPanel = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 34), Size = UDim2.new(1, 0, 1, -224), Visible = false, Parent = main })
	local consoleHeader = W.Label({ Text = "Live Console", Font = Theme.FontBold, Position = UDim2.new(0, 0, 1, -184), Size = UDim2.new(0.5, 0, 0, 20), Parent = main })
	local consoleHolder = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 1, -160), Size = UDim2.new(1, 0, 0, 160), Parent = main })
	local console = ctx.VirtualList.new(consoleHolder, {
		render = function(row, e)
			row.Text = string.format("%9.3f [%-5s] %-18s %s", e.t, e.level, e.id, e.msg)
			row.TextColor3 = levelColor[e.level] or C.Text
		end,
		onSelect = function() end,
	})

	-- kartu modul
	local cards = {}
	local function rebuildCards()
		for _, c in cards do
			c.frame:Destroy()
		end
		table.clear(cards)
		for i, def in em:List(query, category) do
			local f = New("Frame", { BackgroundColor3 = C.PanelAlt, LayoutOrder = i, Parent = cardsArea }, { W.Corner(8), W.Padding(8) })
			W.Label({ Text = def.name, Font = Theme.FontBold, Size = UDim2.new(1, -110, 0, 18), Parent = f })
			local status = W.Label({ Text = "", TextSize = Theme.SmallText, Font = Theme.FontBold, TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(1, -110, 0, 0), Size = UDim2.new(0, 110, 0, 18), Parent = f })
			W.Label({ Text = "[" .. def.env .. "] " .. (def.implemented == false and ("NOT IMPLEMENTED: " .. def.note) or def.desc),
				TextColor3 = C.TextDim, TextSize = Theme.SmallText, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.new(0, 0, 0, 20), Size = UDim2.new(1, 0, 0, 34), Parent = f })
			local bar = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 1, -26), Size = UDim2.new(1, 0, 0, 26), Parent = f }, { W.HList(6) })
			local disabled = def.implemented == false
			local function btn(text: string, order: number, color: Color3?, fn: () -> ())
				local b = W.Button(text, fn, { Size = UDim2.new(0, 76, 0, 24), TextSize = Theme.SmallText, LayoutOrder = order, BackgroundColor3 = color or C.ChipOff })
				b.Parent = bar
				if disabled and text ~= "VIEW LOG" then
					b.TextColor3 = C.TextDim
				end
			end
			btn("RUN", 1, not disabled and C.Accent or nil, function()
				em:Run(def.id)
			end)
			btn("STOP", 2, nil, function()
				em:Stop(def.id)
			end)
			btn("VIEW LOG", 3, nil, function()
				consoleFilter = def.id
			end)
			cards[def.id] = { frame = f, status = status }
		end
	end

	-- Script Panel
	local snippetBar = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), Parent = scriptPanel }, { W.HList(6) })
	local snippetInfo = W.Label({ Text = "", TextColor3 = C.TextDim, TextSize = Theme.SmallText, TextWrapped = true, Position = UDim2.new(0, 0, 0, 30), Size = UDim2.new(1, 0, 0, 30), Parent = scriptPanel })
	local codeBox = W.TextInput("", {
		Position = UDim2.new(0, 0, 0, 64), Size = UDim2.new(1, 0, 1, -98), MultiLine = true, TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Font = Theme.Mono, TextSize = Theme.SmallText, Parent = scriptPanel,
	})
	local copyBtn = W.Button("Copy Script (pilih semua, lalu Ctrl+C)", function()
		codeBox:CaptureFocus()
		codeBox.SelectionStart = 1
		codeBox.CursorPosition = #codeBox.Text + 1
		em:Log(nil, "INFO", "teks dipilih; tekan Ctrl+C (game script tidak punya API clipboard resmi)")
	end, { Position = UDim2.new(0, 0, 1, -28), Size = UDim2.new(0, 280, 0, 26), BackgroundColor3 = C.Accent, TextColor3 = C.AccentText })
	copyBtn.Parent = scriptPanel
	local snippetSetters = {}
	local function showSnippet(s)
		snippetInfo.Text = "Pemasangan: " .. s.info
		codeBox.Text = s.code
		for id, set in snippetSetters do
			set(id == s.id)
		end
	end
	for i, s in SNIPPETS do
		local chip, setOn = W.Chip(s.label, i == 1, function()
			showSnippet(s)
		end)
		chip.LayoutOrder = i
		chip.Parent = snippetBar
		snippetSetters[s.id] = setOn
	end
	showSnippet(SNIPPETS[1])

	-- sidebar & search
	local sideButtons = {}
	local function selectCategory(id: string)
		category = id
		for cid, b in sideButtons do
			b.BackgroundColor3 = cid == id and C.RowSelected or C.Sidebar
		end
		local isScript = id == "script"
		scriptPanel.Visible = isScript
		cardsArea.Visible = not isScript
		if not isScript then
			rebuildCards()
		end
	end
	for i, entry in { { "all", "Semua modul" }, { "client", "Client" }, { "server", "Server" }, { "continuous", "Kontinu" }, { "studio", "Studio" }, { "script", "Script Panel" } } do
		local b = W.Button(entry[2], function()
			selectCategory(entry[1])
		end, { Size = UDim2.new(1, 0, 0, 28), LayoutOrder = i, TextSize = Theme.SmallText, BackgroundColor3 = C.Sidebar })
		b.Parent = side
		sideButtons[entry[1]] = b
	end
	local search = W.TextInput("Cari modul...", { Size = UDim2.new(0, 220, 0, 24), LayoutOrder = 1, Parent = top })
	search.FocusLost:Connect(function()
		query = search.Text
		if category == "script" then
			selectCategory("all")
		else
			rebuildCards()
		end
	end)
	local allLogs = W.Button("Semua log", function()
		consoleFilter = nil
	end, { Size = UDim2.new(0, 90, 0, 24), TextSize = Theme.SmallText, LayoutOrder = 2 })
	allLogs.Parent = top
	selectCategory("all")

	return {
		Refresh = function()
			for id, c in cards do
				local st = em:StateOf(id)
				c.status.Text = st.status .. (st.runs > 0 and (" #" .. st.runs) or "")
				c.status.TextColor3 = statusColor[st.status] or C.Text
			end
			local src = consoleFilter and em:StateOf(consoleFilter).logs:ToArray() or em.console:ToArray()
			local items = {}
			for i = #src, 1, -1 do
				table.insert(items, src[i])
			end
			console:SetItems(items, true)
			consoleHeader.Text = "Live Console" .. (consoleFilter and (" : " .. consoleFilter) or " : semua")
		end,
	}
end
