--[[
	RuntimeInspector Delta Android (client-side)
	FILE INI DIHASILKAN OTOMATIS oleh standalone/build.py dari modul di src/ (commit unknown).
	Jangan edit langsung: ubah src/ atau standalone/StandaloneMain.luau lalu build ulang.

	Delta Android: tempel seluruh isi file ini ke editor executor saat sudah berada di dalam game, lalu Execute.
	Client-only. UI dapat dibuka melalui tombol Inspector di layar.
	Modul: Serializer, Schema, Net, Config, Maid, Signal, RingBuffer, Scheduler, InstanceInfo, AssetCatalog, Findings, Timeline, DataModelExplorer, ScriptInspector, AssetAuditor, InstanceMonitor, CharacterProfiler, NetworkMonitor, AnomalyDetector, ExportCenter, Theme, Widgets, VirtualList, TreeView, ListDetailView
]]

local __modules = {}
local __cache = {}

-- Integrasi opsional: bila repo utama terpasang, pakai Net milik game agar panggilan
-- Net.FireServer dari script game ikut tercatat. Tanpa itu, Net internal yang dipakai.
local function __external(name)
	if name ~= "Net" then
		return nil
	end
	local folder = game:GetService("ReplicatedStorage"):FindFirstChild("RuntimeInspectorNet")
	local m = folder and folder:FindFirstChild("Net")
	if m and m:IsA("ModuleScript") then
		local ok, v = pcall(require, m)
		if ok then
			return v
		end
	end
	return nil
end

local function __require(name)
	local cached = __cache[name]
	if cached ~= nil then
		return cached
	end
	local value = __external(name)
	if value == nil then
		local loader = __modules[name]
		if not loader then
			error("[RuntimeInspector] modul tidak ada di bundle: " .. tostring(name), 2)
		end
		value = loader()
	end
	__cache[name] = value
	return value
end

-- ===== Serializer (ReplicatedStorage/RuntimeInspectorNet/Serializer.luau) =====
__modules.Serializer = function()
--[[
	Serializer
	Mengubah nilai Luau / datatype Roblox apa pun menjadi tabel "plain" (aman untuk
	HttpService:JSONEncode) beserta daftar masalah (NaN, inf, siklus, tabel campuran,
	fungsi yang tidak bisa dikirim lewat remote, dan sebagainya).

	Dipakai oleh: Net (wrapper remote), NetworkMonitor, SecureRemote, ExportCenter.
	Tidak menyentuh state global, aman di-require dari client maupun server.
]]

local HttpService = game:GetService("HttpService")

local Serializer = {}

Serializer.DefaultOptions = table.freeze({
	maxDepth = 6, -- kedalaman tabel bertingkat
	maxItems = 64, -- entri per tabel yang dideskripsikan
	maxNodes = 1500, -- total node per panggilan
	maxString = 400, -- karakter string yang disimpan
})

local INF = math.huge

local function isFinite(n: number): boolean
	return n == n and n ~= INF and n ~= -INF
end
Serializer.IsFinite = isFinite

-- Angka aman JSON: NaN/inf diganti string supaya JSONEncode tidak gagal.
function Serializer.Num(n: any): any
	if type(n) ~= "number" then
		return n
	end
	if n ~= n then
		return "NaN"
	end
	if n == INF then
		return "inf"
	end
	if n == -INF then
		return "-inf"
	end
	return n
end

local function r3(n: number): any
	if not isFinite(n) then
		return Serializer.Num(n)
	end
	return math.round(n * 1000) / 1000
end

function Serializer.Vec3(v: Vector3): { any }
	return { r3(v.X), r3(v.Y), r3(v.Z) }
end

local function safeFullName(inst: Instance): string
	local ok, name = pcall(inst.GetFullName, inst)
	return ok and name or "<unknown>"
end
Serializer.SafeFullName = safeFullName

--[[
	Describe(value, options) -> described, issues, stats
	described : tabel plain { t = <typeof>, v = ..., ... }
	issues    : array string "<path>: <masalah>"
	stats     : { nodes = number, bytes = number (perkiraan, bukan ukuran paket asli) }
]]
function Serializer.Describe(value: any, options: any?)
	local opt = options or Serializer.DefaultOptions
	local state = { nodes = 0, bytes = 0, issues = {}, seen = {} }

	local function issue(path: string, msg: string)
		if #state.issues < 48 then
			table.insert(state.issues, path .. ": " .. msg)
		end
	end

	local walk

	local function describeTable(tbl: { [any]: any }, depth: number, path: string)
		if state.seen[tbl] then
			issue(path, "referensi siklik (remote Roblox tidak mendukung siklus)")
			return { t = "table", cycle = true }
		end
		if depth >= opt.maxDepth then
			return { t = "table", depthLimited = true }
		end
		state.seen[tbl] = true

		local count, numericKeys, stringKeys, otherKeys = 0, 0, 0, 0
		local maxIndex = 0
		for k in tbl do
			count += 1
			local kt = type(k)
			if kt == "number" then
				numericKeys += 1
				if k > maxIndex then
					maxIndex = k
				end
			elseif kt == "string" then
				stringKeys += 1
			else
				otherKeys += 1
			end
		end

		local kind = "dict"
		if count == 0 then
			kind = "empty"
		elseif numericKeys == count then
			kind = (maxIndex == count) and "array" or "sparse"
		elseif numericKeys > 0 and stringKeys > 0 then
			kind = "mixed"
		end

		if kind == "mixed" then
			issue(path, "tabel campuran (array + dictionary): sebagian entri bisa hilang saat dikirim via remote")
		elseif kind == "sparse" then
			issue(path, "array berlubang (ada nil): elemen setelah lubang bisa hilang saat dikirim via remote")
		end
		if otherKeys > 0 then
			issue(path, "key bukan string/number: tidak bisa diserialisasi remote")
		end
		if getmetatable(tbl) ~= nil then
			issue(path, "memiliki metatable: metatable TIDAK ikut terkirim via remote")
		end

		local out = { t = "table", kind = kind, n = count, items = {} }
		local emitted = 0
		for k, v in tbl do
			if emitted >= opt.maxItems or state.nodes >= opt.maxNodes then
				out.truncated = true
				break
			end
			emitted += 1
			local keyText = (type(k) == "string" or type(k) == "number") and tostring(k) or ("<" .. typeof(k) .. ">")
			state.bytes += #keyText + 1
			table.insert(out.items, { k = keyText, v = walk(v, depth + 1, path .. "." .. keyText) })
		end
		state.seen[tbl] = nil
		return out
	end

	walk = function(v: any, depth: number, path: string): any
		state.nodes += 1
		if state.nodes > opt.maxNodes then
			return { t = "truncated" }
		end

		local t = typeof(v)
		if t == "nil" then
			state.bytes += 1
			return { t = "nil" }
		elseif t == "boolean" then
			state.bytes += 1
			return { t = "boolean", v = v }
		elseif t == "number" then
			state.bytes += 8
			if not isFinite(v) then
				issue(path, "angka tidak valid (" .. tostring(v) .. ")")
				return { t = "number", v = Serializer.Num(v), invalid = true }
			end
			return { t = "number", v = v }
		elseif t == "string" then
			state.bytes += #v + 2
			local out: { [string]: any } = { t = "string", len = #v }
			if utf8.len(v) == nil then
				issue(path, "string bukan UTF-8 valid")
				out.v = "<binary " .. #v .. " bytes>"
				out.invalid = true
			elseif #v > opt.maxString then
				out.v = string.sub(v, 1, opt.maxString)
				out.truncated = true
			else
				out.v = v
			end
			return out
		elseif t == "table" then
			return describeTable(v, depth, path)
		elseif t == "Vector3" then
			state.bytes += 12
			if not (isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)) then
				issue(path, "Vector3 berisi NaN/inf")
				return { t = t, v = Serializer.Vec3(v), invalid = true }
			end
			return { t = t, v = Serializer.Vec3(v), mag = r3(v.Magnitude) }
		elseif t == "CFrame" then
			state.bytes += 48
			local comps = { v:GetComponents() }
			local valid = true
			for _, c in comps do
				if not isFinite(c) then
					valid = false
					break
				end
			end
			local rx, ry, rz = v:ToOrientation()
			local out = {
				t = t,
				p = Serializer.Vec3(v.Position),
				rotDeg = { r3(math.deg(rx)), r3(math.deg(ry)), r3(math.deg(rz)) },
			}
			if not valid then
				out.invalid = true
				issue(path, "CFrame berisi NaN/inf")
			end
			return out
		elseif t == "Instance" then
			state.bytes += 8
			local okClass, className = pcall(function()
				return v.ClassName
			end)
			local out = {
				t = t,
				class = okClass and className or "?",
				name = v.Name,
				path = safeFullName(v),
			}
			if v.Parent == nil then
				out.detached = true
				issue(path, "Instance tanpa Parent (detached/destroyed)")
			end
			return out
		elseif t == "Vector2" then
			state.bytes += 8
			return { t = t, v = { r3(v.X), r3(v.Y) } }
		elseif t == "Color3" then
			state.bytes += 12
			return { t = t, v = { r3(v.R), r3(v.G), r3(v.B) } }
		elseif t == "UDim2" then
			state.bytes += 16
			return { t = t, v = { r3(v.X.Scale), v.X.Offset, r3(v.Y.Scale), v.Y.Offset } }
		elseif t == "EnumItem" then
			state.bytes += 4
			return { t = t, v = tostring(v) }
		elseif t == "buffer" then
			local len = buffer.len(v)
			state.bytes += len
			return { t = t, len = len }
		elseif t == "function" or t == "thread" or t == "userdata" then
			issue(path, t .. " tidak dapat dikirim via remote (akan menjadi nil)")
			return { t = t }
		else
			-- Datatype lain (UDim, Rect, NumberRange, ColorSequence, BrickColor, DateTime, Content, ...)
			local okStr, str = pcall(tostring, v)
			state.bytes += 16
			return { t = t, v = okStr and string.sub(str, 1, opt.maxString) or "<tostring gagal>" }
		end
	end

	local described = walk(value, 0, "$")
	return described, state.issues, { nodes = state.nodes, bytes = state.bytes }
end

-- DescribeArgs(...) untuk argumen remote; aman terhadap nil di tengah argumen.
function Serializer.DescribeArgs(...)
	local n = select("#", ...)
	local packed = table.pack(...)
	local args, types, issues = table.create(n), table.create(n), {}
	local bytes, nodes = 0, 0
	for i = 1, n do
		local d, iss, st = Serializer.Describe(packed[i])
		args[i] = d
		types[i] = typeof(packed[i])
		bytes += st.bytes
		nodes += st.nodes
		for _, s in iss do
			if #issues < 48 then
				table.insert(issues, "arg" .. i .. string.sub(s, 2))
			end
		end
	end
	return { argc = n, args = args, types = types, issues = issues, bytes = bytes, nodes = nodes }
end

--[[
	EstimateBytes(value, cap) -> bytes, exceeded
	Perkiraan cepat ukuran payload TANPA membangun deskripsi. Berhenti begitu melewati cap.
	Ini adalah estimasi buatan sistem ini, bukan ukuran paket jaringan Roblox yang sebenarnya.
]]
function Serializer.EstimateBytes(value: any, cap: number): (number, boolean)
	local total = 0
	local seen = {}
	local stack = { value }
	local nodes = 0
	while #stack > 0 do
		local v = table.remove(stack)
		nodes += 1
		if nodes > 20000 then
			return total, true
		end
		local t = typeof(v)
		if t == "string" then
			total += #v + 2
		elseif t == "number" then
			total += 8
		elseif t == "boolean" or t == "nil" then
			total += 1
		elseif t == "Vector3" then
			total += 12
		elseif t == "CFrame" then
			total += 48
		elseif t == "buffer" then
			total += buffer.len(v)
		elseif t == "table" then
			if not seen[v] then
				seen[v] = true
				for k, item in v do
					table.insert(stack, k)
					table.insert(stack, item)
				end
			end
		else
			total += 16
		end
		if total > cap then
			return total, true
		end
	end
	return total, false
end

-- Ringkasan satu baris untuk tampilan list.
function Serializer.Summarize(d: any, maxLen: number?): string
	local limit = maxLen or 80
	local s
	if type(d) ~= "table" then
		s = tostring(d)
	elseif d.t == "string" then
		s = string.format("%q", d.v or "")
	elseif d.t == "number" or d.t == "boolean" or d.t == "EnumItem" then
		s = tostring(d.v)
	elseif d.t == "nil" then
		s = "nil"
	elseif d.t == "Vector3" or d.t == "Vector2" or d.t == "Color3" or d.t == "UDim2" then
		local parts = {}
		for _, c in d.v do
			table.insert(parts, tostring(c))
		end
		s = d.t .. "(" .. table.concat(parts, ", ") .. ")"
	elseif d.t == "CFrame" then
		s = string.format("CFrame(%s, %s, %s)", tostring(d.p[1]), tostring(d.p[2]), tostring(d.p[3]))
	elseif d.t == "Instance" then
		s = d.class .. " " .. d.path
	elseif d.t == "table" then
		s = "{" .. (d.kind or "?") .. " " .. tostring(d.n or 0) .. "}"
	else
		s = "<" .. tostring(d.t) .. ">"
	end
	if d and type(d) == "table" and d.invalid then
		s = "!" .. s
	end
	if #s > limit then
		s = string.sub(s, 1, limit - 3) .. "..."
	end
	return s
end

-- Tampilan multi-baris (dipakai panel detail).
function Serializer.Pretty(d: any, indent: number?): string
	local lines = {}
	local function emit(node: any, depth: number, label: string)
		local pad = string.rep("  ", depth)
		if type(node) == "table" and node.t == "table" and node.items then
			table.insert(lines, pad .. label .. "{" .. tostring(node.kind) .. ", n=" .. tostring(node.n) .. "}")
			for _, item in node.items do
				emit(item.v, depth + 1, "[" .. item.k .. "] = ")
			end
			if node.truncated then
				table.insert(lines, pad .. "  ...(dipotong)")
			end
		else
			table.insert(lines, pad .. label .. Serializer.Summarize(node, 200))
		end
	end
	emit(d, indent or 0, "")
	return table.concat(lines, "\n")
end

function Serializer.ToJSON(value: any): (boolean, string)
	local ok, result = pcall(HttpService.JSONEncode, HttpService, value)
	if ok then
		return true, result
	end
	return false, tostring(result)
end

return Serializer
end

-- ===== Schema (ReplicatedStorage/RuntimeInspectorNet/Schema.luau) =====
__modules.Schema = function()
--[[
	Schema
	Validator argumen remote yang bisa dipakai di server (WAJIB, otoritatif) dan di client
	(opsional, hanya untuk deteksi bug sebelum mengirim). Validasi client TIDAK memberi
	keamanan karena client bisa dimodifikasi; keamanan hanya dari validasi server.

	Contoh:
		local S = Schema
		local AttackSchema = S.Tuple({
			S.OneOf({ "Light", "Heavy" }),
			S.Vector3({ maxMagnitude = 1.01 }),
		})
		local ok, err = S.CheckTuple(AttackSchema, ...)
]]

local Schema = {}

local INF = math.huge
local function isFinite(n: number): boolean
	return n == n and n ~= INF and n ~= -INF
end

type Validator = { kind: string, check: (any, string) -> (boolean, string?) }

local function make(kind: string, check): Validator
	return table.freeze({ kind = kind, check = check })
end

function Schema.Any(): Validator
	return make("any", function()
		return true
	end)
end

function Schema.Nil(): Validator
	return make("nil", function(v, path)
		if v ~= nil then
			return false, path .. ": harus nil"
		end
		return true
	end)
end

function Schema.Boolean(): Validator
	return make("boolean", function(v, path)
		if type(v) ~= "boolean" then
			return false, path .. ": harus boolean, didapat " .. typeof(v)
		end
		return true
	end)
end

-- opts: { min, max, integer, allowNonFinite }
function Schema.Number(opts: any?): Validator
	local o = opts or {}
	return make("number", function(v, path)
		if type(v) ~= "number" then
			return false, path .. ": harus number, didapat " .. typeof(v)
		end
		if not o.allowNonFinite and not isFinite(v) then
			return false, path .. ": NaN/inf tidak diizinkan"
		end
		if o.integer and v % 1 ~= 0 then
			return false, path .. ": harus integer"
		end
		if o.min and v < o.min then
			return false, path .. ": < min " .. o.min
		end
		if o.max and v > o.max then
			return false, path .. ": > max " .. o.max
		end
		return true
	end)
end

-- opts: { maxLen, minLen, pattern }
function Schema.String(opts: any?): Validator
	local o = opts or {}
	local maxLen = o.maxLen or 256
	return make("string", function(v, path)
		if type(v) ~= "string" then
			return false, path .. ": harus string, didapat " .. typeof(v)
		end
		if #v > maxLen then
			return false, path .. ": panjang " .. #v .. " > " .. maxLen
		end
		if o.minLen and #v < o.minLen then
			return false, path .. ": terlalu pendek"
		end
		if utf8.len(v) == nil then
			return false, path .. ": bukan UTF-8 valid"
		end
		if o.pattern and not string.match(v, o.pattern) then
			return false, path .. ": tidak cocok pola " .. o.pattern
		end
		return true
	end)
end

-- opts: { maxMagnitude, minMagnitude }
function Schema.Vector3(opts: any?): Validator
	local o = opts or {}
	return make("Vector3", function(v, path)
		if typeof(v) ~= "Vector3" then
			return false, path .. ": harus Vector3, didapat " .. typeof(v)
		end
		if not (isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)) then
			return false, path .. ": Vector3 berisi NaN/inf"
		end
		local m = v.Magnitude
		if o.maxMagnitude and m > o.maxMagnitude then
			return false, path .. ": magnitude " .. string.format("%.2f", m) .. " > " .. o.maxMagnitude
		end
		if o.minMagnitude and m < o.minMagnitude then
			return false, path .. ": magnitude terlalu kecil"
		end
		return true
	end)
