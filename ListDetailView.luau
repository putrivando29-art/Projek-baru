--[[
	ListDetailView: komponen generik "toolbar + list virtual + panel detail".
	Dipakai oleh hampir semua tab (Scripts, Assets, Runtime, Actions, Network, Security).

	spec = {
		groups = { { id = "env", options = { {id="client",label="Client"}, ... }, default = "client" }, ... },
		search = true,
		buttons = { { label = "Rescan", onClick = function(view) end } },
		getItems = function(state) -> { item } ,   -- state.env, state.<groupId>, state.search
		rowText  = function(item, state) -> string,
		rowColor = function(item, state) -> Color3?,
		detail   = function(item, state, setDetail) -> string?   (boleh memanggil setDetail async)
		header   = function(state) -> string?      -- teks ringkasan di atas list
		listWidth = 0.58,
	}
]]

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)
local VirtualList = require(script.Parent.VirtualList)
local New = Widgets.New
local C = Theme.Colors

local ListDetailView = {}
ListDetailView.__index = ListDetailView

function ListDetailView.new(parent: Instance, spec: { [string]: any }, maxDetailChars: number)
	local self = setmetatable({ spec = spec, state = { search = "" }, chipSetters = {}, selected = nil }, ListDetailView)

	local root = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = parent })
	self.root = root

	local toolbar = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = root }, { Widgets.HList(6) })
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	for _, group in spec.groups or {} do
		self.state[group.id] = group.default or (group.options[1] and group.options[1].id)
		self.chipSetters[group.id] = {}
		for _, opt in group.options do
			local chip, setOn
			chip, setOn = Widgets.Chip(opt.label, self.state[group.id] == opt.id, function()
				self.state[group.id] = opt.id
				for id, setter in self.chipSetters[group.id] do
					setter(id == opt.id)
				end
				self.view.list.selectedItem = nil
				self:Refresh()
			end)
			chip.LayoutOrder = nextOrder()
			chip.Parent = toolbar
			self.chipSetters[group.id][opt.id] = setOn
		end
		local sep = New("Frame", { BackgroundColor3 = C.Border, BorderSizePixel = 0, Size = UDim2.new(0, 1, 0, 18), LayoutOrder = nextOrder(), Parent = toolbar })
		sep.Name = "Sep"
	end

	if spec.search ~= false then
		local box = Widgets.TextInput("cari...", { Size = UDim2.new(0, 150, 0, 24), LayoutOrder = nextOrder(), Parent = toolbar })
		box.FocusLost:Connect(function()
			self.state.search = string.lower(box.Text)
			self:Refresh()
		end)
	end
	for _, b in spec.buttons or {} do
		local btn = Widgets.Button(b.label, function()
			b.onClick(self)
		end, { Size = UDim2.new(0, math.max(60, #b.label * 7 + 16), 0, 24), TextSize = Theme.SmallText, LayoutOrder = nextOrder() })
		btn.Parent = toolbar
	end

	self.headerLabel = Widgets.Label({
		Text = "",
		TextColor3 = C.TextDim,
		TextSize = Theme.SmallText,
		Position = UDim2.new(0, 0, 0, 32),
		Size = UDim2.new(1, 0, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = root,
	})

	local body = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 54), Size = UDim2.new(1, 0, 1, -54), Parent = root })
	local listW = spec.listWidth or 0.58
	local listHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(listW, -4, 1, 0), Parent = body })
	local detailHolder = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(listW, 4, 0, 0), Size = UDim2.new(1 - listW, -4, 1, 0), Parent = body })
	local _, setDetail = Widgets.DetailPane(detailHolder, maxDetailChars)
	self.setDetail = setDetail
	setDetail("Pilih baris untuk melihat detail.")

	self.view = { list = nil }
	self.view.list = VirtualList.new(listHolder, {
		render = function(row, item)
			row.Text = spec.rowText(item, self.state)
			row.TextColor3 = (spec.rowColor and spec.rowColor(item, self.state)) or C.Text
		end,
		onSelect = function(item)
			self.selected = item
			local text = spec.detail(item, self.state, function(t)
				if self.selected == item then
					setDetail(t)
				end
			end)
			if text then
				setDetail(text)
			end
		end,
	})
	return self
end

function ListDetailView:Refresh()
	local ok, items = pcall(self.spec.getItems, self.state)
	if not ok then
		self.headerLabel.Text = "Error: " .. tostring(items)
		return
	end
	local search = self.state.search
	if search ~= "" then
		local filtered = {}
		for _, item in items do
			local okText, text = pcall(self.spec.rowText, item, self.state)
			if okText and string.find(string.lower(text), search, 1, true) then
				table.insert(filtered, item)
			end
		end
		items = filtered
	end
	self.items = items
	self.view.list:SetItems(items, true)
	if self.spec.header then
		local okH, h = pcall(self.spec.header, self.state, items)
		self.headerLabel.Text = okH and (h or "") or ("header error: " .. tostring(h))
	else
		self.headerLabel.Text = #items .. " entri"
	end
end

function ListDetailView:Destroy()
	self.view.list:Destroy()
	self.root:Destroy()
end

return ListDetailView
