--[[
	NetworkMonitor
	Audit komunikasi client-server dengan dua sumber data yang sah:

	1. Pasif (tanpa mengubah kode game):
	   - Client: RemoteEvent/UnreliableRemoteEvent.OnClientEvent  (Server->Client)
	   - Server: RemoteEvent/UnreliableRemoteEvent.OnServerEvent  (Client->Server)
	   - Keduanya: BindableEvent.Event (Local)
	   Listener tambahan tidak mengubah perilaku listener game, KECUALI pada remote
	   yang belum punya listener sama sekali: Roblox mengantrekan event tersebut dan
	   listener pertama yang terhubung menerima antreannya. Karena itu pemasangan
	   ditunda PassiveAttachDelay detik.

	2. Wrapper Net (ReplicatedStorage.RuntimeInspectorNet.Net):
	   Satu-satunya cara sah melihat panggilan KELUAR (FireServer/FireClient),
	   RemoteFunction, dan BindableFunction. Callback (OnServerInvoke/OnInvoke)
	   hanya boleh satu, jadi tidak bisa diamati pasif.

	Tidak memakai hookmetamethod, getrawmetatable, executor, atau teknik serupa.
]]

local RunService = game:GetService("RunService")

local Shared = script.Parent.Parent
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local RingBuffer = require(Shared.Util.RingBuffer)
local Scheduler = require(Shared.Util.Scheduler)
local NetFolder = game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet")
local Serializer = require(NetFolder:WaitForChild("Serializer"))
local Schema = require(NetFolder:WaitForChild("Schema"))
local Net = require(NetFolder:WaitForChild("Net"))

local IS_SERVER = RunService:IsServer()

local NetworkMonitor = {}
NetworkMonitor.__index = NetworkMonitor

local REMOTE_CLASSES = {
	RemoteEvent = true,
	UnreliableRemoteEvent = true,
	RemoteFunction = true,
	BindableEvent = true,
	BindableFunction = true,
}

function NetworkMonitor.new(config: any, explorer: any, timeline: any)
	return setmetatable({
		config = config,
		cfg = config.Network,
		explorer = explorer,
		timeline = timeline,
		env = IS_SERVER and "server" or "client",
		remotes = setmetatable({}, { __mode = "k" }), -- inst -> info
		remoteCount = 0,
		ring = RingBuffer.new(config.Network.RingSize),
		schemas = {}, -- remoteName -> Schema.Tuple
		maid = Maid.new(),
		Entry = Signal.new(), -- (entry)
		RateExceeded = Signal.new(), -- (info, count, limit, playerName?)
		SchemaMismatch = Signal.new(), -- (entry, err)
		InvalidPayload = Signal.new(), -- (entry)
	}, NetworkMonitor)
end

function NetworkMonitor:RegisterSchema(remoteName: string, tuple: any)
	self.schemas[remoteName] = tuple
end

function NetworkMonitor:_info(inst: Instance)
	local info = self.remotes[inst]
	if not info then
		info = {
			name = inst.Name,
			class = inst.ClassName,
			path = Serializer.SafeFullName(inst),
			passive = false,
			observable = inst.ClassName == "RemoteEvent" or inst.ClassName == "UnreliableRemoteEvent" or inst.ClassName == "BindableEvent",
			note = (inst.ClassName == "RemoteFunction" or inst.ClassName == "BindableFunction")
				and "Callback tunggal: hanya bisa diamati via Net wrapper"
				or nil,
			count = 0,
			bytes = 0,
			windowStart = os.clock(),
			windowCount = 0,
			rate = 0,
			peakRate = 0,
			loggedThisWindow = 0,
			droppedLogs = 0,
			lastT = 0,
			perPlayer = {},
		}
		self.remotes[inst] = info
		self.remoteCount += 1
	end
	return info
end

function NetworkMonitor:_limitFor(info: any): number
	return self.cfg.PerRemoteRateLimit[info.name] or self.cfg.DefaultRateLimit
end

