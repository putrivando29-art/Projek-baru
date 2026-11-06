--[[ Tab 4: Asset Inspector: ID aset per kategori, lokasi, penilaian eksposur, aset runtime tak dikenal. ]]

return function(ctx: any, container: Frame)
	local agent = ctx.agent
	local A = agent.Protocol.Actions
	local Theme = ctx.Theme

	local function fetchServer()
		if agent.server.assetsLoading then
			return
		end
		agent.server.assetsLoading = true
		task.spawn(function()
			local all, offset, base = {}, 0, nil
			repeat
				local r = agent.link:Call(A.AssetsReport, { offset = offset, limit = 300 })
				if type(r) ~= "table" or r.error then
					break
				end
				base = r
				for _, a in r.assets or {} do
					table.insert(all, a)
				end
				offset += #(r.assets or {})
			until #(r.assets or {}) == 0 or offset >= (r.total or 0)
			if base then
				base.assets = all
				agent.server.assets = base
			end
			agent.server.assetsLoading = false
		end)
	end

	local categories = { { id = "all", label = "Semua" } }
	for _, c in { "AnimationId", "SoundId", "MeshId", "TextureId", "Image", "Decal", "ShirtTemplate", "PantsTemplate", "Video", "ParticleTexture", "SurfaceAppearance", "Sky" } do
		table.insert(categories, { id = c, label = c })
	end
	table.insert(categories, { id = "unknown", label = "Runtime?" })
	table.insert(categories, { id = "unreadable", label = "Unreadable" })
	table.insert(categories, { id = "source", label = "Di source" })

	local view = ctx.ListDetailView.new(container, {
		groups = {
			{ id = "env", options = { { id = "client", label = "Client" }, { id = "server", label = "Server" } } },
			{ id = "cat", options = categories },
		},
		buttons = {
			{ label = "Rescan", onClick = function(v)
				if v.state.env == "client" then
					task.spawn(function()
						agent.assets:Scan()
						v:Refresh()
					end)
				else
					agent.server.assets = nil
					fetchServer()
				end
			end },
		},
		getItems = function(state)
			local report
			if state.env == "client" then
				report = agent.assets:Report()
			else
				report = agent.server.assets
				if not report then
					fetchServer()
					return {}
				end
			end
			state._report = report -- dipakai header; Report() tidak dihitung dua kali
			if state.cat == "unreadable" then
				return report.unreadable or {}
			end
			if state.cat == "source" then
				local m = agent.server.manifest
				return (m and m.assetRefs) or (report.manifestAssetRefs or {})
			end
			local out = {}
			for _, a in report.assets do
				local include = state.cat == "all" or (state.cat == "unknown" and a.unknownRuntime) or table.find(a.categories, state.cat) ~= nil
				if include then
					table.insert(out, a)
				end
			end
			return out
		end,
		rowText = function(item, state)
			if state.cat == "unreadable" then
				return string.format("[%s] %s.%s", tostring(item.class), tostring(item.path), tostring(item.property))
			elseif state.cat == "source" then
				return string.format("%s  %s:%s", tostring(item.id), tostring(item.script), tostring(item.line))
			end
			return string.format("[%-6s] %-14s x%-4d %-24s %s", item.level, item.key, item.count, table.concat(item.categories, "|"), tostring(item.locations[1]))
		end,
		rowColor = function(item, state)
			if state.cat == "unreadable" or state.cat == "source" then
				return nil
			end
			return Theme.Severity[item.level]
		end,
		detail = function(item, state)
			if state.cat == "unreadable" then
				return "Properti tidak dapat dibaca script runtime:\n\n" .. tostring(item.path) .. "\n" .. tostring(item.property) .. "\n\n" .. tostring(item.error)
					.. "\n\nAlternatif: jalankan plugin Source Analyzer di Studio (PluginSecurity)."
			elseif state.cat == "source" then
				return string.format("Asset ID %s ditemukan di source %s baris %s.\n\nKonteks:\n%s\n\nCatatan: ID di dalam source ModuleScript/LocalScript yang direplikasi ikut terkirim ke client sebagai bytecode.", tostring(item.id), tostring(item.script), tostring(item.line), tostring(item.context))
			end
			local lines = {
				"Asset key    : " .. item.key,
				"Jenis        : " .. tostring(item.kind),
				"Kategori     : " .. table.concat(item.categories, ", "),
				"Properti     : " .. table.concat(item.properties, ", "),
				"Service      : " .. table.concat(item.services, ", "),
				"Kemunculan   : " .. item.count,
				"Muncul runtime: " .. tostring(item.runtime) .. (item.unknownRuntime and " (TIDAK dikenal)" or ""),
				"",
				"Penilaian    : " .. item.level,
				"Alasan       : " .. item.reason,
				"",
				"[Lokasi (maks 25)]",
			}
			for _, loc in item.locations do
				table.insert(lines, "  " .. loc)
			end
			return table.concat(lines, "\n")
		end,
		header = function(state, items)
			local report = state._report
			if not report or (state.env == "server" and not agent.server.assets) then
				return "Memuat data server..."
			end
			local parts = {}
			for cat, n in report.byCategory do
				table.insert(parts, cat .. ":" .. n)
			end
			table.sort(parts)
			return string.format("%d ditampilkan | unik %d, referensi %d | %s", #items, report.uniqueAssets, report.references, table.concat(parts, " "))
		end,
	}, ctx.Config.UI.DetailMaxChars)

	return { Refresh = function()
		view:Refresh()
	end }
end
