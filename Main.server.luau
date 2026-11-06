--[[
	Plugin Studio: RuntimeInspector Source Analyzer
	Build dengan Rojo:  rojo build plugin.project.json --plugin RuntimeInspectorAnalyzer.rbxm
	Manual: letakkan modul SourceAnalyzer sebagai child Script ini, klik kanan Script ->
	"Save as Local Plugin...".
]]

local module = script:FindFirstChild("SourceAnalyzer") or (script.Parent and script.Parent:FindFirstChild("SourceAnalyzer"))
if not module then
	warn("[RuntimeInspector] SourceAnalyzer module tidak ditemukan di plugin")
	return
end
local SourceAnalyzer = require(module)
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local toolbar = plugin:CreateToolbar("Runtime Inspector")
local button = toolbar:CreateButton("AnalyzeSources", "Analisis Source semua script + map aset PluginSecurity, tulis ServerStorage.RuntimeInspectorManifest", "", "Analyze Sources")
button.ClickableWhenViewportHidden = true

button.Click:Connect(function()
	local recording = ChangeHistoryService:TryBeginRecording("RuntimeInspectorManifest", "Generate RuntimeInspector manifest")
	local ok, err = pcall(SourceAnalyzer.Run)
	if recording then
		ChangeHistoryService:FinishRecording(recording, ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
	if not ok then
		warn("[RuntimeInspector] SourceAnalyzer gagal: " .. tostring(err))
	end
end)