-- Update statistik; return false bila entri tidak perlu disimpan (throttle log).
function NetworkMonitor:_stat(info: any, bytes: number, playerName: string?): boolean
	local now = os.clock()
	info.count += 1
	info.bytes += bytes
	info.lastT = now
	local key = playerName or "_"
	local pp = info.perPlayer[key]
	if not pp then
		pp = { windowStart = now, windowCount = 0 }
		info.perPlayer[key] = pp
	end
	if now - pp.windowStart >= 1 then
		pp.windowStart = now
		pp.windowCount = 0
	end
	pp.windowCount += 1
	local limit = self:_limitFor(info)
	if pp.windowCount == limit + 1 then
		self.RateExceeded:Fire(info, pp.windowCount, limit, playerName)
	end

	if now - info.windowStart >= 1 then
		info.rate = info.windowCount / (now - info.windowStart)
		info.peakRate = math.max(info.peakRate, info.rate)
		info.windowStart = now
		info.windowCount = 0
		info.loggedThisWindow = 0
	end
	info.windowCount += 1
	if info.loggedThisWindow >= self.cfg.MaxLoggedPerRemotePerSecond then
		info.droppedLogs += 1
		return false
	end
	info.loggedThisWindow += 1
	return true
end

function NetworkMonitor:_store(entry: { [string]: any })
	entry.seq = self.ring:Push(entry)
	if #entry.issues > 0 then
		self.InvalidPayload:Fire(entry)
	end
	local tuple = self.schemas[entry.remote]
	if tuple and entry._args then
		local ok, err = Schema.CheckTuple(tuple, table.unpack(entry._args, 1, entry._args.n))
		if not ok then
			entry.schemaError = err
			self.SchemaMismatch:Fire(entry, err)
		end
	end
	entry._args = nil -- jangan simpan nilai mentah (referensi Instance, memori)
	self.timeline:Record("Network", "Remote." .. entry.direction, string.format("%s %s argc=%d", entry.direction, entry.remote, entry.argc), { remote = entry.remote })
	self.Entry:Fire(entry)
end

function NetworkMonitor:_observe(inst: Instance, direction: string, player: Player?, ...)
	local info = self:_info(inst)
	local n = select("#", ...)
	local okEst, bytes = pcall(Serializer.EstimateBytes, table.pack(...), 65536)
	local keep = self:_stat(info, okEst and bytes or 0, player and player.Name or nil)
	if not keep then
		return
	end
	local okDesc, desc = pcall(Serializer.DescribeArgs, ...)
	local entry = {
		t = os.clock(),
		st = workspace:GetServerTimeNow(),
		env = self.env,
		via = "passive",
		direction = direction,
		remote = inst.Name,
		path = info.path,
		class = inst.ClassName,
		player = player and player.Name or nil,
		userId = player and player.UserId or nil,
		argc = n,
		args = okDesc and desc.args or {},
		types = okDesc and desc.types or {},
		issues = okDesc and desc.issues or { "serializer error" },
		bytes = okDesc and desc.bytes or 0,
		_args = table.pack(...),
	}
	self:_store(entry)
end

function NetworkMonitor:_attachPassive(inst: Instance)
	local info = self:_info(inst)
	if info.passive or not info.observable or not self.cfg.PassiveListen then
		return
	end
	info.passive = true -- tandai sekarang agar tidak dijadwalkan dua kali
	self.maid:Give(task.delay(self.cfg.PassiveAttachDelay, function()
		if inst.Parent == nil then
			info.passive = false
			return
		end
		local conn
		if inst.ClassName == "BindableEvent" then
			conn = (inst :: any).Event:Connect(function(...)
				self:_observe(inst, "Local", nil, ...)
			end)
		elseif IS_SERVER then
			conn = (inst :: any).OnServerEvent:Connect(function(player, ...)
				self:_observe(inst, "Client->Server", player, ...)
			end)
		else
			conn = (inst :: any).OnClientEvent:Connect(function(...)
				self:_observe(inst, "Server->Client", nil, ...)
			end)
		end
		info.conn = conn
		self.maid:Give(conn)
		self.maid:Give(inst.Destroying:Connect(function()
			if conn.Connected then
				conn:Disconnect()
			end
		end))
	end))
end

