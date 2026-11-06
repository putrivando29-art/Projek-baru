--[[
	DataModelExplorer
	- Daftar root sesuai environment (server melihat ServerStorage & ServerScriptService,
	  client TIDAK; client mendapat shortcut LocalPlayer/PlayerGui/PlayerScripts/Backpack/Character).
	- Baseline scan bertahap (frame budget) untuk menghitung Instance & mencatat firstSeen.
	- Instance yang muncul setelah baseline ditandai runtimeSpawned.
	- Registry ID (weak table) agar server bisa merujuk Instance server-only ke client
	  tanpa mengirim referensi Instance (yang akan menjadi nil di client).
]]

local RunService = game:GetService("RunService")

local Shared = script.Parent.Parent
local Scheduler = require(Shared.Util.Scheduler)
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local InstanceInfo = require(Shared.Core.InstanceInfo)

local IS_SERVER = RunService:IsServer()

local Explorer = {}
Explorer.__index = Explorer

Explorer.ServiceOrder = table.freeze({
	"Workspace", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage", "ServerScriptService",
	"StarterGui", "StarterPack", "StarterPlayer", "Lighting", "SoundService", "Teams",
	"TextChatService", "Players", "MaterialService",
})

function Explorer.new(config: any, ignore: ((Instance) -> boolean)?)
	local self = setmetatable({
		config = config,
		ignore = ignore or function()
			return false
		end,
		env = IS_SERVER and "server" or "client",
		firstSeen = setmetatable({}, { __mode = "k" }),
		runtime = setmetatable({}, { __mode = "k" }),
		instToId = setmetatable({}, { __mode = "k" }),
		idToInst = setmetatable({}, { __mode = "v" }),
		nextId = 0,
		baselineDone = false,
		baselineTruncated = false,
		baselineDuration = 0,
		counts = { total = 0, byService = {}, byClass = {} },
		maid = Maid.new(),
		BaselineFinished = Signal.new(),
	}, Explorer)
	return self
end

function Explorer:ServiceRoots(): { Instance }
	local roots = {}
	for _, className in Explorer.ServiceOrder do
		if IS_SERVER or not InstanceInfo.ServerOnlyServices[className] then
			local ok, service = pcall(game.GetService, game, className)
			if ok and service then
				table.insert(roots, service)
			end
		end
	end
	return roots
end

-- Root untuk tampilan tree: { { inst, label } }
function Explorer:Roots(): { { any } }
	local out = {}
	for _, s in self:ServiceRoots() do
		table.insert(out, { s, s.ClassName })
	end
	if not IS_SERVER then
		for _, pair in InstanceInfo.LocalPlayerRoots() do
			table.insert(out, { pair[1], "* " .. pair[2] })
		end
	end
	return out
end

function Explorer:IdOf(inst: Instance): number
	local id = self.instToId[inst]
	if not id then
		self.nextId += 1
		id = self.nextId
		self.instToId[inst] = id
		self.idToInst[id] = inst
	end
	return id
end

function Explorer:FromId(id: number): Instance?
	return self.idToInst[id]
end

local function bump(map: { [string]: number }, key: string, delta: number)
	local v = (map[key] or 0) + delta
	map[key] = if v <= 0 then nil else v
end

function Explorer:_count(inst: Instance, service: Instance, delta: number)
	self.counts.total += delta
	bump(self.counts.byService, service.ClassName, delta)
	bump(self.counts.byClass, inst.ClassName, delta)
end

function Explorer:_isIgnored(inst: Instance): boolean
	local ok, result = pcall(self.ignore, inst)
	return ok and result == true
end

-- Memulai baseline scan + pelacakan penambahan/penghapusan. Tidak memblokir.
function Explorer:Start()
	for _, service in self:ServiceRoots() do
		self.maid:Give(service.DescendantAdded:Connect(function(inst)
			if self.firstSeen[inst] == nil and not self:_isIgnored(inst) then
				self.firstSeen[inst] = os.clock()
				if self.baselineDone then
					self.runtime[inst] = true
				end
				self:_count(inst, service, 1)
			end
		end))
		self.maid:Give(service.DescendantRemoving:Connect(function(inst)
			if self.firstSeen[inst] ~= nil then
				self.firstSeen[inst] = nil
				self:_count(inst, service, -1)
			end
		end))
	end

	self.maid:Give(task.spawn(function()
		local started = os.clock()
		local budget = self.config.Scan.FrameBudgetMs
		local maxNodes = self.config.Scan.MaxNodes
		local visitedTotal = 0
		for _, service in self:ServiceRoots() do
			local visited, truncated = Scheduler.Walk(service, function(inst)
				if self.firstSeen[inst] == nil then
					self.firstSeen[inst] = os.clock()
					self:_count(inst, service, 1)
				end
				return true
			end, {
				budgetMs = budget,
				maxNodes = math.max(1, maxNodes - visitedTotal),
				includeRoot = false,
				skip = function(inst)
					return self:_isIgnored(inst)
				end,
			})
			visitedTotal += visited
			if truncated then
				self.baselineTruncated = true
				break
			end
		end
		self.baselineDone = true
		self.baselineDuration = os.clock() - started
		self.BaselineFinished:Fire(self.counts)
	end))
