--[[
	InstanceMonitor
	Pemantauan perubahan DataModel real-time:
	- DescendantAdded / DescendantRemoving pada setiap root.
	- GetPropertyChangedSignal untuk properti terdaftar pada kelas yang dipantau.
	- AttributeChanged dengan nilai sebelum/sesudah.

	Pengendalian performa:
	- Handler event hanya memasukkan ke antrean (O(1)). Pemrosesan di Heartbeat
	  dengan budget waktu. Antrean dibatasi QueueMax; kelebihan dihitung sebagai dropped.
	- Jumlah Instance yang dipasangi watcher dibatasi MaxWatchedInstances.
	- Watcher dibersihkan saat Instance Destroying atau keluar dari root.

	Keterbatasan resmi:
	- "Sumber perubahan" (script mana yang mengubah) tidak tersedia di API Roblox.
	- Perubahan CFrame/Position akibat simulasi fisika tidak memicu Changed/GetPropertyChangedSignal.
]]

local RunService = game:GetService("RunService")

local Shared = script.Parent.Parent
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local RingBuffer = require(Shared.Util.RingBuffer)
local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))

local IS_SERVER = RunService:IsServer()

local InstanceMonitor = {}
InstanceMonitor.__index = InstanceMonitor

function InstanceMonitor.new(config: any, roots: { Instance }, ignore: (Instance) -> boolean, classifier: ((Instance) -> string?)?)
	local self = setmetatable({
		config = config,
		cfg = config.Monitor,
		roots = roots,
		ignore = ignore,
		classifier = classifier, -- fungsi opsional: info lokal/replikasi untuk kolom source
		env = IS_SERVER and "server" or "client",
		queue = {},
		queueHead = 1,
		dropped = 0,
		ring = RingBuffer.new(config.Monitor.RingSize),
		watchers = setmetatable({}, { __mode = "k" }),
		watchedCount = 0,
		watchSkipped = 0,
		stats = { added = 0, removed = 0, property = 0, attribute = 0 },
		maid = Maid.new(),
		Event = Signal.new(), -- (entry, inst?)
		InstanceAdded = Signal.new(), -- (inst, entry) setelah diproses; untuk modul lain
	}, InstanceMonitor)

	local watchedSet = {}
	for _, c in self.cfg.WatchedClasses do
		watchedSet[c] = true
	end
	self.watchedSet = watchedSet
	return self
end

function InstanceMonitor:_isWatchedClass(inst: Instance): boolean
	if self.watchedSet[inst.ClassName] then
		return true
	end
	-- IsA untuk subclass (contoh: Seat adalah Part)
	for c in self.watchedSet do
		local ok, isA = pcall(inst.IsA, inst, c)
		if ok and isA then
			return true
		end
	end
	return false
end

function InstanceMonitor:_source(inst: Instance?): string
	local base = "tidak dapat ditentukan via API resmi; diamati di " .. self.env
	if inst and self.classifier then
		local ok, hint = pcall(self.classifier, inst)
		if ok and hint then
			return base .. " (" .. hint .. ")"
		end
	end
	return base
end

function InstanceMonitor:_emit(entry: { [string]: any }, inst: Instance?)
	entry.seq = self.ring:Push(entry)
	self.Event:Fire(entry, inst)
end

function InstanceMonitor:_enqueue(kind: string, inst: Instance, root: Instance)
	local size = #self.queue - self.queueHead + 1
	if size >= self.cfg.QueueMax then
		self.dropped += 1
		return
	end
	local item = { kind = kind, inst = inst, t = os.clock(), st = workspace:GetServerTimeNow(), name = inst.Name, class = inst.ClassName }
	if kind == "removed" then
		-- FullName harus dibaca sekarang, sebelum parent berubah
		item.path = Serializer.SafeFullName(inst)
		item.parent = inst.Parent and Serializer.SafeFullName(inst.Parent) or "nil"
	end
	table.insert(self.queue, item)
end

function InstanceMonitor:_process()
	local deadline = os.clock() + self.cfg.ProcessBudgetMs / 1000
	while self.queueHead <= #self.queue do
		if os.clock() > deadline then
			break
		end
		local item = self.queue[self.queueHead]
		self.queue[self.queueHead] = nil
		self.queueHead += 1
		local ok, err = pcall(self._handle, self, item)
		if not ok then
			warn(self.config.LogPrefix .. " monitor error: " .. tostring(err))
		end
	end
	if self.queueHead > #self.queue then
		self.queue = {}
		self.queueHead = 1
	end
end

function InstanceMonitor:_handle(item: { [string]: any })
	local inst: Instance = item.inst
	if item.kind == "added" then
		self.stats.added += 1
		local alive = inst.Parent ~= nil
		local watched = self:_isWatchedClass(inst)
		local entry = {
			t = item.t,
			st = item.st,
			env = self.env,
			kind = "added",
			name = item.name,
			class = item.class,
			path = alive and Serializer.SafeFullName(inst) or ("(dihapus sebelum diproses) " .. item.name),
			parent = alive and inst.Parent and Serializer.SafeFullName(inst.Parent) or "nil",
			watchedClass = watched,
			source = self:_source(alive and inst or nil),
		}
		self:_emit(entry, alive and inst or nil)
		if alive then
			if watched then
				self:Watch(inst)
			end
			self.InstanceAdded:Fire(inst, entry)
		end
	elseif item.kind == "removed" then
		self.stats.removed += 1
		self:Unwatch(inst)
		self:_emit({
			t = item.t,
			st = item.st,
			env = self.env,
			kind = "removed",
			name = item.name,
			class = item.class,
			path = item.path,
			parent = item.parent,
			source = self:_source(nil),
		}, nil)
	end
