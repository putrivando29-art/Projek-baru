--[[
	AssetAuditor
	Mengumpulkan referensi aset yang TERLIHAT di environment ini, lalu menilai
	eksposurnya berdasarkan konteks.

	Prinsip penilaian:
	- Aset yang dirender/diputar client WAJIB bisa diunduh client. Itu bukan kebocoran.
	- Yang patut ditinjau: aset yang direplikasi jauh sebelum dipakai (misal konten belum
	  rilis di ReplicatedStorage), aset yang ditandai sensitif tetapi terlihat client,
	  dan aset baru yang muncul saat gameplay tanpa ada di baseline/allowlist.
	- ID aset di dalam source code tidak terlihat oleh scanner runtime; itu dideteksi
	  Source Analyzer plugin (StaticManifest).
]]

local RunService = game:GetService("RunService")

local Shared = script.Parent.Parent
local Scheduler = require(Shared.Util.Scheduler)
local Signal = require(Shared.Util.Signal)
local AssetCatalog = require(Shared.Core.AssetCatalog)
local InstanceInfo = require(Shared.Core.InstanceInfo)
local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))

local IS_SERVER = RunService:IsServer()

local AssetAuditor = {}
AssetAuditor.__index = AssetAuditor

local PREREPLICATED = { ReplicatedStorage = true, ReplicatedFirst = true, StarterGui = true, StarterPack = true, StarterPlayer = true }
local ACTIVE = { Workspace = true, Players = true, Lighting = true, SoundService = true }

--[[
	policy (opsional, hanya server): {
		Sensitive = { ["123"] = "alasan" },  -- aset yang tidak boleh terlihat client
		RuntimeAllowlist = { ["456"] = true }, -- aset yang memang boleh muncul saat runtime
	}
]]
function AssetAuditor.new(config: any, explorer: any, policy: any?)
	return setmetatable({
		config = config,
		explorer = explorer,
		policy = policy or {},
		env = IS_SERVER and "server" or "client",
		assets = {}, -- key -> record
		refCount = 0,
		unreadable = {},
		baselineDone = false,
		UnknownAsset = Signal.new(),
	}, AssetAuditor)
end

function AssetAuditor:SetRuntimeAllowlist(list: { [string]: boolean })
	self.policy.RuntimeAllowlist = list
end

function AssetAuditor:_add(inst: Instance, ref: { [string]: any }, runtime: boolean)
	if ref.unreadable then
		if #self.unreadable < 200 then
			table.insert(self.unreadable, {
				path = Serializer.SafeFullName(inst),
				class = inst.ClassName,
				property = ref.property,
				error = ref.error,
			})
		end
		return
	end
	local rec = self.assets[ref.key]
	local isNew = rec == nil
	if not rec then
		rec = {
			key = ref.key,
			kind = ref.kind,
			categories = {},
			count = 0,
			locations = {},
			services = {},
			properties = {},
			firstSeen = os.clock(),
			runtime = runtime,
		}
		self.assets[ref.key] = rec
	end
	rec.count += 1
	self.refCount += 1
	rec.categories[ref.category] = true
	rec.properties[inst.ClassName .. "." .. ref.property] = true
	if #rec.locations < 25 then
		table.insert(rec.locations, Serializer.SafeFullName(inst))
	end
	local top = InstanceInfo.TopService(inst)
	if top then
		rec.services[top.ClassName] = true
	end
	if isNew and runtime and ref.kind == "asset" then
		local allow = self.policy.RuntimeAllowlist
		if not (allow and allow[ref.key]) then
			rec.unknownRuntime = true
			self.UnknownAsset:Fire(rec, inst)
		end
	end
end

function AssetAuditor:ScanInstance(inst: Instance, runtime: boolean)
	if not AssetCatalog.HasAssetProperties(inst) then
		return
	end
	for _, ref in AssetCatalog.Scan(inst) do
		self:_add(inst, ref, runtime)
	end
end

-- Baseline scan (yield bertahap).
function AssetAuditor:Scan()
	table.clear(self.assets)
	table.clear(self.unreadable)
	self.refCount = 0
	for _, root in self.explorer:ServiceRoots() do
		Scheduler.Walk(root, function(inst)
			self:ScanInstance(inst, false)
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
	self.baselineDone = true
end

-- Dipanggil InstanceMonitor untuk Instance baru dan perubahan properti aset.
function AssetAuditor:OnInstanceAdded(inst: Instance)
	if self.baselineDone then
		self:ScanInstance(inst, true)
	end
end

function AssetAuditor:Assess(rec: { [string]: any }): (string, string)
	if rec.kind == "engine" then
		return "INFO", "Konten bawaan engine (rbxasset://), bukan aset ter-upload."
	end
	local sensitive = self.policy.Sensitive and self.policy.Sensitive[rec.key]
	local clientVisible = not IS_SERVER
	local onlyServer = true
	local onlyPrereplicated = true
	local active = false
	for service in rec.services do
		if not InstanceInfo.ServerOnlyServices[service] then
			clientVisible = true
			onlyServer = false
		end
		if not PREREPLICATED[service] then
			onlyPrereplicated = false
		end
		if ACTIVE[service] then
			active = true
		end
	end
	if sensitive and clientVisible then
		return "HIGH", "Ditandai sensitif di AssetPolicy (" .. tostring(sensitive) .. ") tetapi berada di container yang direplikasi ke client."
	end
	if IS_SERVER and onlyServer then
		return "INFO", "Hanya di ServerStorage/ServerScriptService: tidak terekspos ke client."
	end
	if rec.unknownRuntime then
		return "MEDIUM", "Muncul saat gameplay, tidak ada di baseline maupun RuntimeAllowlist. Pastikan sumbernya script game sendiri."
	end
	if onlyPrereplicated and not active and next(rec.services) ~= nil then
		return "LOW", "Hanya ada di container pra-replikasi (ReplicatedStorage/Starter*). Semua client menerimanya sebelum dipakai. Bila ini konten belum rilis, simpan di ServerStorage dan clone saat dibutuhkan."
	end
	return "INFO", "Wajar: client harus mengunduh aset ini untuk merender/memutarnya."
end

function AssetAuditor:Report(): { [string]: any }
	local byCategory = {}
	local list = {}
	for _, rec in self.assets do
		local level, reason = self:Assess(rec)
		local cats, props, services = {}, {}, {}
		for c in rec.categories do
			table.insert(cats, c)
		end
		for p in rec.properties do
			table.insert(props, p)
		end
		for s in rec.services do
			table.insert(services, s)
		end
		table.sort(cats)
		local item = {
			key = rec.key,
			kind = rec.kind,
			categories = cats,
			properties = props,
			services = services,
			count = rec.count,
			locations = rec.locations,
			runtime = rec.runtime,
			unknownRuntime = rec.unknownRuntime == true,
			level = level,
			reason = reason,
		}
		table.insert(list, item)
		for _, c in cats do
			byCategory[c] = (byCategory[c] or 0) + 1
		end
	end
	table.sort(list, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.key < b.key
	end)
	return {
		env = self.env,
		uniqueAssets = #list,
		references = self.refCount,
		byCategory = byCategory,
		assets = list,
		unreadable = self.unreadable,
	}
end

return AssetAuditor
