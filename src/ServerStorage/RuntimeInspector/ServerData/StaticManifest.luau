--[[
	StaticManifest (placeholder)
	Plugin plugin/SourceAnalyzer menulis hasil analisis ke ModuleScript
	ServerStorage.RuntimeInspectorManifest (di LUAR folder yang dikelola Rojo, agar tidak
	tertimpa saat sync). Server membaca modul itu lebih dulu; file ini hanya fallback kosong.
]]

return {
	generatedAt = nil,
	scripts = {},
	assetRefs = {},
}
