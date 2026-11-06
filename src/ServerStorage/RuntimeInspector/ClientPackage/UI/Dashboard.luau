--[[
	Dashboard: jendela utama (drag, minimize, toggle hotkey) dengan 9 tab.
	- Tab dibangun malas saat pertama dibuka.
	- Hanya tab aktif yang di-refresh (RefreshHz), sehingga biaya UI konstan
	  walaupun log terus bertambah.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)
local VirtualList = require(script.Parent.VirtualList)
local TreeView = require(script.Parent.TreeView)
local ListDetailView = require(script.Parent.ListDetailView)
local ExportCenter = require(script.Parent.Parent.ExportCenter)
local New, C = Widgets.New, Theme.Colors

local Dashboard = {}
Dashboard.__index = Dashboard

local TABS = {
	{ id = "overview", label = "Overview", module = "OverviewTab" },
	{ id = "explorer", label = "DataModel Explorer", module = "ExplorerTab" },
	{ id = "scripts", label = "Script Inspector", module = "ScriptsTab" },
	{ id = "assets", label = "Asset Inspector", module = "AssetsTab" },
	{ id = "runtime", label = "Runtime Monitor", module = "RuntimeTab" },
	{ id = "actions", label = "Action Profiler", module = "ActionsTab" },
	{ id = "network", label = "Network Monitor", module = "NetworkTab" },
	{ id = "security", label = "Security Audit", module = "SecurityTab" },
	{ id = "export", label = "Export Center", module = "ExportTab" },
}

function Dashboard.new(gui: ScreenGui, agent: any)
	local self = setmetatable({ gui = gui, agent = agent, tabs = {}, active = nil, alive = true, conns = {} }, Dashboard)
	self:_build()
	return self
end

function Dashboard:_build()
	local agent = self.agent
	local Config = agent.Config

	local window = New("Frame", {
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.86, 0.82),
		BackgroundColor3 = C.Window,
		Active = true,
		Visible = false,
		Parent = self.gui,
	}, {
		Widgets.Corner(10),
		Widgets.Stroke(C.Border, 1),
		New("UISizeConstraint", { MinSize = Vector2.new(720, 420), MaxSize = Vector2.new(1500, 900) }),
	})
	self.window = window

	-- title bar
	local titleBar = New("Frame", { BackgroundColor3 = C.Sidebar, Size = UDim2.new(1, 0, 0, 34), Active = true, Parent = window }, { Widgets.Corner(10) })
	Widgets.Label({ Text = "Runtime Inspector & Security Audit", Font = Theme.FontBold, TextSize = 15, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(0.5, 0, 1, 0), Parent = titleBar })
	self.statusLabel = Widgets.Label({ Text = "", TextColor3 = C.TextDim, TextSize = Theme.SmallText, TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(0.4, 0, 0, 0), Size = UDim2.new(0.6, -90, 1, 0), Parent = titleBar })
	Widgets.Button("_", function()
		self:SetVisible(false)
	end, { Size = UDim2.new(0, 28, 0, 24), Position = UDim2.new(1, -66, 0, 5), Parent = titleBar })
	Widgets.Button("X", function()
		self:SetVisible(false)
	end, { Size = UDim2.new(0, 28, 0, 24), Position = UDim2.new(1, -34, 0, 5), Parent = titleBar })

	-- drag
	local dragging, dragStart, startPos = false, nil, nil
	table.insert(self.conns, titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, window.Position
		end
	end))
	table.insert(self.conns, UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	table.insert(self.conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	-- sidebar
	local sidebar = New("Frame", { BackgroundColor3 = C.Sidebar, Position = UDim2.new(0, 0, 0, 34), Size = UDim2.new(0, 170, 1, -34), Parent = window }, {
		Widgets.Padding(8),
		Widgets.VList(4),
	})
	self.content = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 178, 0, 42), Size = UDim2.new(1, -186, 1, -50), ClipsDescendants = true, Parent = window })

	self.tabButtons = {}
	for i, tab in TABS do
		local btn = Widgets.Button(tab.label, function()
			self:Select(tab.id)
		end, { Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i, TextXAlignment = Enum.TextXAlignment.Left, BackgroundColor3 = C.Sidebar })
		New("UIPadding", { PaddingLeft = UDim.new(0, 10), Parent = btn })
		btn.Parent = sidebar
		self.tabButtons[tab.id] = btn
	end

	-- tombol kecil saat dashboard tertutup
	self.launcher = Widgets.Button("Inspector (" .. Config.ToggleKey.Name .. ")", function()
		self:SetVisible(true)
	end, { Position = UDim2.new(0, 12, 1, -40), Size = UDim2.new(0, 150, 0, 28), BackgroundColor3 = C.Accent, TextColor3 = C.AccentText, Parent = self.gui })

	table.insert(self.conns, UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Config.ToggleKey then
			self:SetVisible(not self.window.Visible)
		end
	end))

	self.ctx = {
		agent = agent,
		Config = Config,
		Theme = Theme,
		Widgets = Widgets,
		VirtualList = VirtualList,
		TreeView = TreeView,
		ListDetailView = ListDetailView,
		ExportCenter = ExportCenter,
		NetworkMonitorLib = require(agent.shared.Inspectors.NetworkMonitor),
		isStudio = RunService:IsStudio(),
	}
end

function Dashboard:SetVisible(v: boolean)
	self.window.Visible = v
	self.launcher.Visible = not v
	if v and not self.active then
		self:Select("overview")
	end
end

function Dashboard:Select(id: string)
	for tid, btn in self.tabButtons do
		btn.BackgroundColor3 = tid == id and C.RowSelected or C.Sidebar
	end
	for tid, t in self.tabs do
		t.frame.Visible = tid == id
	end
	if not self.tabs[id] then
		local def
		for _, tab in TABS do
			if tab.id == id then
				def = tab
			end
		end
		local frame = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = self.content })
		local ok, result = pcall(function()
			local builder = require(script.Parent.Tabs[def.module])
			return builder(self.ctx, frame)
		end)
		if not ok then
			Widgets.Label({ Text = "Gagal membangun tab: " .. tostring(result), TextWrapped = true, Size = UDim2.fromScale(1, 1), Parent = frame })
			result = { Refresh = function() end }
		end
		self.tabs[id] = { frame = frame, api = result }
	end
	self.active = id
	self:_refreshActive()
end

function Dashboard:_refreshActive()
	local t = self.active and self.tabs[self.active]
	if t and t.api and t.api.Refresh then
		local ok, err = pcall(t.api.Refresh)
		if not ok then
			self.statusLabel.Text = "refresh error: " .. string.sub(tostring(err), 1, 120)
		end
	end
end

function Dashboard:Start()
	self:SetVisible(false)
	local hz = self.agent.Config.UI.RefreshHz
	task.spawn(function()
		while self.alive do
			task.wait(1 / hz)
			if self.window.Visible then
				self:_refreshActive()
				local a = self.agent
				self.statusLabel.Text = string.format("%s | risk srv %d / cli %d | net %d | link %s",
					RunService:IsStudio() and "Studio" or "Live",
					a.serverFindings:RiskScore(), a.findings:RiskScore(),
					a.network.ring.count,
					a.link.available and "OK" or "OFF")
			end
		end
	end)
end

function Dashboard:Destroy()
	self.alive = false
	for _, c in self.conns do
		c:Disconnect()
	end
	self.window:Destroy()
	self.launcher:Destroy()
end

return Dashboard
