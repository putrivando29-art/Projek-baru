--[[ Tab 3: Script Inspector: daftar Script/LocalScript/ModuleScript, exports (probe), dependency (manifest), error. ]]

return function(ctx: any, container: Frame)
	local agent = ctx.agent
	local A = agent.Protocol.Actions
	local Theme = ctx.Theme

	local function fetchServer(force: boolean?)
		if agent.server.scriptsLoading then
			return
		end
		agent.server.scriptsLoading = true
		task.spawn(function()
			local records, offset, total, errors, counts = {}, 0, nil, {}, nil
			repeat
				local r = agent.link:Call(A.ScriptsList, { offset = offset, limit = 300, refresh = force and offset == 0 })
				if type(r) ~= "table" or r.error then
					break
				end
				for _, rec in r.records or {} do
					table.insert(records, rec)
				end
				total = r.total
				errors = r.errors or errors
				counts = r.counts
				offset += #(r.records or {})
			until #(r.records or {}) == 0 or offset >= (total or 0)
			agent.server.scripts = { records = records, errors = errors, counts = counts }
			local m = agent.link:Call(A.ScriptsManifest)
			if type(m) == "table" and not m.error then
				agent.server.manifest = m
			end
			agent.server.scriptsLoading = false
		end)
	end

	local function manifestEntry(fullName: string)
		local m = agent.server.manifest
		return m and m.scripts and m.scripts[fullName] or nil
	end

	local function formatRecord(r)
		local lines = {
			"Name        : " .. tostring(r.name),
			"ClassName   : " .. tostring(r.class),
			"FullName    : " .. tostring(r.fullName),
			"Enabled     : " .. tostring(r.enabled == nil and "n/a" or r.enabled),
			"RunContext  : " .. tostring(r.runContext or "n/a"),
			"Visibility  : " .. tostring(r.visibility),
			"Berjalan    : " .. tostring(r.runHint),
			"Source      : tidak dibaca (ProtectedString; hanya plugin/Command Bar Studio)",
		}
		if r.exposure then
			table.insert(lines, "Keamanan    : " .. r.exposure)
		end
		if r.class == "ModuleScript" then
			table.insert(lines, "Status modul: " .. tostring(r.moduleStatus))
			local p = r.probe
			if p then
				table.insert(lines, string.format("Probe       : %s, load %s ms", tostring(p.status), tostring(p.loadTimeMs or "-")))
				if p.error then
					table.insert(lines, "Error       : " .. tostring(p.error))
				end
				if p.exports then
					table.insert(lines, "Return type : " .. tostring(p.exports.type) .. (p.exports.hasMetatable and " (metatable)" or "") .. (p.exports.frozen and " (frozen)" or ""))
					if p.exports.info then
						table.insert(lines, "  " .. p.exports.info)
					end
					for _, e in p.exports.entries or {} do
						table.insert(lines, string.format("  %-28s %-9s %s", e.key, e.type, e.info))
					end
				end
			end
		end
		table.insert(lines, "")
		table.insert(lines, "[Attributes]")
		local any = false
		for k, v in r.attributes or {} do
			any = true
			table.insert(lines, "  " .. k .. " = " .. tostring(v))
		end
		if not any then
			table.insert(lines, "  (none)")
		end
		table.insert(lines, "")
		table.insert(lines, "[Dependency & referensi (analisis statis plugin)]")
		local m = manifestEntry(r.fullName)
		if not agent.server.manifest then
			table.insert(lines, "  Manifest belum dimuat (pilih Server sekali) atau plugin belum dijalankan.")
		elseif not m then
			table.insert(lines, "  Tidak ada entri manifest untuk script ini.")
		else
			table.insert(lines, "  Baris source : " .. tostring(m.lines))
			for _, dep in m.requires or {} do
				table.insert(lines, "  require -> " .. tostring(dep))
			end
			for _, rem in m.remotes or {} do
				table.insert(lines, "  remote  -> " .. tostring(rem))
			end
			for _, id in m.assetIds or {} do
				table.insert(lines, "  asset   -> " .. tostring(id))
			end
			for _, w in m.warnings or {} do
				table.insert(lines, "  PERINGATAN: " .. tostring(w))
			end
		end
		return table.concat(lines, "\n")
	end

	local view = ctx.ListDetailView.new(container, {
		groups = {
			{ id = "env", options = { { id = "client", label = "Client" }, { id = "server", label = "Server" } } },
			{ id = "class", options = {
				{ id = "all", label = "Semua" },
				{ id = "Script", label = "Script" },
				{ id = "LocalScript", label = "LocalScript" },
				{ id = "ModuleScript", label = "Module" },
				{ id = "errors", label = "Error" },
			} },
		},
		buttons = {
			{ label = "Rescan", onClick = function(v)
				if v.state.env == "client" then
					task.spawn(function()
						agent.scripts:Collect()
						v:Refresh()
					end)
				else
					fetchServer(true)
				end
			end },
			{ label = "Probe require", onClick = function(v)
				local r = v.selected
				if not r or r.class ~= "ModuleScript" then
					v.setDetail("Pilih ModuleScript dulu.")
					return
				end
				v.setDetail("Probing... (require dapat menjalankan modul dan memicu efek samping)")
				task.spawn(function()
					local probe
					if v.state.env == "client" then
						probe = agent.scripts:Probe(r.inst)
					else
						probe = agent.link:Call(A.ScriptsProbe, { id = r.id })
					end
					r.probe = probe
					r.moduleStatus = probe and probe.status or "?"
					v.setDetail(formatRecord(r))
				end)
			end },
		},
		getItems = function(state)
			local errorsMode = state.class == "errors"
			if state.env == "server" and not agent.server.scripts then
				fetchServer(false)
				return {}
			end
			if errorsMode then
				local src = state.env == "client" and agent.scripts:Errors() or (agent.server.scripts.errors or {})
				local out = {}
				for i = #src, 1, -1 do
					table.insert(out, src[i])
				end
				return out
			end
			local src = state.env == "client" and agent.scripts.records or agent.server.scripts.records
			local out = {}
			for _, r in src do
				if state.class == "all" or r.class == state.class then
					table.insert(out, r)
				end
			end
			return out
		end,
		rowText = function(item, state)
			if state.class == "errors" then
				return string.format("%.2f [%s] %s :: %s", item.t or 0, tostring(item.kind), tostring(item.script or "?"), tostring(item.message))
			end
			local en = item.enabled == nil and "  -  " or (item.enabled and " ON  " or " OFF ")
			return string.format("%-12s %s %s", item.class, en, item.fullName)
		end,
		rowColor = function(item, state)
			if state.class == "errors" then
				return item.kind == "warning" and Theme.Severity.MEDIUM or Theme.Severity.CRITICAL
			end
			if item.exposure and item.class == "ModuleScript" then
				return Theme.Severity.MEDIUM
			end
			return nil
		end,
		detail = function(item, state)
			if state.class == "errors" then
				return string.format("Waktu  : %.3f\nEnv    : %s\nJenis  : %s\nScript : %s\n\nPesan:\n%s\n\nStack:\n%s", item.t or 0, tostring(item.env), tostring(item.kind), tostring(item.script), tostring(item.message), tostring(item.stack or "(tidak ada)"))
			end
			return formatRecord(item)
		end,
		header = function(state, items)
			local c = state.env == "client" and agent.scripts:Counts() or (agent.server.scripts and agent.server.scripts.counts)
			if not c then
				return "Memuat data server..."
			end
			return string.format("%d ditampilkan | Script %d, LocalScript %d, ModuleScript %d | error %d", #items, c.Script or 0, c.LocalScript or 0, c.ModuleScript or 0,
				state.env == "client" and agent.scripts.errorCount or #((agent.server.scripts and agent.server.scripts.errors) or {}))
		end,
	}, ctx.Config.UI.DetailMaxChars)

	return { Refresh = function()
		view:Refresh()
	end }
end
