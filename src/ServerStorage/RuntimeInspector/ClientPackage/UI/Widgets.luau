--[[
	Widgets: helper pembuatan GUI. Semua elemen dibuat lewat New() agar properti
	diterapkan sebelum Parent di-set (lebih murah untuk layout engine).
]]

local Theme = require(script.Parent.Theme)
local C = Theme.Colors

local Widgets = {}

function Widgets.New(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local inst = Instance.new(className)
	local parent = nil
	for k, v in props or {} do
		if k == "Parent" then
			parent = v
		else
			(inst :: any)[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
local New = Widgets.New

function Widgets.Corner(radius: number?): UICorner
	return New("UICorner", { CornerRadius = UDim.new(0, radius or 6) }) :: UICorner
end

function Widgets.Stroke(color: Color3?, thickness: number?): UIStroke
	return New("UIStroke", { Color = color or C.Border, Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) :: UIStroke
end

function Widgets.Padding(px: number): UIPadding
	local u = UDim.new(0, px)
	return New("UIPadding", { PaddingLeft = u, PaddingRight = u, PaddingTop = u, PaddingBottom = u }) :: UIPadding
end

function Widgets.HList(padding: number?): UIListLayout
	return New("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding or 6),
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}) :: UIListLayout
end

function Widgets.VList(padding: number?): UIListLayout
	return New("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding or 4),
	}) :: UIListLayout
end

function Widgets.Label(props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextSize = Theme.TextSize,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, 20),
	}
	for k, v in props do
		base[k] = v
	end
	return New("TextLabel", base) :: TextLabel
end

function Widgets.Button(text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local base = {
		Text = text,
		Font = Theme.FontMedium,
		TextSize = Theme.TextSize,
		TextColor3 = C.Text,
		BackgroundColor3 = C.ChipOff,
		AutoButtonColor = true,
		Size = UDim2.new(0, math.max(64, #text * 8 + 20), 0, 26),
	}
	for k, v in props or {} do
		base[k] = v
	end
	local b = New("TextButton", base, { Widgets.Corner(5) }) :: TextButton
	b.Activated:Connect(function()
		local ok, err = pcall(onClick)
		if not ok then
			warn("[RuntimeInspector] UI error: " .. tostring(err))
		end
	end)
	return b
end

-- Chip toggle. setOn(bool) mengubah tampilan.
function Widgets.Chip(text: string, on: boolean, onClick: () -> ()): (TextButton, (boolean) -> ())
	local b = Widgets.Button(text, onClick, { Size = UDim2.new(0, math.max(48, #text * 7 + 18), 0, 24), TextSize = Theme.SmallText })
	local function setOn(v: boolean)
		b.BackgroundColor3 = v and C.ChipOn or C.ChipOff
		b.TextColor3 = v and C.AccentText or C.Text
	end
	setOn(on)
	return b, setOn
end

function Widgets.TextInput(placeholder: string, props: { [string]: any }?): TextBox
	local base = {
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.TextDim,
		Text = "",
		Font = Theme.Font,
		TextSize = Theme.TextSize,
		TextColor3 = C.Text,
		BackgroundColor3 = C.Input,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0, 180, 0, 26),
	}
	for k, v in props or {} do
		base[k] = v
	end
	return New("TextBox", base, { Widgets.Corner(5), Widgets.Stroke(), New("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) }) :: TextBox
end

-- Panel detail teks yang bisa di-scroll (TextLabel AutomaticSize di dalam ScrollingFrame).
function Widgets.DetailPane(parent: Instance, maxChars: number): (ScrollingFrame, (string) -> ())
	local scroll = New("ScrollingFrame", {
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.Border,
		Parent = parent,
	}, { Widgets.Corner(6), Widgets.Padding(8) }) :: ScrollingFrame
	local label = New("TextLabel", {
		BackgroundTransparency = 1,
		Font = Theme.Mono,
		TextSize = Theme.SmallText,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		RichText = false,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -4, 0, 0),
		Text = "",
		Parent = scroll,
	}) :: TextLabel
	local function setText(text: string)
		if #text > maxChars then
			text = string.sub(text, 1, maxChars) .. "\n...(dipotong " .. (#text - maxChars) .. " karakter; gunakan Export untuk data lengkap)"
		end
		label.Text = text
		scroll.CanvasPosition = Vector2.zero
	end
	return scroll, setText
end

function Widgets.SeverityColor(sev: string?): Color3
	return Theme.Severity[sev or "INFO"] or Theme.Severity.INFO
end

return Widgets
