--[[ Tab 2: DataModel Explorer: directory tree client/server, search, filter class, detail. ]]

return function(ctx: any, container: Frame)
	local agent, W, Theme = ctx.agent, ctx.Widgets, ctx.Theme
	local New, C = W.New, Theme.Colors
	local A = agent.Protocol.Actions
	local InstanceInfo = agent.InstanceInfo

	local mode = "client"
	local toolbar = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = container }, { W.HList(6) })
	local body = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 34), Size = UDim2.new(1, 0, 1, -34), Parent = container })
	local left = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0.55, -4, 1, 0), Parent = body })
	local right = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0.55, 4, 0, 0), Size = UDim2.new(0.45, -4, 1, 0), Parent = body })
	local _, setDetail = W.DetailPane(right, ctx.Config.UI.DetailMaxChars)
	setDetail("Klik node untuk membuka/menutup dan melihat detail.\n\nWarna = visibilitas:\n  SERVER_ONLY (merah) hanya server\n  REPLICATED (biru) direplikasi, dilihat dari server\n  OWNER_ONLY (ungu) PlayerGui, hanya pemilik\n  CLIENT_REPLICATED (hijau) terverifikasi ada di server\n  CLIENT_LOCAL (oranye) dibuat lokal oleh client\n  CLIENT_UNVERIFIED (abu) belum diverifikasi\n  *NEW = muncul setelah baseline scan")

	local function clientNode(inst: Instance, label: string?)
		local s = InstanceInfo.Summary(inst)
		agent:QueueVerify(inst)
		return {
			key = inst,
			label = label,
			name = s.name,
			class = s.class,
			childCount = s.childCount,
			vis = agent:VisibilityOf(inst),
			runtime = agent.explorer.runtime[inst] == true,
		}
	end

	local clientProvider = {
		Roots = function()
			local out = {}
			for _, pair in agent.explorer:Roots() do
				table.insert(out, clientNode(pair[1], pair[2]))
			end
			return out
		end,
		Children = function(_, key, offset, limit)
			local page, total = agent.explorer:Children(key, offset, limit)
			local out = {}
			for _, inst in page do
				table.insert(out, clientNode(inst))
			end
			return out, total
		end,
	}
	local function toServerNodes(nodes)
		local out = {}
		for _, n in nodes or {} do
			n.key = n.id
			table.insert(out, n)
		end
		return out
	end
	local serverProvider = {
		Roots = function()
			local r = agent.link:Call(A.TreeRoots)
			return toServerNodes(type(r) == "table" and not r.error and r or {})
		end,
		Children = function(_, key, offset, limit)
			local r = agent.link:Call(A.TreeChildren, { id = key, offset = offset, limit = limit })
			if type(r) ~= "table" then
				return {}, 0
			end
			return toServerNodes(r.nodes), r.total or 0
		end,
	}

	local function showDetails(node)
		if mode == "client" then
			local inst = node.key
			if typeof(inst) ~= "Instance" then
				return
			end
			local d = agent.explorer:Details(inst)
			d.visibility = agent:VisibilityOf(inst)
			d.note = "Visibilitas client diverifikasi dengan mengirim referensi Instance ke server: Instance buatan lokal tiba sebagai nil di server."
			setDetail(InstanceInfo.FormatDetails(d))
		else
			setDetail("Memuat detail dari server...")
			agent.link:CallAsync(A.TreeDetails, { id = node.key }, function(r)
				setDetail(type(r) == "table" and (r.text or r.error or "?") or "gagal")
			end)
		end
	end

	local clientTree = ctx.TreeView.new(left, clientProvider, showDetails)
	local serverTree = ctx.TreeView.new(left, serverProvider, showDetails)
	serverTree:SetVisible(false)

	-- hasil pencarian
	local results = ctx.VirtualList.new(left, {
		render = function(row, item)
			row.Text = string.format("[%s] %s", item.class, item.path)
			row.TextColor3 = item.vis and Theme.Visibility[item.vis] or C.Text
		end,
		onSelect = function(item)
			showDetails(item)
		end,
	})
	results.frame.Visible = false

	local chips = {}
	local nameBox, classBox
	local function setMode(m: string)
		mode = m
		chips.client(m == "client")
		chips.server(m == "server")
		clientTree:SetVisible(m == "client" and not results.frame.Visible)
		serverTree:SetVisible(m == "server" and not results.frame.Visible)
		if m == "server" and #serverTree.roots == 0 then
			serverTree:Load()
		end
	end
	local cClient, setC = W.Chip("Client", true, function()
		setMode("client")
	end)
	cClient.LayoutOrder = 1
	cClient.Parent = toolbar
	chips.client = setC
	local cServer, setS = W.Chip("Server", false, function()
		setMode("server")
	end)
	cServer.LayoutOrder = 2
	cServer.Parent = toolbar
	chips.server = setS

	nameBox = W.TextInput("Nama Instance", { Size = UDim2.new(0, 150, 0, 24), LayoutOrder = 3, Parent = toolbar })
	classBox = W.TextInput("ClassName / IsA", { Size = UDim2.new(0, 130, 0, 24), LayoutOrder = 4, Parent = toolbar })

	local searchBtn = W.Button("Cari", function()
		local q, cf = nameBox.Text, classBox.Text
		results.frame.Visible = true
		clientTree:SetVisible(false)
		serverTree:SetVisible(false)
		results:SetItems({ { class = "...", path = "mencari..." } })
		task.spawn(function()
			local items = {}
			if mode == "client" then
				local found = agent.explorer:Search(q, cf, ctx.Config.Scan.SearchLimit)
				for _, inst in found do
					table.insert(items, { key = inst, class = inst.ClassName, path = inst:GetFullName(), vis = agent:VisibilityOf(inst) })
					agent:QueueVerify(inst)
				end
			else
				local r = agent.link:Call(A.TreeSearch, { query = q, class = cf, limit = 300 })
				for _, n in type(r) == "table" and r.nodes or {} do
					n.key = n.id
					table.insert(items, n)
				end
			end
			results:SetItems(items)
		end)
	end, { Size = UDim2.new(0, 60, 0, 24), LayoutOrder = 5 })
	searchBtn.Parent = toolbar
	local treeBtn = W.Button("Tree", function()
		results.frame.Visible = false
		setMode(mode)
	end, { Size = UDim2.new(0, 60, 0, 24), LayoutOrder = 6 })
	treeBtn.Parent = toolbar
	local reloadBtn = W.Button("Reload", function()
		if mode == "client" then
			clientTree:Load()
		else
			serverTree:Load()
		end
	end, { Size = UDim2.new(0, 70, 0, 24), LayoutOrder = 7 })
	reloadBtn.Parent = toolbar

	clientTree:Load()

	return {
		Refresh = function()
			if mode == "client" then
				for _, node in clientTree.flat do
					if typeof(node.key) == "Instance" then
						node.vis = agent:VisibilityOf(node.key)
					end
				end
				clientTree:Redraw()
			end
		end,
	}
end
