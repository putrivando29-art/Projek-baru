--[[
	ClientAgent
	Merakit inspector sisi client + cermin data server (dari InspectorBridge).

	Pembagian data yang ditegakkan di sini:
	- Data client  : dibaca langsung oleh modul yang berjalan di client admin.
	- Data server  : HANYA diterima sebagai jawaban/stream dari InspectorBridge.
	- Verifikasi replikasi: Instance dikirim ke server sebagai argumen; Instance yang
	  hanya ada di client tiba sebagai nil di server -> CLIENT_LOCAL.
	- Divergence check: nilai properti/atribut lokal dibandingkan dengan nilai server.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ClientAgent = {}
ClientAgent.__index = ClientAgent

function ClientAgent.new(gui: ScreenGui, shared: Folder)
	local Config = require(shared.Config)
	local Protocol = require(shared.Core.Protocol)
	local self = setmetatable({
		gui = gui,
		shared = shared,
		Config = Config,
		Protocol = Protocol,
		player = Players.LocalPlayer,
		visibility = setmetatable({}, { __mode = "k" }), -- inst -> CLIENT_REPLICATED / CLIENT_LOCAL
		verifyQueue = {},
		verifyQueued = setmetatable({}, { __mode = "k" }),
		divergenceStrikes = {},
		server = {
			hello = nil,
			overview = nil,
			overviewT = 0,
			scripts = nil,
			assets = nil,
			manifest = nil,
		},
		alive = true,
		threads = {},
	}, ClientAgent)
	self:_build()
	return self
end

function ClientAgent:_build()
	local shared = self.shared
	local Config = self.Config
	local RingBuffer = require(shared.Util.RingBuffer)
	local Findings = require(shared.Core.Findings)
	local Timeline = require(shared.Core.Timeline)
	local InstanceInfo = require(shared.Core.InstanceInfo)
	local ServerLink = require(script.Parent.ServerLink)

	self.InstanceInfo = InstanceInfo
	self.FindingsLib = Findings
	self.TimelineLib = Timeline
	self.link = ServerLink.new(self.gui, self.Protocol)

	local gui = self.gui
	local lp = self.player
	local ignore = function(inst: Instance): boolean
		if inst == gui or inst:IsDescendantOf(gui) then
			return true
		end
		if not Config.Monitor.MonitorPlayerGuiOnClient then
			local pg = lp:FindFirstChildOfClass("PlayerGui")
			if pg and inst:IsDescendantOf(pg) then
				return true
			end
		end
		return false
	end
	self.ignore = ignore

	local Explorer = require(shared.Inspectors.DataModelExplorer)
	local ScriptInspector = require(shared.Inspectors.ScriptInspector)
	local AssetAuditor = require(shared.Inspectors.AssetAuditor)
	local InstanceMonitor = require(shared.Inspectors.InstanceMonitor)
	local CharacterProfiler = require(shared.Inspectors.CharacterProfiler)
	local NetworkMonitor = require(shared.Inspectors.NetworkMonitor)
	local AnomalyDetector = require(shared.Inspectors.AnomalyDetector)

	self.explorer = Explorer.new(Config, ignore)
	self.timeline = Timeline.new(Config.Character.RingSize)
	self.scripts = ScriptInspector.new(Config, self.explorer, Config.LogPrefix)
	self.assets = AssetAuditor.new(Config, self.explorer, nil)
	self.monitor = InstanceMonitor.new(Config, self.explorer:ServiceRoots(), ignore, function(inst)
		return self.visibility[inst]
	end)
	self.profiler = CharacterProfiler.new(Config, self.timeline)
	self.network = NetworkMonitor.new(Config, self.explorer, self.timeline)
	self.findings = Findings.new(Config.Anomaly.Capacity, Config.Anomaly.DedupeWindow)
	self.detector = AnomalyDetector.new(Config, self.findings)

	-- cermin data server
	self.serverFindings = Findings.new(Config.Anomaly.Capacity * 2, 0)
	self.serverNet = RingBuffer.new(Config.Network.RingSize)
	self.serverRemotes = {}
	self.serverAudit = RingBuffer.new(2000)
	self.serverTimeline = RingBuffer.new(Config.Character.RingSize)
	self.serverMonitor = RingBuffer.new(Config.Monitor.RingSize)
end

---------------------------------------------------------------- verifikasi

function ClientAgent:QueueVerify(inst: Instance)
	if self.visibility[inst] or self.verifyQueued[inst] then
		return
	end
	self.verifyQueued[inst] = true
	table.insert(self.verifyQueue, inst)
end

function ClientAgent:VisibilityOf(inst: Instance): string
	return self.visibility[inst] or self.InstanceInfo.Visibility.CLIENT_UNVERIFIED
end

function ClientAgent:_verifyLoop()
	local V = self.InstanceInfo.Visibility
	local batchSize = self.Config.Verify.ReplicationBatch
	while self.alive do
		task.wait(self.Config.Verify.ReplicationInterval)
		if #self.verifyQueue > 0 then
			local refs, list = {}, {}
			local n = 0
			while #self.verifyQueue > 0 and n < batchSize do
				local inst = table.remove(self.verifyQueue, 1)
				self.verifyQueued[inst] = nil
				if inst.Parent ~= nil then
					n += 1
					refs[tostring(n)] = inst
					list[n] = inst
				end
			end
			if n > 0 then
				local result = self.link:Call(self.Protocol.Actions.VerifyReplication, { refs = refs, n = n })
				if type(result) == "table" and not result.error then
					for i = 1, n do
						local exists = result[tostring(i)]
						if exists ~= nil then
							self.visibility[list[i]] = exists and V.CLIENT_REPLICATED or V.CLIENT_LOCAL
						end
					end
				end
			end
		end
	end
end

-- Membandingkan nilai lokal dengan nilai server. Mismatch harus terjadi 2x berturut-turut
-- (melewati latensi replikasi) sebelum dilaporkan.
function ClientAgent:_divergenceLoop()
	local cfg = self.Config
	while self.alive do
		task.wait(cfg.Verify.DivergenceInterval)
		local char = self.player.Character
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local items, localValues = {}, {}
			for _, prop in cfg.Verify.DivergenceProperties do
				local ok, v = pcall(function()
					return (humanoid :: any)[prop]
				end)
				if ok then
					items["p:" .. prop] = { inst = humanoid, kind = "prop", name = prop }
					localValues["p:" .. prop] = v
				end
			end
			for _, holder in { char, humanoid } do
				for _, attr in cfg.Anomaly.ProtectedAttributes do
					local v = holder:GetAttribute(attr)
					if v ~= nil then
						local key = "a:" .. holder.ClassName .. ":" .. attr
						items[key] = { inst = holder, kind = "attr", name = attr }
						localValues[key] = v
					end
				end
			end
			local result = self.link:Call(self.Protocol.Actions.VerifyValues, { items = items })
			if type(result) == "table" and not result.error then
				for key, localValue in localValues do
					local r = result[key]
					if r and r.ok then
						local differs
						if type(localValue) == "number" and type(r.value) == "number" then
							differs = math.abs(localValue - r.value) > 1e-3
						else
							differs = localValue ~= r.value
						end
						if differs then
							self.divergenceStrikes[key] = (self.divergenceStrikes[key] or 0) + 1
							if self.divergenceStrikes[key] == 2 then
								local item = items[key]
								self.detector:OnDivergence(item.inst:GetFullName(), item.name, localValue, r.value)
							end
						else
							self.divergenceStrikes[key] = 0
						end
					end
				end
			end
		end
	end
end

---------------------------------------------------------------- server mirror

function ClientAgent:_onStream(kind: string, items: { any })
	local S = self.Protocol.Stream
	if type(items) ~= "table" then
		return
	end
	if kind == S.Findings then
		for _, f in items do
			self.serverFindings:Upsert(f)
		end
	elseif kind == S.Net then
		for _, e in items do
			self.serverNet:Push(e)
		end
	elseif kind == S.Events then
		for _, wrap in items do
			if wrap.source == "audit" then
				self.serverAudit:Push(wrap.entry)
			elseif wrap.source == "timeline" then
				self.serverTimeline:Push(wrap.entry)
			elseif wrap.source == "monitor" then
				self.serverMonitor:Push(wrap.entry)
			end
		end
	end
end

function ClientAgent:_catchUp()
	local A = self.Protocol.Actions
	local hello = self.link:Call(A.Hello)
	if type(hello) == "table" then
		self.server.hello = hello
		if hello.runtimeAllowlist then
			self.assets:SetRuntimeAllowlist(hello.runtimeAllowlist)
		end
	end
	local f = self.link:Call(A.FindingsSince, { seq = 0 })
	if type(f) == "table" and f.items then
		for _, item in f.items do
			self.serverFindings:Upsert(item)
		end
	end
	local n = self.link:Call(A.NetSince, { seq = 0 })
	if type(n) == "table" and n.items then
		for _, e in n.items do
			self.serverNet:Push(e)
		end
		self.serverRemotes = n.remotes or {}
	end
	local ev = self.link:Call(A.EventsSince, { audit = 0, timeline = 0, monitor = 0 })
	if type(ev) == "table" then
		for _, e in ev.audit or {} do
			self.serverAudit:Push(e)
		end
		for _, e in ev.timeline or {} do
			self.serverTimeline:Push(e)
		end
		for _, e in ev.monitor or {} do
			self.serverMonitor:Push(e)
		end
	end
end

-- Overview server di-cache; diambil ulang paling cepat tiap 3 detik.
function ClientAgent:ServerOverview(): any
	local now = os.clock()
	if now - self.server.overviewT > 3 and not self.server.overviewPending then
		self.server.overviewPending = true
		self.link:CallAsync(self.Protocol.Actions.Overview, nil, function(r)
			self.server.overviewPending = false
			self.server.overviewT = os.clock()
			if type(r) == "table" and not r.error then
				self.server.overview = r
			end
		end)
	end
	return self.server.overview
end

function ClientAgent:RefreshServerRemotes()
	self.link:CallAsync(self.Protocol.Actions.NetSince, { seq = 1e9 }, function(r)
		if type(r) == "table" and r.remotes then
			self.serverRemotes = r.remotes
		end
	end)
end

-- Laporkan temuan client HIGH/CRITICAL ke server (untuk laporan gabungan).
function ClientAgent:_reportLoop()
	local lastSeq = 0
	while self.alive do
		task.wait(5)
		local changes, last = self.findings:GetSince(lastSeq, 100)
		lastSeq = last
		local out = {}
		for _, f in changes do
			if f.severity == "HIGH" or f.severity == "CRITICAL" then
				table.insert(out, { severity = f.severity, rule = f.rule, path = f.path, detail = f.detail, count = f.count })
			end
		end
		if #out > 0 then
			self.link:Call(self.Protocol.Actions.ReportClient, { findings = out })
		end
	end
end

---------------------------------------------------------------- start

function ClientAgent:Start()
	local Config = self.Config
	self.monitor.InstanceAdded:Connect(function(inst)
		self.profiler:OnInstanceAdded(inst)
		self.network:OnInstanceAdded(inst)
		self.assets:OnInstanceAdded(inst)
		if self.monitor:_isWatchedClass(inst) then
			self:QueueVerify(inst)
		end
	end)
	self.detector:Bind({
		monitor = self.monitor,
		profiler = self.profiler,
		network = self.network,
		scripts = self.scripts,
		assets = self.assets,
	})

	self.scripts:StartErrorCapture()
	self.explorer:Start()
	self.monitor:Start()
	self.profiler:Start()
	self.network:Start()

	if self.link.available then
		self.link:OnStream(function(kind, items)
			self:_onStream(kind, items)
		end)
		table.insert(self.threads, task.spawn(function()
			self:_catchUp()
		end))
		table.insert(self.threads, task.spawn(function()
			self:_verifyLoop()
		end))
		table.insert(self.threads, task.spawn(function()
			self:_divergenceLoop()
		end))
		table.insert(self.threads, task.spawn(function()
			self:_reportLoop()
		end))
	end

	table.insert(self.threads, task.spawn(function()
		local t0 = os.clock()
		self.assets:Scan()
		self.scripts:Collect()
		print(string.format("%s client siap (%.2fs). Tekan %s untuk membuka dashboard.", Config.LogPrefix, os.clock() - t0, Config.ToggleKey.Name))
	end))
end

function ClientAgent:Destroy()
	self.alive = false
	for _, t in self.threads do
		pcall(task.cancel, t)
	end
	self.monitor:Destroy()
	self.profiler:Destroy()
	self.network:Destroy()
	self.scripts:Destroy()
	self.explorer:Destroy()
	self.detector:Destroy()
end

ClientAgent.IsStudio = RunService:IsStudio()

return ClientAgent