function NetworkMonitor:OnInstanceAdded(inst: Instance)
	if REMOTE_CLASSES[inst.ClassName] then
		self:_info(inst)
		self:_attachPassive(inst)
	end
end

-- Entri dari Net wrapper.
function NetworkMonitor:_ingestWrapper(e: { [string]: any })
	local inst = e._inst
	local info = inst and self:_info(inst) or nil
	-- Event masuk yang sudah ditangkap listener pasif tidak dicatat dua kali
	local incoming = (IS_SERVER and e.direction == "Client->Server" and e.note == nil)
		or (not IS_SERVER and e.direction == "Server->Client" and e.note == nil)
	if info and incoming and info.passive and info.conn then
		return
	end
	if info and not self:_stat(info, e.bytes or 0, e.player) then
		return
	end
	local entry = table.clone(e)
	entry._inst = nil
	self:_store(entry)
end

function NetworkMonitor:Start()
	-- katalog awal (bertahap)
	self.maid:Give(task.spawn(function()
		for _, root in self.explorer:ServiceRoots() do
			Scheduler.Walk(root, function(inst)
				if REMOTE_CLASSES[inst.ClassName] then
					self:_info(inst)
					self:_attachPassive(inst)
				end
				return true
			end, {
				budgetMs = self.config.Scan.FrameBudgetMs,
				maxNodes = self.config.Scan.MaxNodes,
				includeRoot = false,
				skip = function(inst)
					return self.explorer:_isIgnored(inst)
				end,
			})
		end
	end))
	-- konsumsi log wrapper Net
	Net.SetEnabled(true)
	self.maid:Give(Net.Subscribe(function(e)
		self:_ingestWrapper(e)
	end))
	-- entri yang terjadi sebelum monitor aktif
	for _, e in Net.GetLog(0) do
		self:_ingestWrapper(e)
	end
end

function NetworkMonitor:Remotes(): { any }
	local out = {}
	for _, info in self.remotes do
		table.insert(out, {
			name = info.name,
			class = info.class,
			path = info.path,
			passive = info.passive and info.conn ~= nil,
			note = info.note,
			count = info.count,
			bytes = info.bytes,
			rate = math.floor(info.rate * 10) / 10,
			peakRate = math.floor(info.peakRate * 10) / 10,
			droppedLogs = info.droppedLogs,
		})
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.path < b.path
	end)
	return out
end

function NetworkMonitor:Entries(): { any }
	return self.ring:ToArray()
end

function NetworkMonitor:GetSince(seq: number, limit: number?)
	return self.ring:GetSince(seq, limit)
end

function NetworkMonitor.FormatEntry(e: { [string]: any }): string
	local lines = {
		string.format("Remote    : %s (%s)", tostring(e.remote), tostring(e.class)),
		"FullName  : " .. tostring(e.path),
		"Direction : " .. tostring(e.direction) .. (e.note and (" [" .. e.note .. "]") or ""),
		"Via       : " .. tostring(e.via) .. "   Env: " .. tostring(e.env),
		string.format("Time      : os.clock=%.3f  serverTime=%.3f", e.t or 0, e.st or 0),
		"Player    : " .. tostring(e.player or "-"),
		"ArgCount  : " .. tostring(e.argc) .. "   ~bytes(estimasi): " .. tostring(e.bytes),
		"ArgTypes  : " .. table.concat(e.types or {}, ", "),
	}
	if e.schemaError then
		table.insert(lines, "SCHEMA    : " .. e.schemaError)
	end
	if e.issues and #e.issues > 0 then
		table.insert(lines, "")
		table.insert(lines, "[Masalah payload]")
		for _, s in e.issues do
			table.insert(lines, "  - " .. s)
		end
	end
	table.insert(lines, "")
	table.insert(lines, "[Payload]")
	for i, a in e.args or {} do
		table.insert(lines, "arg" .. i .. ":")
		table.insert(lines, Serializer.Pretty(a, 1))
	end
	return table.concat(lines, "\n")
end

function NetworkMonitor:Destroy()
	self.maid:Destroy()
	self.Entry:DisconnectAll()
end

return NetworkMonitor
