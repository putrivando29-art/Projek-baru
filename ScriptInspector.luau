--[[
	ScriptInspector
	Mendata Script / LocalScript / ModuleScript yang TERLIHAT di environment ini.

	Batas resmi (tidak diakali):
	- Source tidak dibaca. Script runtime tidak dapat membaca Source script lain
	  (ProtectedString). Analisis source dilakukan plugin Studio (lihat plugin/SourceAnalyzer)
	  dan hasilnya disimpan sebagai StaticManifest di ServerStorage.
	- Status "sudah di-require oleh game?" TIDAK diekspos Roblox. Yang tersedia hanyalah
	  hasil probing manual (require oleh inspector), yang default MATI karena require
	  menjalankan modul bila belum pernah dijalankan (efek samping).
	- Error script ditangkap dari ScriptContext.Error dan LogService.MessageOut untuk
	  environment ini saja (client melihat error client, server melihat error server).
]]

local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local LogService = game:GetService("LogService")

local Shared = script.Parent.Parent
local Scheduler = require(Shared.Util.Scheduler)
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local RingBuffer = require(Shared.Util.RingBuffer)
local InstanceInfo = require(Shared.Core.InstanceInfo)
local Serializer = require(game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet"):WaitForChild("Serializer"))

local IS_SERVER = RunService:IsServer()

local ScriptInspector = {}
ScriptInspector.__index = ScriptInspector

function ScriptInspector.new(config: any, explorer: any, logPrefix: string)
	return setmetatable({
		config = config,
		explorer = explorer,
		logPrefix = logPrefix,
		env = IS_SERVER and "server" or "client",
		records = {},
		probes = setmetatable({}, { __mode = "k" }),
		errors = RingBuffer.new(400),
		errorCount = 0,
		maid = Maid.new(),
		ErrorAdded = Signal.new(),
	}, ScriptInspector)
end

local function isUnderClass(inst: Instance, className: string): boolean
	return inst:FindFirstAncestorOfClass(className) ~= nil
end

-- Petunjuk di mana script ini berjalan (berdasarkan aturan lokasi yang didokumentasikan Roblox).
function ScriptInspector.RunHint(inst: Instance): string
	local ok, runContext = pcall(function()
		return (inst :: any).RunContext
	end)
	if inst:IsA("ModuleScript") then
		return "ModuleScript: hanya berjalan saat di-require"
	end
	if inst:IsA("LocalScript") then
		local inClientContainer = isUnderClass(inst, "PlayerGui")
			or isUnderClass(inst, "Backpack")
			or isUnderClass(inst, "PlayerScripts")
			or inst:IsDescendantOf(game:GetService("ReplicatedFirst"))
		local character = false
		local model = inst:FindFirstAncestorOfClass("Model")
		while model do
			if game:GetService("Players"):GetPlayerFromCharacter(model) then
				character = true
				break
			end
			model = model:FindFirstAncestorOfClass("Model")
		end
		if inClientContainer or character then
			return "LocalScript: berjalan di client (lokasi valid)"
		end
		return "LocalScript: TIDAK berjalan di lokasi ini"
	end
	if inst:IsA("Script") and ok then
		if runContext == Enum.RunContext.Client then
			return "Script RunContext=Client: berjalan di client"
		elseif runContext == Enum.RunContext.Server then
			return "Script RunContext=Server: berjalan di server"
		elseif runContext == Enum.RunContext.Legacy then
			if inst:IsDescendantOf(workspace) or inst:IsDescendantOf(game:GetService("ServerScriptService")) then
				return "Script Legacy: berjalan di server"
			end
			return "Script Legacy: TIDAK berjalan di lokasi ini"
		end
		return "Script RunContext=" .. tostring(runContext)
	end
	return "?"
end

-- Catatan keamanan berdasarkan lokasi.
function ScriptInspector.ExposureNote(inst: Instance): string?
	local top = InstanceInfo.TopService(inst)
	local topClass = top and top.ClassName or ""
	if inst:IsA("ModuleScript") and (topClass == "ReplicatedStorage" or topClass == "ReplicatedFirst" or topClass == "Workspace" or topClass == "StarterPlayer" or topClass == "StarterGui" or topClass == "StarterPack") then
		return "Modul di container yang direplikasi: kodenya dikirim ke client dan dapat diekstrak exploiter. Jangan simpan logika otoritatif/rahasia di sini."
	end
	if inst:IsA("LocalScript") then
		return "LocalScript selalu berada di tangan client: jangan dijadikan lapisan keamanan."
	end
	if inst:IsA("Script") and topClass ~= "ServerScriptService" and topClass ~= "ServerStorage" then
		return "Instance Script ini terlihat client (nama, atribut, properti). Pertimbangkan memindahkannya ke ServerScriptService."
	end
	return nil
end

function ScriptInspector:_record(inst: Instance): { [string]: any }
	local enabled = nil
	if inst:IsA("BaseScript") then
		enabled = InstanceInfo.Enabled(inst)
	end
	local okRc, rc = pcall(function()
		return (inst :: any).RunContext
	end)
	local probe = self.probes[inst]
	return {
		inst = inst,
		id = self.explorer and self.explorer:IdOf(inst) or nil,
		name = inst.Name,
		class = inst.ClassName,
		fullName = Serializer.SafeFullName(inst),
		enabled = enabled,
		runContext = okRc and tostring(rc) or nil,
		attributes = InstanceInfo.Attributes(inst),
		tags = InstanceInfo.Tags(inst),
		visibility = InstanceInfo.StaticVisibility(inst),
		runHint = ScriptInspector.RunHint(inst),
		exposure = ScriptInspector.ExposureNote(inst),
		moduleStatus = inst:IsA("ModuleScript") and (probe and probe.status or "tidak diketahui (belum diprobe)") or nil,
		probe = probe,
	}
end

-- Mengumpulkan semua LuaSourceContainer (yield bertahap).
function ScriptInspector:Collect(): { any }
	local list = {}
	local roots = self.explorer and self.explorer:ServiceRoots() or {}
	for _, root in roots do
		Scheduler.Walk(root, function(inst)
			if inst:IsA("LuaSourceContainer") then
				table.insert(list, self:_record(inst))
			end
			return true
		end, {
			budgetMs = self.config.Scan.FrameBudgetMs,
			maxNodes = self.config.Scan.MaxNodes,
			includeRoot = false,
			skip = function(inst)
				return self.explorer and self.explorer:_isIgnored(inst) or false
			end,
		})
	end
	table.sort(list, function(a, b)
		return a.fullName < b.fullName
	end)
	self.records = list
	return list
end

function ScriptInspector:Counts(): { [string]: number }
	local c = { Script = 0, LocalScript = 0, ModuleScript = 0, total = 0 }
	for _, r in self.records do
		c[r.class] = (c[r.class] or 0) + 1
		c.total += 1
	end
	return c
end

---------------------------------------------------------------- exports

local function describeFunction(fn: (...any) -> ...any): string
	local okS, source, line, name = pcall(debug.info, fn, "sln")
	local okA, arity, variadic = pcall(debug.info, fn, "a")
	local parts = {}
	if okA then
		table.insert(parts, "arity=" .. tostring(arity) .. (variadic and "+..." or ""))
	end
	if okS then
		if name and name ~= "" then
			table.insert(parts, "name=" .. name)
		end
		table.insert(parts, "src=" .. tostring(source) .. ":" .. tostring(line))
	end
	return table.concat(parts, " ")
end

-- Deskripsi nilai yang dikembalikan ModuleScript (hanya refleksi, tidak memanggil fungsi).
function ScriptInspector.DescribeExports(value: any): { [string]: any }
	local t = typeof(value)
	local out = { type = t, entries = {} }
	if t == "table" then
		local keys = {}
		for k in value do
			table.insert(keys, k)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for i, k in keys do
			if i > 200 then
				out.truncated = true
				break
			end
			local v = value[k]
			local vt = typeof(v)
			local info = ""
			if vt == "function" then
				info = describeFunction(v)
			elseif vt == "table" then
				local n = 0
				for _ in v do
					n += 1
				end
				info = "entries=" .. n .. (getmetatable(v) ~= nil and " (metatable)" or "")
			else
				info = Serializer.Summarize((Serializer.Describe(v)), 100)
			end
			table.insert(out.entries, { key = tostring(k), type = vt, info = info })
		end
		out.hasMetatable = getmetatable(value) ~= nil
		out.frozen = table.isfrozen(value)
	elseif t == "function" then
		out.info = describeFunction(value)
	else
		out.info = Serializer.Summarize((Serializer.Describe(value)), 200)
	end
	return out
end

-- require() terkontrol. Mengembalikan record probe.
function ScriptInspector:Probe(moduleScript: ModuleScript): { [string]: any }
	local cfg = self.config.Scripts
	local fullName = Serializer.SafeFullName(moduleScript)
	if not cfg.AllowRequireProbe then
		return { status = "ditolak", error = "Config.Scripts.AllowRequireProbe = false" }
	end
	if not table.find(cfg.ProbeAllowlist, fullName) then
		return { status = "ditolak", error = "Tidak ada di Config.Scripts.ProbeAllowlist: " .. fullName }
	end
	local probe = { status = "loading", started = os.clock() }
	self.probes[moduleScript] = probe
	local done = false
	task.spawn(function()
		local ok, result = pcall(require, moduleScript)
		probe.finished = os.clock()
		probe.loadTimeMs = math.floor((probe.finished - probe.started) * 100000) / 100
		if ok then
			probe.status = "loaded"
			probe.exports = ScriptInspector.DescribeExports(result)
		else
			probe.status = "error"
			probe.error = tostring(result)
		end
		done = true
	end)
	local deadline = os.clock() + (cfg.ProbeTimeout or 3)
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	if not done then
		probe.status = "yielding (require belum selesai dalam " .. tostring(cfg.ProbeTimeout) .. " detik)"
	end
	return probe
end

---------------------------------------------------------------- error capture

function ScriptInspector:_pushError(kind: string, message: string, stack: string?, scriptPath: string?)
	if string.sub(message, 1, #self.logPrefix) == self.logPrefix then
		return -- jangan merekam log inspector sendiri (mencegah loop)
	end
	self.errorCount += 1
	local entry = {
		t = os.clock(),
		st = workspace:GetServerTimeNow(),
		env = self.env,
		kind = kind,
		message = string.sub(message, 1, 1000),
		stack = stack and string.sub(stack, 1, 2000) or nil,
		script = scriptPath,
	}
	self.errors:Push(entry)
	self.ErrorAdded:Fire(entry)
end

function ScriptInspector:StartErrorCapture()
	-- error yang terjadi sebelum inspector aktif (riwayat Output environment ini)
	local okHist, history = pcall(LogService.GetLogHistory, LogService)
	if okHist then
		for _, h in history do
			if h.messageType == Enum.MessageType.MessageError then
				self:_pushError("error(history)", tostring(h.message), nil, nil)
			end
		end
	end

	self.maid:Give(ScriptContext.Error:Connect(function(message, stackTrace, scriptInst)
		self:_pushError("error", message, stackTrace, scriptInst and Serializer.SafeFullName(scriptInst) or nil)
	end))
	self.maid:Give(LogService.MessageOut:Connect(function(message, messageType)
		if messageType == Enum.MessageType.MessageWarning then
			self:_pushError("warning", message, nil, nil)
		end
		-- MessageError sudah ditangkap ScriptContext.Error (dengan stack & script);
		-- tidak direkam dua kali.
	end))
end

function ScriptInspector:Errors(): { any }
	return self.errors:ToArray()
end

function ScriptInspector:Destroy()
	self.maid:Destroy()
	self.ErrorAdded:DisconnectAll()
end

return ScriptInspector