end

function Schema.CFrame(): Validator
	return make("CFrame", function(v, path)
		if typeof(v) ~= "CFrame" then
			return false, path .. ": harus CFrame, didapat " .. typeof(v)
		end
		for _, c in { v:GetComponents() } do
			if not isFinite(c) then
				return false, path .. ": CFrame berisi NaN/inf"
			end
		end
		return true
	end)
end

--[[
	opts: {
		isA = "BasePart",                 -- wajib IsA
		descendantOf = function() return workspace end, -- wajib di bawah root ini
		predicate = function(inst) return true end,
	}
	Catatan: Instance yang hanya ada di client akan tiba sebagai nil di server,
	sehingga gagal di validator ini (perilaku yang memang diinginkan).
]]
function Schema.Instance(opts: any?): Validator
	local o = opts or {}
	return make("Instance", function(v, path)
		if typeof(v) ~= "Instance" then
			return false, path .. ": harus Instance, didapat " .. typeof(v)
		end
		if o.isA and not v:IsA(o.isA) then
			return false, path .. ": harus IsA " .. o.isA .. ", didapat " .. v.ClassName
		end
		if o.descendantOf then
			local root = o.descendantOf()
			if root and not v:IsDescendantOf(root) then
				return false, path .. ": tidak berada di bawah " .. root:GetFullName()
			end
		end
		if o.predicate and not o.predicate(v) then
			return false, path .. ": predicate ditolak"
		end
		return true
	end)
end

function Schema.EnumItem(enumType: Enum): Validator
	return make("EnumItem", function(v, path)
		if typeof(v) ~= "EnumItem" or v.EnumType ~= enumType then
			return false, path .. ": harus " .. tostring(enumType)
		end
		return true
	end)
end

function Schema.OneOf(values: { any }): Validator
	local set = {}
	for _, v in values do
		set[v] = true
	end
	return make("oneOf", function(v, path)
		if v == nil or not set[v] then
			return false, path .. ": nilai tidak diizinkan (" .. tostring(v) .. ")"
		end
		return true
	end)
end

function Schema.Optional(inner: Validator): Validator
	return make("optional", function(v, path)
		if v == nil then
			return true
		end
		return inner.check(v, path)
	end)
end

-- opts: { maxLen, minLen }
function Schema.Array(inner: Validator, opts: any?): Validator
	local o = opts or {}
	local maxLen = o.maxLen or 64
	return make("array", function(v, path)
		if type(v) ~= "table" then
			return false, path .. ": harus array"
		end
		if getmetatable(v) ~= nil then
			return false, path .. ": metatable tidak diizinkan"
		end
		local n = #v
		local count = 0
		for _ in v do
			count += 1
		end
		if count ~= n then
			return false, path .. ": bukan array murni (ada key non-urut)"
		end
		if n > maxLen then
			return false, path .. ": panjang " .. n .. " > " .. maxLen
		end
		if o.minLen and n < o.minLen then
			return false, path .. ": panjang < " .. o.minLen
		end
		for i = 1, n do
			local ok, err = inner.check(v[i], path .. "[" .. i .. "]")
			if not ok then
				return false, err
			end
		end
		return true
	end)
end

-- fields: { name = Validator }, opts: { allowExtra = false }
function Schema.Struct(fields: { [string]: Validator }, opts: any?): Validator
	local o = opts or {}
	return make("struct", function(v, path)
		if type(v) ~= "table" then
			return false, path .. ": harus tabel"
		end
		if getmetatable(v) ~= nil then
			return false, path .. ": metatable tidak diizinkan"
		end
		for key, validator in fields do
			local ok, err = validator.check(v[key], path .. "." .. key)
			if not ok then
				return false, err
			end
		end
		if not o.allowExtra then
			for key in v do
				if type(key) ~= "string" or fields[key] == nil then
					return false, path .. ": key tidak dikenal " .. tostring(key)
				end
			end
		end
		return true
	end)
end

-- Tuple untuk argumen remote. opts: { allowExtra = false }
function Schema.Tuple(items: { Validator }, opts: any?)
	return table.freeze({ kind = "tuple", items = items, allowExtra = (opts and opts.allowExtra) or false })
end

function Schema.Check(validator: Validator, value: any, path: string?): (boolean, string?)
	local ok, a, b = pcall(validator.check, value, path or "$")
	if not ok then
		return false, "validator error: " .. tostring(a)
	end
	return a, b
end

function Schema.CheckTuple(tuple: any, ...): (boolean, string?)
	local n = select("#", ...)
	local expected = #tuple.items
	if n > expected and not tuple.allowExtra then
		return false, "jumlah argumen " .. n .. " > " .. expected
	end
	local packed = table.pack(...)
	for i = 1, expected do
		local ok, err = Schema.Check(tuple.items[i], packed[i], "arg" .. i)
		if not ok then
			return false, err
		end
	end
	return true
end

return Schema
end

-- ===== Net (ReplicatedStorage/RuntimeInspectorNet/Net.luau) =====
__modules.Net = function()
--[[
	Net: wrapper instrumentasi untuk RemoteEvent, UnreliableRemoteEvent, RemoteFunction,
	BindableEvent, dan BindableFunction MILIK GAME ANDA SENDIRI.

	Kenapa wrapper?
	Roblox tidak menyediakan API resmi untuk "menyadap" FireServer/InvokeServer/OnServerInvoke
	yang dipanggil script lain. Satu-satunya cara sah untuk mencatat panggilan KELUAR dan
	callback (RemoteFunction/BindableFunction) adalah memanggilnya lewat modul ini.
	Event MASUK (OnClientEvent/OnServerEvent/BindableEvent.Event) juga bisa diamati pasif
	oleh NetworkMonitor, tetapi argumen keluar hanya terlihat lewat wrapper.

	Pemakaian (client):
		local Net = require(ReplicatedStorage.RuntimeInspectorNet.Net)
		Net.FireServer(remote, "Attack", aimDir)
		Net.FireServerSecure(remote, "Attack", aimDir) -- menambah (seq, sentAt) untuk ReplayGuard
	Pemakaian (server):
		Net.OnServerEvent(remote, function(player, ...) end)
		Net.FireClient(remote, player, data)
]]

local RunService = game:GetService("RunService")

local Serializer = __require("Serializer")

local IS_SERVER = RunService:IsServer()

local Net = {}

Net.Enabled = RunService:IsStudio()
Net.Capacity = 600
Net.Directions = table.freeze({
	ClientToServer = "Client->Server",
	ServerToClient = "Server->Client",
	Local = "Local",
	Return = "Return",
})

local entries = table.create(Net.Capacity)
local head, count, seq = 0, 0, 0
local listeners: { [number]: (any) -> () } = {}
local listenerId = 0
local sequenceByRemote = setmetatable({}, { __mode = "k" })

local function push(entry)
	head = head % Net.Capacity + 1
	entries[head] = entry
	if count < Net.Capacity then
		count += 1
	end
end

local function record(direction: string, remote: Instance, player: Player?, note: string?, ...)
	if not Net.Enabled then
		return
	end
	seq += 1
	local ok, desc = pcall(Serializer.DescribeArgs, ...)
	local entry = {
		seq = seq,
		t = os.clock(),
		st = workspace:GetServerTimeNow(),
		env = IS_SERVER and "server" or "client",
		via = "wrapper",
		direction = direction,
		note = note,
		remote = remote.Name,
		path = Serializer.SafeFullName(remote),
		class = remote.ClassName,
		player = player and player.Name or nil,
		userId = player and player.UserId or nil,
		argc = ok and desc.argc or select("#", ...),
		args = ok and desc.args or {},
		types = ok and desc.types or {},
		issues = ok and desc.issues or { "serializer error: " .. tostring(desc) },
		bytes = ok and desc.bytes or 0,
		_inst = remote, -- referensi lokal; dibuang sebelum ekspor/pengiriman
	}
	push(entry)
	for _, fn in listeners do
		local okCall, err = pcall(fn, entry)
		if not okCall then
			warn("[RuntimeInspector] Net listener error: " .. tostring(err))
		end
	end
end

local function assertClass(inst: any, classNames: { string }, fnName: string)
	if typeof(inst) ~= "Instance" then
		error(fnName .. ": argumen pertama harus Instance", 3)
	end
	for _, c in classNames do
		if inst.ClassName == c then
			return
		end
	end
	error(fnName .. ": " .. inst:GetFullName() .. " bukan " .. table.concat(classNames, "/"), 3)
end

local REMOTE_EVENTS = { "RemoteEvent", "UnreliableRemoteEvent" }

---------------------------------------------------------------- konsumen log

function Net.SetEnabled(enabled: boolean)
	Net.Enabled = enabled
end

function Net.Subscribe(fn: (any) -> ()): () -> ()
	listenerId += 1
	local id = listenerId
	listeners[id] = fn
	return function()
		listeners[id] = nil
	end
end

-- Mengembalikan entri dengan seq > sinceSeq, urut lama ke baru.
function Net.GetLog(sinceSeq: number?): { any }
	local out = {}
	local start = (head - count) % Net.Capacity
	for i = 1, count do
		local e = entries[(start + i - 1) % Net.Capacity + 1]
		if e and e.seq > (sinceSeq or 0) then
			table.insert(out, e)
		end
	end
	return out
end

---------------------------------------------------------------- client -> server

function Net.FireServer(remote: Instance, ...)
	assertClass(remote, REMOTE_EVENTS, "Net.FireServer")
	record(Net.Directions.ClientToServer, remote, nil, nil, ...)
	;(remote :: any):FireServer(...)
end

-- Menambah nomor urut dan waktu server di depan argumen. Pasangkan dengan
-- SecureRemote { replay = true } di server. Ini mencegah replay naif, BUKAN
-- jaminan keamanan: exploiter mengendalikan client dan bisa membuat nomor urut sendiri.
function Net.FireServerSecure(remote: Instance, ...)
	local n = (sequenceByRemote[remote] or 0) + 1
	sequenceByRemote[remote] = n
	Net.FireServer(remote, n, workspace:GetServerTimeNow(), ...)
end

function Net.InvokeServer(remote: Instance, ...)
	assertClass(remote, { "RemoteFunction" }, "Net.InvokeServer")
	record(Net.Directions.ClientToServer, remote, nil, "invoke", ...)
	local result = table.pack(pcall((remote :: any).InvokeServer, remote, ...))
	if not result[1] then
		record(Net.Directions.Return, remote, nil, "invoke error", tostring(result[2]))
		error(result[2], 2)
	end
	record(Net.Directions.Return, remote, nil, "invoke return", table.unpack(result, 2, result.n))
	return table.unpack(result, 2, result.n)
end

function Net.OnClientEvent(remote: Instance, handler: (...any) -> ()): RBXScriptConnection
	assertClass(remote, REMOTE_EVENTS, "Net.OnClientEvent")
	return (remote :: any).OnClientEvent:Connect(function(...)
		record(Net.Directions.ServerToClient, remote, nil, nil, ...)
		handler(...)
	end)
end

-- Server sebaiknya tidak memakai InvokeClient (client bisa tidak pernah membalas).
function Net.SetClientInvoke(remote: Instance, handler: (...any) -> ...any)
	assertClass(remote, { "RemoteFunction" }, "Net.SetClientInvoke")
	;(remote :: any).OnClientInvoke = function(...)
		record(Net.Directions.ServerToClient, remote, nil, "invoke", ...)
		local r = table.pack(handler(...))
		record(Net.Directions.Return, remote, nil, "invoke return", table.unpack(r, 1, r.n))
		return table.unpack(r, 1, r.n)
	end
end

---------------------------------------------------------------- server

local function requireServer(fnName: string)
	if not IS_SERVER then
		error(fnName .. " hanya boleh dipanggil dari server", 3)
	end
end

function Net.OnServerEvent(remote: Instance, handler: (Player, ...any) -> ()): RBXScriptConnection
	requireServer("Net.OnServerEvent")
	assertClass(remote, REMOTE_EVENTS, "Net.OnServerEvent")
	return (remote :: any).OnServerEvent:Connect(function(player, ...)
		record(Net.Directions.ClientToServer, remote, player, nil, ...)
		handler(player, ...)
	end)
end

function Net.SetServerInvoke(remote: Instance, handler: (Player, ...any) -> ...any)
	requireServer("Net.SetServerInvoke")
	assertClass(remote, { "RemoteFunction" }, "Net.SetServerInvoke")
	;(remote :: any).OnServerInvoke = function(player, ...)
		record(Net.Directions.ClientToServer, remote, player, "invoke", ...)
		local r = table.pack(handler(player, ...))
		record(Net.Directions.Return, remote, player, "invoke return", table.unpack(r, 1, r.n))
		return table.unpack(r, 1, r.n)
	end
end

function Net.FireClient(remote: Instance, player: Player, ...)
	requireServer("Net.FireClient")
	assertClass(remote, REMOTE_EVENTS, "Net.FireClient")
	record(Net.Directions.ServerToClient, remote, player, nil, ...)
	;(remote :: any):FireClient(player, ...)
end

function Net.FireAllClients(remote: Instance, ...)
	requireServer("Net.FireAllClients")
	assertClass(remote, REMOTE_EVENTS, "Net.FireAllClients")
	record(Net.Directions.ServerToClient, remote, nil, "all clients", ...)
	;(remote :: any):FireAllClients(...)
end

---------------------------------------------------------------- bindable (lokal satu environment)

function Net.Fire(bindable: Instance, ...)
	assertClass(bindable, { "BindableEvent" }, "Net.Fire")
	record(Net.Directions.Local, bindable, nil, "fire", ...)
	;(bindable :: any):Fire(...)
end

function Net.OnEvent(bindable: Instance, handler: (...any) -> ()): RBXScriptConnection
	assertClass(bindable, { "BindableEvent" }, "Net.OnEvent")
	return (bindable :: any).Event:Connect(handler)
end

function Net.Invoke(bindable: Instance, ...)
	assertClass(bindable, { "BindableFunction" }, "Net.Invoke")
	record(Net.Directions.Local, bindable, nil, "invoke", ...)
	local r = table.pack((bindable :: any):Invoke(...))
	record(Net.Directions.Return, bindable, nil, "invoke return", table.unpack(r, 1, r.n))
	return table.unpack(r, 1, r.n)
end

function Net.SetInvoke(bindable: Instance, handler: (...any) -> ...any)
	assertClass(bindable, { "BindableFunction" }, "Net.SetInvoke")
	;(bindable :: any).OnInvoke = handler
end

return Net
end

-- ===== Config (ServerStorage/RuntimeInspector/Shared/Config.luau) =====
__modules.Config = function()
--[[
	Config (shared, NON-RAHASIA)
	Modul ini ikut di-clone ke client admin. Jangan menaruh UserId admin, damage senjata,
	URL webhook, atau data sensitif lain di sini: itu ada di ServerData/ServerConfig.
]]

return table.freeze({
	Version = "1.0.0",
	LogPrefix = "[RuntimeInspector]",
	ToggleKey = Enum.KeyCode.F6,

	Scan = {
		FrameBudgetMs = 2, -- waktu CPU maks per frame untuk traversal besar
		MaxNodes = 250000, -- batas keras jumlah Instance per scan
		SearchLimit = 400,
	},

	Monitor = {
		QueueMax = 6000, -- antrean DescendantAdded sebelum diproses; lebih dari ini dibuang (dihitung)
		ProcessBudgetMs = 1.5,
		RingSize = 2500,
		MaxWatchedInstances = 1500, -- batas Instance yang dipasangi property watcher
		-- Kelas yang diberi perhatian khusus saat muncul selama gameplay
		WatchedClasses = {
			"Part", "MeshPart", "Model", "Attachment", "WeldConstraint", "Motor6D",
			"LinearVelocity", "VectorForce", "BodyVelocity", "BodyGyro", "BodyPosition",
			"AlignPosition", "ParticleEmitter", "Trail", "Beam", "Sound", "Highlight",
			"ProximityPrompt", "Tool", "Humanoid",
		},
		-- Properti yang dipantau via GetPropertyChangedSignal (berdasarkan IsA).
		-- Catatan: perubahan CFrame/Position akibat simulasi fisika TIDAK memicu sinyal ini.
		WatchedProperties = {
			BasePart = { "Size", "Anchored", "CanCollide", "Transparency", "Massless" },
			Humanoid = { "WalkSpeed", "JumpPower", "JumpHeight", "Health", "MaxHealth", "PlatformStand" },
			LinearVelocity = { "VectorVelocity", "MaxForce", "Enabled" },
			VectorForce = { "Force", "Enabled" },
			BodyVelocity = { "Velocity", "MaxForce" },
			BodyGyro = { "MaxTorque", "CFrame" },
			ParticleEmitter = { "Enabled", "Rate", "Texture" },
			Sound = { "SoundId", "Playing" },
			Highlight = { "Enabled", "Adornee" },
			ProximityPrompt = { "Enabled", "MaxActivationDistance", "HoldDuration" },
			Tool = { "Enabled" },
			Motor6D = { "Part0", "Part1", "Enabled" },
			WeldConstraint = { "Part0", "Part1", "Enabled" },
		},
		MonitorPlayerGuiOnClient = true,
	},

	Character = {
		SampleInterval = 0.1, -- sampling posisi HumanoidRootPart
		MoveDirectionThrottle = 0.15,
		RunningSpeedDelta = 1.5, -- Humanoid.Running dicatat bila perubahan speed > nilai ini
		CombatAttributes = { "Combo", "ComboIndex", "Stunned", "Stun", "Cooldown", "Attacking", "Blocking", "IFrames" },
		HitboxNamePatterns = { "hitbox" }, -- dicocokkan lowercase
		HitboxTag = "Hitbox",
		EffectClasses = { "ParticleEmitter", "Trail", "Beam", "Sound", "Highlight", "Explosion" },
		EffectRadius = 30,
		AttackInputs = { "MouseButton1", "E", "Q", "R", "F" }, -- nama KeyCode/UserInputType yang dianggap "attack"
		RingSize = 2000,
		Correlation = { Window = 0.6, PreWindow = 0.08, MaxChains = 60 },
	},

	Network = {
		RingSize = 2000,
		PassiveListen = true,
		-- Jeda sebelum listener pasif dipasang ke remote baru. Remote yang belum punya
		-- listener mengantrekan event; listener pertama akan menerima antrean itu.
		-- Jeda ini memberi kesempatan script game terhubung lebih dulu.
		PassiveAttachDelay = 2,
		MaxLoggedPerRemotePerSecond = 30,
		DefaultRateLimit = 25, -- panggilan/detik per remote sebelum dianggap anomali
		PerRemoteRateLimit = {}, -- [remoteName] = number
	},

	Scripts = {
		-- require() menjalankan ModuleScript bila belum pernah di-require. Itu bisa memicu
		-- efek samping. Karena itu probing default MATI dan butuh allowlist eksplisit.
		AllowRequireProbe = false,
		ProbeTimeout = 3,
		ProbeAllowlist = {}, -- daftar FullName, contoh "ReplicatedStorage.Modules.Util"
	},

	Anomaly = {
		Capacity = 600,
		DedupeWindow = 30,
		AllowedWalkSpeeds = { 16 },
		MaxWalkSpeed = 32,
		MaxJumpPower = 60,
		MaxJumpHeight = 12,
		TeleportDistance = 60,
		SuspiciousCharacterClasses = {
			"BodyVelocity", "BodyGyro", "BodyPosition", "BodyAngularVelocity", "BodyThrust",
			"LinearVelocity", "AngularVelocity", "VectorForce", "AlignPosition", "AlignOrientation",
		},
		AllowedMoverNames = {}, -- nama mover milik game sendiri, contoh { DashVelocity = true }
		MaxHitboxSize = Vector3.new(14, 14, 14),
		ProtectedAttributes = { "Stunned", "Cooldown", "Damage", "Level", "Coins" },
		ErrorBurstCount = 5,
		ErrorBurstWindow = 10,
		UnknownAssetSeverity = "MEDIUM",
	},

	Verify = {
		ReplicationBatch = 100,
		ReplicationInterval = 1,
		DivergenceInterval = 2,
		DivergenceProperties = { "WalkSpeed", "JumpPower", "JumpHeight", "MaxHealth" },
	},

	UI = {
		RefreshHz = 3,
		RowHeight = 22,
		DetailMaxChars = 16000,
		ExportPageChars = 20000,
	},
})
end

