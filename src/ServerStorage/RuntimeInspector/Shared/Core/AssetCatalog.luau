--[[
	AssetCatalog
	Peta properti yang menyimpan referensi aset, dicek terhadap Roblox API Dump:
	- Properti ContentId biasa (Read security: None) dibaca langsung.
	- SurfaceAppearance.ColorMap/NormalMap/MetalnessMap/RoughnessMap ber-security
	  PluginSecurity (tidak bisa dibaca script runtime). Versi *Content-nya
	  (ColorMapContent, dll.) dapat dibaca, lalu diambil Uri-nya.
	- SEMUA map MaterialVariant (termasuk *Content) ber-security PluginSecurity.
	  Runtime hanya bisa mencatat keberadaan MaterialVariant; ID-nya hanya bisa
	  diambil Source Analyzer plugin di Studio.
]]

local AssetCatalog = {}

AssetCatalog.Categories = table.freeze({
	"AnimationId", "SoundId", "MeshId", "TextureId", "Image", "Decal",
	"ShirtTemplate", "PantsTemplate", "Video", "ParticleTexture",
	"SurfaceAppearance", "MaterialVariant", "Sky", "Other",
})

-- { className (IsA), property, category, isContent }
AssetCatalog.Map = {
	{ "Animation", "AnimationId", "AnimationId" },
	{ "Sound", "SoundId", "SoundId" },
	{ "AudioPlayer", "Asset", "SoundId" },
	{ "MeshPart", "MeshId", "MeshId" },
	{ "MeshPart", "TextureID", "TextureId" },
	{ "FileMesh", "MeshId", "MeshId" }, -- SpecialMesh mewarisi FileMesh
	{ "FileMesh", "TextureId", "TextureId" },
	{ "Decal", "Texture", "Decal" }, -- Texture (kelas) mewarisi Decal
	{ "ImageLabel", "Image", "Image" },
	{ "ImageButton", "Image", "Image" },
	{ "ImageButton", "HoverImage", "Image" },
	{ "ImageButton", "PressedImage", "Image" },
	{ "BackpackItem", "TextureId", "Image" }, -- ikon Tool
	{ "Shirt", "ShirtTemplate", "ShirtTemplate" },
	{ "Pants", "PantsTemplate", "PantsTemplate" },
	{ "ShirtGraphic", "Graphic", "ShirtTemplate" },
	{ "VideoFrame", "Video", "Video" },
	{ "ParticleEmitter", "Texture", "ParticleTexture" },
	{ "Beam", "Texture", "ParticleTexture" },
	{ "Trail", "Texture", "ParticleTexture" },
	{ "SurfaceAppearance", "ColorMapContent", "SurfaceAppearance", true },
	{ "SurfaceAppearance", "NormalMapContent", "SurfaceAppearance", true },
	{ "SurfaceAppearance", "MetalnessMapContent", "SurfaceAppearance", true },
	{ "SurfaceAppearance", "RoughnessMapContent", "SurfaceAppearance", true },
	{ "Sky", "SkyboxBk", "Sky" },
	{ "Sky", "SkyboxDn", "Sky" },
	{ "Sky", "SkyboxFt", "Sky" },
	{ "Sky", "SkyboxLf", "Sky" },
	{ "Sky", "SkyboxRt", "Sky" },
	{ "Sky", "SkyboxUp", "Sky" },
	{ "Sky", "SunTextureId", "Sky" },
	{ "Sky", "MoonTextureId", "Sky" },
}

-- Peta ClassName -> daftar entri, dibangun malas (cache per ClassName).
local byClassCache: { [string]: { any } } = {}

local function entriesFor(inst: Instance): { any }
	local cached = byClassCache[inst.ClassName]
	if cached then
		return cached
	end
	local list = {}
	for _, e in AssetCatalog.Map do
		local ok, isA = pcall(inst.IsA, inst, e[1])
		if ok and isA then
			table.insert(list, e)
		end
	end
	byClassCache[inst.ClassName] = list
	return list
end

--[[
	Parse(str) -> key, kind
	kind: "asset"     ID aset ter-upload (rbxassetid://, ?id=, angka murni, rbxthumb)
	      "engine"    rbxasset:// konten bawaan klien Roblox (bukan aset upload)
	      "url"       http(s) URL lain
	      "other"
]]
function AssetCatalog.Parse(s: any): (string?, string?)
	if type(s) ~= "string" or s == "" then
		return nil, nil
	end
	local id = string.match(s, "rbxassetid://(%d+)")
		or string.match(s, "[?&][iI][dD]=(%d+)")
		or string.match(s, "^%s*(%d+)%s*$")
	if id then
		return id, "asset"
	end
	if string.match(s, "^rbxasset://") then
		return s, "engine"
	end
	if string.match(s, "^https?://") then
		return s, "url"
	end
	return s, "other"
end

local function contentUri(value: any): string?
	if typeof(value) ~= "Content" then
		return nil
	end
	local ok, uri = pcall(function()
		return (value :: any).Uri
	end)
	if ok and type(uri) == "string" and uri ~= "" then
		return uri
	end
	return nil
end

--[[
	Scan(inst) -> array referensi { category, property, raw, key, kind }
	Mengembalikan juga entri "unreadable" bila properti gagal dibaca.
]]
function AssetCatalog.Scan(inst: Instance): { any }
	local out = {}
	local entries = entriesFor(inst)
	for _, e in entries do
		local prop, category, isContent = e[2], e[3], e[4]
		local ok, value = pcall(function()
			return (inst :: any)[prop]
		end)
		if ok then
			local raw = if isContent then contentUri(value) else value
			local key, kind = AssetCatalog.Parse(raw)
			if key then
				table.insert(out, { category = category, property = prop, raw = raw, key = key, kind = kind })
			end
		else
			table.insert(out, { category = category, property = prop, unreadable = true, error = tostring(value) })
		end
	end
	if inst.ClassName == "MaterialVariant" then
		table.insert(out, {
			category = "MaterialVariant",
			property = "(ColorMap/NormalMap/...)",
			unreadable = true,
			error = "PluginSecurity: map MaterialVariant hanya bisa dibaca plugin Studio (Source Analyzer)",
		})
	end
	return out
end

function AssetCatalog.HasAssetProperties(inst: Instance): boolean
	return #entriesFor(inst) > 0 or inst.ClassName == "MaterialVariant"
end

return AssetCatalog
