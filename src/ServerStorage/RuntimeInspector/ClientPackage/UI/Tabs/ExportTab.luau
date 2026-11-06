--[[ Tab 9: Export Center: JSON/TXT/CSV, filter kategori, scope client/server, paging, Output, HTTP (server). ]]

return function(ctx: any, container: Frame)
	local agent, W, Theme = ctx.agent, ctx.Widgets, ctx.Theme
	local New, C = W.New, Theme.Colors
	local Export = ctx.ExportCenter
	local A = agent.Protocol.Actions

	local state = { format = "json", scope = "both", categories = {}, pages = { "" }, page = 1, serverMode = false, serverPages = 1 }
	for _, c in Export.Categories do
		state.categories[c] = true
	end

	local row1 = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), Parent = container }, { W.HList(6) })
	local row2 = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 30), Size = UDim2.new(1, 0, 0, 26), Parent = container }, { W.HList(6) })
	local row3 = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 60), Size = UDim2.new(1, 0, 0, 26), Parent = container }, { W.HList(6) })
	local status = W.Label({ Text = "Pilih format & kategori, lalu Generate.", TextColor3 = C.TextDim, TextSize = Theme.SmallText, Position = UDim2.new(0, 0, 0, 90), Size = UDim2.new(1, 0, 0, 18), Parent = container })

	local output = W.TextInput("", {
		Position = UDim2.new(0, 0, 0, 112),
		Size = UDim2.new(1, 0, 1, -112),
		MultiLine = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Theme.Mono,
		TextSize = Theme.SmallText,
		Parent = container,
	})

	local order = 0
	local function o()
		order += 1
		return order
	end
	local function chipGroup(parent: Instance, options: { { any } }, key: string)
		local setters = {}
		for _, opt in options do
			local chip, setOn = W.Chip(opt[2], state[key] == opt[1], function()
				state[key] = opt[1]
				for id, s in setters do
					s(id == opt[1])
				end
			end)
			chip.LayoutOrder = o()
			chip.Parent = parent
			setters[opt[1]] = setOn
		end
	end
	W.Label({ Text = "Format:", Size = UDim2.new(0, 56, 0, 24), LayoutOrder = o(), Parent = row1 })
	chipGroup(row1, { { "json", "JSON" }, { "txt", "TXT" }, { "csv", "CSV" } }, "format")
	W.Label({ Text = "  Scope:", Size = UDim2.new(0, 56, 0, 24), LayoutOrder = o(), Parent = row1 })
	chipGroup(row1, { { "client", "Client" }, { "server", "Server (cermin)" }, { "both", "Keduanya" } }, "scope")

	W.Label({ Text = "Kategori:", Size = UDim2.new(0, 64, 0, 24), LayoutOrder = o(), Parent = row2 })
	for _, c in Export.Categories do
		local chip, setOn
		chip, setOn = W.Chip(c, true, function()
			state.categories[c] = not state.categories[c]
			setOn(state.categories[c])
		end)
		chip.LayoutOrder = o()
		chip.Parent = row2
	end

	local function show()
		local text = state.pages[state.page] or ""
		output.Text = text
		status.Text = string.format("Halaman %d/%d | %d karakter di halaman ini%s", state.page, #state.pages, #text,
			state.serverMode and " | sumber: laporan lengkap server (JSON)" or "")
	end

	local function generate()
		state.serverMode = false
		status.Text = "Menyusun laporan..."
		task.spawn(function()
			local report = Export.Collect(agent, state.categories, state.scope)
			local text
			if state.format == "json" then
				text = Export.ToJSON(report)
			elseif state.format == "csv" then
				text = Export.ToCSV(report)
			else
				text = Export.ToTXT(report)
			end
			state.pages = Export.Paginate(text, ctx.Config.UI.ExportPageChars)
			state.page = 1
			state.fullText = text
			show()
		end)
	end

	local function fetchServerPage(page: number, http: boolean?)
		status.Text = "Mengambil laporan server..."
		agent.link:CallAsync(A.ExportServer, { page = page, http = http }, function(r)
			if type(r) ~= "table" or r.error then
				status.Text = "Gagal: " .. tostring(r and r.error)
				return
			end
			state.serverMode = true
			state.pages = table.create(r.pages, "")
			state.pages[r.page] = r.text
			state.page = r.page
			show()
			if r.http then
				status.Text ..= " | HTTP: " .. r.http
			end
		end)
	end

	local function b(text: string, fn: () -> ())
		local btn = W.Button(text, fn, { Size = UDim2.new(0, math.max(64, #text * 7 + 18), 0, 24), TextSize = Theme.SmallText, LayoutOrder = o() })
		btn.Parent = row3
	end
	b("Generate", generate)
	b("< Prev", function()
		if state.page > 1 then
			state.page -= 1
			if state.serverMode and state.pages[state.page] == "" then
				fetchServerPage(state.page)
			else
				show()
			end
		end
	end)
	b("Next >", function()
		if state.page < #state.pages then
			state.page += 1
			if state.serverMode and state.pages[state.page] == "" then
				fetchServerPage(state.page)
			else
				show()
			end
		end
	end)
	b("Pilih semua (lalu Ctrl+C)", function()
		output:CaptureFocus()
		output.SelectionStart = 1
		output.CursorPosition = #output.Text + 1
	end)
	b("Print ke Output", function()
		local text = state.fullText or output.Text
		task.spawn(Export.PrintToOutput, text, ctx.Config.LogPrefix)
		status.Text = "Dicetak ke Output (" .. #text .. " karakter). Di Studio: buka View > Output, salin dari sana."
	end)
	b("Laporan lengkap server", function()
		fetchServerPage(1, false)
	end)
	b("Kirim HTTP (server)", function()
		fetchServerPage(1, true)
	end)

	return { Refresh = function() end }
end
