--[[ Tab 7: Network Monitor: remote masuk/keluar, payload, statistik per remote. ]]

return function(ctx: any, container: Frame)
	local agent = ctx.agent
	local Theme = ctx.Theme
	local NetLib = ctx.NetworkMonitorLib

	local function incoming(env: string, e: any): boolean
		if env == "client" then
			return e.direction == "Server->Client"
		end
		return e.direction == "Client->Server"
	end
	local function outgoing(env: string, e: any): boolean
		if env == "client" then
			return e.direction == "Client->Server"
		end
		return e.direction == "Server->Client"
	end

	local view = ctx.ListDetailView.new(container, {
		groups = {
			{ id = "env", options = { { id = "client", label = "Client" }, { id = "server", label = "Server" } } },
			{ id = "dir", options = {
				{ id = "all", label = "Semua" },
				{ id = "in", label = "Incoming" },
				{ id = "out", label = "Outgoing" },
				{ id = "local", label = "Bindable" },
				{ id = "issues", label = "Bermasalah" },
				{ id = "remotes", label = "Daftar remote" },
			} },
		},
		buttons = {
			{ label = "Refresh daftar server", onClick = function(v)
				agent:RefreshServerRemotes()
			end },
		},
		getItems = function(state)
			if state.dir == "remotes" then
				return state.env == "client" and agent.network:Remotes() or agent.serverRemotes
			end
			local src = state.env == "client" and agent.network:Entries() or agent.serverNet:ToArray()
			local out = {}
			for i = #src, 1, -1 do
				local e = src[i]
				local d = state.dir
				local ok = d == "all"
					or (d == "in" and incoming(state.env, e))
					or (d == "out" and outgoing(state.env, e))
					or (d == "local" and e.direction == "Local")
					or (d == "issues" and ((e.issues and #e.issues > 0) or e.schemaError ~= nil))
				if ok then
					table.insert(out, e)
				end
			end
			return out
		end,
		rowText = function(item, state)
			if state.dir == "remotes" then
				return string.format("%-22s n=%-6d %5.1f/s peak %5.1f %s %s", item.class, item.count, item.rate, item.peakRate, item.passive and "[pasif]" or "[wrapper]", item.path)
			end
			return string.format("%9.3f %-15s %-8s argc=%d %s%s", item.t or 0, item.direction, item.via, item.argc or 0, item.path, item.player and (" <" .. item.player .. ">") or "")
		end,
		rowColor = function(item, state)
			if state.dir == "remotes" then
				return item.note and Theme.Colors.TextDim or nil
			end
			if item.schemaError then
				return Theme.Severity.HIGH
			end
			if item.issues and #item.issues > 0 then
				return Theme.Severity.MEDIUM
			end
			return nil
		end,
		detail = function(item, state)
			if state.dir == "remotes" then
				return string.format("Remote     : %s\nClass      : %s\nFullName   : %s\nPanggilan  : %d\nBytes(est) : %d\nRate       : %.1f/s (peak %.1f)\nListener pasif: %s\nLog dibuang (throttle): %d\n%s",
					item.name, item.class, item.path, item.count, item.bytes, item.rate, item.peakRate, tostring(item.passive), item.droppedLogs or 0,
					item.note and ("\nCatatan: " .. item.note .. "\nGunakan Net.InvokeServer / Net.SetServerInvoke / Net.Invoke agar tercatat.") or "")
			end
			return NetLib.FormatEntry(item) .. (item.argsSummarized and "\n\n(payload diringkas server karena besar)" or "")
		end,
		header = function(state, items)
			return string.format("%d entri | Outgoing hanya terlihat bila game memakai Net wrapper | RemoteFunction/BindableFunction butuh wrapper", #items)
		end,
	}, ctx.Config.UI.DetailMaxChars)

	return { Refresh = function()
		view:Refresh()
	end }
end
