--[[ Tab 6: Action Profiler: jump, movement, attack, tool, animation, input + rantai korelasi. ]]

return function(ctx: any, container: Frame)
	local agent = ctx.agent
	local Theme = ctx.Theme
	local TimelineLib = agent.TimelineLib

	local catColor = {
		Jump = Theme.Severity.LOW,
		Attack = Theme.Severity.HIGH,
		Tool = Theme.Severity.MEDIUM,
		Animation = Theme.Colors.Accent,
		Input = Theme.Colors.TextDim,
		Hitbox = Theme.Severity.CRITICAL,
		Effect = Theme.Visibility.OWNER_ONLY,
	}

	local function entries(env: string)
		return env == "client" and agent.timeline:ToArray() or agent.serverTimeline:ToArray()
	end

	local view = ctx.ListDetailView.new(container, {
		groups = {
			{ id = "env", options = { { id = "client", label = "Client" }, { id = "server", label = "Server" } } },
			{ id = "cat", options = {
				{ id = "chains", label = "Rantai" },
				{ id = "all", label = "Semua" },
				{ id = "Jump", label = "Jump" },
				{ id = "Movement", label = "Movement" },
				{ id = "Attack", label = "Attack" },
				{ id = "Tool", label = "Tool" },
				{ id = "Animation", label = "Animation" },
				{ id = "Input", label = "Input" },
				{ id = "Hitbox", label = "Hitbox" },
				{ id = "Effect", label = "Efek" },
				{ id = "Network", label = "Remote" },
			}, default = "chains" },
		},
		getItems = function(state)
			local all = entries(state.env)
			if state.cat == "chains" then
				return TimelineLib.CorrelateEntries(all, ctx.Config.Character.Correlation)
			end
			local out = {}
			for i = #all, 1, -1 do
				local e = all[i]
				if state.cat == "all" or e.cat == state.cat then
					table.insert(out, e)
				end
			end
			return out
		end,
		rowText = function(item, state)
			if state.cat == "chains" then
				return string.format("%9.3f %-20s %s  (+%d kejadian)", item.anchor.t, item.anchor.kind, item.anchor.summary, #item.events)
			end
			return string.format("%9.3f %-10s %-26s %s", item.t, item.cat, item.kind, item.summary)
		end,
		rowColor = function(item, state)
			if state.cat == "chains" then
				return Theme.Colors.Accent
			end
			return catColor[item.cat]
		end,
		detail = function(item, state)
			if state.cat == "chains" then
				return TimelineLib.FormatChain(item)
					.. "\n\nCara membaca: offset (ms) relatif terhadap anchor. Ini korelasi waktu, bukan bukti bahwa anchor menyebabkan kejadian lain."
			end
			local lines = {
				string.format("os.clock   : %.4f", item.t or 0),
				string.format("serverTime : %.4f", item.st or 0),
				"Kategori   : " .. tostring(item.cat),
				"Jenis      : " .. tostring(item.kind),
				"Ringkasan  : " .. tostring(item.summary),
				"",
				"[Data]",
			}
			for k, v in item.data or {} do
				local text = v
				if type(v) == "table" then
					local parts = {}
					for _, x in v do
						table.insert(parts, tostring(x))
					end
					text = "{" .. table.concat(parts, ", ") .. "}"
				end
				table.insert(lines, string.format("  %-14s %s", tostring(k), tostring(text)))
			end
			return table.concat(lines, "\n")
		end,
		header = function(state, items)
			local c = ctx.Config.Character.Correlation
			return string.format("%d item | jendela korelasi %.2fs (pre %.2fs) | serverTime memungkinkan perbandingan client vs server", #items, c.Window, c.PreWindow)
		end,
	}, ctx.Config.UI.DetailMaxChars)

	return { Refresh = function()
		view:Refresh()
	end }
end
