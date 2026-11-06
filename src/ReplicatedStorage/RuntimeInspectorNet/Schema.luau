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
