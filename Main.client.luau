--[[
	Main (LocalScript)
	Hanya berjalan bila diletakkan server di dalam ScreenGui RuntimeInspectorGui pada
	PlayerGui pemain terotorisasi. Di ServerStorage, LocalScript tidak berjalan.
]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local gui = script:FindFirstAncestorOfClass("ScreenGui")
if not gui or not gui:IsDescendantOf(player) then
	return
end

local shared = gui:WaitForChild("Shared", 30)
if not shared then
	warn("[RuntimeInspector] folder Shared tidak ditemukan di " .. gui:GetFullName())
	return
end

local ok, err = pcall(function()
	local ClientAgent = require(script.Parent.ClientAgent)
	local Dashboard = require(script.Parent.UI.Dashboard)

	local agent = ClientAgent.new(gui, shared)
	agent:Start()
	local dashboard = Dashboard.new(gui, agent)
	dashboard:Start()

	gui.Destroying:Connect(function()
		dashboard:Destroy()
		agent:Destroy()
	end)
end)
if not ok then
	warn("[RuntimeInspector] gagal memulai dashboard: " .. tostring(err))
end
