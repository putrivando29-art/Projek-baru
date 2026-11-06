--[[
	InspectorBridge (server)
	1. Mengirim paket dashboard HANYA ke pemain terotorisasi: ScreenGui dibuat server dan
	   diparent ke PlayerGui pemain itu. Isi PlayerGui hanya direplikasi ke pemiliknya,
	   jadi pemain lain tidak menerima kode inspector maupun remote-nya.
	2. Remote inspector (RemoteFunction + RemoteEvent) dibuat DI DALAM ScreenGui tersebut,
	   bukan di ReplicatedStorage, sehingga tidak menambah permukaan serangan global.
	3. Semua request divalidasi: pemanggil harus pemilik sesi, masih terotorisasi,
	   lolos rate limit, dan payload sesuai bentuk yang diharapkan.
	4. Data server-only dikirim sebagai DATA (string/angka/tabel), dirujuk dengan ID numerik.
	   Client tidak pernah "membaca ServerStorage"; server yang menjawab admin.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")

local Root = ServerStorage:WaitForChild("RuntimeInspector")
local Shared = Root:WaitForChild("Shared")
local Protocol = require(Shared.Core.Protocol)
local RateLimiter = require(Shared.Util.RateLimiter)
local Batcher = require(Shared.Util.Batcher)
local InstanceInfo = require(Shared.Core.InstanceInfo)
local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))
local AccessControl = require(script.Parent.AccessControl)

local A = Protocol.Actions

local Bridge = {}
Bridge.__index = Bridge

-- ctx = { config, serverConfig, audit, explorer, scripts, assets, monitor, profiler, network,
--         timeline, secure, manifest, policy, clientReports }
function Bridge.new(ctx: { [string]: any })
	local self = setmetatable({
		ctx = ctx,
		sessions = {},
		limiter = RateLimiter.new(ctx.serverConfig.Bridge.RequestsPerSecond, ctx.serverConfig.Bridge.Burst),
		conns = {},
		exportCache = {},
	}, Bridge)
	return self
end

-- Salinan dangkal tanpa key berawalan "_" (referensi lokal / nilai mentah).
local function plain(entry: { [string]: any }): { [string]: any }
	local out = {}
	for k, v in entry do
		if type(k) ~= "string" or string.sub(k, 1, 1) ~= "_" then
			if typeof(v) == "Instance" then
				out[k] = Serializer.SafeFullName(v)
			else
				out[k] = v
			end
		end
	end
	return out
end
Bridge.Plain = plain

local function plainNet(entry: { [string]: any }): { [string]: any }
	local out = plain(entry)
	if (out.bytes or 0) > 2500 and out.args then
		-- payload besar: kirim ringkasan agar batch stream tidak membengkak
		local summaries = {}
		for i, a in out.args do
			summaries[i] = { t = "summary", v = Serializer.Summarize(a, 160) }
		end
		out.args = summaries
		out.argsSummarized = true
	end
	return out
end

local function clampInt(v: any, min: number, max: number, default: number): number
	if type(v) ~= "number" or v ~= v then
		return default
	end
	return math.clamp(math.floor(v), min, max)
end

---------------------------------------------------------------- handlers

function Bridge:_overview()
	local ctx = self.ctx
	local assetReport = ctx.assets:Report()
	return {
		explorer = ctx.explorer:Stats(),
		scripts = ctx.scripts:Counts(),
		scriptErrors = ctx.scripts.errorCount,
		assets = { unique = assetReport.uniqueAssets, references = assetReport.references, byCategory = assetReport.byCategory },
		remotes = ctx.network.remoteCount,
		findings = ctx.audit.findings:Counts(),
		riskScore = ctx.audit.findings:RiskScore(),
		monitor = ctx.monitor:Stats(),
		secureRemotes = ctx.secure:Stats(),
		players = #Players:GetPlayers(),
		heartbeatMs = math.floor(game:GetService("Stats").HeartbeatTime * 100000) / 100,
		memoryMb = math.floor(game:GetService("Stats"):GetTotalMemoryUsageMb()),
	}
end

function Bridge:_node(inst: Instance, label: string?)
	local n = self.ctx.explorer:NodeOf(inst)
	n.label = label
	return n
end

