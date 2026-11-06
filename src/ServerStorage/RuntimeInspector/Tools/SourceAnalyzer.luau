--[[
	SourceAnalyzer (STUDIO-ONLY)
	Analisis statis Source semua Script/LocalScript/ModuleScript + map aset ber-PluginSecurity.
	Hanya bekerja dari konteks yang diizinkan membaca Source:
	  - Plugin Studio (plugin/Main.server.luau), atau
	  - Command Bar Studio:
	      require(game.ServerStorage.RuntimeInspector.Tools.SourceAnalyzer).Run()
	Dari script runtime biasa, pembacaan Source gagal (ProtectedString) dan modul ini
	melaporkan script sebagai "unreadable"; tidak ada cara resmi untuk melewatinya.

	Hasil: ModuleScript ServerStorage.RuntimeInspectorManifest (di luar folder Rojo).

	Ini analisis berbasis pola teks (heuristik), bukan parser Luau penuh:
	- require dengan path dinamis (variabel dihitung runtime) tidak bisa di-resolve.
	- Komentar dibuang dengan pola sederhana; string yang berisi "--" bisa terpotong.
]]

local ServerStorage = game:GetService("ServerStorage")

local SourceAnalyzer = {}

SourceAnalyzer.Services = {
	"Workspace", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage",
	"StarterGui", "StarterPack", "StarterPlayer", "Lighting", "SoundService", "Teams",
	"TextChatService", "Chat", "MaterialService",
}

SourceAnalyzer.OutputName = "RuntimeInspectorManifest"
SourceAnalyzer.MaxAssetRefs = 5000

local function readSource(s: LuaSourceContainer): (string?, string?)
	local okEditor, editorSource = pcall(function()
		return game:GetService("ScriptEditorService"):GetEditorSource(s)
	end)
	if okEditor and type(editorSource) == "string" then
		return editorSource, nil
	end
	local okRaw, raw = pcall(function()
		return (s :: any).Source
	end)
	if okRaw and type(raw) == "string" then
		return raw, nil
	end
	return nil, "Source tidak dapat dibaca dari konteks ini (gunakan plugin / Command Bar)"
end

local function stripComments(src: string): string
	src = string.gsub(src, "%-%-%[(=*)%[.-%]%1%]", "")
	src = string.gsub(src, "%-%-[^\n]*", "")
	return src
end

---------------------------------------------------------------- resolusi require

