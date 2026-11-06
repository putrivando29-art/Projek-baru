--[[
	RuntimeInspectorServer (Script, ServerScriptService)
	Bootstrap sisi server:
	  A. Lapisan keamanan (SELALU aktif, juga di game live):
	     AuditLog, SecureRemote, MovementValidator, CombatAuthority, Honeypot
	  B. Inspector server (aktif di Studio, atau di live bila ServerConfig.EnableInLiveGame):
	     DataModelExplorer, ScriptInspector, AssetAuditor, InstanceMonitor,
	     CharacterProfiler, NetworkMonitor, AnomalyDetector, InspectorBridge
]]

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Root = ServerStorage:WaitForChild("RuntimeInspector")
local Shared = Root:WaitForChild("Shared")
local ServerData = Root:WaitForChild("ServerData")

local Config = require(Shared.Config)
local ServerConfig = require(ServerData.ServerConfig)
local WeaponDefinitions = require(ServerData.WeaponDefinitions)
local AssetPolicy = require(ServerData.AssetPolicy)

local AuditLog = require(script.AuditLog)
local SecureRemote = require(script.Security.SecureRemote)
local MovementValidator = require(script.Security.MovementValidator)
local CombatAuthority = require(script.Security.CombatAuthority)
local Honeypot = require(script.Security.Honeypot)
local Bridge = require(script.InspectorBridge)
local API = require(script.API)

local PREFIX = Config.LogPrefix

local function loadManifest()
	-- Hasil plugin (di luar folder Rojo) lebih diutamakan daripada placeholder.
	local generated = ServerStorage:FindFirstChild("RuntimeInspectorManifest")
	for _, candidate in { generated, ServerData:FindFirstChild("StaticManifest") } do
		if candidate and candidate:IsA("ModuleScript") then
			local ok, m = pcall(require, candidate)
			if ok and type(m) == "table" then
				m.scripts = m.scripts or {}
				m.assetRefs = m.assetRefs or {}
				return m
			end
		end
	end
	return { generatedAt = nil, scripts = {}, assetRefs = {} }
end

---------------------------------------------------------------- A. keamanan

local audit = AuditLog.new(ServerConfig, Config)
local secure = SecureRemote.new(audit, ServerConfig)
local movement = MovementValidator.new(audit, ServerConfig)
local combat = CombatAuthority.new(audit, secure, ServerConfig, WeaponDefinitions)
local honeypot = Honeypot.new(audit, ServerConfig)

for name, fn in {
	MovementValidator = function()
		movement:Start()
	end,
	CombatAuthority = function()
		combat:Start()
	end,
	Honeypot = function()
		honeypot:Start()
	end,
} do
	local ok, err = pcall(fn)
	if not ok then
		warn(PREFIX .. " gagal memulai " .. name .. ": " .. tostring(err))
	end
end

API._set({
	AuditLog = audit,
	SecureRemote = secure,
	MovementValidator = movement,
	CombatAuthority = combat,
	Honeypot = honeypot,
})

---------------------------------------------------------------- B. inspector

local inspectorEnabled = RunService:IsStudio() or ServerConfig.EnableInLiveGame
if not inspectorEnabled then
	print(PREFIX .. " lapisan keamanan aktif; inspector nonaktif (game live, EnableInLiveGame=false)")
	return
end

local Explorer = require(Shared.Inspectors.DataModelExplorer)
local ScriptInspector = require(Shared.Inspectors.ScriptInspector)
local AssetAuditor = require(Shared.Inspectors.AssetAuditor)
local InstanceMonitor = require(Shared.Inspectors.InstanceMonitor)
local CharacterProfiler = require(Shared.Inspectors.CharacterProfiler)
local NetworkMonitor = require(Shared.Inspectors.NetworkMonitor)
local AnomalyDetector = require(Shared.Inspectors.AnomalyDetector)
local Timeline = require(Shared.Core.Timeline)

-- Konfigurasi efektif server: Shared Config + override Scripts dari ServerConfig.
local serverView = setmetatable({ Scripts = ServerConfig.Scripts }, { __index = Config })

local ignore = function(inst: Instance): boolean
	return Bridge.IsInspectorInstance(inst) or honeypot:IsHoneypot(inst)
end

local explorer = Explorer.new(serverView, ignore)
local timeline = Timeline.new(Config.Character.RingSize)
local scripts = ScriptInspector.new(serverView, explorer, PREFIX)
local assets = AssetAuditor.new(serverView, explorer, AssetPolicy)
local monitor = InstanceMonitor.new(serverView, explorer:ServiceRoots(), ignore, nil)
local profiler = CharacterProfiler.new(serverView, timeline)
local network = NetworkMonitor.new(serverView, explorer, timeline)
local detector = AnomalyDetector.new(serverView, audit.findings)

monitor.InstanceAdded:Connect(function(inst)
	profiler:OnInstanceAdded(inst)
	network:OnInstanceAdded(inst)
	assets:OnInstanceAdded(inst)
end)
detector:Bind({ monitor = monitor, profiler = profiler, network = network, scripts = scripts, assets = assets })

local bridge = Bridge.new({
	config = serverView,
	serverConfig = ServerConfig,
	audit = audit,
	explorer = explorer,
	scripts = scripts,
	assets = assets,
	monitor = monitor,
	profiler = profiler,
	network = network,
	timeline = timeline,
	secure = secure,
	manifest = loadManifest(),
	policy = AssetPolicy,
	clientReports = {},
})

scripts:StartErrorCapture()
explorer:Start()
monitor:Start()
profiler:Start()
network:Start()
bridge:Start()

task.spawn(function()
	local t0 = os.clock()
	assets:Scan()
	scripts:Collect()
	print(string.format("%s server siap: %d Instance, %d script, %d aset unik (%.2fs)",
		PREFIX, explorer.counts.total, #scripts.records, assets:Report().uniqueAssets, os.clock() - t0))
end)

API._set({
	Explorer = explorer,
	Timeline = timeline,
	NetworkMonitor = network,
	InstanceMonitor = monitor,
	Detector = detector,
})

game:BindToClose(function()
	bridge:Destroy()
	monitor:Destroy()
	profiler:Destroy()
	network:Destroy()
	scripts:Destroy()
	explorer:Destroy()
	detector:Destroy()
end)
