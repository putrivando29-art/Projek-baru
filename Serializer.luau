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