function Bridge:_handle(player: Player, action: string, payload: any)
	local ctx = self.ctx
	local p = type(payload) == "table" and payload or {}
	local maxPage = ctx.serverConfig.Bridge.MaxPageSize

	if action == A.Hello then
		return {
			version = ctx.config.Version,
			isStudio = RunService:IsStudio(),
			serverTime = workspace:GetServerTimeNow(),
			streamingEnabled = workspace.StreamingEnabled,
			placeId = game.PlaceId,
			jobId = game.JobId,
			manifestAvailable = ctx.manifest.generatedAt ~= nil,
			runtimeAllowlist = ctx.policy.RuntimeAllowlist or {},
			serverOnlyServices = { "ServerStorage", "ServerScriptService" },
		}
	elseif action == A.Overview then
		return self:_overview()
	elseif action == A.TreeRoots then
		local out = {}
		for _, pair in ctx.explorer:Roots() do
			table.insert(out, self:_node(pair[1], pair[2]))
		end
		return out
	elseif action == A.TreeChildren then
		local inst = ctx.explorer:FromId(clampInt(p.id, 1, 2 ^ 31, 0))
		if not inst then
			return { nodes = {}, total = 0, error = "id tidak dikenal / Instance sudah hilang" }
		end
		local page, total = ctx.explorer:Children(inst, clampInt(p.offset, 0, 1e7, 0), clampInt(p.limit, 1, maxPage, maxPage))
		local nodes = {}
		for _, c in page do
			table.insert(nodes, self:_node(c))
		end
		return { nodes = nodes, total = total }
	elseif action == A.TreeDetails then
		local inst = ctx.explorer:FromId(clampInt(p.id, 1, 2 ^ 31, 0))
		if not inst then
			return { text = "Instance tidak ditemukan (sudah dihapus?)" }
		end
		local d = ctx.explorer:Details(inst)
		return { text = InstanceInfo.FormatDetails(d), visibility = d.visibility }
	elseif action == A.TreeSearch then
		local q = type(p.query) == "string" and string.sub(p.query, 1, 64) or ""
		local cf = type(p.class) == "string" and string.sub(p.class, 1, 64) or ""
		local results, truncated = ctx.explorer:Search(q, cf, clampInt(p.limit, 1, maxPage, 200))
		local nodes = {}
		for _, inst in results do
			local n = self:_node(inst)
			n.path = Serializer.SafeFullName(inst)
			table.insert(nodes, n)
		end
		return { nodes = nodes, truncated = truncated }
	elseif action == A.ScriptsList then
		if p.refresh or #ctx.scripts.records == 0 then
			ctx.scripts:Collect()
		end
		local offset = clampInt(p.offset, 0, 1e7, 0)
		local limit = clampInt(p.limit, 1, maxPage, maxPage)
		local out = {}
		for i = offset + 1, math.min(#ctx.scripts.records, offset + limit) do
			table.insert(out, plain(ctx.scripts.records[i]))
		end
		local errors = {}
		for _, e in ctx.scripts:Errors() do
			table.insert(errors, e)
		end
		return { records = out, total = #ctx.scripts.records, counts = ctx.scripts:Counts(), errors = errors }
	elseif action == A.ScriptsManifest then
		return ctx.manifest
	elseif action == A.ScriptsProbe then
		local inst = ctx.explorer:FromId(clampInt(p.id, 1, 2 ^ 31, 0))
		if not inst or not inst:IsA("ModuleScript") then
			return { status = "ditolak", error = "bukan ModuleScript" }
		end
		return ctx.scripts:Probe(inst)
	elseif action == A.AssetsReport then
		local report = ctx.assets:Report()
		local offset = clampInt(p.offset, 0, 1e7, 0)
		local limit = clampInt(p.limit, 1, maxPage, maxPage)
		local page = {}
		for i = offset + 1, math.min(#report.assets, offset + limit) do
			table.insert(page, report.assets[i])
		end
		return {
			uniqueAssets = report.uniqueAssets,
			references = report.references,
			byCategory = report.byCategory,
			assets = page,
			total = #report.assets,
			unreadable = report.unreadable,
			manifestAssetRefs = ctx.manifest.assetRefs,
		}
	elseif action == A.FindingsSince then
		local items, last = ctx.audit.findings:GetSince(clampInt(p.seq, 0, 1e9, 0), 300)
		return { items = items, last = last }
	elseif action == A.NetSince then
		local items, last = ctx.network:GetSince(clampInt(p.seq, 0, 1e9, 0), 200)
		local out = {}
		for _, e in items do
			table.insert(out, plainNet(e))
		end
		return { items = out, last = last, remotes = ctx.network:Remotes() }
	elseif action == A.EventsSince then
		local audit, lastA = ctx.audit.events:GetSince(clampInt(p.audit, 0, 1e9, 0), 300)
		local tl, lastT = ctx.timeline:GetSince(clampInt(p.timeline, 0, 1e9, 0), 300)
		local mon, lastM = ctx.monitor:GetSince(clampInt(p.monitor, 0, 1e9, 0), 300)
		local tlOut, monOut = {}, {}
		for _, e in tl do
			table.insert(tlOut, plain(e))
		end
		for _, e in mon do
			table.insert(monOut, plain(e))
		end
		return { audit = audit, lastAudit = lastA, timeline = tlOut, lastTimeline = lastT, monitor = monOut, lastMonitor = lastM }
	elseif action == A.VerifyReplication then
		-- Instance yang dibuat lokal di client tiba sebagai nil di server.
		local refs = type(p.refs) == "table" and p.refs or {}
		local n = clampInt(p.n, 0, 200, 0)
		local result = {}
		for i = 1, n do
			local inst = refs[tostring(i)]
			result[tostring(i)] = typeof(inst) == "Instance"
		end
		return result
	elseif action == A.VerifyValues then
		local items = type(p.items) == "table" and p.items or {}
		local allowedProps = {}
		for _, name in ctx.config.Verify.DivergenceProperties do
			allowedProps[name] = true
		end
		local out = {}
		local count = 0
		for key, item in items do
			count += 1
			if count > 100 then
				break
			end
			if type(key) == "string" and type(item) == "table" and typeof(item.inst) == "Instance" and type(item.name) == "string" then
				if item.kind == "attr" then
					out[key] = { ok = true, value = item.inst:GetAttribute(item.name) }
				elseif item.kind == "prop" and allowedProps[item.name] then
					local okRead, v = pcall(function()
						return (item.inst :: any)[item.name]
					end)
					out[key] = { ok = okRead, value = okRead and v or nil }
				end
			end
		end
		return out
	elseif action == A.ReportClient then
		local list = type(p.findings) == "table" and p.findings or {}
		local stored = 0
		for _, f in list do
			if stored >= 50 then
				break
			end
			if type(f) == "table" and type(f.rule) == "string" and type(f.severity) == "string" then
				stored += 1
				table.insert(ctx.clientReports, {
					reporter = player.Name,
					receivedSt = workspace:GetServerTimeNow(),
					severity = string.sub(f.severity, 1, 12),
					rule = string.sub(f.rule, 1, 80),
					path = type(f.path) == "string" and string.sub(f.path, 1, 300) or "?",
					detail = type(f.detail) == "string" and string.sub(f.detail, 1, 500) or "",
					count = type(f.count) == "number" and f.count or 1,
					source = "client-reported (tidak terpercaya)",
				})
				if #ctx.clientReports > 500 then
					table.remove(ctx.clientReports, 1)
				end
			end
		end
		return { stored = stored }
	elseif action == A.ExportServer then
		local cache = self.exportCache[player]
		local pageIndex = clampInt(p.page, 1, 10000, 1)
		if pageIndex == 1 or not cache then
			local report = ctx.audit:ExportTable()
			report.overview = self:_overview()
			report.clientReports = ctx.clientReports
			report.remotes = ctx.network:Remotes()
			report.assets = ctx.assets:Report()
			local okJson, json = pcall(HttpService.JSONEncode, HttpService, report)
			if not okJson then
				return { error = "JSONEncode gagal: " .. tostring(json) }
			end
			cache = { json = json, t = os.clock() }
			self.exportCache[player] = cache
			if p.http then
				local okPost, msg = ctx.audit:PostHttp(json)
				cache.http = (okPost and "OK: " or "GAGAL: ") .. tostring(msg)
			end
		end
		local chunk = ctx.config.UI.ExportPageChars
		local pages = math.max(1, math.ceil(#cache.json / chunk))
		return {
			page = pageIndex,
			pages = pages,
			text = string.sub(cache.json, (pageIndex - 1) * chunk + 1, pageIndex * chunk),
			http = cache.http,
		}
	end
	return { error = "aksi tidak dikenal: " .. tostring(action) }
end

---------------------------------------------------------------- sesi

function Bridge:_deliver(player: Player)
	if self.sessions[player] then
		return
	end
	if not AccessControl.IsAuthorized(player, self.ctx.serverConfig) then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui", 20)
	if not playerGui or player.Parent ~= Players then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = Protocol.GuiName
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local request = Instance.new("RemoteFunction")
	request.Name = Protocol.RequestName
	request.Parent = gui
	local stream = Instance.new("RemoteEvent")
	stream.Name = Protocol.StreamName
	stream.Parent = gui

	local sharedCopy = Shared:Clone()
	sharedCopy.Name = "Shared"
	sharedCopy.Parent = gui
	local package = Root:WaitForChild("ClientPackage"):Clone()
	package.Name = "Package"
	package.Parent = gui

	local session = { gui = gui, request = request, stream = stream, conns = {} }
	self.sessions[player] = session

	request.OnServerInvoke = function(caller: Player, action: any, payload: any)
		if caller ~= player then
			self.ctx.audit:Finding({
				severity = "HIGH",
				rule = "inspector.foreign_caller",
				object = request.Name,
				detail = caller.Name .. " memanggil remote inspector milik " .. player.Name,
				reason = "Remote inspector hanya direplikasi ke pemiliknya; pemanggil lain berarti referensi didapat secara tidak wajar.",
				recommendation = "Tinjau pemain ini.",
			}, caller)
			return nil
		end
		if not AccessControl.IsAuthorized(caller, self.ctx.serverConfig) then
			return nil
		end
		if not self.limiter:Allow(caller) then
			return { error = "rate limited" }
		end
		if type(action) ~= "string" or #action > 40 then
			return { error = "aksi tidak valid" }
		end
		local ok, result = xpcall(self._handle, debug.traceback, self, caller, action, payload)
		if not ok then
			warn("[RuntimeInspector] bridge error: " .. tostring(result))
			return { error = "server error: " .. string.sub(tostring(result), 1, 300) }
		end
		return result
	end

	-- streaming batch ke dashboard
	local function batcher(kind: string)
		return Batcher.new(self.ctx.serverConfig.Bridge.StreamInterval, self.ctx.serverConfig.Bridge.StreamMaxBatch, function(items)
			if stream.Parent and player.Parent == Players then
				stream:FireClient(player, kind, items)
			end
		end)
	end
	local bFindings = batcher(Protocol.Stream.Findings)
	local bNet = batcher(Protocol.Stream.Net)
	local bEvents = batcher(Protocol.Stream.Events)
	session.batchers = { bFindings, bNet, bEvents }
	table.insert(session.conns, self.ctx.audit.findings.Changed:Connect(function(entry)
		bFindings:Add(entry)
	end))
	table.insert(session.conns, self.ctx.network.Entry:Connect(function(entry)
		bNet:Add(plainNet(entry))
	end))
	table.insert(session.conns, self.ctx.audit.EventAdded:Connect(function(entry)
		bEvents:Add({ source = "audit", entry = entry })
	end))
	table.insert(session.conns, self.ctx.timeline.Added:Connect(function(entry)
		bEvents:Add({ source = "timeline", entry = plain(entry) })
	end))
	table.insert(session.conns, self.ctx.monitor.Event:Connect(function(entry)
		bEvents:Add({ source = "monitor", entry = plain(entry) })
	end))

	gui.Parent = playerGui
	self.ctx.audit:Event("inspector.delivered", "Dashboard dikirim ke " .. player.Name, nil)
end

function Bridge:_close(player: Player)
	local s = self.sessions[player]
	if not s then
		return
	end
	self.sessions[player] = nil
	for _, c in s.conns do
		c:Disconnect()
	end
	for _, b in s.batchers or {} do
		b:Destroy()
	end
	if s.gui then
		s.gui:Destroy()
	end
	self.limiter:Remove(player)
	self.exportCache[player] = nil
end

function Bridge:Start()
	for _, p in Players:GetPlayers() do
		task.spawn(self._deliver, self, p)
	end
	table.insert(self.conns, Players.PlayerAdded:Connect(function(p)
		self:_deliver(p)
	end))
	table.insert(self.conns, Players.PlayerRemoving:Connect(function(p)
		self:_close(p)
	end))
end

-- Predicate ignore: subtree dashboard tidak boleh dipantau oleh inspector sendiri
-- (mencegah feedback loop log -> UI -> log).
function Bridge.IsInspectorInstance(inst: Instance): boolean
	return inst.Name == Protocol.GuiName or inst:FindFirstAncestor(Protocol.GuiName) ~= nil
end

function Bridge:Destroy()
	for p in self.sessions do
		self:_close(p)
	end
	for _, c in self.conns do
		c:Disconnect()
	end
end

return Bridge