-- ===== Maid (ServerStorage/RuntimeInspector/Shared/Util/Maid.luau) =====
__modules.Maid = function()
--[[
	Maid: pengelola cleanup. Setiap koneksi, Instance, thread, atau fungsi yang
	diberikan ke Maid akan dibersihkan saat Cleanup()/Destroy() dipanggil.
	Dipakai di semua modul untuk mencegah listener menumpuk saat Character respawn.
]]

local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _tasks = {}, _destroyed = false }, Maid)
end

function Maid:Give(item: any): any
	if self._destroyed then
		Maid._cleanTask(item)
		return item
	end
	table.insert(self._tasks, item)
	return item
end

-- Menyimpan item dengan key; item lama pada key yang sama dibersihkan dulu.
function Maid:Set(key: any, item: any)
	self._keyed = self._keyed or {}
	local old = self._keyed[key]
	if old ~= nil and old ~= item then
		Maid._cleanTask(old)
	end
	self._keyed[key] = item
	if self._destroyed and item ~= nil then
		Maid._cleanTask(item)
		self._keyed[key] = nil
	end
end

function Maid:Remove(key: any)
	if self._keyed and self._keyed[key] ~= nil then
		Maid._cleanTask(self._keyed[key])
		self._keyed[key] = nil
	end
end

function Maid._cleanTask(item: any)
	local t = typeof(item)
	if t == "RBXScriptConnection" then
		item:Disconnect()
	elseif t == "function" then
		local ok, err = pcall(item)
		if not ok then
			warn("[RuntimeInspector] Maid cleanup error: " .. tostring(err))
		end
	elseif t == "Instance" then
		pcall(item.Destroy, item)
	elseif t == "thread" then
		if coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif t == "table" then
		if type(item.Destroy) == "function" then
			pcall(item.Destroy, item)
		elseif type(item.Disconnect) == "function" then
			pcall(item.Disconnect, item)
		end
	end
end

function Maid:Cleanup()
	local tasks = self._tasks
	self._tasks = {}
	for i = #tasks, 1, -1 do
		Maid._cleanTask(tasks[i])
	end
	if self._keyed then
		local keyed = self._keyed
		self._keyed = {}
		for _, item in keyed do
			Maid._cleanTask(item)
		end
	end
end

function Maid:Destroy()
	self:Cleanup()
	self._destroyed = true
end

return Maid
end

-- ===== Signal (ServerStorage/RuntimeInspector/Shared/Util/Signal.luau) =====
__modules.Signal = function()
--[[
	Signal ringan berbasis tabel (tanpa BindableEvent) agar tabel tidak di-deep-copy
	dan metatable tidak hilang. Listener dipanggil sinkron dalam pcall.
]]

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _listeners = {}, _nextId = 0 }, Signal)
end

function Signal:Connect(fn: (...any) -> ())
	self._nextId += 1
	local id = self._nextId
	self._listeners[id] = fn
	local listeners = self._listeners
	return {
		Connected = true,
		Disconnect = function(conn)
			conn.Connected = false
			listeners[id] = nil
		end,
	}
end

function Signal:Fire(...)
	for _, fn in self._listeners do
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[RuntimeInspector] Signal listener error: " .. tostring(err))
		end
	end
end

function Signal:DisconnectAll()
	table.clear(self._listeners)
end

Signal.Destroy = Signal.DisconnectAll

return Signal
end

-- ===== RingBuffer (ServerStorage/RuntimeInspector/Shared/Util/RingBuffer.luau) =====
__modules.RingBuffer = function()
--[[
	RingBuffer: penyimpanan log berukuran tetap. Entri tertua otomatis tertimpa,
	sehingga memori tidak tumbuh tanpa batas selama sesi panjang.
	Setiap entri mendapat nomor urut (seq) untuk konsumsi inkremental (GetSince).
]]

local RingBuffer = {}
RingBuffer.__index = RingBuffer

function RingBuffer.new(capacity: number)
	assert(capacity > 0, "capacity harus > 0")
	return setmetatable({
		capacity = capacity,
		items = table.create(capacity),
		seqs = table.create(capacity),
		head = 0,
		count = 0,
		total = 0,
	}, RingBuffer)
end

function RingBuffer:Push(item: any): number
	self.head = self.head % self.capacity + 1
	self.total += 1
	self.items[self.head] = item
	self.seqs[self.head] = self.total
	if self.count < self.capacity then
		self.count += 1
	end
	return self.total
end

-- Urut dari lama ke baru.
function RingBuffer:ToArray(): { any }
	local out = table.create(self.count)
	local start = (self.head - self.count) % self.capacity
	for i = 1, self.count do
		out[i] = self.items[(start + i - 1) % self.capacity + 1]
	end
	return out
end

function RingBuffer:GetSince(seq: number, limit: number?): ({ any }, number)
	local out = {}
	local start = (self.head - self.count) % self.capacity
	local last = seq
	for i = 1, self.count do
		local idx = (start + i - 1) % self.capacity + 1
		if self.seqs[idx] > seq then
			table.insert(out, self.items[idx])
			last = self.seqs[idx]
			if limit and #out >= limit then
				break
			end
		end
	end
	return out, last
end

function RingBuffer:Clear()
	table.clear(self.items)
	table.clear(self.seqs)
	self.head = 0
	self.count = 0
end

return RingBuffer
end

-- ===== Scheduler (ServerStorage/RuntimeInspector/Shared/Util/Scheduler.luau) =====
__modules.Scheduler = function()
--[[
	Scheduler: traversal DataModel dengan batas waktu per frame (frame budget).
	Traversal memakai stack eksplisit (bukan rekursi) sehingga tidak ada risiko
	stack overflow / infinite recursion pada pohon Instance yang sangat dalam.
]]

local Scheduler = {}

-- Mengembalikan fungsi yang memanggil task.wait() bila budget frame habis.
function Scheduler.Budget(ms: number): () -> ()
	local limit = ms / 1000
	local start = os.clock()
	return function()
		if os.clock() - start >= limit then
			task.wait()
			start = os.clock()
		end
	end
end

--[[
	Walk(root, visit, opts)
	visit(inst, depth) -> return false untuk melewati subtree inst.
	opts = { budgetMs = 2, maxNodes = 200000, skip = function(inst) -> bool, includeRoot = true }
	Return: jumlah node dikunjungi, truncated(bool)
	HARUS dipanggil dari thread yang boleh yield (task.spawn).
]]
function Scheduler.Walk(root: Instance, visit: (Instance, number) -> boolean?, opts: any?): (number, boolean)
	local o = opts or {}
	local step = Scheduler.Budget(o.budgetMs or 2)
	local maxNodes = o.maxNodes or 200000
	local skip = o.skip
	local stack = { root }
	local depths = { 0 }
	local visited = 0
	local includeRoot = o.includeRoot ~= false

	while #stack > 0 do
		local inst = table.remove(stack)
		local depth = table.remove(depths)
		if inst and inst.Parent ~= nil or inst == game or (inst == root) then
			if not (skip and skip(inst)) then
				local descend = true
				if inst ~= root or includeRoot then
					visited += 1
					local ok, result = pcall(visit, inst, depth)
					if ok and result == false then
						descend = false
					end
				end
				if visited >= maxNodes then
					return visited, true
				end
				if descend then
					local okChildren, children = pcall(inst.GetChildren, inst)
					if okChildren then
						for i = #children, 1, -1 do
							table.insert(stack, children[i])
							table.insert(depths, depth + 1)
						end
					end
				end
			end
		end
		step()
	end
	return visited, false
end

return Scheduler
end

