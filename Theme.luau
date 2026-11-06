--[[
	Theme: token warna & tipografi dashboard. Kontras teks utama terhadap panel
	dipilih tinggi (teks terang di atas latar gelap) agar log padat tetap terbaca.
]]

local Theme = {
	Font = Enum.Font.BuilderSans,
	FontMedium = Enum.Font.BuilderSansMedium,
	FontBold = Enum.Font.BuilderSansBold,
	Mono = Enum.Font.RobotoMono,

	TextSize = 14,
	SmallText = 12,
	RowHeight = 22,

	Colors = {
		Window = Color3.fromRGB(17, 19, 24),
		Sidebar = Color3.fromRGB(23, 26, 33),
		Panel = Color3.fromRGB(28, 32, 40),
		PanelAlt = Color3.fromRGB(34, 38, 48),
		Row = Color3.fromRGB(28, 32, 40),
		RowAlt = Color3.fromRGB(32, 36, 45),
		RowSelected = Color3.fromRGB(44, 70, 110),
		Border = Color3.fromRGB(52, 58, 72),
		Text = Color3.fromRGB(232, 236, 243),
		TextDim = Color3.fromRGB(160, 168, 184),
		Accent = Color3.fromRGB(86, 156, 255),
		AccentText = Color3.fromRGB(10, 14, 22),
		Input = Color3.fromRGB(20, 23, 29),
		ChipOn = Color3.fromRGB(86, 156, 255),
		ChipOff = Color3.fromRGB(40, 45, 56),
	},

	Severity = {
		INFO = Color3.fromRGB(140, 150, 168),
		LOW = Color3.fromRGB(120, 200, 140),
		MEDIUM = Color3.fromRGB(240, 196, 80),
		HIGH = Color3.fromRGB(245, 140, 60),
		CRITICAL = Color3.fromRGB(240, 80, 90),
	},

	Visibility = {
		SERVER_ONLY = Color3.fromRGB(240, 110, 120),
		REPLICATED = Color3.fromRGB(110, 170, 255),
		OWNER_ONLY = Color3.fromRGB(190, 140, 255),
		SERVER_UNCLASSIFIED = Color3.fromRGB(150, 150, 150),
		CLIENT_UNVERIFIED = Color3.fromRGB(150, 158, 172),
		CLIENT_REPLICATED = Color3.fromRGB(120, 210, 150),
		CLIENT_LOCAL = Color3.fromRGB(250, 170, 80),
	},
}

return Theme