-- Mengubah ekspresi seperti script.Parent:WaitForChild("Util").Maid menjadi langkah-langkah.
local function parseChain(expr: string): { any }?
	local s = string.gsub(expr, "%s+", "")
	local steps = {}
	local rest
	local service = string.match(s, "^game:GetService%([\"']([%w_]+)[\"']%)")
	if service then
		table.insert(steps, { "service", service })
		rest = string.sub(s, #string.match(s, "^game:GetService%([\"'][%w_]+[\"']%)") + 1)
	elseif string.match(s, "^script%f[^%w_]") then
		table.insert(steps, { "script" })
		rest = string.sub(s, 7)
	elseif string.match(s, "^workspace%f[^%w_]") then
		table.insert(steps, { "service", "Workspace" })
		rest = string.sub(s, 10)
	elseif string.match(s, "^game%f[^%w_]") then
		table.insert(steps, { "game" })
		rest = string.sub(s, 5)
	else
		local ident = string.match(s, "^([%a_][%w_]*)")
		if not ident then
			return nil
		end
		table.insert(steps, { "alias", ident })
		rest = string.sub(s, #ident + 1)
	end
	local guard = 0
	while #rest > 0 do
		guard += 1
		if guard > 40 then
			return nil
		end
		local m
		m = string.match(rest, "^%.Parent")
		if m and not string.match(rest, "^%.Parent[%w_]") then
			table.insert(steps, { "parent" })
			rest = string.sub(rest, 8)
			continue
		end
		local name = string.match(rest, "^%.([%a_][%w_]*)")
		if name then
			table.insert(steps, { "child", name })
			rest = string.sub(rest, #name + 2)
			continue
		end
		local full, child = string.match(rest, "^(%[[\"']([^\"']+)[\"']%])")
		if full then
			table.insert(steps, { "child", child })
			rest = string.sub(rest, #full + 1)
			continue
		end
		local call, method, arg = string.match(rest, "^(:([%a]+)%([\"']([^\"']+)[\"'][^%)]*%))")
		if call and (method == "WaitForChild" or method == "FindFirstChild" or method == "FindFirstChildOfClass") then
			table.insert(steps, { method == "FindFirstChildOfClass" and "childOfClass" or "child", arg })
			rest = string.sub(rest, #call + 1)
			continue
		end
		if call and method == "GetService" then
			table.insert(steps, { "service", arg })
			rest = string.sub(rest, #call + 1)
			continue
		end
		return nil
	end
	return steps
end

local function resolve(steps: { any }, scriptInst: Instance, aliases: { [string]: string }, depth: number): Instance?
	if depth > 6 then
		return nil
	end
	local cur: Instance? = nil
	for i, step in steps do
		local kind = step[1]
		if i == 1 then
			if kind == "script" then
				cur = scriptInst
			elseif kind == "game" then
				cur = game
			elseif kind == "service" then
				local ok, svc = pcall(game.GetService, game, step[2])
				cur = ok and svc or nil
			elseif kind == "alias" then
				local rhs = aliases[step[2]]
				local sub = rhs and parseChain(rhs)
				cur = sub and resolve(sub, scriptInst, aliases, depth + 1) or nil
			end
		elseif cur then
			if kind == "parent" then
				cur = cur.Parent
			elseif kind == "child" then
				cur = cur:FindFirstChild(step[2])
			elseif kind == "childOfClass" then
				cur = cur:FindFirstChildOfClass(step[2])
			elseif kind == "service" then
				local ok, svc = pcall(game.GetService, game, step[2])
				cur = ok and svc or nil
			end
		end
		if cur == nil then
			return nil
		end
	end
	return cur
end

---------------------------------------------------------------- analisis per script

local REMOTE_METHODS = { "FireServer", "InvokeServer", "FireClient", "FireAllClients", "InvokeClient" }
local SUSPICIOUS_PARAMS = { "damage", "dmg", "speed", "walkspeed", "cframe", "position", "pos", "health", "amount", "price", "cost", "reward" }

function SourceAnalyzer.AnalyzeScript(s: LuaSourceContainer): ({ [string]: any }?, { any }, string?)
	local src, err = readSource(s)
	if not src then
		return nil, {}, err
	end
	local code = stripComments(src)
	local info = {
		class = s.ClassName,
		lines = select(2, string.gsub(src, "\n", "\n")) + 1,
		requires = {},
		remotes = {},
		assetIds = {},
		warnings = {},
	}
	local assetRefs = {}

	-- alias lokal: local X = game:GetService("Y") / local X = script.Parent.Z
	local aliases = {}
	for name, rhs in string.gmatch(code, "local%s+([%a_][%w_]*)%s*=%s*([^\n;]+)") do
		local trimmed = string.match(rhs, "^%s*(.-)%s*$")
		if trimmed and (string.match(trimmed, "^game") or string.match(trimmed, "^script") or string.match(trimmed, "^workspace") or string.match(trimmed, "^[%a_][%w_]*[%.:%[]")) then
			if not string.match(trimmed, "^require") then
				aliases[name] = trimmed
			end
		end
	end

	local seenReq = {}
	for inner in string.gmatch(code, "require%s*(%b())") do
		local expr = string.sub(inner, 2, -2)
		local trimmed = string.match(expr, "^%s*(.-)%s*$") or expr
		local label
		if string.match(trimmed, "^%d+$") then
			label = "assetId:" .. trimmed
			table.insert(info.warnings, "require(" .. trimmed .. "): memuat ModuleScript dari asset ID (kode eksternal; risiko backdoor bila bukan milik Anda)")
		else
			local steps = parseChain(trimmed)
			local target = steps and resolve(steps, s, aliases, 0)
			label = target and target:GetFullName() or ("?" .. string.sub(trimmed, 1, 80))
		end
		if not seenReq[label] then
			seenReq[label] = true
			table.insert(info.requires, label)
		end
	end

	local seenRemote = {}
	for _, method in REMOTE_METHODS do
		for receiver in string.gmatch(code, "([%w_%.]+)%s*:%s*" .. method .. "%s*%(") do
			local key = receiver .. ":" .. method
			if not seenRemote[key] then
				seenRemote[key] = true
				table.insert(info.remotes, key)
			end
		end
	end
	for receiver, event in string.gmatch(code, "([%w_%.]+)%.(On[%a]+Event)") do
		local key = receiver .. "." .. event
		if not seenRemote[key] then
			seenRemote[key] = true
			table.insert(info.remotes, key)
		end
	end
	for receiver in string.gmatch(code, "([%w_%.]+)%.OnServerInvoke%s*=") do
		table.insert(info.remotes, receiver .. ".OnServerInvoke")
	end

	-- parameter handler server yang terlihat seperti nilai otoritatif dari client
	for params in string.gmatch(code, "OnServerEvent:Connect%(%s*function%s*%(([^%)]*)%)") do
		local lower = string.lower(params)
		for _, p in SUSPICIOUS_PARAMS do
			if string.find(lower, "%f[%w_]" .. p .. "%f[^%w_]") then
				table.insert(info.warnings, "OnServerEvent menerima parameter '" .. p .. "' dari client: nilai ini harus dihitung/divalidasi server, bukan dipercaya")
				break
			end
		end
	end

	if string.find(code, "%f[%w_]loadstring%f[^%w_]") then
		table.insert(info.warnings, "loadstring: eksekusi kode dinamis")
	end
	if string.find(code, "%f[%w_]getfenv%f[^%w_]") or string.find(code, "%f[%w_]setfenv%f[^%w_]") then
		table.insert(info.warnings, "getfenv/setfenv: mematikan optimasi Luau; sering dipakai obfuscation/backdoor")
	end
	if string.find(code, "LoadAsset%s*%(") then
		table.insert(info.warnings, "InsertService:LoadAsset: memuat aset/model saat runtime")
	end
	if s:IsA("LocalScript") and (string.find(code, ":TakeDamage%s*%(") or string.find(code, "%.Health%s*=[^=]")) then
		table.insert(info.warnings, "LocalScript mengubah Health/TakeDamage: perubahan client tidak berlaku di server; damage harus di server")
	end

	-- asset ID di source (per baris agar ada nomor baris)
	local lineNo = 0
	local seenAsset = {}
	for line in string.gmatch(src .. "\n", "([^\n]*)\n") do
		lineNo += 1
		for id in string.gmatch(line, "rbxassetid://(%d+)") do
			table.insert(assetRefs, { id = id, script = s:GetFullName(), line = lineNo, context = string.sub(string.match(line, "^%s*(.-)%s*$") or line, 1, 120) })
			if not seenAsset[id] then
				seenAsset[id] = true
				table.insert(info.assetIds, id)
			end
		end
		for id in string.gmatch(line, "[?&]id=(%d+)") do
			table.insert(assetRefs, { id = id, script = s:GetFullName(), line = lineNo, context = string.sub(string.match(line, "^%s*(.-)%s*$") or line, 1, 120) })
			if not seenAsset[id] then
				seenAsset[id] = true
				table.insert(info.assetIds, id)
			end
		end
	end
	return info, assetRefs, nil
end

---------------------------------------------------------------- map aset PluginSecurity

local MAP_PROPS = { "ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap" }

local function scanMaterialMaps(inst: Instance, out: { any })
	if inst:IsA("SurfaceAppearance") or inst:IsA("MaterialVariant") then
		for _, prop in MAP_PROPS do
			local ok, value = pcall(function()
				return (inst :: any)[prop]
			end)
			if ok and type(value) == "string" then
				local id = string.match(value, "rbxassetid://(%d+)") or string.match(value, "[?&]id=(%d+)")
				if id then
					table.insert(out, { id = id, script = inst:GetFullName(), line = 0, context = inst.ClassName .. "." .. prop })
				end
			end
		end
	end
end

---------------------------------------------------------------- serialisasi ke Luau

local function toLuau(value: any, indent: string): string
	local t = type(value)
	if t == "string" then
		return string.format("%q", value)
	elseif t == "number" or t == "boolean" then
		return tostring(value)
	elseif t == "nil" then
		return "nil"
	elseif t == "table" then
		local inner = indent .. "\t"
		local parts = {}
		if #value > 0 then
			for _, v in ipairs(value) do
				table.insert(parts, inner .. toLuau(v, inner))
			end
		else
			local keys = {}
			for k in value do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for _, k in keys do
				table.insert(parts, inner .. "[" .. string.format("%q", tostring(k)) .. "] = " .. toLuau(value[k], inner))
			end
		end
		if #parts == 0 then
			return "{}"
		end
		return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
	end
	return "nil"
end

---------------------------------------------------------------- run

function SourceAnalyzer.Analyze(): { [string]: any }
	local manifest = {
		generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		generator = "RuntimeInspector SourceAnalyzer (analisis pola teks)",
		scripts = {},
		assetRefs = {},
		unreadable = {},
		totals = { scripts = 0, warnings = 0, requires = 0, assetRefs = 0 },
	}
	for _, name in SourceAnalyzer.Services do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			for _, inst in service:GetDescendants() do
				if inst:IsA("LuaSourceContainer") and inst.Name ~= SourceAnalyzer.OutputName then
					local info, refs, err = SourceAnalyzer.AnalyzeScript(inst)
					if info then
						manifest.scripts[inst:GetFullName()] = info
						manifest.totals.scripts += 1
						manifest.totals.warnings += #info.warnings
						manifest.totals.requires += #info.requires
						for _, r in refs do
							if #manifest.assetRefs < SourceAnalyzer.MaxAssetRefs then
								table.insert(manifest.assetRefs, r)
							end
						end
					else
						table.insert(manifest.unreadable, inst:GetFullName() .. " :: " .. tostring(err))
					end
				else
					scanMaterialMaps(inst, manifest.assetRefs)
				end
			end
		end
	end
	manifest.totals.assetRefs = #manifest.assetRefs
	return manifest
end

function SourceAnalyzer.Write(manifest: { [string]: any }): ModuleScript
	local source = "-- Dihasilkan otomatis oleh RuntimeInspector SourceAnalyzer. Jangan edit manual.\nreturn " .. toLuau(manifest, "") .. "\n"
	local module = ServerStorage:FindFirstChild(SourceAnalyzer.OutputName)
	if not (module and module:IsA("ModuleScript")) then
		if module then
			module:Destroy()
		end
		module = Instance.new("ModuleScript")
		module.Name = SourceAnalyzer.OutputName
		module.Parent = ServerStorage
	end
	local okUpdate = pcall(function()
		game:GetService("ScriptEditorService"):UpdateSourceAsync(module, function()
			return source
		end)
	end)
	if not okUpdate then
		(module :: any).Source = source
	end
	return module :: ModuleScript
end

function SourceAnalyzer.Run(): { [string]: any }
	local t0 = os.clock()
	local manifest = SourceAnalyzer.Analyze()
	local module = SourceAnalyzer.Write(manifest)
	print(string.format("[RuntimeInspector] SourceAnalyzer: %d script, %d require, %d peringatan, %d referensi aset, %d tidak terbaca (%.2fs) -> %s",
		manifest.totals.scripts, manifest.totals.requires, manifest.totals.warnings, manifest.totals.assetRefs, #manifest.unreadable, os.clock() - t0, module:GetFullName()))
	for path, info in manifest.scripts do
		for _, w in info.warnings do
			warn("[RuntimeInspector] " .. path .. ": " .. w)
		end
	end
	return manifest
end

return SourceAnalyzer
