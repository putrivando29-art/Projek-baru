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