-- ===== InstanceInfo (ServerStorage/RuntimeInspector/Shared/Core/InstanceInfo.luau) =====
__modules.InstanceInfo = function()
--[[
	InstanceInfo
	Membaca informasi Instance secara aman (semua akses properti dibungkus pcall)
	dan mengklasifikasikan visibilitasnya.

	Yang TIDAK tersedia lewat API resmi dan karena itu TIDAK diklaim:
	- Waktu pembuatan Instance (yang dicatat adalah "firstSeen": kapan inspector melihatnya).
	- Script yang membuat atau mengubah Instance.
	- Source/bytecode Script dan LocalScript (Source adalah ProtectedString; hanya
	  plugin / Command Bar Studio yang bisa membacanya).
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Serializer = __require("Serializer")

local IS_SERVER = RunService:IsServer()

local InstanceInfo = {}

InstanceInfo.Visibility = table.freeze({
	SERVER_ONLY = "SERVER_ONLY", -- ServerStorage / ServerScriptService: tidak pernah direplikasi
	REPLICATED = "REPLICATED", -- container yang direplikasi ke client (diamati dari server)
	OWNER_ONLY = "OWNER_ONLY", -- PlayerGui: hanya direplikasi ke pemilik
	SERVER_UNCLASSIFIED = "SERVER_UNCLASSIFIED",
	CLIENT_UNVERIFIED = "CLIENT_UNVERIFIED", -- terlihat client, belum dicek ke server
	CLIENT_REPLICATED = "CLIENT_REPLICATED", -- terverifikasi: Instance juga ada di server
	CLIENT_LOCAL = "CLIENT_LOCAL", -- terverifikasi: hanya ada di client (dibuat lokal)
})

-- Diklasifikasikan berdasarkan ClassName service (Name service bisa diganti).
InstanceInfo.ServerOnlyServices = table.freeze({
	ServerStorage = true,
	ServerScriptService = true,
})

InstanceInfo.ReplicatedServices = table.freeze({
	Workspace = true,
	ReplicatedStorage = true,
	ReplicatedFirst = true,
	Lighting = true,
	SoundService = true,
	Teams = true,
	Players = true,
	StarterGui = true,
	StarterPack = true,
	StarterPlayer = true,
	TextChatService = true,
	Chat = true,
	MaterialService = true,
})

-- Properti penting per kelas (dicek dengan IsA, urutan umum -> spesifik).
InstanceInfo.PropertySchema = {
	{ "Instance", { "Archivable" } },
	{ "PVInstance", {} },
	{ "BasePart", { "Anchored", "CanCollide", "CanTouch", "CanQuery", "Massless", "Transparency", "Size", "Position", "Orientation", "Material", "Color", "AssemblyLinearVelocity" } },
	{ "MeshPart", { "MeshId", "TextureID" } },
	{ "Model", { "PrimaryPart", "WorldPivot", "ModelStreamingMode" } },
	{ "Humanoid", { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "UseJumpPower", "AutoRotate", "HipHeight", "PlatformStand", "Sit", "RigType", "MoveDirection" } },
	{ "BaseScript", { "Enabled", "RunContext" } },
	{ "Sound", { "SoundId", "Volume", "Playing", "Looped", "PlaybackSpeed", "TimeLength" } },
	{ "Animation", { "AnimationId" } },
	{ "Tool", { "Enabled", "RequiresHandle", "CanBeDropped", "ManualActivationOnly", "TextureId", "ToolTip" } },
	{ "ProximityPrompt", { "Enabled", "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "RequiresLineOfSight", "KeyboardKeyCode" } },
	{ "ParticleEmitter", { "Enabled", "Texture", "Rate" } },
	{ "Trail", { "Enabled", "Texture", "Lifetime" } },
	{ "Beam", { "Enabled", "Texture" } },
	{ "Highlight", { "Enabled", "Adornee", "DepthMode" } },
	{ "Attachment", { "Position", "WorldPosition" } },
	{ "JointInstance", { "Part0", "Part1", "C0", "C1", "Enabled" } },
	{ "WeldConstraint", { "Part0", "Part1", "Enabled" } },
	{ "Constraint", { "Enabled", "Attachment0", "Attachment1" } },
	{ "LinearVelocity", { "VectorVelocity", "MaxForce" } },
	{ "VectorForce", { "Force", "RelativeTo" } },
	{ "BodyVelocity", { "Velocity", "MaxForce", "P" } },
	{ "BodyGyro", { "MaxTorque", "CFrame", "P", "D" } },
	{ "LayerCollector", { "Enabled", "ResetOnSpawn" } },
	{ "GuiObject", { "Visible", "Size", "Position", "ZIndex" } },
	{ "ImageLabel", { "Image" } },
	{ "ImageButton", { "Image" } },
	{ "Decal", { "Texture", "Transparency" } },
	{ "ValueBase", { "Value" } },
	{ "Light", { "Enabled", "Brightness" } },
	{ "Player", { "UserId", "DisplayName", "Team", "AccountAge" } },
	{ "Team", { "TeamColor", "AutoAssignable" } },
	{ "Camera", { "CFrame", "FieldOfView", "CameraType" } },
	{ "Lighting", { "ClockTime", "Brightness" } },
	{ "Workspace", { "StreamingEnabled", "Gravity" } },
	{ "Animator", {} },
	{ "RemoteEvent", {} },
}

local function read(inst: Instance, prop: string): (boolean, any)
	return pcall(function()
		return (inst :: any)[prop]
	end)
end
InstanceInfo.Read = read

-- Service paling atas (anak langsung dari game) untuk inst.
function InstanceInfo.TopService(inst: Instance): Instance?
	local cur: Instance? = inst
	while cur and cur.Parent ~= game do
		cur = cur.Parent
	end
	return cur
end

function InstanceInfo.IsUnder(inst: Instance, ancestor: Instance?): boolean
	return ancestor ~= nil and (inst == ancestor or inst:IsDescendantOf(ancestor))
end

-- Klasifikasi visibilitas statis (tanpa verifikasi jaringan).
function InstanceInfo.StaticVisibility(inst: Instance): string
	local V = InstanceInfo.Visibility
	if not IS_SERVER then
		return V.CLIENT_UNVERIFIED
	end
	local top = InstanceInfo.TopService(inst)
	if not top then
		return V.SERVER_UNCLASSIFIED
	end
	if InstanceInfo.ServerOnlyServices[top.ClassName] then
		return V.SERVER_ONLY
	end
	if top.ClassName == "Players" then
		local player = inst:FindFirstAncestorOfClass("Player")
		if player then
			local gui = player:FindFirstChildOfClass("PlayerGui")
			if gui and InstanceInfo.IsUnder(inst, gui) then
				return V.OWNER_ONLY
			end
		end
		return V.REPLICATED
	end
	if InstanceInfo.ReplicatedServices[top.ClassName] then
		return V.REPLICATED
	end
	return V.SERVER_UNCLASSIFIED
end

function InstanceInfo.Enabled(inst: Instance): boolean?
	local ok, v = read(inst, "Enabled")
	if ok and type(v) == "boolean" then
		return v
	end
	return nil
end

function InstanceInfo.Attributes(inst: Instance): { [string]: string }
	local out = {}
	local ok, attrs = pcall(inst.GetAttributes, inst)
	if ok then
		for k, v in attrs do
			out[k] = Serializer.Summarize((Serializer.Describe(v)), 120)
		end
	end
	return out
end

function InstanceInfo.Tags(inst: Instance): { string }
	local ok, tags = pcall(inst.GetTags, inst)
	return ok and tags or {}
end

function InstanceInfo.PropertyList(inst: Instance): { string }
	local list, seen = {}, {}
	for _, entry in InstanceInfo.PropertySchema do
		local okIsA, isA = pcall(inst.IsA, inst, entry[1])
		if okIsA and isA then
			for _, prop in entry[2] do
				if not seen[prop] then
					seen[prop] = true
					table.insert(list, prop)
				end
			end
		end
	end
	return list
end

-- Properti penting sebagai pasangan { name, value(string) }.
function InstanceInfo.Properties(inst: Instance): { { any } }
	local out = {}
	for _, prop in InstanceInfo.PropertyList(inst) do
		local ok, v = read(inst, prop)
		if ok then
			table.insert(out, { prop, Serializer.Summarize((Serializer.Describe(v)), 160) })
		else
			table.insert(out, { prop, "<tidak dapat dibaca: " .. string.sub(tostring(v), 1, 80) .. ">" })
		end
	end
	return out
end

-- Ringkasan untuk baris tree (murah).
function InstanceInfo.Summary(inst: Instance): { [string]: any }
	local okChildren, children = pcall(inst.GetChildren, inst)
	return {
		name = inst.Name,
		class = inst.ClassName,
		childCount = okChildren and #children or 0,
		enabled = InstanceInfo.Enabled(inst),
	}
end

-- Detail lengkap (untuk panel detail; lebih mahal, panggil hanya saat dipilih).
function InstanceInfo.Details(inst: Instance, extra: { [string]: any }?): { [string]: any }
	local okChildren, children = pcall(inst.GetChildren, inst)
	local descendantCount: any = "n/a"
	local top = InstanceInfo.TopService(inst)
	if inst.Parent ~= game and inst ~= game then
		local okD, desc = pcall(inst.GetDescendants, inst)
		descendantCount = okD and #desc or "n/a"
	else
		descendantCount = "(service: lihat Overview)"
	end
	local d = {
		name = inst.Name,
		class = inst.ClassName,
		fullName = Serializer.SafeFullName(inst),
		parent = inst.Parent and Serializer.SafeFullName(inst.Parent) or "nil",
		service = top and top.ClassName or "?",
		childCount = okChildren and #children or 0,
		descendantCount = descendantCount,
		enabled = InstanceInfo.Enabled(inst),
		attributes = InstanceInfo.Attributes(inst),
		tags = InstanceInfo.Tags(inst),
		properties = InstanceInfo.Properties(inst),
		visibility = InstanceInfo.StaticVisibility(inst),
		env = IS_SERVER and "server" or "client",
		creationTime = "tidak tersedia via API resmi (lihat firstSeen)",
	}
	if extra then
		for k, v in extra do
			d[k] = v
		end
	end
	return d
end

-- Teks detail siap tampil.
function InstanceInfo.FormatDetails(d: { [string]: any }): string
	local lines = {
		"Name        : " .. tostring(d.name),
		"ClassName   : " .. tostring(d.class),
		"FullName    : " .. tostring(d.fullName),
		"Parent      : " .. tostring(d.parent),
		"Service     : " .. tostring(d.service),
		"Environment : " .. tostring(d.env),
		"Visibility  : " .. tostring(d.visibility),
		"Enabled     : " .. (d.enabled == nil and "n/a" or tostring(d.enabled)),
		"Children    : " .. tostring(d.childCount),
		"Descendants : " .. tostring(d.descendantCount),
		"FirstSeen   : " .. tostring(d.firstSeen or "-"),
		"Runtime     : " .. tostring(d.runtimeSpawned and "YA (muncul setelah baseline scan)" or "tidak / baseline"),
		"Created     : " .. tostring(d.creationTime),
		"",
		"[Tags]",
	}
	if d.tags and #d.tags > 0 then
		table.insert(lines, "  " .. table.concat(d.tags, ", "))
	else
		table.insert(lines, "  (none)")
	end
	table.insert(lines, "")
	table.insert(lines, "[Attributes]")
	local hasAttr = false
	if d.attributes then
		local keys = {}
		for k in d.attributes do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in keys do
			hasAttr = true
			table.insert(lines, "  " .. k .. " = " .. d.attributes[k])
		end
	end
	if not hasAttr then
		table.insert(lines, "  (none)")
	end
	table.insert(lines, "")
	table.insert(lines, "[Properties]")
	for _, pair in d.properties or {} do
		table.insert(lines, "  " .. pair[1] .. " = " .. tostring(pair[2]))
	end
	if d.note then
		table.insert(lines, "")
		table.insert(lines, "[Catatan]")
		table.insert(lines, "  " .. tostring(d.note))
	end
	return table.concat(lines, "\n")
end

-- Untuk client: shortcut LocalPlayer containers.
function InstanceInfo.LocalPlayerRoots(): { { any } }
	local roots = {}
	local lp = Players.LocalPlayer
	if not lp then
		return roots
	end
	table.insert(roots, { lp, "LocalPlayer" })
	local gui = lp:FindFirstChildOfClass("PlayerGui")
	if gui then
		table.insert(roots, { gui, "PlayerGui" })
	end
	local ps = lp:FindFirstChildOfClass("PlayerScripts")
	if ps then
		table.insert(roots, { ps, "PlayerScripts" })
	end
	local bp = lp:FindFirstChildOfClass("Backpack")
	if bp then
		table.insert(roots, { bp, "Backpack" })
	end
	if lp.Character then
		table.insert(roots, { lp.Character, "Character" })
	end
	return roots
end

return InstanceInfo
end

-- ===== AssetCatalog (ServerStorage/RuntimeInspector/Shared/Core/AssetCatalog.luau) =====
__modules.AssetCatalog = function()
--[[
	AssetCatalog
	Peta properti yang menyimpan referensi aset, dicek terhadap Roblox API Dump:
	- Properti ContentId biasa (Read security: None) dibaca langsung.
	- SurfaceAppearance.ColorMap/NormalMap/MetalnessMap/RoughnessMap ber-security
	  PluginSecurity (tidak bisa dibaca script runtime). Versi *Content-nya
	  (ColorMapContent, dll.) dapat dibaca, lalu diambil Uri-nya.
	- SEMUA map MaterialVariant (termasuk *Content) ber-security PluginSecurity.
	  Runtime hanya bisa mencatat keberadaan MaterialVariant; ID-nya hanya bisa
	  diambil Source Analyzer plugin di Studio.
]]

local AssetCatalog = {}

AssetCatalog.Categories = table.freeze({
	"AnimationId", "SoundId", "MeshId", "TextureId", "Image", "Decal",
	"ShirtTemplate", "PantsTemplate", "Video", "ParticleTexture",
	"SurfaceAppearance", "MaterialVariant", "Sky", "Other",
})

-- { className (IsA), property, category, isContent }
AssetCatalog.Map = {
	{ "Animation", "AnimationId", "AnimationId" },
	{ "Sound", "SoundId", "SoundId" },
	{ "AudioPlayer", "Asset", "SoundId" },
	{ "MeshPart", "MeshId", "MeshId" },
	{ "MeshPart", "TextureID", "TextureId" },
	{ "FileMesh", "MeshId", "MeshId" }, -- SpecialMesh mewarisi FileMesh
	{ "FileMesh", "TextureId", "TextureId" },
	{ "Decal", "Texture", "Decal" }, -- Texture (kelas) mewarisi Decal
	{ "ImageLabel", "Image", "Image" },
	{ "ImageButton", "Image", "Image" },
	{ "ImageButton", "HoverImage", "Image" },
	{ "ImageButton", "PressedImage", "Image" },
	{ "BackpackItem", "TextureId", "Image" }, -- ikon Tool
	{ "Shirt", "ShirtTemplate", "ShirtTemplate" },
	{ "Pants", "PantsTemplate", "PantsTemplate" },
	{ "ShirtGraphic", "Graphic", "ShirtTemplate" },
	{ "VideoFrame", "Video", "Video" },
	{ "ParticleEmitter", "Texture", "ParticleTexture" },
	{ "Beam", "Texture", "ParticleTexture" },
	{ "Trail", "Texture", "ParticleTexture" },
	{ "SurfaceAppearance", "ColorMapContent", "SurfaceAppearance", true },
	{ "SurfaceAppearance", "NormalMapContent", "SurfaceAppearance", true },
	{ "SurfaceAppearance", "MetalnessMapContent", "SurfaceAppearance", true },
	{ "SurfaceAppearance", "RoughnessMapContent", "SurfaceAppearance", true },
	{ "Sky", "SkyboxBk", "Sky" },
	{ "Sky", "SkyboxDn", "Sky" },
	{ "Sky", "SkyboxFt", "Sky" },
	{ "Sky", "SkyboxLf", "Sky" },
	{ "Sky", "SkyboxRt", "Sky" },
	{ "Sky", "SkyboxUp", "Sky" },
	{ "Sky", "SunTextureId", "Sky" },
	{ "Sky", "MoonTextureId", "Sky" },
}

-- Peta ClassName -> daftar entri, dibangun malas (cache per ClassName).
local byClassCache: { [string]: { any } } = {}

local function entriesFor(inst: Instance): { any }
	local cached = byClassCache[inst.ClassName]
	if cached then
		return cached
	end
	local list = {}
	for _, e in AssetCatalog.Map do
		local ok, isA = pcall(inst.IsA, inst, e[1])
		if ok and isA then
			table.insert(list, e)
		end
	end
	byClassCache[inst.ClassName] = list
	return list
end

--[[
	Parse(str) -> key, kind
	kind: "asset"     ID aset ter-upload (rbxassetid://, ?id=, angka murni, rbxthumb)
	      "engine"    rbxasset:// konten bawaan klien Roblox (bukan aset upload)
	      "url"       http(s) URL lain
	      "other"
]]
function AssetCatalog.Parse(s: any): (string?, string?)
	if type(s) ~= "string" or s == "" then
		return nil, nil
	end
	local id = string.match(s, "rbxassetid://(%d+)")
		or string.match(s, "[?&][iI][dD]=(%d+)")
		or string.match(s, "^%s*(%d+)%s*$")
	if id then
		return id, "asset"
	end
	if string.match(s, "^rbxasset://") then
		return s, "engine"
	end
	if string.match(s, "^https?://") then
		return s, "url"
	end
	return s, "other"
end

local function contentUri(value: any): string?
	if typeof(value) ~= "Content" then
		return nil
	end
	local ok, uri = pcall(function()
		return (value :: any).Uri
	end)
	if ok and type(uri) == "string" and uri ~= "" then
		return uri
	end
	return nil
end

--[[
	Scan(inst) -> array referensi { category, property, raw, key, kind }
	Mengembalikan juga entri "unreadable" bila properti gagal dibaca.
]]
function AssetCatalog.Scan(inst: Instance): { any }
	local out = {}
	local entries = entriesFor(inst)
	for _, e in entries do
		local prop, category, isContent = e[2], e[3], e[4]
		local ok, value = pcall(function()
			return (inst :: any)[prop]
		end)
		if ok then
			local raw = if isContent then contentUri(value) else value
			local key, kind = AssetCatalog.Parse(raw)
			if key then
				table.insert(out, { category = category, property = prop, raw = raw, key = key, kind = kind })
			end
		else
			table.insert(out, { category = category, property = prop, unreadable = true, error = tostring(value) })
		end
	end
	if inst.ClassName == "MaterialVariant" then
		table.insert(out, {
			category = "MaterialVariant",
			property = "(ColorMap/NormalMap/...)",
			unreadable = true,
			error = "PluginSecurity: map MaterialVariant hanya bisa dibaca plugin Studio (Source Analyzer)",
		})
	end
	return out
end

function AssetCatalog.HasAssetProperties(inst: Instance): boolean
	return #entriesFor(inst) > 0 or inst.ClassName == "MaterialVariant"
end

return AssetCatalog
end

-- ===== Findings (ServerStorage/RuntimeInspector/Shared/Core/Findings.luau) =====
__modules.Findings = function()
--[[
	Findings: penyimpanan temuan anomali/keamanan dengan deduplikasi.
	Temuan dengan rule + path yang sama dalam DedupeWindow digabung (count bertambah)
	agar log tidak banjir ketika anomali terjadi tiap frame.

	Skor risiko adalah HEURISTIK sistem ini (bukan standar industri):
	score = min(100, sum(weight(severity) * (1 + log2(count))))
]]

local Signal = __require("Signal")
local RingBuffer = __require("RingBuffer")

local Findings = {}
Findings.__index = Findings

Findings.Severity = table.freeze({ LOW = "LOW", MEDIUM = "MEDIUM", HIGH = "HIGH", CRITICAL = "CRITICAL", INFO = "INFO" })
Findings.Rank = table.freeze({ INFO = 0, LOW = 1, MEDIUM = 2, HIGH = 3, CRITICAL = 4 })
Findings.Weight = table.freeze({ INFO = 0, LOW = 1, MEDIUM = 3, HIGH = 7, CRITICAL = 15 })

function Findings.new(capacity: number?, dedupeWindow: number?)
	local self = setmetatable({
		capacity = capacity or 600,
		dedupeWindow = dedupeWindow or 30,
		list = {}, -- urut waktu dibuat
		byKey = {},
		byId = {},
		nextId = 0,
		changes = RingBuffer.new(2000), -- untuk konsumsi inkremental (streaming)
		Changed = Signal.new(),
	}, Findings)
	return self
end

--[[
	f = {
		severity, rule, object, path, detail, reason, recommendation,
		env = "client"|"server", source = "observed"|"client-reported"|...
	}
]]
function Findings:Report(f: { [string]: any }): { [string]: any }
	local now = os.clock()
	local key = tostring(f.rule) .. "|" .. tostring(f.path or f.object or "?") .. "|" .. tostring(f.env or "")
	local existing = self.byKey[key]
	if existing and now - existing.lastT <= self.dedupeWindow then
		existing.count += 1
		existing.lastT = now
		existing.lastSt = workspace:GetServerTimeNow()
		existing.detail = f.detail or existing.detail
		if (Findings.Rank[f.severity] or 0) > (Findings.Rank[existing.severity] or 0) then
			existing.severity = f.severity
		end
		self.changes:Push(existing)
		self.Changed:Fire(existing, false)
		return existing
	end

	self.nextId += 1
	local entry = {
		id = (f.env or "x") .. ":" .. self.nextId,
		severity = f.severity or "LOW",
		rule = f.rule or "unknown",
		object = f.object or "?",
		path = f.path or f.object or "?",
		detail = f.detail or "",
		reason = f.reason or "",
		recommendation = f.recommendation or "",
		env = f.env or "?",
		source = f.source or "observed",
		player = f.player,
		count = 1,
		firstT = now,
		lastT = now,
		st = workspace:GetServerTimeNow(),
		lastSt = workspace:GetServerTimeNow(),
		clock = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	self.byKey[key] = entry
	self.byId[entry.id] = entry
	table.insert(self.list, entry)
	if #self.list > self.capacity then
		local removed = table.remove(self.list, 1)
		self.byId[removed.id] = nil
		for k, v in self.byKey do
			if v == removed then
				self.byKey[k] = nil
				break
			end
		end
	end
	self.changes:Push(entry)
	self.Changed:Fire(entry, true)
	return entry
end

-- Menyisipkan temuan yang sudah berbentuk entry (misal dari server ke client).
function Findings:Upsert(entry: { [string]: any })
	local existing = self.byId[entry.id]
	if existing then
		for k, v in entry do
			existing[k] = v
		end
		self.Changed:Fire(existing, false)
		return
	end
	self.byId[entry.id] = entry
	table.insert(self.list, entry)
	if #self.list > self.capacity then
		local removed = table.remove(self.list, 1)
		self.byId[removed.id] = nil
	end
	self.Changed:Fire(entry, true)
end

function Findings:List(minSeverity: string?): { any }
	local minRank = Findings.Rank[minSeverity or "INFO"] or 0
	local out = {}
	for _, f in self.list do
		if (Findings.Rank[f.severity] or 0) >= minRank then
			table.insert(out, f)
		end
	end
	table.sort(out, function(a, b)
		local ra, rb = Findings.Rank[a.severity] or 0, Findings.Rank[b.severity] or 0
		if ra ~= rb then
			return ra > rb
		end
		return a.lastT > b.lastT
	end)
	return out
end

function Findings:Counts(): { [string]: number }
	local c = { INFO = 0, LOW = 0, MEDIUM = 0, HIGH = 0, CRITICAL = 0, total = 0 }
	for _, f in self.list do
		c[f.severity] = (c[f.severity] or 0) + 1
		c.total += 1
	end
	return c
end

function Findings.ScoreOf(list: { any }): number
	local score = 0
	for _, f in list do
		local w = Findings.Weight[f.severity] or 0
		score += w * (1 + math.log(math.max(1, f.count or 1), 2))
	end
	return math.min(100, math.floor(score + 0.5))
end

function Findings:RiskScore(): number
	return Findings.ScoreOf(self.list)
end

function Findings:GetSince(seq: number, limit: number?)
	return self.changes:GetSince(seq, limit)
end

function Findings:Clear()
	table.clear(self.list)
	table.clear(self.byKey)
	table.clear(self.byId)
	self.changes:Clear()
end

return Findings
end

-- ===== Timeline (ServerStorage/RuntimeInspector/Shared/Core/Timeline.luau) =====
__modules.Timeline = function()
--[[
	Timeline: urutan kejadian aksi (input, lompat, tool, animasi, remote, efek, hitbox)
	dengan timestamp os.clock() dan workspace:GetServerTimeNow().

	Correlate() mengelompokkan kejadian di sekitar "anchor" (misal input serangan atau
	Tool.Activated) dalam jendela waktu. Ini KORELASI WAKTU, bukan bukti kausalitas:
	Roblox tidak memberi tahu script mana yang membuat suatu Instance atau memutar animasi.
]]

local RingBuffer = __require("RingBuffer")
local Signal = __require("Signal")

local Timeline = {}
Timeline.__index = Timeline

Timeline.DefaultAnchors = table.freeze({
	["Input.AttackBegan"] = true,
	["Input.JumpBegan"] = true,
	["Humanoid.Jumping"] = true,
	["Tool.Activated"] = true,
	["Combat.Request"] = true,
})

function Timeline.new(capacity: number)
	return setmetatable({ ring = RingBuffer.new(capacity), Added = Signal.new() }, Timeline)
end

-- category: Movement | Jump | Attack | Tool | Animation | Input | Network | Combat | Effect | Hitbox
function Timeline:Record(category: string, kind: string, summary: string, data: { [string]: any }?)
	local entry = {
		t = os.clock(),
		st = workspace:GetServerTimeNow(),
		cat = category,
		kind = kind,
		summary = summary,
		data = data,
	}
	entry.seq = self.ring:Push(entry)
	self.Added:Fire(entry)
	return entry
end

function Timeline:ToArray()
	return self.ring:ToArray()
end

function Timeline:GetSince(seq: number, limit: number?)
	return self.ring:GetSince(seq, limit)
end

--[[
	Correlate(opts) -> { { anchor = entry, events = { { dtMs = number, entry = entry } } } }
	opts = { Window = 0.6, PreWindow = 0.08, anchors = set kind, MaxChains = 60 }
	(nama key sama dengan Config.Character.Correlation)
]]
function Timeline:Correlate(opts: { [string]: any }?)
	return Timeline.CorrelateEntries(self.ring:ToArray(), opts)
end

-- Versi statis: dipakai juga untuk cermin timeline server di client.
function Timeline.CorrelateEntries(all: { any }, opts: { [string]: any }?)
	local o = opts or {}
	local window = o.Window or o.window or 0.6
	local pre = o.PreWindow or o.pre or 0.08
	local anchors = o.anchors or Timeline.DefaultAnchors
	local maxChains = o.MaxChains or o.maxChains or 60
	local chains = {}
	-- mulai dari anchor terbaru
	for i = #all, 1, -1 do
		local a = all[i]
		if anchors[a.kind] then
			local events = {}
			-- mundur sedikit (pre) lalu maju sampai window
			local j = i
			while j > 1 and a.t - all[j - 1].t <= pre do
				j -= 1
			end
			while j <= #all and all[j].t - a.t <= window do
				if all[j] ~= a then
					table.insert(events, { dtMs = math.floor((all[j].t - a.t) * 1000 + 0.5), entry = all[j] })
				end
				j += 1
			end
			table.insert(chains, { anchor = a, events = events })
			if #chains >= maxChains then
				break
			end
		end
	end
	return chains
end

function Timeline.FormatChain(chain: { [string]: any }): string
	local a = chain.anchor
	local lines = { string.format("[t=%.3f] ANCHOR %s :: %s", a.t, a.kind, a.summary) }
	for _, ev in chain.events do
		table.insert(lines, string.format("   %+5d ms  %-10s %-24s %s", ev.dtMs, ev.entry.cat, ev.entry.kind, ev.entry.summary))
	end
	return table.concat(lines, "\n")
end

return Timeline
end

-- ===== DataModelExplorer (ServerStorage/RuntimeInspector/Shared/Inspectors/DataModelExplorer.luau) =====
__modules.DataModelExplorer = function()
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

-- [standalone] local Shared = script.Parent.Parent
local Scheduler = __require("Scheduler")
local Maid = __require("Maid")
local Signal = __require("Signal")
local InstanceInfo = __require("InstanceInfo")

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
end

-- ===== ScriptInspector (ServerStorage/RuntimeInspector/Shared/Inspectors/ScriptInspector.luau) =====
__modules.ScriptInspector = function()
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

-- [standalone] local Shared = script.Parent.Parent
local Scheduler = __require("Scheduler")
local Maid = __require("Maid")
local Signal = __require("Signal")
local RingBuffer = __require("RingBuffer")
local InstanceInfo = __require("InstanceInfo")
local Serializer = __require("Serializer")

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
end

-- ===== AssetAuditor (ServerStorage/RuntimeInspector/Shared/Inspectors/AssetAuditor.luau) =====
__modules.AssetAuditor = function()
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

-- [standalone] local Shared = script.Parent.Parent
local Scheduler = __require("Scheduler")
local Signal = __require("Signal")
local AssetCatalog = __require("AssetCatalog")
local InstanceInfo = __require("InstanceInfo")
local Serializer = __require("Serializer")

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
end

-- ===== InstanceMonitor (ServerStorage/RuntimeInspector/Shared/Inspectors/InstanceMonitor.luau) =====
__modules.InstanceMonitor = function()
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

-- [standalone] local Shared = script.Parent.Parent
local Maid = __require("Maid")
local Signal = __require("Signal")
local RingBuffer = __require("RingBuffer")
local Serializer = __require("Serializer")

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
end

-- ===== CharacterProfiler (ServerStorage/RuntimeInspector/Shared/Inspectors/CharacterProfiler.luau) =====
__modules.CharacterProfiler = function()
--[[
	CharacterProfiler
	Profiling movement, combat, tool, input, dan animasi karakter secara real-time.
	- Client: hanya LocalPlayer (plus input lokal).
	- Server: semua pemain (tanpa input; input tidak pernah dikirim ke server).

	Siklus hidup koneksi:
	- Setiap pemain punya Maid; setiap karakter punya Maid sendiri yang dibersihkan
	  pada CharacterRemoving, Destroying, atau saat pemain keluar. Respawn tidak
	  menumpuk listener.
	- Sampling posisi memakai SATU koneksi Heartbeat untuk semua karakter.

	Keterbatasan resmi:
	- Tidak ada API untuk mengetahui fungsi/script yang memutar animasi atau membuat hitbox.
	  Kolom "nearestCharacter" pada hitbox adalah heuristik jarak, bukan bukti pemilik.
	- Di server, posisi karakter berasal dari replikasi fisika client (network owner).
	  Properti seperti WalkSpeed yang diubah di client TIDAK terlihat di server.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

-- [standalone] local Shared = script.Parent.Parent
local Maid = __require("Maid")
local Signal = __require("Signal")
local Serializer = __require("Serializer")

local IS_SERVER = RunService:IsServer()

local CharacterProfiler = {}
CharacterProfiler.__index = CharacterProfiler

local MOVEMENT_PROPS = { "WalkSpeed", "JumpPower", "JumpHeight", "AutoRotate", "UseJumpPower", "HipHeight" }

function CharacterProfiler.new(config: any, timeline: any)
	local cfg = config.Character
	local attackInputs = {}
	for _, n in cfg.AttackInputs do
		attackInputs[n] = true
	end
	local combatAttrs = {}
	for _, n in cfg.CombatAttributes do
		combatAttrs[n] = true
	end
	local effectClasses = {}
	for _, n in cfg.EffectClasses do
		effectClasses[n] = true
	end
	return setmetatable({
		config = config,
		cfg = cfg,
		timeline = timeline,
		env = IS_SERVER and "server" or "client",
		players = {}, -- player -> { maid, char = state }
		attackInputs = attackInputs,
		combatAttrs = combatAttrs,
		effectClasses = effectClasses,
		maid = Maid.new(),
		-- Hook untuk AnomalyDetector
		HumanoidPropertyChanged = Signal.new(), -- (player, humanoid, prop, old, new)
		Teleported = Signal.new(), -- (player, fromPos, toPos, distance, dt)
		ToolActivated = Signal.new(), -- (player, tool, cooldownInfo?)
		HitboxSeen = Signal.new(), -- (part, size, nearestPlayerName, distance)
		AttributeChanged = Signal.new(), -- (player, inst, name, old, new)
	}, CharacterProfiler)
end

function CharacterProfiler:_rec(category: string, kind: string, summary: string, data: any?)
	return self.timeline:Record(category, kind, summary, data)
end

local function v3(v: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function attrSummary(v: any): string
	return Serializer.Summarize((Serializer.Describe(v)), 60)
end

-- Info cooldown dari atribut karakter/tool (nama atribut dari config).
function CharacterProfiler:_cooldownInfo(char: Model, tool: Tool?): string?
	for _, holder in { tool, char } do
		if holder then
			for _, name in { "Cooldown", "OnCooldown", "Stunned", "Stun" } do
				local v = holder:GetAttribute(name)
				if v == true or (type(v) == "number" and v > 0) then
					return holder.Name .. "." .. name .. "=" .. tostring(v)
				end
			end
		end
	end
	return nil
end

function CharacterProfiler:_bindTool(player: Player, state: any, tool: Tool)
	if state.tools[tool] then
		return
	end
	local m = Maid.new()
	state.tools[tool] = m
	local name = tool.Name
	m:Give(tool.Equipped:Connect(function()
		self:_rec("Tool", "Tool.Equipped", player.Name .. " equip " .. name, { tool = name })
	end))
	m:Give(tool.Unequipped:Connect(function()
		self:_rec("Tool", "Tool.Unequipped", player.Name .. " unequip " .. name, { tool = name })
	end))
	m:Give(tool.Activated:Connect(function()
		local cd = state.char and self:_cooldownInfo(state.char, tool) or nil
		self:_rec("Tool", "Tool.Activated", player.Name .. " activate " .. name .. (cd and (" [cooldown aktif: " .. cd .. "]") or ""), { tool = name, cooldown = cd })
		self.ToolActivated:Fire(player, tool, cd)
	end))
	m:Give(tool.Deactivated:Connect(function()
		self:_rec("Tool", "Tool.Deactivated", player.Name .. " deactivate " .. name, { tool = name })
	end))
	m:Give(tool.AncestryChanged:Connect(function()
		-- Lepas bila tool tidak lagi milik pemain ini (dibuang / dihancurkan)
		local backpack = player:FindFirstChildOfClass("Backpack")
		local stillOwned = (backpack and tool:IsDescendantOf(backpack)) or (state.char and tool:IsDescendantOf(state.char))
		if not stillOwned then
			m:Destroy()
			state.tools[tool] = nil
		end
	end))
end

function CharacterProfiler:_bindAnimator(player: Player, state: any, animator: Animator)
	state.charMaid:Give(animator.AnimationPlayed:Connect(function(track: AnimationTrack)
		local okId, animId = pcall(function()
			return track.Animation and track.Animation.AnimationId or "?"
		end)
		local data = {
			animationId = okId and animId or "?",
			trackName = track.Name,
			priority = tostring(track.Priority),
			speed = track.Speed,
			weight = track.WeightCurrent,
			isPlaying = track.IsPlaying,
			length = track.Length,
		}
		self:_rec("Animation", "Animator.AnimationPlayed",
			string.format("%s play %s id=%s prio=%s speed=%.2f", player.Name, track.Name, tostring(data.animationId), data.priority, track.Speed),
			data)
		-- WeightCurrent biasanya 0 tepat saat Play (fade-in); sampling ulang sesaat kemudian.
		task.delay(0.12, function()
			if track then
				local okW, w = pcall(function()
					return track.WeightCurrent
				end)
				self:_rec("Animation", "AnimationTrack.Sample",
					string.format("%s %s weight=%.2f playing=%s", player.Name, track.Name, okW and w or -1, tostring(track.IsPlaying)),
					{ trackName = track.Name, weight = okW and w or nil, isPlaying = track.IsPlaying })
			end
		end)
		-- Once: koneksi lepas otomatis setelah sekali fire, tidak menumpuk di Maid
		track.Stopped:Once(function()
			self:_rec("Animation", "AnimationTrack.Stopped", player.Name .. " stop " .. track.Name, { trackName = track.Name })
		end)
	end))
end

function CharacterProfiler:_bindHumanoid(player: Player, state: any, humanoid: Humanoid)
	local m = state.charMaid
	state.humanoid = humanoid
	m:Give(humanoid.StateChanged:Connect(function(old, new)
		local cat = (new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall or new == Enum.HumanoidStateType.Landed) and "Jump" or "Movement"
		self:_rec(cat, "Humanoid.StateChanged", player.Name .. " " .. old.Name .. " -> " .. new.Name, { old = old.Name, new = new.Name })
	end))
	m:Give(humanoid.Jumping:Connect(function(active)
		if active then
			self:_rec("Jump", "Humanoid.Jumping", player.Name .. " jumping", { active = active })
		end
	end))
	local lastSpeed = -1
	m:Give(humanoid.Running:Connect(function(speed)
		if math.abs(speed - lastSpeed) >= self.cfg.RunningSpeedDelta or (speed == 0) ~= (lastSpeed == 0) then
			lastSpeed = speed
			self:_rec("Movement", "Humanoid.Running", string.format("%s running speed=%.2f", player.Name, speed), { speed = speed })
		end
	end))
	local lastMoveT = 0
	m:Give(humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
		local now = os.clock()
		if now - lastMoveT >= self.cfg.MoveDirectionThrottle then
			lastMoveT = now
			local md = humanoid.MoveDirection
			self:_rec("Movement", "Humanoid.MoveDirection", player.Name .. " moveDir " .. v3(md), { moveDirection = Serializer.Vec3(md) })
		end
	end))
	for _, prop in MOVEMENT_PROPS do
		local okRead, initial = pcall(function()
			return (humanoid :: any)[prop]
		end)
		if okRead then
			local old = initial
			m:Give(humanoid:GetPropertyChangedSignal(prop):Connect(function()
				local new = (humanoid :: any)[prop]
				self:_rec("Movement", "Humanoid." .. prop, string.format("%s %s %s -> %s", player.Name, prop, tostring(old), tostring(new)), { prop = prop, old = old, new = new })
				self.HumanoidPropertyChanged:Fire(player, humanoid, prop, old, new)
				old = new
			end))
		end
	end
	self:_watchAttributes(player, state, humanoid)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		self:_bindAnimator(player, state, animator)
	else
		m:Give(task.spawn(function()
			local a = humanoid:WaitForChild("Animator", 10)
			if a and a:IsA("Animator") and state.humanoid == humanoid then
				self:_bindAnimator(player, state, a)
			end
		end))
	end
end

function CharacterProfiler:_watchAttributes(player: Player, state: any, inst: Instance)
	local okAttrs, attrs = pcall(inst.GetAttributes, inst)
	local snapshot = okAttrs and attrs or {}
	state.charMaid:Give(inst.AttributeChanged:Connect(function(name)
		local old = snapshot[name]
		local new = inst:GetAttribute(name)
		snapshot[name] = new
		local isCombat = self.combatAttrs[name] == true
		self:_rec(isCombat and "Attack" or "Movement", isCombat and "Combat.Attribute" or "Character.Attribute",
			string.format("%s %s.%s %s -> %s", player.Name, inst.Name, name, attrSummary(old), attrSummary(new)),
			{ holder = inst.Name, attribute = name, old = attrSummary(old), new = attrSummary(new) })
		self.AttributeChanged:Fire(player, inst, name, old, new)
	end))
end

function CharacterProfiler:_bindCharacter(player: Player, char: Model)
	local pState = self.players[player]
	if not pState then
		return
	end
	if pState.char then
		self:_unbindCharacter(player)
	end
	local state = {
		char = char,
		charMaid = Maid.new(),
		tools = {},
		humanoid = nil,
		hrp = nil,
		lastPos = nil,
		lastT = 0,
		spawnT = os.clock(),
	}
	pState.char = state
	self:_rec("Movement", "Character.Added", player.Name .. " character spawned", { character = char.Name })

	state.charMaid:Give(char.Destroying:Connect(function()
		if pState.char == state then
			self:_unbindCharacter(player)
		end
	end))
	self:_watchAttributes(player, state, char)

	local function onChild(child: Instance)
		if child:IsA("Tool") then
			self:_bindTool(player, state, child)
		elseif child:IsA("Humanoid") and state.humanoid == nil then
			self:_bindHumanoid(player, state, child)
		elseif child.Name == "HumanoidRootPart" and child:IsA("BasePart") then
			state.hrp = child
		end
	end
	for _, child in char:GetChildren() do
		onChild(child)
	end
	state.charMaid:Give(char.ChildAdded:Connect(onChild))

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				self:_bindTool(player, state, child)
			end
		end
		state.charMaid:Give(backpack.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				self:_bindTool(player, state, child)
			end
		end))
	end
end

function CharacterProfiler:_unbindCharacter(player: Player)
	local pState = self.players[player]
	if not pState or not pState.char then
		return
	end
	local state = pState.char
	pState.char = nil
	for tool, m in state.tools do
		m:Destroy()
		state.tools[tool] = nil
	end
	state.charMaid:Destroy()
	self:_rec("Movement", "Character.Removed", player.Name .. " character removed", nil)
end

function CharacterProfiler:_addPlayer(player: Player)
	if self.players[player] then
		return
	end
	local pState = { maid = Maid.new(), char = nil }
	self.players[player] = pState
	pState.maid:Give(player.CharacterAdded:Connect(function(char)
		self:_bindCharacter(player, char)
	end))
	pState.maid:Give(player.CharacterRemoving:Connect(function()
		self:_unbindCharacter(player)
	end))
	if player.Character then
		self:_bindCharacter(player, player.Character)
	end
end

function CharacterProfiler:_removePlayer(player: Player)
	local pState = self.players[player]
	if not pState then
		return
	end
	self:_unbindCharacter(player)
	pState.maid:Destroy()
	self.players[player] = nil
end

function CharacterProfiler:_sample()
	local now = os.clock()
	for player, pState in self.players do
		local state = pState.char
		if state and state.hrp and state.hrp.Parent then
			if now - state.lastT >= self.cfg.SampleInterval then
				local pos = state.hrp.Position
				if state.lastPos then
					local dt = now - state.lastT
					local delta = (pos - state.lastPos).Magnitude
					local vel = state.hrp.AssemblyLinearVelocity
					-- Lompatan posisi yang tidak dijelaskan oleh velocity => kandidat teleport
					local explained = vel.Magnitude * dt * 1.5 + 4
					if delta > self.config.Anomaly.TeleportDistance and delta > explained and now - state.spawnT > 2 then
						self:_rec("Movement", "HRP.PositionJump", string.format("%s lompatan posisi %.1f studs dalam %.2fs", player.Name, delta, dt), { from = Serializer.Vec3(state.lastPos), to = Serializer.Vec3(pos), distance = delta })
						self.Teleported:Fire(player, state.lastPos, pos, delta, dt)
					end
				end
				state.lastPos = pos
				state.lastT = now
			end
		end
	end
end

-- Dipanggil InstanceMonitor.InstanceAdded (agar tidak membuat koneksi DescendantAdded tambahan).
function CharacterProfiler:OnInstanceAdded(inst: Instance)
	if inst:IsA("BasePart") then
		local lname = string.lower(inst.Name)
		local isHitbox = CollectionService:HasTag(inst, self.cfg.HitboxTag)
		if not isHitbox then
			for _, pattern in self.cfg.HitboxNamePatterns do
				if string.find(lname, pattern, 1, true) then
					isHitbox = true
					break
				end
			end
		end
		if isHitbox then
			local nearestName, nearestDist = nil, math.huge
			for player, pState in self.players do
				local s = pState.char
				if s and s.hrp and s.hrp.Parent then
					local d = (s.hrp.Position - inst.Position).Magnitude
					if d < nearestDist then
						nearestName, nearestDist = player.Name, d
					end
				end
			end
			self:_rec("Hitbox", "Hitbox.Created",
				string.format("%s size=%s near=%s (%.1f studs, heuristik)", inst.Name, v3(inst.Size), tostring(nearestName), nearestDist),
				{ path = Serializer.SafeFullName(inst), size = Serializer.Vec3(inst.Size), nearest = nearestName, distance = nearestDist })
			self.HitboxSeen:Fire(inst, inst.Size, nearestName, nearestDist)
		end
		return
	end
	if self.effectClasses[inst.ClassName] then
		local owner = nil
		for player, pState in self.players do
			local s = pState.char
			if s and s.char and inst:IsDescendantOf(s.char) then
				owner = player.Name
				break
			end
		end
		if not owner then
			local parentPart = inst:FindFirstAncestorWhichIsA("BasePart")
			if parentPart then
				for player, pState in self.players do
					local s = pState.char
					if s and s.hrp and (s.hrp.Position - parentPart.Position).Magnitude <= self.cfg.EffectRadius then
						owner = player.Name .. " (radius)"
						break
					end
				end
			end
		end
		if owner then
			self:_rec("Effect", "Effect.Created", inst.ClassName .. " " .. inst.Name .. " near " .. owner, { path = Serializer.SafeFullName(inst), owner = owner })
		end
	end
end

function CharacterProfiler:_bindInput()
	local function keyName(input: InputObject): string
		if input.UserInputType == Enum.UserInputType.Keyboard or input.UserInputType == Enum.UserInputType.Gamepad1 then
			return input.KeyCode.Name
		end
		return input.UserInputType.Name
	end
	self.maid:Give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			return
		end
		-- Jangan merekam ketikan saat TextBox fokus (chat, form) demi privasi
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.KeyCode == self.config.ToggleKey then
			return
		end
		local name = keyName(input)
		local kind = "Input.Began"
		local cat = "Input"
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
			kind = "Input.JumpBegan"
		elseif self.attackInputs[name] then
			kind = "Input.AttackBegan"
		end
		self:_rec(cat, kind, name .. (gameProcessed and " (gameProcessed)" or ""), { key = name, gameProcessed = gameProcessed })
	end))
	self.maid:Give(UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		self:_rec("Input", "Input.Ended", keyName(input) .. (gameProcessed and " (gameProcessed)" or ""), { key = keyName(input), gameProcessed = gameProcessed })
	end))
end

function CharacterProfiler:Start()
	if IS_SERVER then
		for _, p in Players:GetPlayers() do
			self:_addPlayer(p)
		end
		self.maid:Give(Players.PlayerAdded:Connect(function(p)
			self:_addPlayer(p)
		end))
		self.maid:Give(Players.PlayerRemoving:Connect(function(p)
			self:_removePlayer(p)
		end))
	else
		local lp = Players.LocalPlayer
		self:_addPlayer(lp)
		self:_bindInput()
	end
	self.maid:Give(RunService.Heartbeat:Connect(function()
		self:_sample()
	end))
end

-- Snapshot movement saat ini (untuk Overview / divergence check).
function CharacterProfiler:Snapshot(player: Player): { [string]: any }?
	local pState = self.players[player]
	local s = pState and pState.char
	if not s or not s.humanoid then
		return nil
	end
	local h = s.humanoid
	local out = {
		WalkSpeed = h.WalkSpeed,
		JumpPower = h.JumpPower,
		JumpHeight = h.JumpHeight,
		UseJumpPower = h.UseJumpPower,
		AutoRotate = h.AutoRotate,
		Health = h.Health,
		MaxHealth = h.MaxHealth,
		State = h:GetState().Name,
	}
	if s.hrp then
		out.Position = Serializer.Vec3(s.hrp.Position)
		out.Velocity = Serializer.Vec3(s.hrp.AssemblyLinearVelocity)
	end
	return out
end

function CharacterProfiler:Destroy()
	for p in self.players do
		self:_removePlayer(p)
	end
	self.maid:Destroy()
end

return CharacterProfiler
end

-- ===== NetworkMonitor (ServerStorage/RuntimeInspector/Shared/Inspectors/NetworkMonitor.luau) =====
__modules.NetworkMonitor = function()
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

-- [standalone] local Shared = script.Parent.Parent
local Maid = __require("Maid")
local Signal = __require("Signal")
local RingBuffer = __require("RingBuffer")
local Scheduler = __require("Scheduler")
-- [standalone] local NetFolder = game:GetService("ReplicatedStorage"):WaitForChild("RuntimeInspectorNet")
local Serializer = __require("Serializer")
local Schema = __require("Schema")
local Net = __require("Net")

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
end

-- ===== AnomalyDetector (ServerStorage/RuntimeInspector/Shared/Inspectors/AnomalyDetector.luau) =====
__modules.AnomalyDetector = function()
--[[
	AnomalyDetector
	Aturan deteksi yang dipasang ke sinyal modul lain. Setiap temuan memiliki:
	severity (LOW/MEDIUM/HIGH/CRITICAL), objek, waktu, detail, alasan, rekomendasi.

	PENTING soal kepercayaan data:
	- Temuan dari environment "server" berasal dari state yang dikendalikan server.
	- Temuan dari environment "client" adalah INDIKATOR untuk pengujian di Studio.
	  Di game live, client bisa dimodifikasi, jadi deteksi client tidak boleh menjadi
	  dasar hukuman. Penegakan ada di Security/* pada ServerScriptService.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- [standalone] local Shared = script.Parent.Parent
local Maid = __require("Maid")
local Serializer = __require("Serializer")

local IS_SERVER = RunService:IsServer()
local ENV = IS_SERVER and "server" or "client"

local AnomalyDetector = {}
AnomalyDetector.__index = AnomalyDetector

function AnomalyDetector.new(config: any, findings: any)
	local cfg = config.Anomaly
	local suspicious = {}
	for _, c in cfg.SuspiciousCharacterClasses do
		suspicious[c] = true
	end
	local protected = {}
	for _, n in cfg.ProtectedAttributes do
		protected[n] = true
	end
	return setmetatable({
		config = config,
		cfg = cfg,
		findings = findings,
		suspicious = suspicious,
		protected = protected,
		errorTimes = {},
		maid = Maid.new(),
	}, AnomalyDetector)
end

function AnomalyDetector:Report(f: { [string]: any })
	f.env = f.env or ENV
	if not IS_SERVER and f.source == nil then
		f.source = "client-observed (indikator, tidak otoritatif)"
	end
	return self.findings:Report(f)
end

local function characterOwner(inst: Instance): Player?
	local model = inst:FindFirstAncestorOfClass("Model")
	while model do
		local p = Players:GetPlayerFromCharacter(model)
		if p then
			return p
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

---------------------------------------------------------------- aturan

function AnomalyDetector:OnInstanceAdded(inst: Instance)
	if self.suspicious[inst.ClassName] then
		local owner = characterOwner(inst)
		if owner and not self.cfg.AllowedMoverNames[inst.Name] then
			self:Report({
				severity = "MEDIUM",
				rule = "runtime.mover_in_character",
				object = inst.Name,
				path = Serializer.SafeFullName(inst),
				player = owner.Name,
				detail = inst.ClassName .. " muncul di karakter " .. owner.Name,
				reason = "Mover fisika di karakter sering dipakai untuk speed/fly/dash. Bila bukan bagian sistem game, ini mencurigakan.",
				recommendation = "Daftarkan nama mover milik game di Config.Anomaly.AllowedMoverNames. Validasi pergerakan di server (MovementValidator), jangan percaya mover client.",
			})
		end
	end
end

function AnomalyDetector:OnHumanoidProperty(player: Player, humanoid: Humanoid, prop: string, old: any, new: any)
	local cfg = self.cfg
	if prop == "WalkSpeed" then
		local allowed = table.find(cfg.AllowedWalkSpeeds, new) ~= nil
		if not allowed then
			local severity = (type(new) == "number" and new > cfg.MaxWalkSpeed) and "HIGH" or "MEDIUM"
			self:Report({
				severity = severity,
				rule = "movement.walkspeed_change",
				object = humanoid.Name,
				path = Serializer.SafeFullName(humanoid),
				player = player.Name,
				detail = string.format("WalkSpeed %s -> %s (diizinkan: %s, maks %s)", tostring(old), tostring(new), table.concat(cfg.AllowedWalkSpeeds, "/"), tostring(cfg.MaxWalkSpeed)),
				reason = IS_SERVER and "Nilai WalkSpeed di server berubah ke nilai di luar daftar yang diharapkan."
					or "WalkSpeed client berubah ke nilai tak terduga. Perubahan WalkSpeed di client TIDAK direplikasi ke server, tetapi pergerakan yang dihasilkannya direplikasi. Exploiter nyata dapat mengubah properti tanpa memicu event lokal, jadi deteksi ini hanya berguna untuk pengujian.",
				recommendation = "Tetapkan WalkSpeed hanya dari server; tambahkan nilai sah ke AllowedWalkSpeeds; andalkan MovementValidator (validasi delta posisi), bukan nilai properti.",
			})
		end
	elseif prop == "JumpPower" or prop == "JumpHeight" then
		local max = prop == "JumpPower" and cfg.MaxJumpPower or cfg.MaxJumpHeight
		if type(new) == "number" and new > max then
			self:Report({
				severity = "HIGH",
				rule = "movement." .. string.lower(prop) .. "_exceeds",
				object = humanoid.Name,
				path = Serializer.SafeFullName(humanoid),
				player = player.Name,
				detail = string.format("%s %s -> %s (maks %s)", prop, tostring(old), tostring(new), tostring(max)),
				reason = prop .. " melebihi batas konfigurasi.",
				recommendation = "Set nilai lompatan dari server dan validasi kenaikan vertikal di MovementValidator.",
			})
		end
	end
end

function AnomalyDetector:OnTeleport(player: Player, from: Vector3, to: Vector3, distance: number, dt: number)
	self:Report({
		severity = IS_SERVER and "HIGH" or "MEDIUM",
		rule = "movement.position_jump",
		object = player.Name,
		path = "Players." .. player.Name,
		player = player.Name,
		detail = string.format("Posisi melompat %.1f studs dalam %.2fs dari %s ke %s", distance, dt, tostring(from), tostring(to)),
		reason = "Perpindahan posisi tidak dapat dijelaskan oleh velocity HumanoidRootPart.",
		recommendation = "Bila teleport sah dilakukan oleh game, panggil MovementValidator.AllowTeleport(player, detik) sebelum memindahkan karakter.",
	})
end

function AnomalyDetector:OnToolActivated(player: Player, tool: Tool, cooldownInfo: string?)
	if cooldownInfo then
		self:Report({
			severity = "LOW",
			rule = "combat.tool_during_cooldown",
			object = tool.Name,
			path = Serializer.SafeFullName(tool),
			player = player.Name,
			detail = "Tool.Activated saat " .. cooldownInfo,
			reason = "Tool diaktifkan ketika atribut cooldown/stun masih aktif. Bisa wajar (input pemain), bisa juga upaya bypass cooldown.",
			recommendation = "Pastikan cooldown divalidasi di server (CombatAuthority). Client hanya boleh menampilkan cooldown.",
		})
	end
end

function AnomalyDetector:OnHitbox(part: BasePart, size: Vector3, nearest: string?, distance: number)
	local max = self.cfg.MaxHitboxSize
	if size.X > max.X or size.Y > max.Y or size.Z > max.Z then
		self:Report({
			severity = "HIGH",
			rule = "combat.hitbox_oversize",
			object = part.Name,
			path = Serializer.SafeFullName(part),
			player = nearest,
			detail = string.format("Ukuran hitbox (%.1f, %.1f, %.1f) melebihi batas (%.1f, %.1f, %.1f)", size.X, size.Y, size.Z, max.X, max.Y, max.Z),
			reason = "Hitbox berukuran tidak wajar memperluas jangkauan serangan.",
			recommendation = "Gunakan ukuran hitbox dari definisi senjata di server; jangan terima ukuran dari client.",
		})
	end
end

function AnomalyDetector:OnRemoteRate(info: any, count: number, limit: number, playerName: string?)
	self:Report({
		severity = count > limit * 3 and "HIGH" or "MEDIUM",
		rule = "network.rate_exceeded",
		object = info.name,
		path = info.path .. (playerName and ("#" .. playerName) or ""),
		player = playerName,
		detail = string.format("%s dipanggil > %d kali/detik", info.name, limit),
		reason = "Frekuensi panggilan remote melebihi batas wajar. Bisa spam/exploit atau bug loop di script.",
		recommendation = "Terapkan rate limit server (SecureRemote) dan atur batas di Config.Network.PerRemoteRateLimit.",
	})
end

function AnomalyDetector:OnInvalidPayload(entry: any)
	self:Report({
		severity = IS_SERVER and "MEDIUM" or "LOW",
		rule = "network.invalid_payload",
		object = entry.remote,
		path = entry.path,
		player = entry.player,
		detail = table.concat(entry.issues, "; "),
		reason = "Payload berisi nilai yang tidak valid atau tidak dapat dikirim utuh (NaN/inf, tabel campuran, fungsi, metatable).",
		recommendation = "Validasi tipe & rentang di server sebelum memakai argumen (Schema). Tolak NaN/inf secara eksplisit.",
	})
end

function AnomalyDetector:OnSchemaMismatch(entry: any, err: string)
	self:Report({
		severity = IS_SERVER and "HIGH" or "MEDIUM",
		rule = "network.schema_mismatch",
		object = entry.remote,
		path = entry.path,
		player = entry.player,
		detail = err,
		reason = "Argumen remote tidak sesuai skema yang didaftarkan.",
		recommendation = "Tolak panggilan yang gagal validasi di server dan catat pelakunya.",
	})
end

function AnomalyDetector:OnScriptError(e: any)
	if e.kind == "warning" then
		return
	end
	local now = os.clock()
	table.insert(self.errorTimes, now)
	while #self.errorTimes > 0 and now - self.errorTimes[1] > self.cfg.ErrorBurstWindow do
		table.remove(self.errorTimes, 1)
	end
	local burst = #self.errorTimes >= self.cfg.ErrorBurstCount
	self:Report({
		severity = burst and "MEDIUM" or "LOW",
		rule = "script.error",
		object = e.script or "?",
		path = (e.script or "?") .. "|" .. string.sub(e.message, 1, 60),
		detail = e.message,
		reason = burst and "Banyak error dalam waktu singkat." or "Script menghasilkan error.",
		recommendation = "Periksa stack trace. Error di handler remote bisa dipicu input client yang tidak divalidasi.",
	})
end

function AnomalyDetector:OnUnknownAsset(rec: any, inst: Instance)
	self:Report({
		severity = self.cfg.UnknownAssetSeverity,
		rule = "asset.unknown_runtime",
		object = rec.key,
		path = Serializer.SafeFullName(inst),
		detail = "Aset " .. rec.key .. " muncul saat gameplay di " .. inst.ClassName,
		reason = "Aset tidak ada di baseline scan maupun RuntimeAllowlist.",
		recommendation = "Bila aset ini sah, tambahkan ke AssetPolicy.RuntimeAllowlist. Bila tidak, telusuri script yang membuat Instance tersebut.",
	})
end

function AnomalyDetector:OnAttributeChanged(player: Player?, inst: Instance, name: string, old: any, new: any)
	if not self.protected[name] then
		return
	end
	self:Report({
		severity = "LOW",
		rule = "attribute.protected_changed",
		object = inst.Name .. "." .. name,
		path = Serializer.SafeFullName(inst) .. "@" .. name,
		player = player and player.Name or nil,
		detail = string.format("%s: %s -> %s", name, tostring(old), tostring(new)),
		reason = IS_SERVER and "Atribut terlindungi berubah di server (pastikan berasal dari sistem game)."
			or "Atribut terlindungi berubah di client. Bisa berupa replikasi dari server; DivergenceCheck akan menaikkan severity bila nilai client berbeda dari server.",
		recommendation = "Ubah atribut terlindungi hanya dari server. Atribut yang diubah client tidak direplikasi ke server, jadi server tidak boleh membaca state dari client.",
	})
end

-- Dipanggil client setelah membandingkan nilai lokal dengan nilai server.
function AnomalyDetector:OnDivergence(path: string, name: string, clientValue: any, serverValue: any)
	self:Report({
		severity = "HIGH",
		rule = "verify.client_server_divergence",
		object = name,
		path = path .. "@" .. name,
		detail = string.format("Client=%s, Server=%s", tostring(clientValue), tostring(serverValue)),
		reason = "Nilai di client berbeda dari server secara konsisten (bukan sekadar latensi replikasi). Indikasi modifikasi lokal.",
		recommendation = "Jangan pernah membaca nilai ini dari client untuk keputusan gameplay. Gunakan nilai server.",
	})
end

---------------------------------------------------------------- wiring

-- modules = { monitor, profiler, network, scripts, assets }
function AnomalyDetector:Bind(modules: { [string]: any })
	local m = self.maid
	if modules.monitor then
		m:Give(modules.monitor.InstanceAdded:Connect(function(inst)
			self:OnInstanceAdded(inst)
		end))
	end
	if modules.profiler then
		local p = modules.profiler
		m:Give(p.HumanoidPropertyChanged:Connect(function(...)
			self:OnHumanoidProperty(...)
		end))
		m:Give(p.Teleported:Connect(function(...)
			self:OnTeleport(...)
		end))
		m:Give(p.ToolActivated:Connect(function(...)
			self:OnToolActivated(...)
		end))
		m:Give(p.HitboxSeen:Connect(function(...)
			self:OnHitbox(...)
		end))
		m:Give(p.AttributeChanged:Connect(function(...)
			self:OnAttributeChanged(...)
		end))
	end
	if modules.network then
		local n = modules.network
		m:Give(n.RateExceeded:Connect(function(...)
			self:OnRemoteRate(...)
		end))
		m:Give(n.InvalidPayload:Connect(function(...)
			self:OnInvalidPayload(...)
		end))
		m:Give(n.SchemaMismatch:Connect(function(...)
			self:OnSchemaMismatch(...)
		end))
	end
	if modules.scripts then
		m:Give(modules.scripts.ErrorAdded:Connect(function(e)
			self:OnScriptError(e)
		end))
	end
	if modules.assets then
		m:Give(modules.assets.UnknownAsset:Connect(function(...)
			self:OnUnknownAsset(...)
		end))
	end
end

function AnomalyDetector:Destroy()
	self.maid:Destroy()
end

return AnomalyDetector
end

-- ===== ExportCenter (ServerStorage/RuntimeInspector/ClientPackage/ExportCenter.luau) =====
__modules.ExportCenter = function()
--[[
	ExportCenter
	Menyusun laporan dari data client (dan cermin data server yang sudah diterima)
	dalam format JSON, TXT, atau CSV.

	Keterbatasan resmi yang harus diketahui:
	- Game script TIDAK punya API clipboard maupun API tulis file. ("setclipboard" adalah
	  fungsi executor, bukan API Roblox.) Karena itu "Copy" dilakukan dengan memilih
	  teks di TextBox lalu Ctrl+A / Ctrl+C, atau melalui Output (print bertahap).
	- Ekspor HTTP hanya bisa dari server (HttpService), lihat ServerConfig.Export.
]]

local HttpService = game:GetService("HttpService")

local ExportCenter = {}

ExportCenter.Categories = {
	"overview", "findings", "network", "runtime", "actions", "assets", "scripts", "errors",
}

-- Konversi mendalam ke bentuk aman JSON.
function ExportCenter.Sanitize(value: any, depth: number?, seen: { [any]: boolean }?): any
	local d = depth or 0
	local t = typeof(value)
	if t == "nil" or t == "boolean" or t == "string" then
		return value
	elseif t == "number" then
		if value ~= value then
			return "NaN"
		elseif value == math.huge then
			return "inf"
		elseif value == -math.huge then
			return "-inf"
		end
		return value
	elseif t == "Instance" then
		local ok, name = pcall(value.GetFullName, value)
		return ok and name or "<Instance>"
	elseif t == "Vector3" then
		return { value.X, value.Y, value.Z }
	elseif t == "Vector2" then
		return { value.X, value.Y }
	elseif t == "CFrame" then
		return { value:GetComponents() }
	elseif t == "Color3" then
		return { value.R, value.G, value.B }
	elseif t == "table" then
		if d > 8 then
			return "<depth limit>"
		end
		local s = seen or {}
		if s[value] then
			return "<cycle>"
		end
		s[value] = true
		local out = {}
		local count = 0
		for _ in value do
			count += 1
		end
		-- Hanya array murni yang mempertahankan key numerik; selain itu semua key jadi string
		-- (JSONEncode menolak tabel campuran).
		local isArray = count > 0 and count == #value
		for k, v in value do
			if type(k) == "string" and string.sub(k, 1, 1) == "_" then
				continue
			end
			local key = isArray and k or tostring(k)
			out[key] = ExportCenter.Sanitize(v, d + 1, s)
		end
		s[value] = nil
		return out
	elseif t == "function" or t == "thread" or t == "userdata" then
		return nil
	end
	local ok, str = pcall(tostring, value)
	return ok and str or ("<" .. t .. ">")
end

local function list(x: any): { any }
	return type(x) == "table" and x or {}
end

-- Mengumpulkan data per kategori dari agent. scope: "client" | "server" | "both"
function ExportCenter.Collect(agent: any, categories: { [string]: boolean }, scope: string): { [string]: any }
	local wantClient = scope == "client" or scope == "both"
	local wantServer = scope == "server" or scope == "both"
	local report = {
		generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		scope = scope,
		player = agent.player.Name,
		placeId = game.PlaceId,
		note = "Data client = observasi client admin. Data server = diterima dari InspectorBridge. Temuan client adalah indikator, bukan bukti otoritatif.",
	}
	if categories.overview then
		report.overview = {
			client = wantClient and {
				explorer = agent.explorer:Stats(),
				scripts = agent.scripts:Counts(),
				monitor = agent.monitor:Stats(),
				remotes = agent.network.remoteCount,
				riskScore = agent.findings:RiskScore(),
			} or nil,
			server = wantServer and agent.server.overview or nil,
			hello = agent.server.hello,
		}
	end
	if categories.findings then
		report.findings = {
			client = wantClient and agent.findings:List() or nil,
			server = wantServer and agent.serverFindings:List() or nil,
		}
	end
	if categories.network then
		report.network = {
			client = wantClient and { remotes = agent.network:Remotes(), entries = agent.network:Entries() } or nil,
			server = wantServer and { remotes = agent.serverRemotes, entries = agent.serverNet:ToArray() } or nil,
		}
	end
	if categories.runtime then
		report.runtime = {
			client = wantClient and agent.monitor:Entries() or nil,
			server = wantServer and agent.serverMonitor:ToArray() or nil,
		}
	end
	if categories.actions then
		local chains = {}
		for _, ch in agent.timeline:Correlate(agent.Config.Character.Correlation) do
			table.insert(chains, agent.TimelineLib.FormatChain(ch))
		end
		report.actions = {
			client = wantClient and { timeline = agent.timeline:ToArray(), chains = chains } or nil,
			server = wantServer and { timeline = agent.serverTimeline:ToArray(), audit = agent.serverAudit:ToArray() } or nil,
		}
	end
	if categories.assets then
		report.assets = {
			client = wantClient and agent.assets:Report() or nil,
			server = wantServer and agent.server.assets or nil,
		}
	end
	if categories.scripts then
		local clientScripts = {}
		if wantClient then
			for _, r in agent.scripts.records do
				local copy = table.clone(r)
				copy.inst = nil
				table.insert(clientScripts, copy)
			end
		end
		report.scripts = {
			client = wantClient and clientScripts or nil,
			server = wantServer and agent.server.scripts or nil,
			manifest = wantServer and agent.server.manifest or nil,
		}
	end
	if categories.errors then
		report.errors = {
			client = wantClient and agent.scripts:Errors() or nil,
			server = wantServer and agent.server.scripts and agent.server.scripts.errors or nil,
		}
	end
	return ExportCenter.Sanitize(report)
end

function ExportCenter.ToJSON(report: any): string
	local ok, json = pcall(HttpService.JSONEncode, HttpService, report)
	return ok and json or ("{\"error\":\"JSONEncode gagal: " .. tostring(json) .. "\"}")
end

local function line(fields: { any }): string
	local out = {}
	for i, f in fields do
		local s = tostring(f == nil and "" or f)
		s = string.gsub(s, "\r?\n", " ")
		if string.find(s, "[,\"]") then
			s = "\"" .. string.gsub(s, "\"", "\"\"") .. "\""
		end
		out[i] = s
	end
	return table.concat(out, ",")
end

function ExportCenter.ToCSV(report: any): string
	local rows = {}
	local function section(name: string, header: { string }, items: { any }, map: (any) -> { any })
		table.insert(rows, "# " .. name)
		table.insert(rows, line(header))
		for _, it in items do
			table.insert(rows, line(map(it)))
		end
		table.insert(rows, "")
	end
	for _, side in { "client", "server" } do
		local f = report.findings and report.findings[side]
		if f then
			section("findings." .. side, { "severity", "rule", "object", "path", "count", "player", "detail", "reason", "recommendation" }, list(f), function(x)
				return { x.severity, x.rule, x.object, x.path, x.count, x.player, x.detail, x.reason, x.recommendation }
			end)
		end
		local n = report.network and report.network[side]
		if n then
			section("network." .. side, { "t", "direction", "remote", "class", "path", "player", "argc", "types", "bytes", "issues" }, list(n.entries), function(x)
				return { x.t, x.direction, x.remote, x.class, x.path, x.player, x.argc, table.concat(list(x.types), "|"), x.bytes, table.concat(list(x.issues), "|") }
			end)
		end
		local r = report.runtime and report.runtime[side]
		if r then
			section("runtime." .. side, { "t", "kind", "class", "path", "prop", "old", "new", "source" }, list(r), function(x)
				return { x.t, x.kind, x.class, x.path, x.prop, x.old, x.new, x.source }
			end)
		end
		local a = report.actions and report.actions[side]
		if a then
			section("actions." .. side, { "t", "category", "kind", "summary" }, list(a.timeline), function(x)
				return { x.t, x.cat, x.kind, x.summary }
			end)
		end
		local s = report.assets and report.assets[side]
		if s then
			section("assets." .. side, { "key", "kind", "categories", "count", "level", "services", "reason", "firstLocation" }, list(s.assets), function(x)
				return { x.key, x.kind, table.concat(list(x.categories), "|"), x.count, x.level, table.concat(list(x.services), "|"), x.reason, list(x.locations)[1] }
			end)
		end
		local sc = report.scripts and report.scripts[side]
		if sc then
			local recs = side == "server" and list(sc.records) or list(sc)
			section("scripts." .. side, { "class", "fullName", "enabled", "runContext", "visibility", "runHint", "moduleStatus" }, recs, function(x)
				return { x.class, x.fullName, x.enabled, x.runContext, x.visibility, x.runHint, x.moduleStatus }
			end)
		end
		local e = report.errors and report.errors[side]
		if e then
			section("errors." .. side, { "t", "kind", "script", "message" }, list(e), function(x)
				return { x.t, x.kind, x.script, x.message }
			end)
		end
	end
	return table.concat(rows, "\n")
end

function ExportCenter.ToTXT(report: any): string
	local out = { "RUNTIME INSPECTOR REPORT", "generatedAt: " .. tostring(report.generatedAt), "scope: " .. tostring(report.scope), tostring(report.note), "" }
	local function add(s: string)
		table.insert(out, s)
	end
	if report.overview then
		add("== OVERVIEW ==")
		local c = report.overview.client
		if c then
			add(string.format("client: instances=%s scripts=%s remotes=%s risk=%s", tostring(c.explorer.total), tostring(c.scripts.total), tostring(c.remotes), tostring(c.riskScore)))
		end
		local s = report.overview.server
		if s then
			add(string.format("server: instances=%s scripts=%s remotes=%s risk=%s", tostring(s.explorer and s.explorer.total), tostring(s.scripts and s.scripts.total), tostring(s.remotes), tostring(s.riskScore)))
		end
		add("")
	end
	for _, side in { "client", "server" } do
		local f = report.findings and report.findings[side]
		if f then
			add("== FINDINGS (" .. side .. ") ==")
			for _, x in list(f) do
				add(string.format("[%s] %s x%s :: %s", tostring(x.severity), tostring(x.rule), tostring(x.count), tostring(x.path)))
				add("   detail : " .. tostring(x.detail))
				add("   alasan : " .. tostring(x.reason))
				add("   saran  : " .. tostring(x.recommendation))
			end
			add("")
		end
		local a = report.actions and report.actions[side]
		if a and a.chains then
			add("== ACTION CHAINS (" .. side .. ") ==")
			for _, ch in list(a.chains) do
				add(ch)
			end
			add("")
		end
		local n = report.network and report.network[side]
		if n then
			add("== NETWORK (" .. side .. ") ==")
			for _, x in list(n.entries) do
				add(string.format("%.3f %s %s argc=%s types=%s%s", tonumber(x.t) or 0, tostring(x.direction), tostring(x.path), tostring(x.argc), table.concat(list(x.types), ","), (#list(x.issues) > 0) and (" ISSUES: " .. table.concat(list(x.issues), "; ")) or ""))
			end
			add("")
		end
		local r = report.runtime and report.runtime[side]
		if r then
			add("== RUNTIME (" .. side .. ") ==")
			for _, x in list(r) do
				add(string.format("%.3f %-9s %-16s %s %s", tonumber(x.t) or 0, tostring(x.kind), tostring(x.class), tostring(x.path), x.prop and (tostring(x.prop) .. ": " .. tostring(x.old) .. " -> " .. tostring(x.new)) or ""))
			end
			add("")
		end
		local s = report.assets and report.assets[side]
		if s then
			add("== ASSETS (" .. side .. ") ==")
			for _, x in list(s.assets) do
				add(string.format("[%s] %s (%s) x%s %s", tostring(x.level), tostring(x.key), table.concat(list(x.categories), "|"), tostring(x.count), tostring(list(x.locations)[1])))
			end
			add("")
		end
		local e = report.errors and report.errors[side]
		if e then
			add("== ERRORS (" .. side .. ") ==")
			for _, x in list(e) do
				add(string.format("%.3f [%s] %s :: %s", tonumber(x.t) or 0, tostring(x.kind), tostring(x.script), tostring(x.message)))
			end
			add("")
		end
	end
	return table.concat(out, "\n")
end

function ExportCenter.Paginate(text: string, pageChars: number): { string }
	local pages = {}
	local i = 1
	while i <= #text do
		table.insert(pages, string.sub(text, i, i + pageChars - 1))
		i += pageChars
	end
	if #pages == 0 then
		pages[1] = ""
	end
	return pages
end

-- print bertahap ke Output (dapat disalin dari jendela Output Studio).
function ExportCenter.PrintToOutput(text: string, prefix: string)
	local chunk = 1800
	local total = math.ceil(#text / chunk)
	for i = 1, total do
		print(string.format("%s EXPORT %d/%d\n%s", prefix, i, total, string.sub(text, (i - 1) * chunk + 1, i * chunk)))
		if i % 20 == 0 then
			task.wait()
		end
	end
end

return ExportCenter
end

-- ===== Theme (ServerStorage/RuntimeInspector/ClientPackage/UI/Theme.luau) =====
__modules.Theme = function()
--[[
	Theme: token warna & tipografi dashboard. Kontras teks utama terhadap panel
	dipilih tinggi (teks terang di atas latar gelap) agar log padat tetap terbaca.
]]

local Theme = {
	Font = Enum.Font.BuilderSans,
	FontMedium = Enum.Font.BuilderSansMedium,
	FontBold = Enum.Font.BuilderSansBold,
	Mono = Enum.Font.RobotoMono,

	TextSize = 14,
	SmallText = 12,
	RowHeight = 22,

	Colors = {
		Window = Color3.fromRGB(17, 19, 24),
		Sidebar = Color3.fromRGB(23, 26, 33),
		Panel = Color3.fromRGB(28, 32, 40),
		PanelAlt = Color3.fromRGB(34, 38, 48),
		Row = Color3.fromRGB(28, 32, 40),
		RowAlt = Color3.fromRGB(32, 36, 45),
		RowSelected = Color3.fromRGB(44, 70, 110),
		Border = Color3.fromRGB(52, 58, 72),
		Text = Color3.fromRGB(232, 236, 243),
		TextDim = Color3.fromRGB(160, 168, 184),
		Accent = Color3.fromRGB(86, 156, 255),
		AccentText = Color3.fromRGB(10, 14, 22),
		Input = Color3.fromRGB(20, 23, 29),
		ChipOn = Color3.fromRGB(86, 156, 255),
		ChipOff = Color3.fromRGB(40, 45, 56),
	},

	Severity = {
		INFO = Color3.fromRGB(140, 150, 168),
		LOW = Color3.fromRGB(120, 200, 140),
		MEDIUM = Color3.fromRGB(240, 196, 80),
		HIGH = Color3.fromRGB(245, 140, 60),
		CRITICAL = Color3.fromRGB(240, 80, 90),
	},

	Visibility = {
		SERVER_ONLY = Color3.fromRGB(240, 110, 120),
		REPLICATED = Color3.fromRGB(110, 170, 255),
		OWNER_ONLY = Color3.fromRGB(190, 140, 255),
		SERVER_UNCLASSIFIED = Color3.fromRGB(150, 150, 150),
		CLIENT_UNVERIFIED = Color3.fromRGB(150, 158, 172),
		CLIENT_REPLICATED = Color3.fromRGB(120, 210, 150),
		CLIENT_LOCAL = Color3.fromRGB(250, 170, 80),
	},
}

return Theme
end

-- ===== Widgets (ServerStorage/RuntimeInspector/ClientPackage/UI/Widgets.luau) =====
__modules.Widgets = function()
--[[
	Widgets: helper pembuatan GUI. Semua elemen dibuat lewat New() agar properti
	diterapkan sebelum Parent di-set (lebih murah untuk layout engine).
]]

local Theme = __require("Theme")
local C = Theme.Colors

local Widgets = {}

function Widgets.New(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local inst = Instance.new(className)
	local parent = nil
	for k, v in props or {} do
		if k == "Parent" then
			parent = v
		else
			(inst :: any)[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
local New = Widgets.New

function Widgets.Corner(radius: number?): UICorner
	return New("UICorner", { CornerRadius = UDim.new(0, radius or 6) }) :: UICorner
end

function Widgets.Stroke(color: Color3?, thickness: number?): UIStroke
	return New("UIStroke", { Color = color or C.Border, Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) :: UIStroke
end

function Widgets.Padding(px: number): UIPadding
	local u = UDim.new(0, px)
	return New("UIPadding", { PaddingLeft = u, PaddingRight = u, PaddingTop = u, PaddingBottom = u }) :: UIPadding
end

function Widgets.HList(padding: number?): UIListLayout
	return New("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding or 6),
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}) :: UIListLayout
end

function Widgets.VList(padding: number?): UIListLayout
	return New("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding or 4),
	}) :: UIListLayout
end

function Widgets.Label(props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextSize = Theme.TextSize,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, 20),
	}
	for k, v in props do
		base[k] = v
	end
	return New("TextLabel", base) :: TextLabel
end

function Widgets.Button(text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local base = {
		Text = text,
		Font = Theme.FontMedium,
		TextSize = Theme.TextSize,
		TextColor3 = C.Text,
		BackgroundColor3 = C.ChipOff,
		AutoButtonColor = true,
		Size = UDim2.new(0, math.max(64, #text * 8 + 20), 0, 26),
	}
	for k, v in props or {} do
		base[k] = v
	end
	local b = New("TextButton", base, { Widgets.Corner(5) }) :: TextButton
	b.Activated:Connect(function()
		local ok, err = pcall(onClick)
		if not ok then
			warn("[RuntimeInspector] UI error: " .. tostring(err))
		end
	end)
	return b
end

-- Chip toggle. setOn(bool) mengubah tampilan.
function Widgets.Chip(text: string, on: boolean, onClick: () -> ()): (TextButton, (boolean) -> ())
	local b = Widgets.Button(text, onClick, { Size = UDim2.new(0, math.max(48, #text * 7 + 18), 0, 24), TextSize = Theme.SmallText })
	local function setOn(v: boolean)
		b.BackgroundColor3 = v and C.ChipOn or C.ChipOff
		b.TextColor3 = v and C.AccentText or C.Text
	end
	setOn(on)
	return b, setOn
end

function Widgets.TextInput(placeholder: string, props: { [string]: any }?): TextBox
	local base = {
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.TextDim,
		Text = "",
		Font = Theme.Font,
		TextSize = Theme.TextSize,
		TextColor3 = C.Text,
		BackgroundColor3 = C.Input,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0, 180, 0, 26),
	}
	for k, v in props or {} do
		base[k] = v
	end
	return New("TextBox", base, { Widgets.Corner(5), Widgets.Stroke(), New("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) }) :: TextBox
end

-- Panel detail teks yang bisa di-scroll (TextLabel AutomaticSize di dalam ScrollingFrame).
function Widgets.DetailPane(parent: Instance, maxChars: number): (ScrollingFrame, (string) -> ())
	local scroll = New("ScrollingFrame", {
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.Border,
		Parent = parent,
	}, { Widgets.Corner(6), Widgets.Padding(8) }) :: ScrollingFrame
	local label = New("TextLabel", {
		BackgroundTransparency = 1,
		Font = Theme.Mono,
		TextSize = Theme.SmallText,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		RichText = false,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -4, 0, 0),
		Text = "",
		Parent = scroll,
	}) :: TextLabel
	local function setText(text: string)
		if #text > maxChars then
			text = string.sub(text, 1, maxChars) .. "\n...(dipotong " .. (#text - maxChars) .. " karakter; gunakan Export untuk data lengkap)"
		end
		label.Text = text
		scroll.CanvasPosition = Vector2.zero
	end
	return scroll, setText
end

function Widgets.SeverityColor(sev: string?): Color3
	return Theme.Severity[sev or "INFO"] or Theme.Severity.INFO
end

return Widgets
end

-- ===== VirtualList (ServerStorage/RuntimeInspector/ClientPackage/UI/VirtualList.luau) =====
__modules.VirtualList = function()
--[[
	VirtualList: list ber-virtualisasi. Hanya baris yang terlihat yang dibuat/di-render,
	sehingga ribuan entri log tidak membuat ribuan GuiObject.
	opts = {
		rowHeight = 22,
		render = function(row: TextButton, item, index, selected: boolean) end,
		onSelect = function(item, index) end,
	}
]]

local Theme = __require("Theme")
local Widgets = __require("Widgets")
local C = Theme.Colors

local VirtualList = {}
VirtualList.__index = VirtualList

function VirtualList.new(parent: Instance, opts: { [string]: any })
	local self = setmetatable({
		rowHeight = opts.rowHeight or Theme.RowHeight,
		render = opts.render,
		onSelect = opts.onSelect,
		items = {},
		pool = {},
		rowIndex = {},
		selectedItem = nil, -- seleksi berdasarkan identitas item (stabil saat list di-refresh)
		conns = {},
	}, VirtualList)

	self.frame = Widgets.New("ScrollingFrame", {
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Size = opts.size or UDim2.fromScale(1, 1),
		Position = opts.position or UDim2.new(),
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ClipsDescendants = true,
		Parent = parent,
	}, { Widgets.Corner(6) })

	table.insert(self.conns, self.frame:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self:_layout()
	end))
	table.insert(self.conns, self.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end))
	return self
end

function VirtualList:_row(k: number): TextButton
	local row = self.pool[k]
	if row then
		return row
	end
	row = Widgets.New("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		BackgroundColor3 = C.Row,
		Size = UDim2.new(1, -8, 0, self.rowHeight),
		Font = Theme.Mono,
		TextSize = Theme.SmallText,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = self.frame,
	}, { Widgets.New("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) }) :: TextButton
	row.Activated:Connect(function()
		local i = self.rowIndex[row]
		if i and self.items[i] ~= nil then
			self.selectedItem = self.items[i]
			self:_layout()
			if self.onSelect then
				local ok, err = pcall(self.onSelect, self.items[i], i)
				if not ok then
					warn("[RuntimeInspector] onSelect error: " .. tostring(err))
				end
			end
		end
	end)
	self.pool[k] = row
	return row
end

function VirtualList:_layout()
	local h = self.rowHeight
	local viewport = self.frame.AbsoluteSize.Y
	local scrollY = self.frame.CanvasPosition.Y
	local first = math.max(1, math.floor(scrollY / h) + 1)
	local visibleCount = math.ceil(viewport / h) + 2
	local k = 0
	for i = first, math.min(#self.items, first + visibleCount - 1) do
		k += 1
		local row = self:_row(k)
		row.Visible = true
		row.Position = UDim2.new(0, 2, 0, (i - 1) * h)
		local selected = self.items[i] == self.selectedItem
		row.BackgroundColor3 = selected and C.RowSelected or ((i % 2 == 0) and C.RowAlt or C.Row)
		self.rowIndex[row] = i
		local ok, err = pcall(self.render, row, self.items[i], i, selected)
		if not ok then
			row.Text = "<render error> " .. tostring(err)
		end
	end
	for j = k + 1, #self.pool do
		self.pool[j].Visible = false
		self.rowIndex[self.pool[j]] = nil
	end
end

function VirtualList:SetItems(items: { any }, keepSelection: boolean?)
	self.items = items
	if not keepSelection then
		self.selectedItem = nil
	end
	self.frame.CanvasSize = UDim2.new(0, 0, 0, #items * self.rowHeight + 4)
	self:_layout()
end

function VirtualList:Selected(): any
	return self.selectedItem
end

function VirtualList:Destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
	self.frame:Destroy()
end

return VirtualList
end

-- ===== TreeView (ServerStorage/RuntimeInspector/ClientPackage/UI/TreeView.luau) =====
__modules.TreeView = function()
--[[
	TreeView: directory tree yang bisa dibuka/tutup, di atas VirtualList.
	Children dimuat malas (lazy) lewat provider dan dipaging (tombol "muat lagi").
	provider = {
		Roots    = function() -> { node }                        (boleh yield)
		Children = function(key, offset, limit) -> { node }, total (boleh yield)
	}
	node = { key, label?, name, class, childCount, vis, runtime }
]]

local Theme = __require("Theme")
local VirtualList = __require("VirtualList")

local TreeView = {}
TreeView.__index = TreeView

local PAGE = 200

function TreeView.new(parent: Instance, provider: any, onSelect: (any) -> ())
	local self = setmetatable({ provider = provider, onSelect = onSelect, roots = {}, flat = {}, generation = 0 }, TreeView)
	self.list = VirtualList.new(parent, {
		render = function(row, node)
			local indent = string.rep("  ", node.depth)
			if node.isMore then
				row.Text = indent .. "  [+ muat " .. node.remaining .. " lagi]"
				row.TextColor3 = Theme.Colors.Accent
				return
			end
			local arrow = node.childCount and node.childCount > 0 and (node.expanded and "- " or "+ ") or "  "
			local label = node.label or node.name
			local badge = node.vis and (" {" .. node.vis .. "}") or ""
			local runtime = node.runtime and " *NEW" or ""
			local loading = node.loading and " (memuat...)" or ""
			row.Text = string.format("%s%s%s  [%s]%s%s%s", indent, arrow, label, node.class or "?", badge, runtime, loading)
			row.TextColor3 = node.vis and Theme.Visibility[node.vis] or Theme.Colors.Text
		end,
		onSelect = function(node)
			if node.isMore then
				self:_loadMore(node)
				return
			end
			self:Toggle(node)
			self.onSelect(node)
		end,
	})
	return self
end

function TreeView:_flatten()
	local flat = {}
	local stack = {}
	for i = #self.roots, 1, -1 do
		table.insert(stack, self.roots[i])
	end
	while #stack > 0 do
		local node = table.remove(stack)
		table.insert(flat, node)
		if node.expanded and node.children then
			for i = #node.children, 1, -1 do
				table.insert(stack, node.children[i])
			end
		end
	end
	self.flat = flat
	self.list:SetItems(flat, true)
end

local function adopt(nodes: { any }, depth: number, parentNode: any?)
	for _, n in nodes do
		n.depth = depth
		n.parentNode = parentNode
	end
	return nodes
end

function TreeView:Load()
	self.generation += 1
	local gen = self.generation
	self.roots = {}
	self:_flatten()
	task.spawn(function()
		local ok, roots = pcall(self.provider.Roots, self.provider)
		if gen ~= self.generation then
			return
		end
		self.roots = ok and adopt(roots or {}, 0, nil) or {}
		self:_flatten()
	end)
end

function TreeView:_fetch(node: any, offset: number)
	node.loading = true
	self:_flatten()
	task.spawn(function()
		local ok, nodes, total = pcall(self.provider.Children, self.provider, node.key, offset, PAGE)
		node.loading = false
		if not ok then
			nodes, total = {}, 0
		end
		local children = node.children or {}
		if children[#children] and children[#children].isMore then
			table.remove(children)
		end
		for _, n in adopt(nodes or {}, node.depth + 1, node) do
			table.insert(children, n)
		end
		local loaded = #children
		if total and total > loaded then
			table.insert(children, { isMore = true, depth = node.depth + 1, remaining = total - loaded, owner = node, offset = loaded })
		end
		node.children = children
		node.childCount = math.max(node.childCount or 0, loaded)
		self:_flatten()
	end)
end

function TreeView:Toggle(node: any)
	if not node.childCount or node.childCount == 0 then
		return
	end
	if node.expanded then
		node.expanded = false
		self:_flatten()
		return
	end
	node.expanded = true
	if node.children == nil then
		self:_fetch(node, 0)
	else
		self:_flatten()
	end
end

function TreeView:_loadMore(moreNode: any)
	self:_fetch(moreNode.owner, moreNode.offset)
end

function TreeView:Redraw()
	self.list:SetItems(self.flat, true)
end

function TreeView:SetVisible(v: boolean)
	self.list.frame.Visible = v
end

function TreeView:Destroy()
	self.list:Destroy()
end

return TreeView
end

-- ===== ListDetailView (ServerStorage/RuntimeInspector/ClientPackage/UI/ListDetailView.luau) =====
__modules.ListDetailView = function()
--[[
	ListDetailView: komponen generik "toolbar + list virtual + panel detail".
	Dipakai oleh hampir semua tab (Scripts, Assets, Runtime, Actions, Network, Security).

	spec = {
		groups = { { id = "env", options = { {id="client",label="Client"}, ... }, default = "client" }, ... },
		search = true,
		buttons = { { label = "Rescan", onClick = function(view) end } },
		getItems = function(state) -> { item } ,   -- state.env, state.<groupId>, state.search
		rowText  = function(item, state) -> string,
		rowColor = function(item, state) -> Color3?,
		detail   = function(item, state, setDetail) -> string?   (boleh memanggil setDetail async)
		header   = function(state) -> string?      -- teks ringkasan di atas list
		listWidth = 0.58,
	}
]]

local Theme = __require("Theme")
local Widgets = __require("Widgets")
local VirtualList = __require("VirtualList")
local New = Widgets.New
local C = Theme.Colors

local ListDetailView = {}
ListDetailView.__index = ListDetailView

function ListDetailView.new(parent: Instance, spec: { [string]: any }, maxDetailChars: number)
	local self = setmetatable({ spec = spec, state = { search = "" }, chipSetters = {}, selected = nil }, ListDetailView)

	local root = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = parent })
	self.root = root

	local toolbar = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = root }, { Widgets.HList(6) })
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	for _, group in spec.groups or {} do
		self.state[group.id] = group.default or (group.options[1] and group.options[1].id)
		self.chipSetters[group.id] = {}
		for _, opt in group.options do
			local chip, setOn
			chip, setOn = Widgets.Chip(opt.label, self.state[group.id] == opt.id, function()
				self.state[group.id] = opt.id
				for id, setter in self.chipSetters[group.id] do
					setter(id == opt.id)
				end
				self.view.list.selectedItem = nil
				self:Refresh()
			end)
			chip.LayoutOrder = nextOrder()
			chip.Parent = toolbar
			self.chipSetters[group.id][opt.id] = setOn
		end
		local sep = New("Frame", { BackgroundColor3 = C.Border, BorderSizePixel = 0, Size = UDim2.new(0, 1, 0, 18), LayoutOrder = nextOrder(), Parent = toolbar })
		sep.Name = "Sep"
	end

	if spec.search ~= false then
		local box = Widgets.TextInput("cari...", { Size = UDim2.new(0, 150, 0, 24), LayoutOrder = nextOrder(), Parent = toolbar })
		box.FocusLost:Connect(function()
			self.state.search = string.lower(box.Text)
			self:Refresh()
		end)
	end
	for _, b in spec.buttons or {} do
		local btn = Widgets.Button(b.label, function()
			b.onClick(self)
		end, { Size = UDim2.new(0, math.max(60, #b.label * 7 + 16), 0, 24), TextSize = Theme.SmallText, LayoutOrder = nextOrder() })
		btn.Parent = toolbar
	end

	self.headerLabel = Widgets.Label({
		Text = "",
		TextColor3 = C.TextDim,
		TextSize = Theme.SmallText,
		Position = UDim2.new(0, 0, 0, 32),
		Size = UDim2.new(1, 0, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = root,
	})

	local body = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 54), Size = UDim2.new(1, 0, 1, -54), Parent = root })
	local listW = spec.listWidth or 0.58
	local listHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(listW, -4, 1, 0), Parent = body })
	local detailHolder = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(listW, 4, 0, 0), Size = UDim2.new(1 - listW, -4, 1, 0), Parent = body })
	local _, setDetail = Widgets.DetailPane(detailHolder, maxDetailChars)
	self.setDetail = setDetail
	setDetail("Pilih baris untuk melihat detail.")

	self.view = { list = nil }
	self.view.list = VirtualList.new(listHolder, {
		render = function(row, item)
			row.Text = spec.rowText(item, self.state)
			row.TextColor3 = (spec.rowColor and spec.rowColor(item, self.state)) or C.Text
		end,
		onSelect = function(item)
			self.selected = item
			local text = spec.detail(item, self.state, function(t)
				if self.selected == item then
					setDetail(t)
				end
			end)
			if text then
				setDetail(text)
			end
		end,
	})
	return self
end

function ListDetailView:Refresh()
	local ok, items = pcall(self.spec.getItems, self.state)
	if not ok then
		self.headerLabel.Text = "Error: " .. tostring(items)
		return
	end
	local search = self.state.search
	if search ~= "" then
		local filtered = {}
		for _, item in items do
			local okText, text = pcall(self.spec.rowText, item, self.state)
			if okText and string.find(string.lower(text), search, 1, true) then
				table.insert(filtered, item)
			end
		end
		items = filtered
	end
	self.items = items
	self.view.list:SetItems(items, true)
	if self.spec.header then
		local okH, h = pcall(self.spec.header, self.state, items)
		self.headerLabel.Text = okH and (h or "") or ("header error: " .. tostring(h))
	else
		self.headerLabel.Text = #items .. " entri"
	end
end

function ListDetailView:Destroy()
	self.view.list:Destroy()
	self.root:Destroy()
end

return ListDetailView
end

-- ===== StandaloneMain (standalone/StandaloneMain.luau) =====
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
local gui = New("ScreenGui", {
    Name = "RuntimeInspectorDelta", ResetOnSpawn = false, IgnoreGuiInset = true,
    DisplayOrder = 9999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = player:WaitForChild("PlayerGui"),
}) :: ScreenGui

local old = gui.Parent:FindFirstChild("RuntimeInspectorDelta")
if old and old ~= gui then old:Destroy() end

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

local function makeReport()
    local categories = {}
    for _, category in ExportCenter.Categories do categories[category] = true end
    local report = ExportCenter.Collect(agent, categories, "client")
    report.note = "Pemindaian client-only. Data server, ServerStorage, ServerScriptService, dan Script.Source yang dilindungi tidak dapat dibaca dari client. Batas MaxNodes dapat membuat scan terpotong."
    report.scan = {
        baselineComplete = agent.explorer.baselineDone == true,
        baselineTruncated = agent.explorer.baselineTruncated == true,
        instanceCount = agent.explorer:Stats().total or 0,
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
            resultBox.Text = scanText
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
    local clipboard = (getgenv and getgenv().setclipboard) or (syn and syn.write_clipboard) or setclipboard
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
    local writer = (getgenv and getgenv().writefile) or writefile
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
