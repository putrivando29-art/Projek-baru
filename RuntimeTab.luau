--[[ Tab 5: Runtime Monitor: Instance baru/dihapus, perubahan properti & atribut. ]]

return function(ctx: any, container: Frame)
	local agent = ctx.agent
	local Theme = ctx.Theme

	local kindColor = {
		added = Theme.Severity.LOW,
		removed = Theme.Severity.HIGH,
		property = Theme.Colors.Accent,
		attribute = Theme.Severity.MEDIUM,
	}

	local view = ctx.ListDetailView.new(container, {
		groups = {
			{ id = "env", options = { { id = "client", label = "Client" }, { id = "server", label = "Server" } } },
			{ id = "kind", options = {
				{ id = "all", label = "Semua" },
				{ id = "added", label = "Baru" },
				{ id = "removed", label = "Dihapus" },
				{ id = "property", label = "Properti" },
				{ id = "attribute", label = "Atribut" },
				{ id = "child", label = "Child (root)" },
				{ id = "watched", label = "Kelas dipantau" },
			} },
		},
		getItems = function(state)
			local src = state.env == "client" and agent.monitor:Entries() or agent.serverMonitor:ToArray()
			local out = {}
			for i = #src, 1, -1 do
				local e = src[i]
				local k = state.kind
				local ok = k == "all"
					or e.kind == k
					or (k == "child" and (e.kind == "child+" or e.kind == "child-"))
					or (k == "watched" and e.watchedClass)
				if ok then
					table.insert(out, e)
				end
			end
			return out
		end,
		rowText = function(e)
			local change = e.prop and (string.format(" %s: %s -> %s", e.prop, tostring(e.old), tostring(e.new))) or ""
			return string.format("%9.3f %-9s %-16s %s%s", e.t or 0, e.kind, e.class, e.path, change)
		end,
		rowColor = function(e)
			return kindColor[e.kind]
		end,
		detail = function(e)
			local lines = {
				string.format("Timestamp  : os.clock %.4f | serverTime %.4f", e.t or 0, e.st or 0),
				"Environment: " .. tostring(e.env),
				"Jenis      : " .. tostring(e.kind),
				"Name       : " .. tostring(e.name),
				"ClassName  : " .. tostring(e.class),
				"FullName   : " .. tostring(e.path),
				"Parent     : " .. tostring(e.parent),
			}
			if e.prop then
				table.insert(lines, "Properti   : " .. tostring(e.prop))
				table.insert(lines, "Sebelum    : " .. tostring(e.old))
				table.insert(lines, "Sesudah    : " .. tostring(e.new))
			end
			table.insert(lines, "Sumber     : " .. tostring(e.source))
			table.insert(lines, "")
			table.insert(lines, "Catatan: Roblox tidak menyediakan API untuk mengetahui script yang membuat/mengubah Instance. Kolom sumber hanya menyebut environment pengamat dan status replikasi bila sudah diverifikasi.")
			return table.concat(lines, "\n")
		end,
		header = function(state, items)
			if state.env == "client" then
				local s = agent.monitor:Stats()
				return string.format("%d entri | +%d -%d prop %d attr %d | watched %d (skip %d) | antrean %d dropped %d", #items, s.added, s.removed, s.property, s.attribute, s.watched, s.watchSkipped, s.queued, s.dropped)
			end
			return #items .. " entri dari server (stream)"
		end,
	}, ctx.Config.UI.DetailMaxChars)

	return { Refresh = function()
		view:Refresh()
	end }
end
