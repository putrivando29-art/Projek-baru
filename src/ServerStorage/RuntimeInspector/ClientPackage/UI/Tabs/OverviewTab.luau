--[[ Tab 1: Overview: ringkasan angka client & server. ]]

return function(ctx: any, container: Frame)
	local agent, W, Theme = ctx.agent, ctx.Widgets, ctx.Theme
	local New, C = W.New, Theme.Colors

	local grid = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 176), Parent = container }, {
		New("UIGridLayout", { CellSize = UDim2.new(0.25, -8, 0, 80), CellPadding = UDim2.new(0, 8, 0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local cards = {}
	local function card(id: string, title: string, order: number)
		local f = New("Frame", { BackgroundColor3 = C.PanelAlt, LayoutOrder = order, Parent = grid }, { W.Corner(8), W.Padding(10) })
		W.Label({ Text = title, TextColor3 = C.TextDim, TextSize = Theme.SmallText, Size = UDim2.new(1, 0, 0, 16), Parent = f })
		local value = W.Label({ Text = "-", Font = Theme.FontBold, TextSize = 22, Position = UDim2.new(0, 0, 0, 18), Size = UDim2.new(1, 0, 0, 28), Parent = f })
		local sub = W.Label({ Text = "", TextColor3 = C.TextDim, TextSize = Theme.SmallText, Position = UDim2.new(0, 0, 0, 46), Size = UDim2.new(1, 0, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = f })
		cards[id] = { value = value, sub = sub }
	end
	card("instances", "Instance (client / server)", 1)
	card("scripts", "Script + LocalScript", 2)
	card("modules", "ModuleScript", 3)
	card("assets", "Referensi aset", 4)
	card("remotes", "Remote & Bindable", 5)
	card("anomalies", "Anomali (client / server)", 6)
	card("risk", "Risk score (heuristik)", 7)
	card("monitor", "Runtime monitor", 8)

	local detailHolder = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 184), Size = UDim2.new(1, 0, 1, -184), Parent = container })
	local _, setDetail = W.DetailPane(detailHolder, ctx.Config.UI.DetailMaxChars)

	local function set(id: string, value: string, sub: string?)
		cards[id].value.Text = value
		cards[id].sub.Text = sub or ""
	end

	local function refresh()
		local so = agent:ServerOverview()
		local cs = agent.explorer:Stats()
		local sc = agent.scripts:Counts()
		local srvExplorer = so and so.explorer
		local srvScripts = so and so.scripts
		set("instances", string.format("%d / %s", cs.total, srvExplorer and tostring(srvExplorer.total) or "?"),
			cs.baselineDone and "baseline selesai" or "baseline berjalan...")
		set("scripts", string.format("%d / %s", (sc.Script or 0) + (sc.LocalScript or 0),
			srvScripts and tostring((srvScripts.Script or 0) + (srvScripts.LocalScript or 0)) or "?"),
			string.format("client S=%d LS=%d", sc.Script or 0, sc.LocalScript or 0))
		set("modules", string.format("%d / %s", sc.ModuleScript or 0, srvScripts and tostring(srvScripts.ModuleScript or 0) or "?"), "client / server")
		local ar = agent.assets:Report()
		set("assets", string.format("%d / %s", ar.references, so and tostring(so.assets.references) or "?"),
			string.format("unik client %d, server %s", ar.uniqueAssets, so and tostring(so.assets.unique) or "?"))
		set("remotes", string.format("%d / %s", agent.network.remoteCount, so and tostring(so.remotes) or "?"), "client / server")
		local cc = agent.findings:Counts()
		local svc = agent.serverFindings:Counts()
		set("anomalies", string.format("%d / %d", cc.total, svc.total),
			string.format("srv C%d H%d M%d L%d", svc.CRITICAL, svc.HIGH, svc.MEDIUM, svc.LOW))
		set("risk", string.format("%d / %d", agent.findings:RiskScore(), agent.serverFindings:RiskScore()), "client / server, maks 100")
		local ms = agent.monitor:Stats()
		set("monitor", string.format("+%d -%d", ms.added, ms.removed), string.format("prop %d attr %d watched %d dropped %d", ms.property, ms.attribute, ms.watched, ms.dropped))

		local hello = agent.server.hello
		local lines = {
			"[Environment]",
			"  Studio            : " .. tostring(ctx.isStudio),
			"  LocalPlayer       : " .. agent.player.Name .. " (UserId " .. agent.player.UserId .. ")",
			"  Ping (detik)      : " .. string.format("%.3f", agent.player:GetNetworkPing()),
			"  StreamingEnabled  : " .. tostring(workspace.StreamingEnabled) .. (workspace.StreamingEnabled and "  -> sebagian Workspace bisa belum ter-stream ke client; jumlah Instance client < server itu normal" or ""),
			"  Server link       : " .. (agent.link.available and "terhubung" or "TIDAK tersedia") .. (agent.link.lastError and ("  (error terakhir: " .. agent.link.lastError .. ")") or ""),
			"  Static manifest   : " .. (hello and (hello.manifestAvailable and "tersedia" or "belum ada: jalankan plugin Source Analyzer") or "?"),
			"",
			"[Instance per service: client | server]",
		}
		local services = {}
		for name in cs.byService do
			services[name] = true
		end
		if srvExplorer then
			for name in srvExplorer.byService do
				services[name] = true
			end
		end
		local names = {}
		for name in services do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local cv = cs.byService[name]
			local sv = srvExplorer and srvExplorer.byService[name]
			local note = ""
			if name == "ServerStorage" or name == "ServerScriptService" then
				note = "  (server-only: client tidak pernah menerima)"
			end
			table.insert(lines, string.format("  %-22s %8s | %8s%s", name, tostring(cv or "-"), tostring(sv or "-"), note))
		end
		table.insert(lines, "")
		table.insert(lines, "[Kelas terbanyak (client)]")
		for _, pair in cs.topClasses do
			table.insert(lines, string.format("  %-28s %d", pair[1], pair[2]))
		end
		if so then
			table.insert(lines, "")
			table.insert(lines, "[Server]")
			table.insert(lines, string.format("  Heartbeat %.2f ms, memori %d MB, pemain %d, error script %d", so.heartbeatMs or 0, so.memoryMb or 0, so.players or 0, so.scriptErrors or 0))
			for _, r in so.secureRemotes or {} do
				table.insert(lines, string.format("  SecureRemote %s: accepted %d, rejected %d, errors %d", r.remote, r.accepted, r.rejected, r.errors))
			end
		end
		setDetail(table.concat(lines, "\n"))
	end

	return { Refresh = refresh }
end
