--[[
	VirtualList: list ber-virtualisasi. Hanya baris yang terlihat yang dibuat/di-render,
	sehingga ribuan entri log tidak membuat ribuan GuiObject.
	opts = {
		rowHeight = 22,
		render = function(row: TextButton, item, index, selected: boolean) end,
		onSelect = function(item, index) end,
	}
]]

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)
local C = Theme.Colors

local VirtualList = {}
VirtualList.__index = VirtualList

function VirtualList.new(parent: Instance, opts: { [string]: any })
	local self = setmetatable({
		rowHeight = opts.rowHeight or Theme.RowHeight,
		render = opts.render,
		onSelect = opts.onSelect,
		items = {},
		pool = {},
		rowIndex = {},
		selectedItem = nil, -- seleksi berdasarkan identitas item (stabil saat list di-refresh)
		conns = {},
	}, VirtualList)

	self.frame = Widgets.New("ScrollingFrame", {
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Size = opts.size or UDim2.fromScale(1, 1),
		Position = opts.position or UDim2.new(),
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ClipsDescendants = true,
		Parent = parent,
	}, { Widgets.Corner(6) })

	table.insert(self.conns, self.frame:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self:_layout()
	end))
	table.insert(self.conns, self.frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end))
	return self
end

function VirtualList:_row(k: number): TextButton
	local row = self.pool[k]
	if row then
		return row
	end
	row = Widgets.New("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		BackgroundColor3 = C.Row,
		Size = UDim2.new(1, -8, 0, self.rowHeight),
		Font = Theme.Mono,
		TextSize = Theme.SmallText,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = self.frame,
	}, { Widgets.New("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) }) :: TextButton
	row.Activated:Connect(function()
		local i = self.rowIndex[row]
		if i and self.items[i] ~= nil then
			self.selectedItem = self.items[i]
			self:_layout()
			if self.onSelect then
				local ok, err = pcall(self.onSelect, self.items[i], i)
				if not ok then
					warn("[RuntimeInspector] onSelect error: " .. tostring(err))
				end
			end
		end
	end)
	self.pool[k] = row
	return row
end

function VirtualList:_layout()
	local h = self.rowHeight
	local viewport = self.frame.AbsoluteSize.Y
	local scrollY = self.frame.CanvasPosition.Y
	local first = math.max(1, math.floor(scrollY / h) + 1)
	local visibleCount = math.ceil(viewport / h) + 2
	local k = 0
	for i = first, math.min(#self.items, first + visibleCount - 1) do
		k += 1
		local row = self:_row(k)
		row.Visible = true
		row.Position = UDim2.new(0, 2, 0, (i - 1) * h)
		local selected = self.items[i] == self.selectedItem
		row.BackgroundColor3 = selected and C.RowSelected or ((i % 2 == 0) and C.RowAlt or C.Row)
		self.rowIndex[row] = i
		local ok, err = pcall(self.render, row, self.items[i], i, selected)
		if not ok then
			row.Text = "<render error> " .. tostring(err)
		end
	end
	for j = k + 1, #self.pool do
		self.pool[j].Visible = false
		self.rowIndex[self.pool[j]] = nil
	end
end

function VirtualList:SetItems(items: { any }, keepSelection: boolean?)
	self.items = items
	if not keepSelection then
		self.selectedItem = nil
	end
	self.frame.CanvasSize = UDim2.new(0, 0, 0, #items * self.rowHeight + 4)
	self:_layout()
end

function VirtualList:Selected(): any
	return self.selectedItem
end

function VirtualList:Destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
	self.frame:Destroy()
end

return VirtualList