end

local function summarize(v: any): string
	return Serializer.Summarize((Serializer.Describe(v)), 120)
end

-- Pasang watcher properti + atribut. Aman dipanggil berulang (idempotent).
function InstanceMonitor:Watch(inst: Instance): boolean
	if self.watchers[inst] then
		return true
	end
	if self.watchedCount >= self.cfg.MaxWatchedInstances then
		self.watchSkipped += 1
		return false
	end
	local maid = Maid.new()
	self.watchers[inst] = maid
	self.watchedCount += 1

	local props = {}
	for className, list in self.cfg.WatchedProperties do
		local ok, isA = pcall(inst.IsA, inst, className)
		if ok and isA then
			for _, p in list do
				props[p] = true
			end
		end
	end

	for prop in props do
		local okRead, initial = pcall(function()
			return (inst :: any)[prop]
		end)
		if okRead then
			local old = initial
			local okSig, signal = pcall(inst.GetPropertyChangedSignal, inst, prop)
			if okSig then
				maid:Give(signal:Connect(function()
					local new = (inst :: any)[prop]
					self.stats.property += 1
					self:_emit({
						t = os.clock(),
						st = workspace:GetServerTimeNow(),
						env = self.env,
						kind = "property",
						name = inst.Name,
						class = inst.ClassName,
						path = Serializer.SafeFullName(inst),
						prop = prop,
						old = summarize(old),
						new = summarize(new),
						source = self:_source(inst),
					}, inst)
					old = new
				end))
			end
		end
	end

	local okAttrs, attrs = pcall(inst.GetAttributes, inst)
	local snapshot = okAttrs and attrs or {}
	maid:Give(inst.AttributeChanged:Connect(function(name)
		local old = snapshot[name]
		local new = inst:GetAttribute(name)
		snapshot[name] = new
		self.stats.attribute += 1
		self:_emit({
			t = os.clock(),
			st = workspace:GetServerTimeNow(),
			env = self.env,
			kind = "attribute",
			name = inst.Name,
			class = inst.ClassName,
			path = Serializer.SafeFullName(inst),
			prop = name,
			old = summarize(old),
			new = summarize(new),
			_oldRaw = old,
			_newRaw = new,
			source = self:_source(inst),
		}, inst)
	end))

	maid:Give(inst.Destroying:Connect(function()
		self:Unwatch(inst)
	end))
	return true
end

function InstanceMonitor:Unwatch(inst: Instance)
	local maid = self.watchers[inst]
	if maid then
		self.watchers[inst] = nil
		self.watchedCount -= 1
		maid:Destroy()
	end
end

function InstanceMonitor:Start()
	for _, root in self.roots do
		self.maid:Give(root.DescendantAdded:Connect(function(inst)
			if not self.ignore(inst) then
				self:_enqueue("added", inst, root)
			end
		end))
		self.maid:Give(root.DescendantRemoving:Connect(function(inst)
			if not self.ignore(inst) then
				self:_enqueue("removed", inst, root)
			end
		end))
		-- ChildAdded/ChildRemoved pada level root: dicatat sebagai info struktur tingkat atas
		self.maid:Give(root.ChildAdded:Connect(function(child)
			if not self.ignore(child) then
				self:_emit({
					t = os.clock(),
					st = workspace:GetServerTimeNow(),
					env = self.env,
					kind = "child+",
					name = child.Name,
					class = child.ClassName,
					path = Serializer.SafeFullName(child),
					parent = root.ClassName,
					source = self:_source(child),
				}, child)
			end
		end))
		self.maid:Give(root.ChildRemoved:Connect(function(child)
			if not self.ignore(child) then
				self:_emit({
					t = os.clock(),
					st = workspace:GetServerTimeNow(),
					env = self.env,
					kind = "child-",
					name = child.Name,
					class = child.ClassName,
					path = root.ClassName .. "." .. child.Name,
					parent = root.ClassName,
					source = self:_source(nil),
				}, nil)
			end
		end))
	end
	self.maid:Give(RunService.Heartbeat:Connect(function()
		self:_process()
	end))
end

function InstanceMonitor:Entries(): { any }
	return self.ring:ToArray()
end

function InstanceMonitor:GetSince(seq: number, limit: number?)
	return self.ring:GetSince(seq, limit)
end

function InstanceMonitor:Stats(): { [string]: any }
	return {
		added = self.stats.added,
		removed = self.stats.removed,
		property = self.stats.property,
		attribute = self.stats.attribute,
		queued = #self.queue - self.queueHead + 1,
		dropped = self.dropped,
		watched = self.watchedCount,
		watchSkipped = self.watchSkipped,
	}
end

function InstanceMonitor:Destroy()
	self.maid:Destroy()
	for inst, maid in self.watchers do
		maid:Destroy()
		self.watchers[inst] = nil
	end
	self.watchedCount = 0
	self.Event:DisconnectAll()
	self.InstanceAdded:DisconnectAll()
end

return InstanceMonitor
