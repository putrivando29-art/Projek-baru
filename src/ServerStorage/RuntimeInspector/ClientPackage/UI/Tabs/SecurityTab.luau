--[[ Tab 8: Security Audit: temuan anomali, risk score, rekomendasi, log audit server. ]]

return function(ctx: any, container: Frame)
	local agent = ctx.agent
	local Theme = ctx.Theme
	local Findings = agent.FindingsLib

	local function formatFinding(f)
		return table.concat({
			"Severity     : " .. tostring(f.severity),
			"Rule         : " .. tostring(f.rule),
			"Objek        : " .. tostring(f.object),
			"Path         : " .. tostring(f.path),
			"Pemain       : " .. tostring(f.player or "-"),
			"Environment  : " .. tostring(f.env) .. "  | sumber: " .. tostring(f.source),
			"Jumlah       : " .. tostring(f.count) .. " kali",
			"Waktu (UTC)  : " .. tostring(f.clock) .. string.format("  | serverTime %.3f", f.st or 0),
			"",
			"Detail:",
			"  " .. tostring(f.detail),
			"",
			"Alasan penandaan:",
			"  " .. tostring(f.reason),
			"",
			"Rekomendasi perbaikan:",
			"  " .. tostring(f.recommendation),
			"",
			f.env == "client" and "Catatan: temuan client adalah indikator dari client admin (berguna di Studio). Di game live, hanya temuan server yang dapat dipercaya." or "Catatan: temuan server berbasis state server (otoritatif).",
		}, "\n")
	end

	local view = ctx.ListDetailView.new(container, {
		groups = {
			{ id = "src", options = {
				{ id = "all", label = "Semua" },
				{ id = "server", label = "Server" },
				{ id = "client", label = "Client" },
				{ id = "audit", label = "Log audit server" },
			} },
			{ id = "min", options = {
				{ id = "INFO", label = "Semua level" },
				{ id = "LOW", label = "LOW+" },
				{ id = "MEDIUM", label = "MEDIUM+" },
				{ id = "HIGH", label = "HIGH+" },
				{ id = "CRITICAL", label = "CRITICAL" },
			} },
		},
		getItems = function(state)
			if state.src == "audit" then
				local src = agent.serverAudit:ToArray()
				local out = {}
				for i = #src, 1, -1 do
					table.insert(out, src[i])
				end
				return out
			end
			local out = {}
			if state.src ~= "client" then
				for _, f in agent.serverFindings:List(state.min) do
					table.insert(out, f)
				end
			end
			if state.src ~= "server" then
				for _, f in agent.findings:List(state.min) do
					table.insert(out, f)
				end
			end
			table.sort(out, function(a, b)
				local ra, rb = Findings.Rank[a.severity] or 0, Findings.Rank[b.severity] or 0
				if ra ~= rb then
					return ra > rb
				end
				return (a.lastSt or 0) > (b.lastSt or 0)
			end)
			return out
		end,
		rowText = function(item, state)
			if state.src == "audit" then
				return string.format("%9.3f %-22s %s", item.t or 0, tostring(item.kind), tostring(item.summary))
			end
			return string.format("[%-8s] %-6s x%-4d %-34s %s", item.severity, item.env, item.count, item.rule, item.path)
		end,
		rowColor = function(item, state)
			if state.src == "audit" then
				return string.find(tostring(item.kind), "rejected") and Theme.Severity.MEDIUM or nil
			end
			return Theme.Severity[item.severity]
		end,
		detail = function(item, state)
			if state.src == "audit" then
				local lines = { string.format("t=%.3f st=%.3f", item.t or 0, item.st or 0), "kind: " .. tostring(item.kind), "summary: " .. tostring(item.summary) }
				for k, v in item.data or {} do
					table.insert(lines, "  " .. tostring(k) .. " = " .. tostring(v))
				end
				return table.concat(lines, "\n")
			end
			return formatFinding(item)
		end,
		header = function(state, items)
			local sc, cc = agent.serverFindings:Counts(), agent.findings:Counts()
			return string.format("Risk server %d | client %d  ||  server C%d H%d M%d L%d  |  client C%d H%d M%d L%d",
				agent.serverFindings:RiskScore(), agent.findings:RiskScore(),
				sc.CRITICAL, sc.HIGH, sc.MEDIUM, sc.LOW, cc.CRITICAL, cc.HIGH, cc.MEDIUM, cc.LOW)
		end,
	}, ctx.Config.UI.DetailMaxChars)

	return { Refresh = function()
		view:Refresh()
	end }
end