end

function Explorer:Meta(inst: Instance): { [string]: any }
	local seen = self.firstSeen[inst]
	return {
		firstSeen = seen and string.format("os.clock %.3f", seen) or "-",
		runtimeSpawned = self.runtime[inst] == true,
	}
end

-- Children terurut nama (case-insensitive). Paging lewat offset/limit.
function Explorer:Children(inst: Instance, offset: number?, limit: number?): ({ any }, number)
	local ok, children = pcall(inst.GetChildren, inst)
	if not ok then
		return {}, 0
	end
	local filtered = {}
	for _, c in children do
		if not self:_isIgnored(c) then
			table.insert(filtered, c)
		end
	end
	table.sort(filtered, function(a, b)
		local an, bn = string.lower(a.Name), string.lower(b.Name)
		if an == bn then
			return a.ClassName < b.ClassName
		end
		return an < bn
	end)
	local from = (offset or 0) + 1
	local to = math.min(#filtered, from + (limit or 300) - 1)
	local page = {}
	for i = from, to do
		table.insert(page, filtered[i])
	end
	return page, #filtered
end

-- Representasi node yang aman dikirim lewat remote (tanpa referensi Instance).
function Explorer:NodeOf(inst: Instance): { [string]: any }
	local s = InstanceInfo.Summary(inst)
	s.id = self:IdOf(inst)
	s.vis = InstanceInfo.StaticVisibility(inst)
	s.runtime = self.runtime[inst] == true
	return s
end

function Explorer:Details(inst: Instance): { [string]: any }
	return InstanceInfo.Details(inst, self:Meta(inst))
end

--[[
	Search(query, classFilter, limit) -> array Instance
	query dicocokkan (substring, case-insensitive) dengan Name; classFilter dicocokkan
	dengan IsA bila nama kelas valid, atau substring ClassName.
	Harus dipanggil dari thread yang boleh yield.
]]
function Explorer:Search(query: string?, classFilter: string?, limit: number?): ({ Instance }, boolean)
	local q = query and string.lower(query) or ""
	local cf = classFilter and classFilter ~= "" and classFilter or nil
	local max = limit or self.config.Scan.SearchLimit
	local results = {}
	local truncated = false
	for _, service in self:ServiceRoots() do
		local _, hitCap = Scheduler.Walk(service, function(inst)
			if #results >= max then
				truncated = true
				return false
			end
			local nameOk = q == "" or string.find(string.lower(inst.Name), q, 1, true) ~= nil
			local classOk = true
			if cf then
				local okIsA, isA = pcall(inst.IsA, inst, cf)
				classOk = (okIsA and isA) or string.find(string.lower(inst.ClassName), string.lower(cf), 1, true) ~= nil
			end
			if nameOk and classOk then
				table.insert(results, inst)
			end
			return true
		end, {
			budgetMs = self.config.Scan.FrameBudgetMs,
			maxNodes = self.config.Scan.MaxNodes,
			skip = function(inst)
				return self:_isIgnored(inst)
			end,
		})
		if hitCap or #results >= max then
			truncated = truncated or hitCap
			break
		end
	end
	return results, truncated
end

function Explorer:Stats(): { [string]: any }
	local topClasses = {}
	for className, n in self.counts.byClass do
		table.insert(topClasses, { className, n })
	end
	table.sort(topClasses, function(a, b)
		return a[2] > b[2]
	end)
	local top = {}
	for i = 1, math.min(15, #topClasses) do
		table.insert(top, topClasses[i])
	end
	return {
		env = self.env,
		total = self.counts.total,
		byService = table.clone(self.counts.byService),
		topClasses = top,
		baselineDone = self.baselineDone,
		baselineTruncated = self.baselineTruncated,
		baselineDuration = self.baselineDuration,
	}
end

function Explorer:Destroy()
	self.maid:Destroy()
	self.BaselineFinished:DisconnectAll()
end

return Explorer
